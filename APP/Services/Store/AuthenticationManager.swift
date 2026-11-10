import Foundation
import Security

@MainActor
class AuthenticationManager: @unchecked Sendable {
    static let shared = AuthenticationManager()
    private let keychainService = "ipatool.swift.service"
    private let keychainAccount = "account"
    private init() {}

    func authenticate(email: String, password: String, mfa: String? = nil) async throws -> Account {
        let response = try await requestStoreAuth(email: email, password: password, code: mfa ?? "")
        return buildAccount(email: email, response: response)
    }

    func authenticateWith2FA(email: String, password: String, code: String,
                             isSMS: Bool = false, phoneId: String? = nil) async throws -> Account {
        let response = try await requestStoreAuth(email: email, password: password, code: code)
        let account = buildAccount(email: email, response: response)
        NotificationCenter.default.post(name: .accountStoreTokensRefreshed,
                                        object: nil, userInfo: ["email": account.email])
        return account
    }

    func reauthenticate(email: String, password: String) async throws -> Account {
        let resp = try await requestStoreAuth(email: email, password: password, code: "")
        let fresh = buildAccount(email: email, response: resp)
        var accounts = loadAllSavedAccounts()
        if let idx = accounts.firstIndex(where: { $0.email == email }) {
            accounts[idx] = fresh
        } else {
            accounts.append(fresh)
        }
        try? saveAllAccounts(accounts)
        return fresh
    }

