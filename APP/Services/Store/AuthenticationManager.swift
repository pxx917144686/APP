import Foundation
import Security

@MainActor
class AuthenticationManager: @unchecked Sendable {
    static let shared = AuthenticationManager()
    private let keychainService = "ipatool.swift.service"
    private let keychainAccount = "account"
    private init() {}

    func authenticate(email: String, password: String, mfa: String? = nil) async throws -> Account {
        let guid = GUIDCache.shared.get()
        if (mfa ?? "").isEmpty {
            do {
                _ = try await LegacyIDMSAuthenticator.shared.authenticate(email: email, password: password)
            } catch StoreError.codeRequired {
                // idmsa 409 时验证码已推送到受信设备；此处立即返回让 UI 弹出输入框，
                // 若继续走下面的 storeAuthenticate 还要等签名服务和 MZFinance 全跑完。
                // 用户输入验证码后由 authenticateWith2FA（密码+验证码）换强 token。
                throw StoreError.codeRequired
            } catch {
            }
        }
        let response = try await StoreRequest.shared.storeAuthenticate(
            email: email, password: password, code: mfa ?? "", guid: guid)
        guard !response.passwordToken.isEmpty, !response.dsPersonId.isEmpty else {
            throw StoreError.authenticationFailedWithDetails("Apple 未返回有效凭据（passwordToken/dsid 为空）")
        }
        let hasCode = !(mfa ?? "").isEmpty
        guard response.passwordToken.count >= 450 || hasCode else {
            PendingSAPAuth.push(email: email, password: password)
            throw StoreError.codeRequired
        }
        let gsa = buildAccountFromGSA(email: email, response: response)
        return await applyLegacyAuthNamePatch(gsa, email: email, password: password, mfa: mfa)
    }

    func authenticateWith2FA(email: String, password: String, code: String, isSMS: Bool = false, phoneId: String? = nil) async throws -> Account {
        let guid = GUIDCache.shared.get()
        PendingAuthHolder.set(password)
        PendingMFACodeHolder.set(code)
        let response = try await StoreRequest.shared.storeAuthenticate(
            email: email, password: password, code: code, guid: guid)
        guard !response.passwordToken.isEmpty, !response.dsPersonId.isEmpty else {
            throw StoreError.authenticationFailedWithDetails("Apple 未返回有效凭据（passwordToken/dsid 为空）")
        }
        let gsa = buildAccountFromGSA(email: email, response: response)
        AccountPodCache.shared.set(dsid: gsa.directoryServicesIdentifier, pod: gsa.pod)
        let patched = await applyLegacyAuthNamePatch(gsa, email: email, password: password, mfa: code)
        NotificationCenter.default.post(name: .accountStoreTokensRefreshed, object: nil, userInfo: ["email": patched.email])
        return patched
    }

    private func applyLegacyAuthNamePatch(_ gsa: Account, email: String, password: String, mfa: String?) async -> Account {
        let hasName = !gsa.name.isEmpty || (!gsa.firstName.isEmpty && !gsa.lastName.isEmpty)
        guard !hasName else { return gsa }
        let fallbackName = email.components(separatedBy: "@").first ?? "Apple ID 用户"
        return Account(
            name: fallbackName,
            email: gsa.email,
            firstName: gsa.firstName,
            lastName: gsa.lastName,
            passwordToken: gsa.passwordToken,
            directoryServicesIdentifier: gsa.directoryServicesIdentifier,
            dsPersonId: gsa.dsPersonId,
            cookies: gsa.cookies,
            countryCode: gsa.countryCode,
            pod: gsa.pod,
            storeResponse: gsa.storeResponse,
            deviceGUID: gsa.deviceGUID.isEmpty ? GUIDCache.shared.get() : gsa.deviceGUID,
            hsc: gsa.hsc,
            adsid: gsa.adsid,
            idmsToken: gsa.idmsToken
        )
    }

