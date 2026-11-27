import SwiftUI

// MARK: - 加载状态

enum SourceLoadPhase<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var errorText: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

// MARK: - 源代码浏览器（目录下钻）

struct SourceBrowserView: View {
    let path: String
    @State private var ref: String

    init(path: String = "", ref: String = SourceBrowserService.defaultRef) {
        self.path = path
        _ref = State(initialValue: ref)
    }

    private let service = SourceBrowserService.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var entriesPhase: SourceLoadPhase<[SourceEntry]> = .loading
    @State private var commitsPhase: SourceLoadPhase<[SourceCommit]> = .loading
    @State private var meta: SourceRepoMeta?
    @State private var tags: [String] = []
    @State private var filter = ""

    private var isRoot: Bool { path.isEmpty }

    private var currentFolderName: String {
        (path as NSString).lastPathComponent
    }

    private var refOptions: [String] {
        var options = [SourceBrowserService.defaultRef]
        for tag in tags where !options.contains(tag) {
            options.append(tag)
        }
        return options
    }

    var body: some View {
        List {
            if isRoot { repoSection }
            if isRoot { latestCommitSection }
            entriesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isRoot ? "source_browser".localized : currentFolderName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Link(destination: SourceBrowserService.repoWebURL) {
                    Image(systemName: "safari")
                        .font(.system(size: 15, weight: .semibold))
                }
                .accessibilityLabel("source_browser_open_github".localized)
            }
        }
        .refreshable {
            await refresh()
        }
        .task(id: "\(ref)#\(path)") {
            await loadEntries()
            if isRoot {
                await loadLatestCommit()
                await loadTags()
                await loadMeta()
            }
        }
    }

    private func refresh() async {
        if isRoot {
            await loadMeta(force: true)
            await loadLatestCommit(force: true)
        }
        await loadEntries(force: true)
    }

    // MARK: 根部：仓库信息 + ref 切换

    @ViewBuilder
    private var repoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(themeAccent)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(SourceBrowserService.repoOwner)/\(SourceBrowserService.repoName)")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                        Text(SourceBrowserService.repoWebURL.absoluteString)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    refMenu
                }

                if let description = meta?.repoDescription, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 40)
                }

                if let meta {
                    HStack(spacing: 14) {
                        statItem(icon: "star.fill", value: "\(meta.stars)", color: .yellow)

                        statItem(icon: "arrow.triangle.branch", value: "\(meta.forks)", color: .secondary)

                        if let language = meta.language, !language.isEmpty {
                            Text(language)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        if let pushedAt = meta.pushedAt {
                            Spacer(minLength: 0)
                            Text(service.relativeDate(pushedAt))
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.leading, 40)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var refMenu: some View {
        Menu {
            ForEach(refOptions, id: \.self) { option in
                Button {
                    ref = option
                } label: {
                    Label(option, systemImage: option == ref ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(ref)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Image(systemName: "chevron.up.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(themeAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(themeAccent.opacity(0.12)))
        }
    }

    private func statItem(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 根部：最新提交

    @ViewBuilder
    private var latestCommitSection: some View {
        Section("source_browser_latest_commit".localized) {
            switch commitsPhase {
            case .loading:
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 180, height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 120, height: 10)
                    }
                }
                .shimmering()
                .padding(.vertical, 4)
            case .failed:
                EmptyView()
            case .loaded(let commits):
                if let latest = commits.first {
                    HStack(alignment: .top, spacing: 10) {
                        SourceCommitAvatar(url: latest.avatarURL, size: 28)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(latest.title)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(3)

                            HStack(spacing: 6) {
                                Text(latest.shortSha)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(themeAccent)
                                Text(latest.author)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(service.relativeDate(latest.date))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    NavigationLink(destination: SourceCommitsView(ref: ref)) {
                        Text("source_browser_recent_commits".localized)
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                    }
                }
            }
        }
    }

    // MARK: 目录列表

    @ViewBuilder
    private var entriesSection: some View {
        Section {
            switch entriesPhase {
            case .loading:
                VStack(spacing: 16) {
                    ForEach(0..<6, id: \.self) { index in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 22, height: 22)

                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: [136, 92, 156, 108, 76, 122][index], height: 13)

                            Spacer(minLength: 0)

                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 44, height: 10)
                        }
                    }
                }
                .shimmering()
                .padding(.vertical, 6)

            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        Task { await loadEntries() }
                    } label: {
                        Text("source_browser_retry".localized)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(themeAccent)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(themeAccent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)

            case .loaded(let entries):
                if entries.isEmpty {
                    Text("source_browser_empty_dir".localized)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else {
                    if entries.count >= 8 {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            TextField("source_browser_filter".localized, text: $filter)
                                .font(.system(size: 14))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .padding(.vertical, 2)
                    }

                    ForEach(filteredEntries(entries)) { entry in
                        entryRow(entry)
                    }
                }
            }
        } header: {
            if !isRoot {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .textCase(nil)
            }
        }
    }

    private func filteredEntries(_ entries: [SourceEntry]) -> [SourceEntry] {
        guard !filter.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    @ViewBuilder
    private func entryRow(_ entry: SourceEntry) -> some View {
        if entry.isDirectory {
            NavigationLink(destination: SourceBrowserView(path: entry.path, ref: ref)) {
                entryLabel(entry)
            }
        } else {
            NavigationLink(destination: SourceFileViewerView(path: entry.path, ref: ref)) {
                entryLabel(entry)
            }
        }
    }

    private func entryLabel(_ entry: SourceEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: service.icon(for: entry))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(entry.isDirectory ? Color.blue : Color.secondary)
                .frame(width: 24)

            Text(entry.name)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if !entry.isDirectory {
                Text(service.formattedSize(entry.size))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var themeAccent: Color {
        themeManager.accentColor
    }

    // MARK: 加载

    private func loadEntries(force: Bool = false) async {
        let hasContent: Bool = {
            if case .loaded = entriesPhase { return true }
            return false
        }()
        if hasContent && !force { return }
        if !hasContent { entriesPhase = .loading }
        do {
            let entries = try await service.fetchDirectory(path, ref: ref, force: force)
            entriesPhase = .loaded(entries)
        } catch {
            if !hasContent {
                entriesPhase = .failed(error.localizedDescription)
            }
        }
    }

    private func loadLatestCommit(force: Bool = false) async {
        do {
            let commits = try await service.fetchCommits(ref: ref, force: force)
            commitsPhase = .loaded(commits)
        } catch {
            if case .loaded = commitsPhase { return }
            commitsPhase = .failed(error.localizedDescription)
        }
    }

    private func loadMeta(force: Bool = false) async {
        meta = try? await service.fetchRepoMeta(force: force)
    }

    private func loadTags() async {
        tags = (try? await service.fetchTags()) ?? []
    }
}

// MARK: - 最近提交列表

struct SourceCommitsView: View {
    let ref: String

    private let service = SourceBrowserService.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var phase: SourceLoadPhase<[SourceCommit]> = .loading
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                switch phase {
                case .loading:
                    VStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 88)
                        }
                    }
                    .shimmering()
                    .padding(.top, 8)

                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            Task { await load() }
                        } label: {
                            Text("source_browser_retry".localized)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(themeManager.accentColor)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(themeManager.accentColor.opacity(0.12)))
                        }
                    }
                    .padding(.top, 60)

                case .loaded(let commits):
                    if commits.isEmpty {
                        Text("source_browser_empty_dir".localized)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .padding(.top, 60)
                    }
                    ForEach(commits) { commit in
                        commitRow(commit)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("source_browser_recent_commits".localized)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ref) { await load() }
    }

    private func commitRow(_ commit: SourceCommit) -> some View {
        Button {
            openURL(SourceBrowserService.commitWebURL(sha: commit.sha))
        } label: {
            HStack(alignment: .top, spacing: 10) {
                SourceCommitAvatar(url: commit.avatarURL, size: 30)

                VStack(alignment: .leading, spacing: 8) {
                    Text(commit.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)

                    HStack(spacing: 6) {
                        Text(commit.shortSha)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(themeManager.accentColor)

                        Text(commit.author)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text(service.relativeDate(commit.date))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        phase = .loading
        do {
            phase = .loaded(try await service.fetchCommits(ref: ref))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - 提交作者头像

struct SourceCommitAvatar: View {
    let url: URL?
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .foregroundStyle(Color.primary.opacity(0.25))
    }
}