    private func requestStoreAuth(email: String, password: String, code: String) async throws -> StoreAuthResponse {
        let guid = GUIDCache.shared.get()
        let signer = SAPSigner.shared
        do {
            let endpoint = try await AppleAuthentication.configuration(
                guid: guid,
                send: { try await HTTPClient.shared.request($0, headers: ["Accept": "application/xml"]) },
                report: { _ in })

            let body = try IPadnLogin.body(email: email, password: password, code: code, guid: guid)
            let signature = try await signer.sign(body, guid: guid, useCache: true, cacheSignature: false)
            var headers = ["Content-Type": "application/x-apple-plist",
                           "X-Apple-ActionSignature": signature]
            if let sf = IPadnLogin.phoneNumberStorefront(email) { headers["X-Apple-Store-Front"] = sf }

            let (raw, response) = try await AppleAuthentication.withStoreProof(
                endpoint: endpoint,
                baseHeaders: headers,
                loadProof: { try await signer.storeProofHeaders(guid: guid, useCache: true) },
                provisionProof: { challenge in
                    try await signer.provisionStoreProof(challenge: challenge, guid: guid, useCache: true)
                },
                resetProof: { signer.resetStoreProof(guid: guid) },
                execute: { headerProvider in
                    try await AppleAuthentication.authenticate(
                        endpoint: endpoint, body: body,
                        makeHeaders: { try await headerProvider(endpoint) },
                        send: { url, body, headers in
                            try await HTTPClient.shared.request(
                                url, method: "POST", body: body, headers: headers,
                                appleRedirects: true, authentication: true,
                                refreshHeaders: headerProvider)
                        },
                        report: { _ in })
                })

            if let failure = IPadnLogin.failure(raw, submittedCode: !code.isEmpty) { throw failure }

            var cookieHeaders: [String: String] = [:]
            for (k, v) in response.allHeaderFields { cookieHeaders[String(describing: k)] = String(describing: v) }
            let cookies = response.url.map { HTTPCookie.cookies(withResponseHeaderFields: cookieHeaders, for: $0) } ?? []
            for c in cookies { HTTPCookieStorage.shared.setCookie(c) }

            var dsid = plistString(raw["dsPersonId"])
            if dsid.isEmpty,
               let h = response.value(forHTTPHeaderField: "X-Dsid")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !h.isEmpty, h.allSatisfy({ $0.isASCII && $0.isNumber }) { dsid = h }
            let token = plistString(raw["passwordToken"])
            guard !dsid.isEmpty, !token.isEmpty else {
                throw StoreError.authenticationFailedWithDetails("auth_err_incomplete_credentials".localized)
            }
            let cookieString = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            if !cookieString.isEmpty {
                AuthCookieCache.shared.set(dsid: dsid, cookies: [cookieString])
                UserDefaults.standard.set(cookieString, forKey: "ipadn_cookie_\(dsid)")
            }
            let info = raw["accountInfo"] as? [String: Any] ?? [:]
            let appleId = plistString(info["appleId"])
            let address = info["address"] as? [String: Any] ?? [:]
            let fullStore = response.value(forHTTPHeaderField: "X-Set-Apple-Store-Front")
                ?? response.value(forHTTPHeaderField: "X-Apple-Request-Store-Front") ?? ""

            return StoreAuthResponse(
                accountInfo: StoreAuthResponse.AccountInfo(
                    appleId: appleId.isEmpty ? email : appleId,
                    address: StoreAuthResponse.AccountInfo.Address(
                        firstName: plistString(address["firstName"]),
                        lastName: plistString(address["lastName"])),
                    dsPersonId: dsid,
                    countryCode: nil,
                    storeFront: fullStore.isEmpty ? nil : fullStore),
                passwordToken: token,
                dsPersonId: dsid,
                pings: nil,
                pod: "",
                kbsync: nil)
        } catch let e as StoreError {
            throw e
        } catch {
            throw StoreError.authenticationFailedWithDetails(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func buildAccount(email: String, response: StoreAuthResponse) -> Account {
        let appleId = response.accountInfo.appleId.isEmpty ? email : response.accountInfo.appleId
        let firstName = response.accountInfo.address.firstName
        let lastName = response.accountInfo.address.lastName
        let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        let countryCode = detectCountryCode(from: response, email: email)
        let storeFront = detectStoreFront(from: response, countryCode: countryCode)
        let dsid = response.dsPersonId.isEmpty ? response.accountInfo.dsPersonId : response.dsPersonId
        return Account(
            name: name.isEmpty ? (email.components(separatedBy: "@").first ?? "account_default_name".localized) : name,
            email: appleId,
            firstName: firstName,
            lastName: lastName,
            passwordToken: response.passwordToken,
            directoryServicesIdentifier: dsid,
            dsPersonId: dsid,
            cookies: [],
            countryCode: countryCode,
            pod: AccountPodCache.shared.get(dsid: dsid),
            storeResponse: Account.AccountStoreResponse(
                directoryServicesIdentifier: dsid,
                passwordToken: response.passwordToken,
                storeFront: storeFront
            ),
            deviceGUID: GUIDCache.shared.get(),
            hsc: response.hsc,
            adsid: response.adsid,
            idmsToken: response.idmsToken,
            kbsync: response.kbsync
        )
    }

    func resetAuthSession() {
        for cookie in HTTPCookieStorage.shared.cookies ?? [] {
            if cookie.domain.contains("apple.com") { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
    }

    func loadAllSavedAccounts() -> [Account] {
        let fileAccounts = SessionFileStore.load()
        if !fileAccounts.isEmpty {
            let kc = loadAllAccountsFromKeychain()
            if !kc.isEmpty {
                let emails = Set(fileAccounts.map(\.email))
                let merged = fileAccounts + kc.filter { !emails.contains($0.email) }
                if merged.count != fileAccounts.count {
                    SessionFileStore.save(merged)
                    return merged
                }
            }
            return fileAccounts
        }
        let keychainAccounts = loadAllAccountsFromKeychain()
        if !keychainAccounts.isEmpty {
            SessionFileStore.save(keychainAccounts)
            return keychainAccounts
        }
        if let old = loadAccountFromKeychain() {
            let accounts = [old]
            SessionFileStore.save(accounts)
            return accounts
        }
        return []
    }

    func saveAllAccounts(_ accounts: [Account]) throws {
        SessionFileStore.save(accounts)
        try saveAllAccountsToKeychain(accounts)
    }

    func validateAccount(_ account: Account) async -> Bool {
        setCookies(account.cookies)
        guard let cookies = HTTPCookieStorage.shared.cookies else { return false }
        for cookie in cookies where cookie.domain.contains("apple.com") {
            if let expires = cookie.expiresDate, expires.timeIntervalSinceNow <= 0 { continue }
            return true
        }
        return false
    }

    func refreshCookies(for account: Account) -> Account {
        let updated = Account(
            name: account.name, email: account.email,
            firstName: account.firstName, lastName: account.lastName,
            passwordToken: account.passwordToken,
            directoryServicesIdentifier: account.directoryServicesIdentifier,
            dsPersonId: account.dsPersonId, cookies: getCurrentCookies(),
            countryCode: account.countryCode, pod: account.pod,
            storeResponse: account.storeResponse, deviceGUID: account.deviceGUID,
            hsc: account.hsc, adsid: account.adsid, idmsToken: account.idmsToken,
            kbsync: account.kbsync
        )
        try? saveAccountToKeychain(updated)
        return updated
    }

    private func getCurrentCookies() -> [String] {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return [] }
        return cookies.compactMap {
            ($0.domain.contains("apple.com") || $0.domain.contains("itunes.apple.com"))
                ? $0.description : nil
        }
    }

    func setCookies(_ cookies: [String]) {
        for cookieString in cookies {
            var cookieDict: [HTTPCookiePropertyKey: Any] = [:]
            for component in cookieString.components(separatedBy: ";") {
                let parts = component.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                switch parts[0].lowercased() {
                case "domain": cookieDict[.domain] = parts[1]
                case "path": cookieDict[.path] = parts[1]
                case "secure": cookieDict[.secure] = true
                default:
                    cookieDict[.name] = parts[0]
                    cookieDict[.value] = parts[1]
                }
            }
            guard cookieDict[.name] is String, cookieDict[.value] is String else { continue }
            if cookieDict[.domain] == nil { cookieDict[.domain] = ".apple.com" }
            if cookieDict[.path] == nil { cookieDict[.path] = "/" }
            if let cookie = HTTPCookie(properties: cookieDict) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    private func detectCountryCode(from response: StoreAuthResponse, email: String) -> String {
        if let cc = response.accountInfo.countryCode, !cc.isEmpty { return cc }
        if let sf = response.accountInfo.storeFront, !sf.isEmpty {
            let code = inferCountryCodeFromStoreFront(sf)
            if !code.isEmpty { return code }
        }
        let fromCookies = detectCountryCodeFromCookies()
        return fromCookies.isEmpty ? "US" : fromCookies
    }

    private func inferCountryCodeFromStoreFront(_ storeFront: String) -> String {
        let code = storeFront.components(separatedBy: "-").first ?? storeFront
        return Apple.storeFrontCodeMap.first { $0.value == code }?.key ?? ""
    }

    private func detectCountryCodeFromCookies() -> String {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return "" }
        for cookie in cookies where cookie.domain.contains("apple.com") {
            if cookie.name.contains("storefront") || cookie.name.contains("storeFront") {
                let comps = cookie.value.components(separatedBy: "=")
                if comps.count > 1 {
                    return inferCountryCodeFromStoreFront(comps[1].components(separatedBy: "-").first ?? comps[1])
                }
            }
        }
        return ""
    }

    private func detectStoreFront(from response: StoreAuthResponse, countryCode: String) -> String {
        if let sf = response.accountInfo.storeFront, !sf.isEmpty { return sf }
        return "\(Apple.storeFrontCodeMap[countryCode] ?? "143441")-1,34"
    }

    private func loadAllAccountsFromKeychain() -> [Account] {
        guard let data = readGenericPassword(service: keychainService, account: keychainAccount) else { return [] }
        let decoder = JSONDecoder()
        if let accounts = try? decoder.decode([Account].self, from: data) { return accounts }
        if let account = try? decoder.decode(Account.self, from: data) { return [account] }
        return []
    }

    private func saveAccountToKeychain(_ account: Account) throws {
        try writeGenericPassword(service: keychainService, account: keychainAccount,
                                 data: JSONEncoder().encode(account))
    }

    private func loadAccountFromKeychain() -> Account? {
        guard let data = readGenericPassword(service: keychainService, account: keychainAccount) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    private func saveAllAccountsToKeychain(_ accounts: [Account]) throws {
        try writeGenericPassword(service: keychainService, account: keychainAccount,
                                 data: JSONEncoder().encode(accounts))
    }

    private nonisolated func writeGenericPassword(service: String, account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        if status == errSecSuccess { return }
        let benign: Set<OSStatus> = [errSecDuplicateItem, errSecInteractionNotAllowed,
                                     errSecUserCanceled, errSecDecode, errSecParam]
        if benign.contains(status) { return }
        throw StoreError.keychainError(status, "service=\(service) account=\(account)")
    }

    private nonisolated func readGenericPassword(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess else { return nil }
        return ref as? Data
    }

    func replaceSavedAccount(oldEmail: String, newAccount: Account) throws {
        var accounts = loadAllSavedAccounts()
        if let idx = accounts.firstIndex(where: { $0.email == oldEmail }) {
            accounts[idx] = newAccount
        } else {
            accounts.append(newAccount)
        }
        try saveAllAccountsToKeychain(accounts)
    }
}
