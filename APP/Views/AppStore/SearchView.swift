import SwiftUI
import UIKit

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct UIKitTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var onEditingChanged: ((Bool) -> Void)?
    var onCommit: (() -> Void)?
    var onTextChange: ((String) -> Void)?

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 34))
        textField.placeholder = placeholder
        textField.font = .systemFont(ofSize: 17)
        textField.textColor = .label
        textField.clearButtonMode = .never
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.returnKeyType = .search
        textField.enablesReturnKeyAutomatically = true
        textField.delegate = context.coordinator
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.required, for: .vertical)
        textField.setContentHuggingPriority(.required, for: .vertical)
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if uiView.placeholder != placeholder {
            uiView.placeholder = placeholder
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: UIKitTextField

        init(_ parent: UIKitTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            let newText = textField.text ?? ""
            if parent.text != newText {
                parent.text = newText
                parent.onTextChange?(newText)
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onEditingChanged?(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onEditingChanged?(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onCommit?()
            textField.resignFirstResponder()
            return true
        }
    }
}

struct SearchTimeoutError: Error {}

final class SearchResultCache: @unchecked Sendable {
    static let shared = SearchResultCache()
    private let lock = NSLock()
    private var memory: [String: [iTunesSearchResult]] = [:]
    private var order: [String] = []
    private let maxEntries = 40
    private let maxAge: TimeInterval = 2 * 60 * 60

    func get(_ key: String) -> [iTunesSearchResult]? {
        lock.lock()
        if let hit = memory[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let persisted = DiskCache.shared.read([iTunesSearchResult].self, key: "search_\(key)", maxAge: maxAge),
              !persisted.isEmpty else { return nil }
        lock.lock(); memory[key] = persisted; lock.unlock()
        return persisted
    }

    func set(_ results: [iTunesSearchResult], for key: String) {
        guard !results.isEmpty else { return }

        lock.lock()
        memory[key] = results
        order.removeAll { $0 == key }
        order.append(key)
        var evicted: [String] = []
        while order.count > maxEntries {
            let old = order.removeFirst()
            memory.removeValue(forKey: old)
            evicted.append(old)
        }
        lock.unlock()

        DiskCache.shared.write(results, key: "search_\(key)")
        for old in evicted { DiskCache.shared.remove(key: "search_\(old)") }
    }

}

final class VersionListCache: @unchecked Sendable {
    static let shared = VersionListCache()
    private let lock = NSLock()
    private var storage: [Int: [StoreAppVersion]] = [:]
    private let maxAge: TimeInterval = 6 * 60 * 60

    private func diskKey(_ trackId: Int) -> String { "versions_\(trackId)" }

    static func isUsable(_ versions: [StoreAppVersion]) -> Bool {
        versions.count > 1 || versions.contains { !$0.versionId.isEmpty }
    }

    func get(_ trackId: Int) -> [StoreAppVersion]? {
        lock.lock()
        if let hit = storage[trackId] {
            lock.unlock()
            return Self.isUsable(hit) ? hit : nil
        }
        lock.unlock()

        guard let persisted = DiskCache.shared.read([StoreAppVersion].self, key: diskKey(trackId), maxAge: maxAge),
              Self.isUsable(persisted) else { return nil }
        lock.lock(); storage[trackId] = persisted; lock.unlock()
        return persisted
    }

    func set(_ versions: [StoreAppVersion], for trackId: Int) {
        guard Self.isUsable(versions) else { return }
        lock.lock(); storage[trackId] = versions; lock.unlock()
        DiskCache.shared.write(versions, key: diskKey(trackId))
    }

}

func withTimeout<T>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in

        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SearchTimeoutError()
        }

        defer { group.cancelAll() }

        guard let result = try await group.next() else { throw SearchTimeoutError() }
        return result
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        y += rowHeight
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

final class ScrollVelocityTracker: ObservableObject {
    private var lastOffset: CGFloat = 0
    private var lastTime = Date()
    @Published var isFast = false

    func update(offset: CGFloat, threshold: CGFloat = 800) {
        let now = Date()
        let timeDiff = now.timeIntervalSince(lastTime)
        if timeDiff > 0 {
            let velocity = abs(offset - lastOffset) / timeDiff
            let fast = velocity > threshold
            if fast != isFast { isFast = fast }
        }
        lastOffset = offset
        lastTime = now
    }
}

struct SearchView: SwiftUI.View {

    @AppStorage("searchKey") var searchKey = ""
    @AppStorage("searchHistory") var searchHistoryData = Data()
    @FocusState var searchKeyFocused
    @State var searchType = DeviceFamily.phone
    @EnvironmentObject var themeManager: ThemeManager

    private var searchBarBackgroundColor: Color {
        themeManager.liquidGlassEnabled ? Color.primary.opacity(0.06) : Color(.systemGray6)
    }
    @EnvironmentObject var appStore: AppStore
    @StateObject private var sessionManager = SessionManager.shared
    @State var searching = false

    @State var showLoginSheet = false
    @State var showAccountSheet = false
    @State private var showPurchasedSheet = false
    @State var showDirectSheet = false
    @State var directInput = ""

    @State var isDownloading = false

    @State var purchasingTrackId: Int?
    @State private var purchasedTrackIds: Set<Int> = []

    @State var searchResult: [iTunesSearchResult] = []
    @State var legacyResults: [iTunesSearchResult] = []
    private let pageSize = 50
    @State var searchHistory: [String] = []
    @State var searchError: String? = nil
    @State var searchSuggestions: [String] = []
    @State var isFetchingSuggestions: Bool = false
    @State var showSearchSuggestions = false
    @StateObject private var suggestionsDebounce = Debounce(delay: 0.1)
    private let searchSuggestionsCache = LRUCache<String, [String]>(capacity: 50)
    @StateObject var vm = AppStore.this
    @State private var animateLogo = false
    @StateObject private var scrollTracker = ScrollVelocityTracker()

    @State var showVersionPicker = false
    @State var selectedApp: iTunesSearchResult?
    @State var availableVersions: [StoreAppVersion] = []
    @State var versionHistory: [iTunesClient.AppVersionInfo] = []

    @State private var showPurchaseAlert: Bool = false
    @State private var purchaseAlertText: String = ""
    @State var isLoadingVersions = false
    @State var versionError: String?
    var body: some SwiftUI.View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdrop()
                    .environmentObject(themeManager)
                    .ignoresSafeArea()

                VStack(spacing: 0) {

                    modernSearchBar
                        .padding(.horizontal, 16)
                        .background(themeManager.backgroundColor)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            searchResultsSection
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(
                            GeometryReader { geometry in
                                Color.clear
                                    .preference(key: ScrollOffsetPreferenceKey.self, value: geometry.frame(in: .named("scroll")).origin.y)
                            }
                        )
                        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                            scrollTracker.update(offset: value)
                        }
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .coordinateSpace(name: "scroll")
                    .refreshable {
                        if !searchKey.isEmpty {
                            await performSearch()
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showVersionPicker) {
                versionPickerSheet
                    .environmentObject(appStore)
                    .environmentObject(themeManager)
            }
            .sheet(isPresented: $showPurchasedSheet) {
                NavigationView {
                    PurchasedView(onClose: { showPurchasedSheet = false })
                        .environmentObject(appStore)
                        .environmentObject(themeManager)
                        .navigationTitle("tab_purchased".localized)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("done".localized) { showPurchasedSheet = false }
                            }
                        }
                }
                .navigationViewStyle(.stack)
            }
            .sheet(isPresented: $showAccountSheet) {
                AccountSheetView()
                    .environmentObject(appStore)
                    .environmentObject(themeManager)
            }
            .sheet(isPresented: $showDirectSheet) {
                directEntrySheet
                    .environmentObject(appStore)
                    .environmentObject(themeManager)
            }
            .sheet(isPresented: $showLoginSheet) {
                AddAccountView()
                    .environmentObject(appStore)
                    .environmentObject(themeManager)
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            loadSearchHistory()
            sessionManager.startSessionMonitoring()
            animateLogo = true
            if let autoTerm = UserDefaults.standard.string(forKey: "autoSearch"), !autoTerm.isEmpty {
                UserDefaults.standard.removeObject(forKey: "autoSearch")
                searchKey = autoTerm
                Task { await performSearch() }
            }
        }
        .onDisappear {

            sessionManager.stopSessionMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ForceRefreshUI"))) { _ in
            animateLogo = true
        }
        .alert("tips".localized, isPresented: $showPurchaseAlert) {
            Button("got_it".localized, role: .cancel) {}
        } message: {
            Text(purchaseAlertText)
        }
    }

    var modernSearchBar: some SwiftUI.View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)
                UIKitTextField(
                    text: $searchKey,
                    placeholder: "search_placeholder".localized,
                    onEditingChanged: { isFocused in
                        searchKeyFocused = isFocused
                        if isFocused, !searchKey.isEmpty {
                            showSearchSuggestions = true
                            searchSuggestions = getSearchSuggestions(for: searchKey)
                            if let cached = searchSuggestionsCache.value(forKey: searchKey) {
                                let combined = Array(Set((searchSuggestions + cached))).sorted()
                                searchSuggestions = combined
                            }
                        }
                    },
                    onCommit: {
                        showSearchSuggestions = false
                        Task {
                            await performSearch()
                        }
                    },
                    onTextChange: { newValue in
                        if !newValue.isEmpty {
                            showSearchSuggestions = true

                            searchSuggestions = getSearchSuggestions(for: newValue)

                            if let cached = searchSuggestionsCache.value(forKey: newValue) {
                                let combined = Array(Set((searchSuggestions + cached))).sorted()
                                searchSuggestions = combined
                            }

                            suggestionsDebounce.execute {
                                Task { await fetchRemoteSuggestions(for: newValue) }
                            }
                        } else {
                            suggestionsDebounce.cancel()
                            showSearchSuggestions = false
                            searchSuggestions = []
                        }
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                if !searchKey.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            searchKey = ""
                            searchResult = []
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("clear".localized)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(searchBarBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        searchKeyFocused ? themeManager.accentColor : Color.clear,
                        lineWidth: 2
                    )
            )
            .padding(.top, 8)

            HStack(spacing: 8) {

                Menu {
                    ForEach(DeviceFamily.allCases, id: \.self) { type in
                        Button {
                            searchType = type
                        } label: {
                            HStack {
                                Image(systemName: "iphone")
                                Text(type.displayName)
                                if searchType == type {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone")
                            .font(.system(size: 14, weight: .medium))
                        Text(searchType.displayName)
                            .font(.caption)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(themeManager.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(themeManager.accentColor.opacity(0.1))
                    )
                }

                Spacer()

                Button(action: {
                    showDirectSheet = true
                }) {
                    Text("delisted_apps_short".localized)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(themeManager.accentColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(themeManager.accentColor.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("legacy_apps_delisted".localized)

                Spacer()

                Button(action: {
                    showPurchasedSheet = true
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "bag.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("tab_purchased".localized)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(themeManager.accentColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(themeManager.accentColor.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("tab_purchased".localized)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    var searchResultsSection: some SwiftUI.View {
        VStack(spacing: 16) {
            if !searchResult.isEmpty {

                currentAccountIndicator

                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: "x_results_found".localized, String(searchResult.count)))
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                    Spacer()

                }
                .padding(.horizontal, 16)
            }

            if let error = searchError {
                searchErrorView(error: error)
            } else if searching {
                searchingIndicator
            } else if searchResult.isEmpty {
                if legacyResults.isEmpty {
                    emptyStateView
                } else {
                    legacyResultsSection
                }
            } else {
                searchResultsGrid
                if !legacyResults.isEmpty { legacyResultsSection }
            }
        }
    }

    var legacyResultsSection: some SwiftUI.View {
        VStack(spacing: 16) {
            HStack {
                Text("legacy_apps_delisted".localized)
                    .font(.title3.bold())
                    .foregroundColor(.primary)
                Spacer()
                Text("\(legacyResults.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)

            LazyVStack(spacing: 16) {
                ForEach(legacyResults.indices, id: \.self) { index in
                    AnyView(resultCardView(item: legacyResults[index], index: index))
                }
            }
            .padding(.horizontal, 24)
        }
    }

    struct ProIDHistoryVersion {
        let version: String
        let versionId: String
        let releaseDate: Date?
        init(version: String, versionId: String, releaseDate: Date? = nil) {
            self.version = version
            self.versionId = versionId
            self.releaseDate = releaseDate
        }
    }

    nonisolated func fetchProIDHistory(trackId: Int) async -> [ProIDHistoryVersion] {
        let list = await IPadnVersionSources.fetch(appID: String(trackId))
        return list.map { ProIDHistoryVersion(version: $0.version, versionId: $0.versionId, releaseDate: $0.releaseDate) }
    }
    func fetchLegacyApps(term: String, exclude: Set<String>) async -> [iTunesSearchResult] {
        var results: [iTunesSearchResult] = []
        var seen = Set<Int>()
        let region = appStore.selectedAccount?.countryCode ?? "US"

        var searchRegions = [region.lowercased()]
        if !searchRegions.contains("us") { searchRegions.append("us") }
        if let termEnc = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            for searchRegion in searchRegions {
                guard let url = URL(string: "https://app.agzy.cn/searchApp?country=\(searchRegion)&name=\(termEnc)&limit=15") else { continue }
                var req = URLRequest(url: url)
                req.timeoutInterval = 12
                req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
                guard let (data, _) = try? await URLSession.shared.data(for: req),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["code"] as? Int) == 200,
                      let arr = obj["data"] as? [[String: Any]] else { continue }

                var candidates: [AgzyCandidate] = []
                for item in arr.prefix(15) {
                    if let candidate = Self.agzyCandidate(from: item) {
                        candidates.append(candidate)
                    }
                }

                let hits = await withTaskGroup(of: iTunesSearchResult?.self) { group -> [iTunesSearchResult] in
                    for candidate in candidates {
                        group.addTask {
                            let available = await Self.isAppAvailable(id: candidate.appId, region: region)
                            return available ? nil : candidate.toSearchResult()
                        }
                    }
                    var acc: [iTunesSearchResult] = []
                    for await value in group {
                        if let value { acc.append(value) }
                    }
                    return acc
                }

                for hit in hits where !seen.contains(hit.trackId) {
                    seen.insert(hit.trackId)
                    results.append(hit)
                }
            }
        }

        for entry in NameDirectory.matches(term) {
            guard let candidateId = Int(entry.id), candidateId > 0, !seen.contains(candidateId) else { continue }
            var req = URLRequest(url: URL(string: "https://itunes.apple.com/lookup?id=\(candidateId)&country=\(region)")!)
            req.timeoutInterval = 12
            guard let (ldata, _) = try? await URLSession.shared.data(for: req),
                  let lobj = try? JSONSerialization.jsonObject(with: ldata) as? [String: Any],
                  let larr = lobj["results"] as? [[String: Any]], let first = larr.first else {
                results.append(Self.delistedResult(fromDirectory: entry))
                continue
            }
            if let decoded = try? JSONDecoder().decode(iTunesSearchResult.self, from: JSONSerialization.data(withJSONObject: first)) {
                if seen.insert(decoded.trackId).inserted { results.append(decoded) }
            } else {
                results.append(Self.delistedResult(fromDirectory: entry))
            }
        }
        return results
    }

    private struct AgzyCandidate: Sendable {
        let appId: Int
        let name: String
        let artistName: String
        let icon: String?
        let version: String
        let price: String?
        let summary: String?

        func toSearchResult() -> iTunesSearchResult {
            iTunesSearchResult(
                trackId: appId,
                trackName: name,
                artistName: artistName,
                bundleId: "",
                version: version,
                formattedPrice: price,
                price: 0.0,
                currency: nil,
                trackViewUrl: "https://apps.apple.com/app/id\(appId)",
                artworkUrl60: icon, artworkUrl100: icon, artworkUrl512: icon,
                screenshotUrls: nil, ipadScreenshotUrls: nil,
                description: summary, releaseNotes: nil,
                sellerName: artistName, genres: nil, primaryGenreName: nil, contentAdvisoryRating: nil,
                averageUserRating: nil, userRatingCount: nil, fileSizeBytes: nil, minimumOsVersion: nil,
                currentVersionReleaseDate: nil, releaseDate: nil, isGameCenterEnabled: nil,
                supportedDevices: nil, languageCodesISO2A: nil, advisories: nil, features: nil)
        }
    }

    private static func agzyCandidate(from item: [String: Any]) -> AgzyCandidate? {
        guard let appId = intValue(item["appId"]), appId > 0 else { return nil }
        let name = (item["name"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        return AgzyCandidate(
            appId: appId,
            name: name,
            artistName: (item["artistName"] as? String) ?? "",
            icon: item["pic"] as? String,
            version: (item["version"] as? String) ?? "",
            price: item["price"] as? String,
            summary: (item["description"] as? String)?.replacingOccurrences(of: "<br>", with: "\n")
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func isAppAvailable(id: Int, region: String) async -> Bool {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(id)&country=\(region.lowercased())") else { return true }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        return ((obj["resultCount"] as? Int) ?? 0) > 0
    }

    private static func delistedResult(fromDirectory entry: NameDirectoryEntry) -> iTunesSearchResult {
        let trackId = Int(entry.id) ?? 0
        return iTunesSearchResult(
            trackId: trackId,
            trackName: entry.name,
            artistName: nil,
            bundleId: "",
            version: "",
            formattedPrice: nil, price: 0.0, currency: nil,
            trackViewUrl: "https://apps.apple.com/app/id\(trackId)",
            artworkUrl60: nil, artworkUrl100: nil, artworkUrl512: nil,
            screenshotUrls: nil, ipadScreenshotUrls: nil, description: nil, releaseNotes: nil,
            sellerName: nil, genres: nil, primaryGenreName: nil, contentAdvisoryRating: nil,
            averageUserRating: nil, userRatingCount: nil, fileSizeBytes: nil, minimumOsVersion: nil,
            currentVersionReleaseDate: nil, releaseDate: nil, isGameCenterEnabled: nil,
            supportedDevices: nil, languageCodesISO2A: nil, advisories: nil, features: nil)
    }

    private static func directoryEntry(fromAppdbMetadata metadata: [String: Any]?, bundleId: String) -> DirectoryEntry? {
        guard let metadata else { return nil }
        let name = (metadata["name"] as? String)
            ?? (metadata["trackName"] as? String)
            ?? (metadata["itemName"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let version = (metadata["version"] as? String) ?? (metadata["trackVersion"] as? String)
        let icon = (metadata["icon"] as? String)
            ?? (metadata["icon512"] as? String)
            ?? (metadata["artwork"] as? String)
            ?? (metadata["artworkUrl512"] as? String)
        var trackId: Int?
        for key in ["trackId", "itemId", "id"] {
            if let v = metadata[key] as? Int { trackId = v; break }
            if let s = metadata[key] as? String, let v = Int(s), v > 0 { trackId = v; break }
        }
        return DirectoryEntry(bundleId: bundleId, name: name, trackId: trackId,
                              version: version, iconURL: icon, updatedAt: Date())
    }

    private static func legacyResult(from entry: DirectoryEntry) -> iTunesSearchResult? {
        guard !entry.name.isEmpty else { return nil }
        return iTunesSearchResult(
            trackId: entry.trackId ?? 0,
            trackName: entry.name,
            artistName: nil,
            bundleId: entry.bundleId,
            version: entry.version ?? "",
            formattedPrice: nil, price: 0.0, currency: nil,
            trackViewUrl: "https://apps.apple.com/app/id\(entry.trackId ?? 0)",
            artworkUrl60: entry.iconURL, artworkUrl100: entry.iconURL, artworkUrl512: entry.iconURL,
            screenshotUrls: nil, ipadScreenshotUrls: nil, description: nil, releaseNotes: nil,
            sellerName: nil, genres: nil, primaryGenreName: nil, contentAdvisoryRating: nil,
            averageUserRating: nil, userRatingCount: nil, fileSizeBytes: nil, minimumOsVersion: nil,
            currentVersionReleaseDate: nil, releaseDate: nil, isGameCenterEnabled: nil,
            supportedDevices: nil, languageCodesISO2A: nil, advisories: nil, features: nil)
    }

    static func resolveDelistedApp(_ app: iTunesSearchResult) async -> iTunesSearchResult {
        guard app.bundleId.isEmpty, app.trackId > 0,
              let url = URL(string: "https://app.agzy.cn/searchVersion?appid=\(app.trackId)") else { return app }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return app }

        let bundleId = (obj["bundleId"] as? String) ?? ""
        guard !bundleId.isEmpty else { return app }
        let latestVersion = (obj["version"] as? String) ?? ""
        let resolvedName = (obj["name"] as? String) ?? ""
        let icon = app.artworkUrl512 ?? app.artworkUrl100 ?? app.artworkUrl60

        return iTunesSearchResult(
            trackId: app.trackId,
            trackName: app.trackName.isEmpty ? resolvedName : app.trackName,
            artistName: app.artistName,
            bundleId: bundleId,
            version: app.version.isEmpty ? latestVersion : app.version,
            formattedPrice: app.formattedPrice,
            price: app.price,
            currency: app.currency,
            trackViewUrl: app.trackViewUrl,
            artworkUrl60: app.artworkUrl60 ?? icon,
            artworkUrl100: app.artworkUrl100 ?? icon,
            artworkUrl512: icon,
            screenshotUrls: app.screenshotUrls,
            ipadScreenshotUrls: app.ipadScreenshotUrls,
            description: app.description,
            releaseNotes: app.releaseNotes,
            sellerName: app.sellerName,
            genres: app.genres,
            primaryGenreName: app.primaryGenreName,
            contentAdvisoryRating: app.contentAdvisoryRating,
            averageUserRating: app.averageUserRating,
            userRatingCount: app.userRatingCount,
            fileSizeBytes: app.fileSizeBytes,
            minimumOsVersion: app.minimumOsVersion,
            currentVersionReleaseDate: app.currentVersionReleaseDate,
            releaseDate: app.releaseDate,
            isGameCenterEnabled: app.isGameCenterEnabled,
            supportedDevices: app.supportedDevices,
            languageCodesISO2A: app.languageCodesISO2A,
            advisories: app.advisories,
            features: app.features
        )
    }

    static func placeholderResult(trackId: Int) -> iTunesSearchResult {
        iTunesSearchResult(
            trackId: trackId, trackName: "", artistName: nil, bundleId: "", version: "",
            formattedPrice: nil, price: 0.0, currency: nil,
            trackViewUrl: "https://apps.apple.com/app/id\(trackId)",
            artworkUrl60: nil, artworkUrl100: nil, artworkUrl512: nil,
            screenshotUrls: nil, ipadScreenshotUrls: nil, description: nil, releaseNotes: nil,
            sellerName: nil, genres: nil, primaryGenreName: nil, contentAdvisoryRating: nil,
            averageUserRating: nil, userRatingCount: nil, fileSizeBytes: nil, minimumOsVersion: nil,
            currentVersionReleaseDate: nil, releaseDate: nil, isGameCenterEnabled: nil,
            supportedDevices: nil, languageCodesISO2A: nil, advisories: nil, features: nil)
    }

    private static func storeRegions(_ accountRegion: String) -> [String] {
        var seen = Set<String>()
        return ([accountRegion, "US", "CN", "HK", "TW", "JP", "GB"])
            .map { $0.uppercased() }
            .filter { seen.insert($0).inserted }
    }

    static func lookupAcrossRegions(bundleId: String, accountRegion: String) async -> iTunesSearchResult? {
        let regions = storeRegions(accountRegion)
        let hits = await withTaskGroup(of: (String, iTunesSearchResult?).self) { group -> [String: iTunesSearchResult] in
            for region in regions {
                group.addTask {
                    let hit = try? await iTunesClient.shared.lookup(bundleIdentifier: bundleId, countryCode: region)
                    return (region, hit)
                }
            }
            var acc: [String: iTunesSearchResult] = [:]
            for await (region, hit) in group {
                if let hit { acc[region] = hit }
            }
            return acc
        }
        for region in regions {
            if let hit = hits[region] { return hit }
        }
        return nil
    }

    static func lookupAcrossRegions(trackId: Int, accountRegion: String) async -> iTunesSearchResult? {
        let regions = storeRegions(accountRegion)
        let hits = await withTaskGroup(of: (String, iTunesSearchResult?).self) { group -> [String: iTunesSearchResult] in
            for region in regions {
                group.addTask {
                    let hit = try? await iTunesClient.shared.lookup(trackId: trackId, countryCode: region)
                    return (region, hit)
                }
            }
            var acc: [String: iTunesSearchResult] = [:]
            for await (region, hit) in group {
                if let hit { acc[region] = hit }
            }
            return acc
        }
        for region in regions {
            if let hit = hits[region] { return hit }
        }
        return nil
    }

    var searchingIndicator: some SwiftUI.View {
        VStack(spacing: 24) {

            ZStack {
                Circle()
                    .stroke(themeManager.accentColor.opacity(0.2), lineWidth: 4)
                    .frame(width: 60, height: 60)
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(
                        LinearGradient(
                            colors: [themeManager.accentColor, Color(.systemGray4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(searching ? 360 : 0))
                    .animation(
                        .linear(duration: 1.5).repeatForever(autoreverses: false),
                        value: searching
                    )
            }
            VStack(spacing: 8) {
                Text("searching".localized)
                    .font(.title2)
                    .foregroundColor(.primary)
                Text("finding_best_results".localized)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    var emptyStateView: some SwiftUI.View {
        VStack(spacing: 24) {

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .cornerRadius(24)
            VStack(spacing: 8) {
                Text("app_downgrade".localized)
                    .font(.title)
                    .foregroundColor(.primary)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            if !searchHistory.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("search_history".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("\(searchHistory.count)")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color(.systemGray5)))

                        Spacer()

                        Button {
                            withAnimation(.easeInOut) {
                                clearSearchHistory()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                Text("clear_all".localized)
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)

                    FlowLayout(spacing: 10) {
                        ForEach(searchHistory, id: \.self) { history in
                            HStack(spacing: 6) {
                                Button {
                                    searchKey = history
                                    Task { await performSearch() }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Text(history)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                    }
                                    .padding(.leading, 12)
                                    .padding(.trailing, 4)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    withAnimation(.easeInOut) {
                                        removeFromHistory(history)
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.secondary.opacity(0.7))
                                        .padding(6)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .background(Capsule().fill(Color(.systemGray6)))
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }

            if showSearchSuggestions && !searchSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("search_suggestions".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            showSearchSuggestions = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    FlowLayout(spacing: 8) {
                        ForEach(searchSuggestions, id: \.self) { suggestion in
                            Button {
                                searchKey = suggestion
                                showSearchSuggestions = false
                                Task { await performSearch() }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text(suggestion)
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                }
                                .padding(.leading, 12)
                                .padding(.trailing, 12)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .background(Capsule().fill(Color(.systemGray6)))
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
    }

    func searchErrorView(error: String) -> some SwiftUI.View {
        VStack(spacing: 24) {

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.red.opacity(0.1), .red.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(.red.opacity(0.8))
            }
            VStack(spacing: 8) {
                Text("search_error".localized)
                    .font(.title)
                    .foregroundColor(.primary)
                Text(error)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Button {
                searchError = nil
                Task {
                    await performSearch()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium))
                    Text("retry".localized)
                        .font(.subheadline)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
    }

    var searchResultsGrid: some SwiftUI.View {
        Group {

            LazyVStack(spacing: 16) {
                ForEach(searchResult.indices, id: \.self) { index in
                    let item = searchResult[index]
                    AnyView(resultCardView(item: item, index: index))
                }
            }
            .padding(.horizontal, 24)
        }
    }

    func resultCardView(item: iTunesSearchResult, index: Int) -> any SwiftUI.View {
        return AppSearchResultCardView(app: item, onTap: {
            handleDownloadApp(item)
        }, onGetAction: {

            handleDownloadApp(item)
        }, isDownloading: purchasingTrackId == item.trackId,
           isPreview: scrollTracker.isFast,
           isOwned: purchasedTrackIds.contains(item.trackId) ? true : nil)
        .environmentObject(themeManager)
        .id(item.trackId)
        .animation(nil, value: scrollTracker.isFast)
    }

    func flag(country: String) -> String {
        let base: UInt32 = 127397
        var s = ""
        for v in country.unicodeScalars {
            if let scalar = UnicodeScalar(base + v.value) {
                s.unicodeScalars.append(scalar)
            }
        }
        return String(s)
    }
    @MainActor
    static let curatedApps: [(keywords: [String], bundleId: String)] = [
        (["forward", "fwrd"], "com.forward.iphone")
    ]

    func fetchCuratedApps(term: String, country: String) async -> [iTunesSearchResult] {
        let normalized = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        var bids: [String] = []
        for entry in Self.curatedApps where entry.keywords.contains(where: { normalized.contains($0) || normalized.count >= 3 && $0.hasPrefix(normalized) }) {
            bids.append(entry.bundleId)
        }
        guard !bids.isEmpty else { return [] }
        var regions = [country.lowercased()]
        if !regions.contains("us") { regions.append("us") }
        var out: [iTunesSearchResult] = []
        var seen = Set<Int>()
        for bid in bids {
            for region in regions {
                if case .some(let hit) = try? await iTunesClient.shared.lookup(bundleIdentifier: bid, countryCode: region),
                   !seen.contains(hit.trackId) {
                    seen.insert(hit.trackId)
                    out.append(hit)
                    break
                }
            }
        }
        return out
    }

    @MainActor
    func performSearch() async {
        let term = searchKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }

        AnalyticsManager.shared.track("search", properties: ["keyword": term])

        let regionToUse = appStore.selectedAccount?.countryCode ?? "US"

        withAnimation(.easeInOut) {
            searching = true
            searchResult = []
            legacyResults = []
            searchError = nil
        }
        addToSearchHistory(term)

        let curatedHits = await fetchCuratedApps(term: term, country: regionToUse)

        let cacheKey = "\(term)_\(searchType.rawValue)_\(regionToUse)"
        if let cachedResult = SearchResultCache.shared.get(cacheKey) {
            let curatedIds = Set(curatedHits.map(\.trackId))
            let merged = curatedHits + cachedResult.filter { !curatedIds.contains($0.trackId) }
            await MainActor.run {
                guard term == searchKey.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                withAnimation(.spring()) {
                    searchResult = merged
                    searching = false
                }
            }
            let excludeIds = Set(cachedResult.map(\.bundleId))
            Task { @MainActor in
                let hits = await fetchLegacyApps(term: term, exclude: excludeIds)
                if term == searchKey.trimmingCharacters(in: .whitespacesAndNewlines) {
                    withAnimation(.spring()) {
                        legacyResults = hits
                    }
                }
            }
            return
        }

        do {
            let response = try await iTunesClient.shared.search(
                term: term,
                limit: pageSize,
                countryCode: regionToUse,
                deviceFamily: searchType
            )
            var finalResults = response ?? []
            if finalResults.isEmpty, term.contains("."), case .some(let hit) = try? await iTunesClient.shared.lookup(bundleIdentifier: term, countryCode: regionToUse) {
                finalResults = [hit]
            }
            let curatedIds = Set(curatedHits.map(\.trackId))
            let merged = curatedHits + finalResults.filter { !curatedIds.contains($0.trackId) }
            await MainActor.run {
                withAnimation(.spring()) {
                    searchResult = merged
                    searching = false
                    SearchResultCache.shared.set(merged, for: cacheKey)
                    updateSearchSuggestions(from: merged)
                    AppDirectory.shared.record(apps: merged)
                }
            }
            let excludeIds = Set(finalResults.map(\.bundleId))
            Task { @MainActor in
                let hits = await fetchLegacyApps(term: term, exclude: excludeIds)
                if term == searchKey.trimmingCharacters(in: .whitespacesAndNewlines) {
                    withAnimation(.spring()) {
                        legacyResults = hits
                    }
                }
            }
        } catch {
            let hits = await fetchLegacyApps(term: term, exclude: [])
            await MainActor.run {
                withAnimation(.easeInOut) {
                    searching = false
                    if hits.isEmpty {
                        searchError = error.localizedDescription
                    } else {
                        searchError = nil
                        legacyResults = hits
                    }
                }
            }
        }
    }
    func updateSearchSuggestions(from results: [iTunesSearchResult]) {
        let suggestions = results.compactMap { result -> String? in
            let name = result.trackName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        guard !suggestions.isEmpty else { return }
        let key = searchKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let combined = Array(Set(suggestions))
        searchSuggestionsCache.setValue(combined, forKey: key)
        if searchKeyFocused {
            searchSuggestions = Array(Set((searchSuggestions + combined))).sorted()
        }
    }
    func loadSearchHistory() {
        if let data = try? JSONDecoder().decode([String].self, from: searchHistoryData) {
            searchHistory = data
        }
    }
    func saveSearchHistory() {
        if let data = try? JSONEncoder().encode(searchHistory) {
            searchHistoryData = data
        }
    }
    func addToSearchHistory(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        searchHistory.removeAll { $0 == trimmedQuery }

        searchHistory.insert(trimmedQuery, at: 0)

        if searchHistory.count > 50 {
            searchHistory = Array(searchHistory.prefix(50))
        }
        saveSearchHistory()
    }
    func removeFromHistory(_ query: String) {
        searchHistory.removeAll { $0 == query }
        saveSearchHistory()
    }
    func clearSearchHistory() {
        searchHistory.removeAll()
        saveSearchHistory()
    }
    func fetchRemoteSuggestions(for query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isFetchingSuggestions { return }
        isFetchingSuggestions = true
        defer { isFetchingSuggestions = false }

        if let cached = searchSuggestionsCache.value(forKey: query) {
            let combined = Array(Set((searchSuggestions + cached))).sorted()
            await MainActor.run { self.searchSuggestions = combined }
            return
        }

        let res = await SearchManager.shared.suggest(term: query)
        switch res {
        case .success(let terms):
            let remote = terms.map { $0.term }
            searchSuggestionsCache.setValue(remote, forKey: query)
            let combined = Array(Set((searchSuggestions + remote))).sorted()
            await MainActor.run { self.searchSuggestions = combined }
        case .failure:
            break
        }
    }
    func getSearchSuggestions(for query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        let lowercaseQuery = query.lowercased()
        let historySuggestions = searchHistory.filter { $0.lowercased().contains(lowercaseQuery) }
        let dynamicSuggestions = searchSuggestions.filter { $0.lowercased().contains(lowercaseQuery) }
        return Array(Set(historySuggestions + dynamicSuggestions)).prefix(5).map { $0 }
    }

    private func openAppStorePage(for item: iTunesSearchResult) {
        let urlStr = item.trackViewUrl
        guard let url = URL(string: urlStr) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        #endif
    }

    @MainActor
    func loadVersionsForApp(_ app: iTunesSearchResult, allowRetry: Bool = true) {

        let isRetry = !allowRetry
        if !isRetry {
            selectedApp = app
            versionError = nil
            availableVersions = []
            isLoadingVersions = true
            showVersionPicker = true
        }

        if !isRetry, app.trackId > 0, var cached = VersionListCache.shared.get(app.trackId) {
            cached.normalizeVersionOrder()
            availableVersions = cached
            isLoadingVersions = false
            return
        }

        Task {
            let accountCountry = self.appStore.selectedAccount?.countryCode
                ?? Locale.current.region?.identifier
                ?? "US"

            var targetApp = app
            if targetApp.trackId <= 0, !targetApp.bundleId.isEmpty {
                if let hit = await Self.lookupAcrossRegions(bundleId: targetApp.bundleId, accountRegion: accountCountry) {
                    targetApp = hit
                    await MainActor.run {
                        if self.selectedApp?.bundleId == app.bundleId {
                            self.selectedApp = hit
                        }
                    }
                }
            }

            let trackId = targetApp.trackId
            do {
                guard trackId > 0 else {
                    throw NSError(domain: "SearchView", code: -2, userInfo: [NSLocalizedDescriptionKey: "api_err_app_not_found".localized])
                }
                let accountCopy = appStore.selectedAccount

                let proTask = Task { (try? await withTimeout(seconds: 20, operation: {
                    await fetchProIDHistory(trackId: trackId)
                })) ?? [] }
                let storeTask: Task<Result<[StoreAppVersion], StoreError>?, Never>? = {
                    guard let accountCopy else { return nil }
                    return Task { try? await withTimeout(seconds: 15, operation: {
                        await StoreClient.shared.getAppVersions(
                            trackId: String(trackId),
                            account: accountCopy,
                            countryCode: accountCountry
                        )
                    }) }
                }()
                let primaryCountries = accountCountry.uppercased() == "US" ? ["US"] : [accountCountry, "US"]
                let histTask = Task { () -> [iTunesClient.AppVersionInfo] in
                    for cc in primaryCountries {
                        if let r = try? await withTimeout(seconds: 10, operation: {
                            try await iTunesClient.shared.versionHistory(id: trackId, country: cc)
                        }), !r.isEmpty { return r }
                    }
                    return []
                }

                let proVersions = await proTask.value
                if !proVersions.isEmpty {
                    var quick = proVersions.map { pv in
                        StoreAppVersion(versionString: pv.version, versionId: pv.versionId,
                                        isCurrent: false, releaseDate: pv.releaseDate, releaseNotes: nil)
                    }
                    quick.normalizeVersionOrder()
                    await MainActor.run {
                        guard self.selectedApp?.trackId == trackId else { return }
                        if self.availableVersions.isEmpty {
                            self.availableVersions = quick
                            self.versionError = nil
                            self.isLoadingVersions = false
                        }
                    }
                }

                var storeVersionsResult: Result<[StoreAppVersion], StoreError>? = nil
                if let storeTask { storeVersionsResult = await storeTask.value }
                let hist = await histTask.value

                if let result = storeVersionsResult, case .success(let versions) = result, !versions.isEmpty {
                    await MainActor.run {
                        guard self.selectedApp?.trackId == trackId else { return }
                        var mergedVersions = versions

                        var versionInfoMap: [String: (releaseDate: Date?, releaseNotes: String?)] = [:]
                        for h in hist {
                            versionInfoMap[h.version] = (h.releaseDate, h.releaseNotes)
                        }

                        var histCursor = 0
                        for i in 0..<mergedVersions.count {
                            let v = mergedVersions[i]
                            let verStr = v.versionString

                            if v.versionString.isEmpty {
                                if histCursor < hist.count {
                                    mergedVersions[i].versionString = hist[histCursor].version
                                    if v.releaseDate == nil {
                                        mergedVersions[i].releaseDate = hist[histCursor].releaseDate
                                    }
                                    mergedVersions[i].releaseNotes = hist[histCursor].releaseNotes
                                    histCursor += 1
                                }
                            } else if let info = versionInfoMap[verStr] {
                                if v.releaseDate == nil {
                                    mergedVersions[i].releaseDate = info.releaseDate
                                }
                                if (v.releaseNotes == nil || v.releaseNotes!.isEmpty) && info.releaseNotes != nil && !info.releaseNotes!.isEmpty {
                                    mergedVersions[i].releaseNotes = info.releaseNotes
                                }
                            }
                        }

                        let incomingNames = Set(proVersions.map { $0.version })
                        var merged = mergedVersions.filter { !incomingNames.contains($0.versionString) }
                        for pv in proVersions {
                            merged.append(StoreAppVersion(
                                versionString: pv.version,
                                versionId: pv.versionId,
                                isCurrent: false,
                                releaseDate: pv.releaseDate,
                                releaseNotes: nil
                            ))
                        }

                        merged.normalizeVersionOrder()

                        if merged.count < hist.count {
                            let known = Set(merged.map { $0.versionString })
                            for info in hist where !known.contains(info.version) {
                                merged.append(StoreAppVersion(
                                    versionString: info.version,
                                    versionId: "",
                                    isCurrent: false,
                                    releaseDate: info.releaseDate,
                                    releaseNotes: info.releaseNotes
                                ))
                            }
                            merged.normalizeVersionOrder()
                        }

                        self.availableVersions = merged
                        self.versionHistory = hist.sorted { $0.releaseDate > $1.releaseDate }
                        self.versionError = nil
                        self.isLoadingVersions = false
                        VersionListCache.shared.set(merged, for: trackId)
                    }
                } else if !hist.isEmpty {
                    var fallbackVersions = hist.map { info in
                        StoreAppVersion(
                            versionString: info.version,
                            versionId: "",
                            isCurrent: false,
                            releaseDate: info.releaseDate,
                            releaseNotes: info.releaseNotes
                        )
                    }
                    fallbackVersions.normalizeVersionOrder()
                    await MainActor.run {
                        guard self.selectedApp?.trackId == trackId else { return }
                        self.availableVersions = fallbackVersions
                        self.versionHistory = hist.sorted { $0.releaseDate > $1.releaseDate }
                        self.versionError = nil
                        self.isLoadingVersions = false
                        VersionListCache.shared.set(fallbackVersions, for: trackId)
                    }
                } else {
                    var resolvedApp = targetApp
                    if resolvedApp.version.isEmpty, resolvedApp.bundleId.isEmpty {
                        resolvedApp = await Self.resolveDelistedApp(resolvedApp)
                    }

                    var fallbackVersions: [StoreAppVersion] = []
                    for pv in proVersions {
                        fallbackVersions.append(StoreAppVersion(
                            versionString: pv.version,
                            versionId: pv.versionId,
                            isCurrent: false,
                            releaseDate: pv.releaseDate,
                            releaseNotes: nil
                        ))
                    }

                    let fromPro = !fallbackVersions.isEmpty
                    if fallbackVersions.isEmpty, !resolvedApp.version.isEmpty {
                        fallbackVersions = [StoreAppVersion(
                            versionString: resolvedApp.version,
                            versionId: "",
                            isCurrent: true
                        )]
                    }

                    guard !fallbackVersions.isEmpty else {
                        throw NSError(domain: "SearchView", code: -1, userInfo: [NSLocalizedDescriptionKey: "versions_unavailable".localized])
                    }

                    fallbackVersions.normalizeVersionOrder()
                    let resolved = fallbackVersions
                    let keepLoading = resolved.count <= 1 && allowRetry
                    await MainActor.run {
                        guard self.selectedApp?.trackId == trackId else { return }
                        self.selectedApp = resolvedApp
                        self.availableVersions = resolved
                        self.versionError = nil
                        self.isLoadingVersions = keepLoading
                        if fromPro, resolved.count > 1 {
                            VersionListCache.shared.set(resolved, for: trackId)
                        }
                    }

                    if allowRetry && !fromPro {
                        scheduleVersionRetry(for: app)
                    }
                }
            } catch {
                if allowRetry {
                    scheduleVersionRetry(for: app)
                }
                await MainActor.run {
                    guard self.selectedApp?.trackId == trackId else { return }
                    if !self.availableVersions.isEmpty {
                        self.isLoadingVersions = false
                    } else if !app.version.isEmpty {
                        self.availableVersions = [StoreAppVersion(
                            versionString: app.version,
                            versionId: "",
                            isCurrent: true
                        )]
                        self.versionError = nil
                        self.isLoadingVersions = allowRetry
                    } else if allowRetry {
                        self.isLoadingVersions = true
                    } else {
                        self.versionError = error.localizedDescription
                        self.isLoadingVersions = false
                    }
                }
            }
        }
    }

    @MainActor
    private func scheduleVersionRetry(for app: iTunesSearchResult) {
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard self.selectedApp?.trackId == app.trackId else { return }
            guard self.availableVersions.count <= 1 else { return }
            self.loadVersionsForApp(app, allowRetry: false)
        }
    }

    var versionPickerSheet: some SwiftUI.View {
        NavigationView {
            ZStack {

                LinearGradient(
                    colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack {

                    versionPickerAccountIndicator

                    if isLoadingVersions {
                        loadingVersionsView
                    } else if let error = versionError {
                        AnyView(errorView(error: error))
                    } else if availableVersions.isEmpty {
                        AnyView(errorView(error: "versions_unavailable_retry".localized))
                    } else {
                        versionsListView
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                )
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("back".localized) {
                        showVersionPicker = false
                    }
                    .foregroundColor(themeManager.accentColor)
                    .font(.system(size: 16, weight: .medium))
                }
            }
        }
    }

    var loadingVersionsView: some SwiftUI.View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.2)
            Text("loading_versions".localized)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    func errorView(error: String) -> some SwiftUI.View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text("load_failed".localized)
                .font(.system(size: 22, weight: .semibold))
            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("retry".localized) {
                if let app = selectedApp {
                    loadVersionsForApp(app)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var versionsListView: some SwiftUI.View {
        ScrollView {
            LazyVStack(spacing: 16) {

                VStack(spacing: 16) {

                    ResourceImage(
                        url: URL(string: selectedApp?.artworkUrl512 ?? ""),
                        pointSize: CGSize(width: 100, height: 100),
                        contentMode: .fit,
                        cornerRadius: 20
                    )
                    .frame(width: 100, height: 100)
                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)

                    VStack(spacing: 8) {
                        Text(selectedApp?.trackName ?? "APP")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)

                        Text(selectedApp?.artistName ?? "Unknown Developer")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)

                HStack {
                    Text("version_history".localized)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.primary)

                    Spacer()

                    Text(String(format: "x_versions".localized, String(availableVersions.count)))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(themeManager.accentColor.opacity(0.1))
                        )
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                ForEach(availableVersions, id: \.id) {
                    AnyView(createModernVersionRow(version: $0))
                }
            }
            .padding(.bottom, 24)
        }
    }
    private func createModernVersionRow(version: StoreAppVersion) -> any SwiftUI.View {
        HStack(spacing: 16) {

            VStack(alignment: .leading, spacing: 8) {

                VStack(alignment: .leading, spacing: 4) {

                    Text(getVersionNumber(version: version))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(themeManager.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(themeManager.accentColor.opacity(0.1))
                        )

                    if let date = getVersionDate(version: version) {
                        Text(date)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(themeManager.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(themeManager.accentColor.opacity(0.1))
                            )
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "number.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("ID: \(version.versionId)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: {
                Task {
                    if let app = selectedApp {
                        await downloadVersion(app: app, version: version)
                    }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                    Text("download".localized)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [themeManager.accentColor, themeManager.accentColor.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Capsule())
                .shadow(color: themeManager.accentColor.opacity(0.3), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
                .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
        )
        .padding(.horizontal, 24)
    }

    private func getVersionNumber(version: StoreAppVersion) -> String {
        return String(format: "version_x".localized, version.versionString)
    }

    private func getVersionDate(version: StoreAppVersion) -> String? {
        let versionStr = version.versionString

        if let date = version.formattedReleaseDate {
            return date
        }

        if let h = versionHistory.first(where: { $0.version == versionStr }) {
            return h.formattedDate
        }

        if let h = versionHistory.first(where: { versionStr.hasPrefix($0.version) || $0.version.hasPrefix(versionStr) }) {
            return h.formattedDate
        }

        let versionComponents = versionStr.split(separator: ".").map(String.init)
        for h in versionHistory {
            let hComponents = h.version.split(separator: ".").map(String.init)
            let minCount = min(versionComponents.count, hComponents.count)
            var matchCount = 0
            for i in 0..<minCount {
                if versionComponents[i] == hComponents[i] {
                    matchCount += 1
                } else {
                    break
                }
            }
            if matchCount >= 2 {
                return h.formattedDate
            }
        }

        if let latestVersion = versionHistory.first {
            return latestVersion.formattedDate
        }

        return nil
    }

    @MainActor
    func downloadVersion(app: iTunesSearchResult, version: StoreAppVersion) async {
        showVersionPicker = false
        guard appStore.selectedAccount != nil else {
            purchaseAlertText = "session_err_no_account".localized
            showPurchaseAlert = true
            return
        }

        var resolvedApp = app
        if resolvedApp.bundleId.isEmpty, resolvedApp.trackId > 0 {
            resolvedApp = await Self.resolveDelistedApp(resolvedApp)
            selectedApp = resolvedApp
        }
        let appId = resolvedApp.trackId
        guard appId > 0 else {
            purchaseAlertText = "api_err_app_not_found".localized
            showPurchaseAlert = true
            return
        }

        let downloadId = UnifiedDownloadManager.shared.addDownload(
            bundleIdentifier: resolvedApp.bundleId,
            name: resolvedApp.trackName,
            version: version.versionString,
            identifier: appId,
            iconURL: resolvedApp.artworkUrl512,
            versionId: version.versionId,
            price: resolvedApp.price,
            currency: resolvedApp.currency
        )

        if let request = UnifiedDownloadManager.shared.downloadRequests.first(where: { $0.id == downloadId }) {
            UnifiedDownloadManager.shared.startDownload(for: request)
        } else {
        }
    }

    private var currentAccountIndicator: some SwiftUI.View {
        HStack(spacing: 12) {

            VStack(alignment: .leading, spacing: 2) {
                if let account = appStore.selectedAccount {
                    Text("current_account".localized)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Text(account.email)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)

                        Text(flag(country: account.countryCode))
                            .font(.caption)

                        Text(RegionNames.localizedName(for: account.countryCode))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Image(systemName: "person.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if appStore.hasMultipleAccounts {
                Button("switch_account".localized) {
                    showAccountSheet = true
                }
                .font(.caption)
                .foregroundColor(themeManager.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(themeManager.accentColor.opacity(0.1))
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
    }

    private var versionPickerAccountIndicator: some SwiftUI.View {
        HStack(spacing: 12) {

            VStack(alignment: .leading, spacing: 2) {
                if let account = appStore.selectedAccount {
                    Text("use_account".localized)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    HStack(spacing: 6) {
                        Text(account.email)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(flag(country: account.countryCode))
                            .font(.caption2)

                        Text(RegionNames.localizedName(for: account.countryCode))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Image(systemName: "person.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(themeManager.surfaceSecondary)
        )
        .padding(.horizontal, 16)
    }

    @MainActor
    private func handleDownloadApp(_ app: iTunesSearchResult) {
        loadVersionsForApp(app)

        guard let account = appStore.selectedAccount else { return }
        if purchasedTrackIds.contains(app.trackId) { return }
        guard purchasingTrackId == nil else { return }

        Task {
            await MainActor.run { purchasingTrackId = app.trackId }
            defer { Task { await MainActor.run { purchasingTrackId = nil } } }

            if (app.price ?? 0) == 0 {
                do {
                    _ = try await withTimeout(seconds: 50, operation: { @Sendable in
                        await PurchaseManager.shared.purchaseAppIfNeeded(
                            appIdentifier: String(app.trackId),
                            account: account,
                            countryCode: account.countryCode,
                            isFree: true
                        )
                    })
                    await MainActor.run {
                        _ = purchasedTrackIds.insert(app.trackId)
                    }
                } catch is SearchTimeoutError {
                    let owned = await quickOwnershipCheck(app, account: account)
                    if owned {
                        await MainActor.run { _ = purchasedTrackIds.insert(app.trackId) }
                    }
                } catch {
                }
                return
            }

            let check = await PurchaseManager.shared.checkAppOwnership(
                appIdentifier: String(app.trackId),
                account: account,
                countryCode: account.countryCode
            )
            if case .success(true) = check {
                await MainActor.run { _ = purchasedTrackIds.insert(app.trackId) }
            }
        }
    }

    var directEntrySheet: some SwiftUI.View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundColor(.secondary)
                    TextField("bundleId / trackId", text: $directInput)
                        .font(.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { resolveDirect() }
                    Button {
                        resolveDirect()
                    } label: {
                        Image(systemName: "arrow.forward.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(themeManager.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(directInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                .padding(.horizontal, 16)
                .padding(.top, 12)

                HStack {
                    Text("search_history".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                List {
                    if !NameDirectory.all.isEmpty {
                        Section(header: Text("legacy_apps_delisted".localized)) {
                            ForEach(NameDirectory.all, id: \.id) { entry in
                                Button {
                                    openTrackId(Int(entry.id) ?? 0)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "archivebox")
                                            .foregroundColor(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.name).foregroundColor(.primary).lineLimit(1)
                                            Text("ID \(entry.id)").font(.caption).foregroundColor(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !AppDirectory.shared.allEntries().isEmpty {
                        Section(header: Text("search_history".localized)) {
                            ForEach(AppDirectory.shared.allEntries()) { entry in
                                Button {
                                    directInput = entry.bundleId
                                    resolveDirect()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "app.gift")
                                            .foregroundColor(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.name).foregroundColor(.primary).lineLimit(1)
                                            Text(entry.bundleId).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("legacy_apps_delisted".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("close".localized) { showDirectSheet = false }
                        .foregroundColor(themeManager.accentColor)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func resolveDirect() {
        let input = directInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let region = appStore.selectedAccount?.countryCode
            ?? Locale.current.region?.identifier
            ?? "US"

        if let trackId = Int(input), trackId > 0 {
            openTrackId(trackId)
            return
        }

        let bundleId = input
        Task {
            let hit = await Self.lookupAcrossRegions(bundleId: bundleId, accountRegion: region)
            await MainActor.run {
                if let hit {
                    searchResult.insert(hit, at: 0)
                } else if let entry = AppDirectory.shared.entry(forBundleId: bundleId),
                          let result = Self.legacyResult(from: entry) {
                    legacyResults.insert(result, at: 0)
                } else {
                    purchaseAlertText = "api_err_app_not_found".localized
                    showPurchaseAlert = true
                }
                showDirectSheet = false
                directInput = ""
            }
        }
    }

    private func openTrackId(_ trackId: Int) {
        guard trackId > 0 else { return }
        let regions = appStore.selectedAccount?.countryCode
            ?? Locale.current.region?.identifier
            ?? "US"
        Task {
            var result = await Self.lookupAcrossRegions(trackId: trackId, accountRegion: regions)
            if result == nil {
                let enriched = await Self.resolveDelistedApp(Self.placeholderResult(trackId: trackId))
                if !enriched.trackName.isEmpty { result = enriched }
            }
            await MainActor.run {
                if let result {
                    searchResult.insert(result, at: 0)
                } else {
                    purchaseAlertText = "api_err_app_not_found".localized
                    showPurchaseAlert = true
                }
                showDirectSheet = false
                directInput = ""
            }
        }
    }

    private func quickOwnershipCheck(_ app: iTunesSearchResult, account: Account) async -> Bool {
        let result = try? await withTimeout(seconds: 30, operation: { @Sendable in
            await PurchaseManager.shared.checkAppOwnership(
                appIdentifier: String(app.trackId),
                account: account,
                countryCode: account.countryCode
            )
        })
        guard let result, case .success(let owned) = result else { return false }
        return owned
    }
}
