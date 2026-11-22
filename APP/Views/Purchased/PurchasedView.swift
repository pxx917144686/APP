import SwiftUI
import Combine

struct PurchasedView: View {
    /// 非空时表示以 sheet 形式呈现：保留导航栏，由外层放关闭按钮。
    var onClose: (() -> Void)? = nil

    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject private var downloadManager = UnifiedDownloadManager.shared
    @State private var apps: [OwnedApp] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var query = ""

    private var filtered: [OwnedApp] {
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop()
                .environmentObject(themeManager)
                .ignoresSafeArea()

            Group {
            if let account = appStore.selectedAccount {
                content(account: account)
            } else {
                hint("please_login_first".localized, systemImage: "person.crop.circle.badge.exclamationmark")
            }
        }
        .toolbar(onClose == nil ? .hidden : .visible, for: .navigationBar)
            .task(id: appStore.selectedAccount?.email) {
                if let account = appStore.selectedAccount {
                    await load(account)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)

            TextField("purchased_search_placeholder".localized, text: $query)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("clear".localized)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func content(account: Account) -> some View {
        if isLoading && apps.isEmpty {
            ProgressView("purchased_syncing".localized)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 44)).foregroundColor(.secondary)
                Text(errorText).multilineTextAlignment(.center).foregroundColor(.secondary)
                Button("retry".localized) { Task { await load(account, force: true) } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if apps.isEmpty {
            hint("purchased_empty".localized, systemImage: "bag")
        } else {
            VStack(spacing: 0) {
                searchField

                if filtered.isEmpty {
                    hint("no_results".localized, systemImage: "magnifyingglass")
                } else {
                    List(filtered) { app in
                        row(app)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.immediately)
                    .refreshable { await load(account, force: true) }
                }
            }
        }
    }

    private func row(_ app: OwnedApp) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: app.iconURL) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Color.gray.opacity(0.2)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.body).lineLimit(1)
                Text(app.bundleID).font(.caption).foregroundColor(.secondary).lineLimit(1)
                if !app.version.isEmpty {
                    Text("v\(app.version)").font(.caption2).foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 8)

