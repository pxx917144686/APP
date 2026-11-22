import Foundation
import UIKit

/// 查 GitHub Releases 上有没有比当前更新的版本。
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(String, URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// 不用 GitHub API（未认证会被 403 限流），直接跟随 releases/latest 的 302，
    /// 从落地地址 /releases/tag/<version> 里读版本号。
    private let latestPage = URL(string: "https://github.com/pxx917144686/APP/releases/latest")!
    private let releasesPage = URL(string: "https://github.com/pxx917144686/APP/releases")!

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking

        var request = URLRequest(url: latestPage)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                state = .failed("no response")
                return
            }
            guard http.statusCode == 200, let finalURL = response.url else {
                state = .failed("HTTP \(http.statusCode)")
                return
            }

            let tag = finalURL.lastPathComponent
            guard finalURL.path.contains("/releases/tag/"), !tag.isEmpty else {
                state = .failed("no release found")
                return
            }

            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            if Self.isNewer(latest, than: currentVersion) {
                state = .available(latest, finalURL)
            } else {
                state = .upToDate(latest)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 按点分数字比较：2.7.10 > 2.7.9。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
