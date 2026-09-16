import Foundation

@MainActor
class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    private var licenseCache: [String: Bool] = [:]
    private var checkingApps: Set<String> = []
    private let purchaseManager = PurchaseManager.shared

    private init() {}

    func hasLicense(for app: iTunesSearchResult) -> Bool? {
        return licenseCache[String(app.trackId)]
    }

    func checkLicense(for app: iTunesSearchResult, account: Account?) async {
        guard let account = account else { return }

        let trackId = String(app.trackId)
        if app.isFree {
            licenseCache[trackId] = true
            objectWillChange.send()
            return
        }

        if checkingApps.contains(trackId) {
            return
        }
        checkingApps.insert(trackId)

        defer {
            checkingApps.remove(trackId)
        }

        let result = await purchaseManager.checkAppOwnership(
            appIdentifier: trackId,
            account: account,
            countryCode: account.countryCode
        )

        switch result {
        case .success(let hasLicense):
            licenseCache[trackId] = hasLicense
            objectWillChange.send()
        case .failure:
            break
        }
    }

    func markAsOwned(trackId: String) {
        licenseCache[trackId] = true
        objectWillChange.send()
    }

    func clearCache() {
        licenseCache.removeAll()
        objectWillChange.send()
    }
}
