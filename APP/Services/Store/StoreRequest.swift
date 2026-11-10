import Foundation

final class AuthCookieCache {
    static let shared = AuthCookieCache()
    private let lock = NSLock()
    private var storage: [String: [String]] = [:]
    func set(dsid: String, cookies: [String]) { lock.lock(); defer { lock.unlock() }; storage[dsid] = cookies }
    func get(dsid: String) -> [String] { lock.lock(); defer { lock.unlock() }; return storage[dsid] ?? [] }
}

final class GUIDCache {
    static let shared = GUIDCache()
    private let lock = NSLock()
    private var cached: String?

    func get() -> String {
        lock.lock()
        let hit = cached
        lock.unlock()
        if let hit, !hit.isEmpty { return hit }
        let guid = (try? MachineIdentityProvider.resolve().guid) ?? ""
        guard !guid.isEmpty else { return "" }
        lock.lock()
        cached = guid
        lock.unlock()
        return guid
    }
}

@MainActor
class StoreRequest {
    static let shared = StoreRequest()
    private init() {}

    private let bagManager = BagManager.shared

    private var baseURL: String { bagManager.downloadURL }
    private var buyBaseURL: String { bagManager.buyURL }

    func currentGUID() -> String { GUIDCache.shared.get() }

    func commerceUserAgent() -> String {
        "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    }

    func savePassword(_ password: String, for email: String) {
        UserDefaults.standard.set(password, forKey: "store_password_\(email)")
    }
    func storedPassword(for email: String) -> String? {
        UserDefaults.standard.string(forKey: "store_password_\(email)")
    }

    private func send(operation: String, path: String, query: String,
                      body: [String: Any], account: Account? = nil) async throws -> [String: Any] {
        var acct = account
        if let a = acct, !a.email.isEmpty {
            let cached = AuthCookieCache.shared.get(dsid: a.dsPersonId).first
                ?? UserDefaults.standard.string(forKey: "ipadn_cookie_\(a.dsPersonId)") ?? ""
            if cached.isEmpty, let pwd = storedPassword(for: a.email), !pwd.isEmpty {
                if let fresh = try? await AuthenticationManager.shared.reauthenticate(email: a.email, password: pwd) {
                    acct = fresh
                }
            }
        }
        let guid = GUIDCache.shared.get()
        let urlString = (path.hasPrefix("/r/") || path.hasPrefix("/up/") ? baseURL : buyBaseURL) + path + query
        guard let url = URL(string: urlString) else { throw StoreError.invalidResponse }
        var headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
            "User-Agent": commerceUserAgent(),
            "X-Apple-Store-Front": acct?.storeResponse.storeFront ?? "143441-1,34"
        ]
        if let a = acct {
            headers["X-Dsid"] = a.dsPersonId
            headers["iCloud-DSID"] = a.dsPersonId
            headers["X-Token"] = a.passwordToken
            if !a.pod.isEmpty { headers["X-Apple-Pod"] = a.pod }
            let dsid = a.dsPersonId
            let cookie = AuthCookieCache.shared.get(dsid: dsid).first
                ?? UserDefaults.standard.string(forKey: "ipadn_cookie_\(dsid)")
            if let cookie, !cookie.isEmpty { headers["Cookie"] = cookie }
        }
        let bodyData = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)

        let signer = SAPSigner.shared
        headers["X-Apple-ActionSignature"] = try await signer.sign(bodyData, guid: guid, useCache: true)

        let (plist, response) = try await AppleAuthentication.withStoreProof(
            endpoint: url,
            baseHeaders: headers,
            loadProof: { try await signer.storeProofHeaders(guid: guid, useCache: true) },
            provisionProof: { challenge in
                try await signer.provisionStoreProof(challenge: challenge, guid: guid, useCache: true)
            },
            resetProof: { signer.resetStoreProof(guid: guid) },
            execute: { headerProvider in
                try await HTTPClient.shared.plist(
                    url, body: bodyData,
                    headers: try await headerProvider(url),
                    allowRedirects: true,
                    refreshHeaders: headerProvider)
            })