            if isDownloading(app) {
                ProgressView()
                    .frame(width: 64)
            } else {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    download(app)
                } label: {
                    Text("download".localized)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("download".localized)
            }
        }
        .contentShape(Rectangle())
    }

    private func load(_ account: Account, force: Bool = false) async {
        if isLoading { return }
        isLoading = true
        errorText = nil

        let key = account.dsPersonId

        if !force, let cached = PurchasedListCache.shared.list(for: key), !cached.isEmpty {
            apps = cached
            isLoading = false
            return
        }

        do {
            var list = try await PurchaseHistoryService.ownedApps(account: account)
            AppDirectory.shared.record(owned: list)
            for index in list.indices {
                if let url = PurchasedIconCache.shared.icon(for: list[index].id) {
                    list[index].iconURL = url
                }
            }
            apps = list
            PurchasedListCache.shared.store(list, for: key)

            let country = account.countryCode.isEmpty ? "cn" : account.countryCode.lowercased()
            let resolved = await resolveIcons(list, country: country)
            apps = resolved
            PurchasedListCache.shared.store(resolved, for: key)
            PurchasedIconCache.shared.flush()
            isLoading = false
        } catch {
            if apps.isEmpty { errorText = error.localizedDescription }
            isLoading = false
        }
    }

    private func resolveIcons(_ list: [OwnedApp], country: String) async -> [OwnedApp] {
        var result = list
        var missing = result.indices.filter { result[$0].iconURL == nil }
        guard !missing.isEmpty else { return result }

        let passes = country.lowercased() == "us" ? ["us"] : [country.lowercased(), "us"]
        for pass in passes {
            let ids = missing.compactMap { Int(result[$0].id) }
            guard !ids.isEmpty else { break }
            let found = await Self.lookupIcons(ids: ids, country: pass)
            guard !found.isEmpty else { continue }
            for index in missing {
                guard let url = found[result[index].id] else { continue }
                result[index].iconURL = url
                PurchasedIconCache.shared.store(url, for: result[index].id)
            }
            missing = result.indices.filter { result[$0].iconURL == nil }
            if missing.isEmpty { break }
        }
        return result
    }

    private static func lookupIcons(ids: [Int], country: String) async -> [String: URL] {
        guard !ids.isEmpty else { return [:] }
        let chunks = stride(from: 0, to: ids.count, by: 100).map {
            Array(ids[$0..<min($0 + 100, ids.count)])
        }
        return await withTaskGroup(of: [String: URL].self) { group in
            for chunk in chunks {
                group.addTask { await fetchIconChunk(chunk, country: country) }
            }
            var merged: [String: URL] = [:]
            for await part in group {
                merged.merge(part) { _, new in new }
            }
            return merged
        }
    }

    private static func fetchIconChunk(_ ids: [Int], country: String) async -> [String: URL] {
        let joined = ids.map(String.init).joined(separator: ",")
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(joined)&country=\(country)&entity=software"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [:] }
        var map: [String: URL] = [:]
        for item in results {
            guard let trackId = item["trackId"] as? Int,
                  let artwork = item["artworkUrl100"] as? String else { continue }
            let large = artwork.replacingOccurrences(of: "100x100bb", with: "512x512bb")
            if let parsed = URL(string: large) ?? URL(string: artwork) {
                map[String(trackId)] = parsed
            }
        }
        return map
    }

    private func download(_ app: OwnedApp) {
        guard let idInt = Int(app.id) else { return }
        let downloadId = UnifiedDownloadManager.shared.addDownload(
            bundleIdentifier: app.bundleID,
            name: app.name,
            version: app.version.isEmpty ? "latest" : app.version,
            identifier: idInt,
            iconURL: app.iconURL?.absoluteString,
            versionId: nil
        )
        if let request = UnifiedDownloadManager.shared.downloadRequests.first(where: { $0.id == downloadId }) {
            UnifiedDownloadManager.shared.startDownload(for: request)
        }
    }

    private func isDownloading(_ app: OwnedApp) -> Bool {
        downloadManager.downloadRequests.contains { request in
            request.bundleIdentifier == app.bundleID &&
            (request.runtime.status == .waiting || request.runtime.status == .downloading || request.runtime.status == .paused)
        }
    }

    private func hint(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage).font(.system(size: 48)).foregroundColor(.secondary)
            Text(text).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class PurchasedListCache: @unchecked Sendable {
    static let shared = PurchasedListCache()
    private let lock = NSLock()
    private var lists: [String: [OwnedApp]] = [:]
    private let maxAge: TimeInterval = 24 * 60 * 60

    private func diskKey(_ key: String) -> String { "purchased_\(key)" }

    func list(for key: String) -> [OwnedApp]? {
        lock.lock()
        if let hit = lists[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let persisted = DiskCache.shared.read([OwnedApp].self, key: diskKey(key), maxAge: maxAge),
              !persisted.isEmpty else { return nil }
        lock.lock(); lists[key] = persisted; lock.unlock()
        return persisted
    }

    func store(_ apps: [OwnedApp], for key: String) {
        guard !apps.isEmpty else { return }
        lock.lock(); lists[key] = apps; lock.unlock()
        DiskCache.shared.write(apps, key: diskKey(key))
    }

}

final class PurchasedIconCache: @unchecked Sendable {
    static let shared = PurchasedIconCache()
    private let lock = NSLock()
    private var icons: [String: String] = [:]
    private var dirty = false
    private let fileURL: URL

    private init() {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = directory.appendingPathComponent("purchased_icons.json")
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            icons = stored
        }
    }

    func icon(for id: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return icons[id].flatMap(URL.init(string:))
    }

    func store(_ url: URL, for id: String) {
        let value = url.absoluteString
        lock.lock()
        if icons[id] != value {
            icons[id] = value
            dirty = true
        }
        lock.unlock()
    }

    func flush() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        dirty = false
        let snapshot = icons
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
