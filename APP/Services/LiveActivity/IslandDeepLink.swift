import Foundation

@MainActor
final class SigningCancelCenter {
    static let shared = SigningCancelCenter()

    private var handlers: [String: () -> Void] = [:]

    private init() {}

    func register(_ key: String, handler: @escaping () -> Void) {
        handlers[key] = handler
    }

    func unregister(_ key: String?) {
        guard let key else { return }
        handlers.removeValue(forKey: key)
    }

    @discardableResult
    func cancel(_ key: String) -> Bool {
        guard let handler = handlers[key] else { return false }
        handler()
        return true
    }
}

@MainActor
enum IslandDeepLink {
    static func handle(_ url: URL) {
        guard url.scheme == "appisland" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let key = items.first(where: { $0.name == "key" })?.value
        let name = items.first(where: { $0.name == "name" })?.value ?? ""

        switch url.host {
        case "tab":
            openTab(named: name)
        case "detail":
            openDetail(key: key)
        case "pause":
            guard let key else { return }
            withDownloadRequest(key: key) { request in
                UnifiedDownloadManager.shared.pauseDownload(request: request)
                IslandActivityManager.shared.update(
                    key: IslandTaskKey.download(request.id),
                    phase: "download_paused".localized,
                    detail: "",
                    progress: request.runtime.progressValue,
                    remaining: "",
                    status: "paused"
                )
            }
        case "resume":
            guard let key else { return }
            withDownloadRequest(key: key) { request in
                UnifiedDownloadManager.shared.resumeDownload(request: request)
            }
        case "cancel":
            cancelTask(key: key)
        default:
            break
        }
    }

    private static func openTab(named name: String) {
        let resolved = name == IslandTaskKind.install ? "downloads" : name
        if let tab = TabEnum(rawValue: resolved) {
            TabRouter.shared.select(tab)
        }
    }

    private static func openDetail(key: String?) {
        guard let key else {
            TabRouter.shared.select(.downloads)
            return
        }
        if key.hasPrefix("sign-") {
            TabRouter.shared.select(.sign)
        } else if key.hasPrefix("decrypt-") {
            TabRouter.shared.select(.decrypt)
        } else {
            TabRouter.shared.select(.downloads)
        }
    }

    private static func cancelTask(key: String?) {
        guard let key else {
            IslandActivityManager.shared.endAll()
            return
        }

        if islandKind(of: key) == IslandTaskKind.download {
            withDownloadRequest(key: key) { request in
                UnifiedDownloadManager.shared.cancelDownload(request: request)
            }
            return
        }

        if key.hasPrefix("sign-") {
            if !SigningCancelCenter.shared.cancel(key) {
                IslandActivityManager.shared.end(key: key)
            }
            return
        }

        if key.hasPrefix("decrypt-") {
            DecryptCoordinator.shared.cancel()
            DecryptActivityManager.shared.fail(
                key: key,
                reason: "decrypt_state_cancelled".localized,
                cancelled: true
            )
            return
        }

        IslandActivityManager.shared.end(key: key)
    }

    private static func islandKind(of key: String) -> String? {
        ["download", "sign", "decrypt", "install"].first { key.hasPrefix($0 + "-") }
    }

    private static func withDownloadRequest(
        key: String,
        attempts: Int = 8,
        action: @escaping (DownloadRequest) -> Void
    ) {
        guard let id = IslandTaskKey.id(from: key, prefix: IslandTaskKind.download) else { return }
        if let request = UnifiedDownloadManager.shared.downloadRequests.first(where: { $0.id == id }) {
            action(request)
            return
        }
        guard attempts > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            withDownloadRequest(key: key, attempts: attempts - 1, action: action)
        }
    }
}