        guard response.statusCode == 200 else {
            throw StoreError.serverErrorWithDetails(response.statusCode, "store_err_request_failed".localized)
        }
        return plist
    }

    private func authHeaders(_ account: Account?) -> [String: String] {
        var h: [String: String] = ["Content-Type": "application/x-www-form-urlencoded"]
        guard let account else { return h }
        h["X-Dsid"] = account.dsPersonId
        h["iCloud-DSID"] = account.dsPersonId
        if !account.passwordToken.isEmpty { h["X-Token"] = account.passwordToken }
        let storeFront = account.storeResponse.storeFront
        if !storeFront.isEmpty { h["X-Apple-Store-Front"] = storeFront }
        let dsid = account.dsPersonId
        let cookie = AuthCookieCache.shared.get(dsid: dsid).first
            ?? UserDefaults.standard.string(forKey: "ipadn_cookie_\(dsid)")
        if let cookie, !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    private func storePlist(_ url: URL, body: Data, headers: [String: String],
                            guid: String) async throws -> ([String: Any], HTTPURLResponse) {
        let signer = SAPSigner.shared
        return try await AppleAuthentication.withStoreProof(
            endpoint: url,
            baseHeaders: headers,
            loadProof: { try await signer.storeProofHeaders(guid: guid, useCache: true) },
            provisionProof: { challenge in
                try await signer.provisionStoreProof(challenge: challenge, guid: guid, useCache: true)
            },
            resetProof: { signer.resetStoreProof(guid: guid) },
            execute: { headerProvider in
                try await HTTPClient.shared.plist(
                    url, body: body,
                    headers: try await headerProvider(url),
                    allowRedirects: true,
                    refreshHeaders: headerProvider)
            })
    }

    private func downloadBody(appIdentifier: String, appVersion: String?) -> [String: Any] {
        var body: [String: Any] = [
            "guid": GUIDCache.shared.get(),
            "salableAdamId": NSNumber(value: UInt64(appIdentifier) ?? 0),
            "serialNumber": "0"
        ]
        if let v = appVersion, !v.isEmpty { body["externalVersionId"] = v }
        return body
    }

    func download(appIdentifier: String, account: Account,
                  appVersion: String? = nil) async throws -> StoreDownloadResponse {
        try await performDownload(appIdentifier: appIdentifier, account: account,
                                  appVersion: appVersion, retried: false)
    }

    private func performDownload(appIdentifier: String, account: Account,
                                 appVersion: String?, retried: Bool) async throws -> StoreDownloadResponse {
        let guid = GUIDCache.shared.get()
        var body = downloadBody(appIdentifier: appIdentifier, appVersion: appVersion)
        body["guid"] = guid
        let kbsync = try await SAPSigner.shared.kbsync(guid: guid, dsid: account.dsPersonId, useCache: true)
        body["kbsync"] = kbsync
        let url = URL(string: "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download?guid=\(guid)")!
        let (plist, _) = try await storePlist(url, body: HTTPClient.encodePlist(body),
                                              headers: authHeaders(account), guid: guid)
        let ft = plistString(plist["failureType"])
        if ["2034", "2042"].contains(ft), !retried,
           let pwd = storedPassword(for: account.email), !pwd.isEmpty,
           let fresh = try? await AuthenticationManager.shared.reauthenticate(email: account.email, password: pwd) {
            return try await performDownload(appIdentifier: appIdentifier, account: fresh,
                                             appVersion: appVersion, retried: true)
        }
        return try parseDownloadResponse(plist: plist)
    }

    func download(appIdentifier: String, directoryServicesIdentifier: String,
                  appVersion: String? = nil, passwordToken: String? = nil,
                  storeFront: String? = nil) async throws -> StoreDownloadResponse {
        let fake = accountStub(dsid: directoryServicesIdentifier, token: passwordToken, storeFront: storeFront)
        return try await download(appIdentifier: appIdentifier, account: fake, appVersion: appVersion)
    }

    func redownload(appIdentifier: String, account: Account) async throws -> StoreDownloadResponse {
        return try await download(appIdentifier: appIdentifier, account: account, appVersion: nil)
    }

    func purchase(appIdentifier: String, account: Account) async throws -> StorePurchaseResponse {
        let guid = GUIDCache.shared.get()
        let body: [String: Any] = [
            "appExtVrsId": "0", "buyWithoutAuthorization": "true", "guid": guid,
            "hasAskedToFulfillPreorder": "true", "hasDoneAgeCheck": "true", "price": "0",
            "pricingParameters": "STDQ", "productType": "C", "salableAdamId": appIdentifier
        ]
        var headers = authHeaders(account)
        headers["Content-Type"] = "application/x-apple-plist"
        let url = URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct")!
        let (plist, _) = try await storePlist(url, body: HTTPClient.encodePlist(body),
                                              headers: headers, guid: guid)
        let ft = plistString(plist["failureType"])
        if ft == "5002" { 
            return StorePurchaseResponse(dsPersonId: account.dsPersonId, jingleDocType: "purchaseSuccess",
                                          jingleAction: "buyProduct", pings: nil)
        }
        return try parsePurchaseResponse(plist: plist)
    }

    func downloadRawPlist(appIdentifier: String, directoryServicesIdentifier: String,
                          appVersion: String? = nil, passwordToken: String? = nil,
                          storeFront: String? = nil) async throws -> [String: Any] {
        let account = accountStub(dsid: directoryServicesIdentifier, token: passwordToken, storeFront: storeFront)
        let guid = GUIDCache.shared.get()
        var body = downloadBody(appIdentifier: appIdentifier, appVersion: appVersion)
        body["guid"] = guid
        let kbsync = try await SAPSigner.shared.kbsync(guid: guid, dsid: account.dsPersonId, useCache: true)
        body["kbsync"] = kbsync
        let url = URL(string: "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download?guid=\(guid)")!
        let (plist, _) = try await storePlist(url, body: HTTPClient.encodePlist(body),
                                              headers: authHeaders(account), guid: guid)
        return plist
    }

    private func accountStub(dsid: String, token: String?, storeFront: String?) -> Account {
        Account(name: "", email: "", firstName: "", lastName: "",
                passwordToken: token ?? "", directoryServicesIdentifier: dsid,
                dsPersonId: dsid, cookies: [], countryCode: "", pod: "",
                storeResponse: Account.AccountStoreResponse(
                    directoryServicesIdentifier: dsid,
                    passwordToken: token ?? "",
                    storeFront: storeFront ?? "143441-1,34"),
                deviceGUID: GUIDCache.shared.get(), hsc: 0, adsid: "",
                idmsToken: "", kbsync: nil)
    }

    private func parseDownloadResponse(plist: [String: Any]) throws -> StoreDownloadResponse {

        let failureType = plist["failureType"] as? String ?? ""
        if !failureType.isEmpty {
            throw StoreError.fromFailureType(failureType)
        }
        guard let songs = plist["songList"] as? [[String: Any]] else {
            throw StoreError.notOwned
        }
        let songList = songs.compactMap { parseStoreItem(from: $0) }
        let dsPersonId = plist["dsPersonID"] as? String ?? ""
        let jingleDocType = plist["jingleDocType"] as? String
        let jingleAction = plist["jingleAction"] as? String
        let pings = plist["pings"] as? [String]
        return StoreDownloadResponse(
            songList: songList,
            dsPersonId: dsPersonId,
            jingleDocType: jingleDocType,
            jingleAction: jingleAction,
            pings: pings
        )
    }

    private func parseStoreItem(from dict: [String: Any]) -> StoreItem? {
        guard let url = dict["URL"] as? String,
              let md5 = dict["md5"] as? String else {
            return nil
        }
        var sinfs: [SinfInfo] = []
        if let sinfsArray = dict["sinfs"] as? [[String: Any]] {
            sinfs = sinfsArray.compactMap { sinfDict in
                guard let id = sinfDict["id"] as? Int,
                      let sinfString = sinfDict["sinf"] as? String else {
                    return nil
                }
                return SinfInfo(id: id, sinf: sinfString)
            }
        }
        var metadata: AppMetadata
        if let metadataDict = dict["metadata"] as? [String: Any] {
            let bundleId = metadataDict["softwareVersionBundleId"] as? String ??
                          metadataDict["bundle-identifier"] as? String ?? ""
            let bundleDisplayName = metadataDict["bundleDisplayName"] as? String ??
                                   metadataDict["itemName"] as? String ??
                                   metadataDict["item-name"] as? String ?? ""
            let bundleShortVersionString = metadataDict["bundleShortVersionString"] as? String ??
                                          metadataDict["bundle-short-version-string"] as? String ?? ""
            let softwareVersionExternalIdentifier = String(metadataDict["softwareVersionExternalIdentifier"] as? Int ?? 0)
            let softwareVersionExternalIdentifiers = metadataDict["softwareVersionExternalIdentifiers"] as? [Int]
            metadata = AppMetadata(
                bundleId: bundleId,
                bundleDisplayName: bundleDisplayName,
                bundleShortVersionString: bundleShortVersionString,
                softwareVersionExternalIdentifier: softwareVersionExternalIdentifier,
                softwareVersionExternalIdentifiers: softwareVersionExternalIdentifiers
            )
        } else {
            metadata = AppMetadata(
                bundleId: "",
                bundleDisplayName: "",
                bundleShortVersionString: "",
                softwareVersionExternalIdentifier: "",
                softwareVersionExternalIdentifiers: nil
            )
        }
        return StoreItem(
            url: url,
            md5: md5,
            sinfs: sinfs,
            metadata: metadata
        )
    }

    private func parsePurchaseResponse(plist: [String: Any]) throws -> StorePurchaseResponse {

        let failureType = plist["failureType"] as? String ?? ""
        let customerMessage = plist["customerMessage"] as? String ?? ""
        if !failureType.isEmpty {
            throw StoreError.fromFailureType(failureType)
        }
        let hasDialog = plist["dialog"] != nil
        if hasDialog && !customerMessage.isEmpty {
            throw StoreError.userInteractionRequired
        }
        let dsPersonId = (plist["dsPersonID"] as? String) ?? (plist["dsPersonId"] as? String) ?? ""
        return StorePurchaseResponse(
            dsPersonId: dsPersonId,
            jingleDocType: plist["jingleDocType"] as? String,
            jingleAction: plist["jingleAction"] as? String,
            pings: plist["pings"] as? [String]
        )
    }

}

