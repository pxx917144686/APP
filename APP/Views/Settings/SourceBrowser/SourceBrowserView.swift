import SwiftUI

enum SourceLoadPhase<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var errorText: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

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
    @State private var filter = ""

    private var isRoot: Bool { path.isEmpty }

    private var currentFolderName: String {
        (path as NSString).lastPathComponent
    }

    var body: some View {
        List {
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
        }
    }

    private func refresh() async {
        await loadEntries(force: true)
    }

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

}