    private func buildAccountFromGSA(email: String, response: StoreAuthResponse) -> Account {
        let appleId = response.accountInfo.appleId.isEmpty ? email : response.accountInfo.appleId
        let firstName = response.accountInfo.address.firstName
        let lastName = response.accountInfo.address.lastName
        let parts = [firstName, lastName].filter { !$0.isEmpty }
        let displayName = parts.joined(separator: " ")
        let countryCode = detectCountryCode(from: response, email: email)
        let storeFront = detectStoreFront(from: response, countryCode: countryCode)
        let dsid = response.dsPersonId.isEmpty ? response.accountInfo.dsPersonId : response.dsPersonId
        return Account(
            name: displayName,
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
            idmsToken: response.idmsToken
        )
    }

    func resetAuthSession() {
        AppleIDAuthenticator.shared.resetSession()
        AppleIDAuthenticator.clearAppleCookies()
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

        let newFormatAccounts = loadAllAccountsFromKeychain()
        if !newFormatAccounts.isEmpty {
            SessionFileStore.save(newFormatAccounts)
            return newFormatAccounts
        }

        if let oldFormatAccount = loadAccountFromKeychain() {
            let accounts = [oldFormatAccount]
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

        for cookie in cookies {
            if cookie.domain.contains("apple.com") {
                if let expiresDate = cookie.expiresDate {
                    if expiresDate.timeIntervalSinceNow > 0 {
                        return true
                    }
                } else {
                    return true
                }
            }
        }

        return false
    }

    func refreshCookies(for account: Account) -> Account {
        let updatedAccount = Account(
            name: account.name,
            email: account.email,
            firstName: account.firstName,
            lastName: account.lastName,
            passwordToken: account.passwordToken,
            directoryServicesIdentifier: account.directoryServicesIdentifier,
            dsPersonId: account.dsPersonId,
            cookies: getCurrentCookies(),
            countryCode: account.countryCode,
            pod: account.pod,
            storeResponse: account.storeResponse,
            deviceGUID: account.deviceGUID,
            hsc: account.hsc,
            adsid: account.adsid,
            idmsToken: account.idmsToken
        )

        try? saveAccountToKeychain(updatedAccount)
        return updatedAccount
    }

    private func getCurrentCookies() -> [String] {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return [] }
        return cookies.compactMap { cookie in
            if cookie.domain.contains("apple.com") || cookie.domain.contains("itunes.apple.com") {
                return cookie.description
            }
            return nil
        }
    }

    func setCookies(_ cookies: [String]) {
        for cookieString in cookies {
            let components = cookieString.components(separatedBy: ";")
            var cookieDict: [HTTPCookiePropertyKey: Any] = [:]
            for component in components {
                let parts = component.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    let k = parts[0].lowercased()
                    if k == "domain" {
                        cookieDict[.domain] = parts[1]
                    } else if k == "path" {
                        cookieDict[.path] = parts[1]
                    } else if k == "secure" {
                        cookieDict[.secure] = true
                    } else {
                        cookieDict[.name] = parts[0]
                        cookieDict[.value] = parts[1]
                    }
                }
            }
            if let _ = cookieDict[.name] as? String, let _ = cookieDict[.value] as? String {
                cookieDict[.domain] = cookieDict[.domain] as? String ?? ".apple.com"
                cookieDict[.path] = cookieDict[.path] as? String ?? "/"
                if let cookie = HTTPCookie(properties: cookieDict) {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
            }
        }
    }

    private func detectCountryCode(from response: StoreAuthResponse, email: String) -> String {
        if let serverCountryCode = response.accountInfo.countryCode, !serverCountryCode.isEmpty {
            return serverCountryCode
        }

        if let storeFront = response.accountInfo.storeFront, !storeFront.isEmpty {
            let cc = inferCountryCodeFromStoreFront(storeFront)
            if !cc.isEmpty { return cc }
        }

        let cookieCountryCode = detectCountryCodeFromCookies()
        if !cookieCountryCode.isEmpty {
            return cookieCountryCode
        }

        return "US"
    }

