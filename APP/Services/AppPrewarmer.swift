import Foundation

@MainActor
enum AppPrewarmer {
    private static var warmed = false

    static func warm() {
        guard !warmed else { return }
        warmed = true

        _ = ThemeManager.shared
        _ = AppStore.this
        _ = SigningStore.shared
        _ = SigningHistoryStore.shared

        let downloads = UnifiedDownloadManager.shared
        let iconURLs = downloads.downloadRequests.compactMap { request -> URL? in
            guard let raw = request.package.iconURL else { return nil }
            return URL(string: raw)
        }
        ImageLoader.shared.prefetch(iconURLs)
    }
}
