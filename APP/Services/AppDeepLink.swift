import Foundation

@MainActor
enum AppDeepLink {
    static func handle(_ url: URL) {
        guard url.scheme == "bambooapp", url.host == "tab" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let name = items.first(where: { $0.name == "name" })?.value,
              let tab = TabEnum(rawValue: name) else { return }
        TabRouter.shared.select(tab)
    }
}