    private func inferCountryCodeFromStoreFront(_ storeFront: String) -> String {
        let storeFrontCode = storeFront.components(separatedBy: "-").first ?? storeFront

        for (countryCode, code) in Apple.storeFrontCodeMap {
            if code == storeFrontCode {
                return countryCode
            }
        }

        return ""
    }

    private func detectCountryCodeFromCookies() -> String {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return "" }

        for cookie in cookies {
            if cookie.domain.contains("apple.com") {
                let cookieString = "\(cookie.name)=\(cookie.value)"

                if cookieString.contains("storefront") || cookieString.contains("storeFront") {
                    let components = cookieString.components(separatedBy: "=")
                    if components.count > 1 {
                        let value = components[1]
                        let storeFrontCode = value.components(separatedBy: "-").first ?? value
                        return inferCountryCodeFromStoreFront(storeFrontCode)
                    }
                }
            }
        }

        return ""
    }

    private func inferCountryCodeFromEmail(_ email: String) -> String {
        let domain = email.components(separatedBy: "@").last?.lowercased() ?? ""
        let domainMap: [String: String] = [
            ".cn": "CN", ".co.uk": "GB", ".uk": "GB", ".ac.uk": "GB",
            ".jp": "JP", ".kr": "KR", ".hk": "HK", ".tw": "TW",
            ".sg": "SG", ".au": "AU", ".ca": "CA", ".de": "DE",
            ".fr": "FR", ".it": "IT", ".es": "ES", ".nl": "NL",
            ".ru": "RU", ".br": "BR", ".in": "IN", ".mx": "MX",
            ".co.kr": "KR", ".co.jp": "JP", ".com.cn": "CN",
            ".com.hk": "HK", ".com.tw": "TW", ".com.sg": "SG",
            ".com.au": "AU", ".co.nz": "NZ", ".se": "SE",
            ".no": "NO", ".dk": "DK", ".fi": "FI", ".pl": "PL",
            ".tr": "TR", ".ae": "AE", ".sa": "SA", ".za": "ZA",
            ".com.mx": "MX", ".com.br": "BR", ".co.in": "IN"
        ]
        for (suffix, code) in domainMap {
            if domain.hasSuffix(suffix) {
                return code
            }
        }
        return ""
    }

    private func detectStoreFront(from response: StoreAuthResponse, countryCode: String) -> String {
        if let serverStoreFront = response.accountInfo.storeFront, !serverStoreFront.isEmpty {
            return serverStoreFront
        }

        let storeFrontCode = Apple.storeFrontCodeMap[countryCode] ?? "143441"
        return "\(storeFrontCode)-1,34"
    }

    private func loadAllAccountsFromKeychain() -> [Account] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        guard status == errSecSuccess,
              let data = dataTypeRef as? Data else {
            return []
        }

        let decoder = JSONDecoder()

        if let accounts = try? decoder.decode([Account].self, from: data) {
            return accounts
        } else if let account = try? decoder.decode(Account.self, from: data) {
            return [account]
        } else {
            return []
        }
    }

    private func saveAccountToKeychain(_ account: Account) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(account)
        try writeGenericPassword(service: self.keychainService, account: self.keychainAccount, data: data)
    }

    private func loadAccountFromKeychain() -> Account? {
        guard let data = readGenericPassword(service: self.keychainService, account: self.keychainAccount) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    private func saveAllAccountsToKeychain(_ accounts: [Account]) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(accounts)
        try writeGenericPassword(service: self.keychainService, account: self.keychainAccount, data: data)
    }

    private nonisolated func writeGenericPassword(service: String, account: String, data: Data) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary) 

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateAttrs: [String: Any] = [kSecValueData as String: data]
            status = SecItemUpdate(deleteQuery as CFDictionary, updateAttrs as CFDictionary)
        }
        if status == errSecSuccess { return }
        let benign: Set<OSStatus> = [
            errSecDuplicateItem,
            errSecInteractionNotAllowed,
            errSecUserCanceled,
            errSecDecode,
            errSecParam
        ]
        if benign.contains(status) {
            return
        }
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
        var dataTypeRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        guard status == errSecSuccess else {
            return nil
        }
        return dataTypeRef as? Data
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