public enum StoreError: Error, LocalizedError, Equatable {
    case networkError(Error)
    case invalidResponse
    case authenticationFailed
    case authenticationFailedWithDetails(String)
    case accountNotFound
    case invalidCredentials
    case invalidCredentialsWithDetails(String)
    case serverError(Int)
    case serverErrorWithDetails(Int, String)
    case unknown(String)
    case genericError
    case invalidItem
    case invalidLicense
    case unknownError
    case codeRequired
    case lockedAccount
    case lockedAccountWithDetails(String)
    case keychainError(OSStatus, String?)
    case userInteractionRequired
    case invalidVerificationCode
    case licenseExpired
    case paymentVerificationRequired
    case termsOfServiceUpdateRequired
    case storefrontChangeRequired
    case ageVerificationRequired
    case tooManyRequests
    case appNotAvailableInStorefront
    case notOwned

    public var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .authenticationFailed:
            return "Authentication failed"
        case .authenticationFailedWithDetails(let s):
            return "Authentication failed (\(s))"
        case .accountNotFound:
            return "Account not found"
        case .invalidCredentials:
            return "Invalid credentials"
        case .invalidCredentialsWithDetails(let s):
            return "Invalid credentials (\(s))"
        case .serverError(let code):
            return "Server error: \(code)"
        case .serverErrorWithDetails(let code, let s):
            return "Server error \(code): \(s)"
        case .unknown(let message):
            return "Unknown error: \(message)"
        case .genericError:
            return "Generic error occurred"
        case .invalidItem:
            return "Invalid item"
        case .invalidLicense:
            return "Invalid license"
        case .codeRequired:
            return "Verification code required"
        case .lockedAccount:
            return "Account is locked"
        case .lockedAccountWithDetails(let s):
            return "Account is locked (\(s))"
        case .keychainError(let status, let detail):
            let hex = String(format: "OSStatus=0x%08X(%d)", status, status)
            return "Keychain 失败 \(hex)：\(detail ?? SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        case .userInteractionRequired:
            return "store_err_auth_required".localized
        case .invalidVerificationCode:
            return "store_err_invalid_code".localized
        case .licenseExpired:
            return "store_err_license_expired".localized
        case .paymentVerificationRequired:
            return "purchase_err_payment_verification".localized
        case .termsOfServiceUpdateRequired:
            return "purchase_err_terms".localized
        case .storefrontChangeRequired:
            return "store_err_switch_region".localized
        case .ageVerificationRequired:
            return "purchase_err_age_verification".localized
        case .tooManyRequests:
            return "store_err_rate_limited".localized
        case .appNotAvailableInStorefront:
            return "purchase_err_region_unavailable".localized
        case .notOwned:
            return "store_err_not_purchased".localized
        case .unknownError:
            return "Unknown error occurred"
        }
    }

    public static func fromFailureType(_ failureType: String) -> StoreError {
        switch failureType {
        case "authenticationFailed", "2042":
            return .authenticationFailed
        case "accountNotFound":
            return .accountNotFound
        case "invalidCredentials", "2002":
            return .invalidCredentials
        case "codeRequired":
            return .codeRequired
        case "lockedAccount":
            return .lockedAccount
        case "invalidVerificationCode":
            return .invalidVerificationCode
        case "licenseExpired", "invalidLicense":
            return .licenseExpired
        case "2034", "paymentVerificationRequired":
            return .paymentVerificationRequired
        case "2056", "termsOfServiceUpdateRequired":
            return .termsOfServiceUpdateRequired
        case "storefrontChangeRequired", "100":
            return .storefrontChangeRequired
        case "ageVerificationRequired":
            return .ageVerificationRequired
        case "tooManyRequests", "rateLimitExceeded":
            return .tooManyRequests
        case "appNotAvailableInStorefront", "notAvailableInStorefront":
            return .appNotAvailableInStorefront
        case "notOwned", "notOwnedLicense", "noLicense", "9610":
            return .notOwned
        case "invalidItem":
            return .invalidItem
        case "userInteractionRequired":
            return .userInteractionRequired
        default:
            return .unknownError
        }
    }

    public static func == (lhs: StoreError, rhs: StoreError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidResponse, .invalidResponse),
             (.authenticationFailed, .authenticationFailed),
             (.accountNotFound, .accountNotFound),
             (.invalidCredentials, .invalidCredentials),
             (.genericError, .genericError),
             (.invalidItem, .invalidItem),
             (.invalidLicense, .invalidLicense),
             (.unknownError, .unknownError),
             (.codeRequired, .codeRequired),
             (.lockedAccount, .lockedAccount),
             (.keychainError, .keychainError),
             (.userInteractionRequired, .userInteractionRequired),
             (.invalidVerificationCode, .invalidVerificationCode),
             (.licenseExpired, .licenseExpired),
             (.paymentVerificationRequired, .paymentVerificationRequired),
             (.termsOfServiceUpdateRequired, .termsOfServiceUpdateRequired),
             (.storefrontChangeRequired, .storefrontChangeRequired),
             (.ageVerificationRequired, .ageVerificationRequired),
             (.tooManyRequests, .tooManyRequests),
             (.appNotAvailableInStorefront, .appNotAvailableInStorefront),
             (.notOwned, .notOwned):
            return true
        case (.authenticationFailedWithDetails(let l), .authenticationFailedWithDetails(let r)):
            return l == r
        case (.invalidCredentialsWithDetails(let l), .invalidCredentialsWithDetails(let r)):
            return l == r
        case (.lockedAccountWithDetails(let l), .lockedAccountWithDetails(let r)):
            return l == r
        case (.networkError(let lhsError), .networkError(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        case (.serverError(let lhsCode), .serverError(let rhsCode)):
            return lhsCode == rhsCode
        case (.serverErrorWithDetails(let lc, let ls), .serverErrorWithDetails(let rc, let rs)):
            return lc == rc && ls == rs
        case (.unknown(let lhsMessage), .unknown(let rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

struct StoreAuthResponse: Codable {
    let accountInfo: AccountInfo
    let passwordToken: String
    let dsPersonId: String
    let pings: [String]?
    let hsc: Int
    let adsid: String
    let idmsToken: String
    var pod: String = ""
    var kbsync: String? = nil

    struct AccountInfo: Codable {
        let appleId: String
        let address: Address
        let dsPersonId: String
        let countryCode: String?
        let storeFront: String?

        struct Address: Codable {
            let firstName: String
            let lastName: String
        }
    }

    init(accountInfo: AccountInfo, passwordToken: String, dsPersonId: String, pings: [String]?, hsc: Int = 0, adsid: String = "", idmsToken: String = "", pod: String = "", kbsync: String? = nil) {
        self.accountInfo = accountInfo
        self.passwordToken = passwordToken
        self.dsPersonId = dsPersonId
        self.pings = pings
        self.hsc = hsc
        self.adsid = adsid
        self.idmsToken = idmsToken
        self.pod = pod
        self.kbsync = kbsync
    }
}

struct StoreDownloadResponse: Codable {
    let songList: [StoreItem]
    let dsPersonId: String
    let jingleDocType: String?
    let jingleAction: String?
    let pings: [String]?
}

struct StorePurchaseResponse: Codable {
    let dsPersonId: String
    let jingleDocType: String?
    let jingleAction: String?
    let pings: [String]?
}

struct StoreItem: Codable {
    let url: String
    let md5: String
    let sinfs: [SinfInfo]
    let metadata: AppMetadata
}

struct AppMetadata: Codable {
    let bundleId: String
    let bundleDisplayName: String
    let bundleShortVersionString: String
    let softwareVersionExternalIdentifier: String
    let softwareVersionExternalIdentifiers: [Int]?

    enum CodingKeys: String, CodingKey {
        case bundleId = "softwareVersionBundleId"
        case bundleDisplayName
        case bundleShortVersionString
        case softwareVersionExternalIdentifier
        case softwareVersionExternalIdentifiers
    }
}

struct SinfInfo: Codable {
    let id: Int
    let sinf: String
}
