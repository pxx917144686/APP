import Foundation
import CommonCrypto

private func iso8601Now() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return f.string(from: Date())
}

private let CHINA_COUNTRY_CODES: Set<String> = ["CHN", "CHINA", "CN", "143465", "143477"]

private func isChinaRegionCode(_ code: String?) -> Bool {
    guard let c = code else { return false }
    let up = c.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return CHINA_COUNTRY_CODES.contains(up)
}

private let STOREFRONT_FROM_NUMERIC: [String: String] = [
    "143441": "US", "143465": "CN", "143477": "CN",
    "143462": "JP", "143444": "GB", "143443": "DE",
    "143442": "FR", "143460": "AU", "143455": "CA",
    "143450": "IT", "143454": "ES", "143466": "KR",
    "143503": "BR", "143468": "MX", "143467": "IN",
    "143469": "RU", "143452": "NL", "143456": "SE",
    "143457": "NO", "143458": "DK", "143447": "FI",
    "143463": "HK", "143470": "TW", "143475": "TH",
    "143476": "ID", "143473": "MY", "143474": "PH",
    "143464": "SG", "143481": "AE", "143479": "SA"
]

private func normalizeCountryCode(_ v: String?) -> String? {
    guard let s = v?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    if s.count == 2 { return s.uppercased() }
    if s.count == 3 {
        switch s.uppercased() {
        case "CHN": return "CN"
        case "USA": return "US"
        case "GBR": return "GB"
        case "JPN": return "JP"
        case "DEU": return "DE"
        case "FRA": return "FR"
        default: break
        }
    }
    let up = s.uppercased()
    if CHINA_COUNTRY_CODES.contains(up) { return "CN" }
    if let code = Int(s) {
        if let m = STOREFRONT_FROM_NUMERIC[String(code)] { return m }
        if code == 143465 || code == 143477 { return "CN" }
        if code == 143441 { return "US" }
    }
    return s.uppercased()
}

private func countryCodeFromStoreFront(_ sf: String?) -> String? {
    guard let s = sf, !s.isEmpty else { return nil }
    let code = s.components(separatedBy: "-").first ?? s
    for (cc, num) in Apple.storeFrontCodeMap where num == code {
        return cc
    }
    if let m = STOREFRONT_FROM_NUMERIC[code] { return m }
    return nil
}

final class SRPURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = SRPURLSessionDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request)
    }
}

func syncCookiesToShared(dsPersonId: String, passwordToken: String, appleId: String, countryCode: String? = nil, storeFront: String? = nil, forceCN: Bool = false) {
    let storage = HTTPCookieStorage.shared
    for c in storage.cookies ?? [] {
        let d = c.domain.lowercased()
        if d == "apple.com" || d.hasSuffix(".apple.com") ||
           d == "itunes.apple.com" || d.hasSuffix(".itunes.apple.com") ||
           d == "icloud.com" || d.hasSuffix(".icloud.com") {
            storage.deleteCookie(c)
        }
    }
    func add(name: String, value: String, domain: String) {
        if let c = HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: true, .version: 0]) {
            storage.setCookie(c)
        }
    }
    let isCN = forceCN || isChinaRegionCode(countryCode) || isChinaRegionCode(storeFront)
    var domains: Set<String> = [".apple.com", ".itunes.apple.com"]
    if isCN {
        domains.insert(".apple.com.cn")
        domains.insert(".icloud.com.cn")
    }
    if let sf = storeFront, !sf.isEmpty {
        for d in domains {
            add(name: "s_isf", value: sf, domain: d)
            add(name: "storefront", value: sf, domain: d)
            add(name: "X-Apple-Store-Front", value: sf, domain: d)
        }
    }
    for d in domains {
        add(name: "DSPersonID", value: dsPersonId, domain: d)
        if isTrueCommerceKitPasswordToken(passwordToken) {
            add(name: "download_token", value: passwordToken, domain: d)
        }
        add(name: "mzf_in", value: "1", domain: d)
        if !appleId.isEmpty { add(name: "aocid2", value: appleId, domain: d) }
    }
}

private func buildStoreAuthResponse(dsPersonId: String, passwordToken: String, appleId: String, firstName: String, lastName: String, countryCode: String?, storeFront: String?, hsc: Int = 0, adsid: String = "", idmsToken: String = "") -> StoreAuthResponse {
    let addr = StoreAuthResponse.AccountInfo.Address(firstName: firstName, lastName: lastName)
    let cc = countryCode?.isEmpty == true ? nil : countryCode
    let sf = storeFront?.isEmpty == true ? nil : storeFront
    let info = StoreAuthResponse.AccountInfo(appleId: appleId, address: addr, dsPersonId: dsPersonId, countryCode: cc, storeFront: sf)
    return StoreAuthResponse(accountInfo: info, passwordToken: passwordToken, dsPersonId: dsPersonId, pings: nil, hsc: hsc, adsid: adsid, idmsToken: idmsToken)
}

struct PendingAuthHolder {
    static var password: String = ""
    static let lock = NSLock()
    static func get() -> String { lock.lock(); defer { lock.unlock() }; return password }
    static func set(_ v: String) { lock.lock(); defer { lock.unlock() }; password = v }
}

func composeCookieLines(dsid: String, storeFront: String, pod: String, passwordToken: String) -> [String] {
    var out: [String] = []
    if !dsid.isEmpty && !passwordToken.isEmpty {
        out.append("mz_at0_fr-\(dsid)=\(passwordToken); Domain=apple.com; Path=/; Secure; HttpOnly")
    }
    if !pod.isEmpty {
        out.append("itspod=\(pod); Domain=itunes.apple.com; Path=/")
        out.append("pod=\(pod); Domain=apple.com; Path=/")
    }
    if !storeFront.isEmpty {
        out.append("X-Apple-Store-Front=\(storeFront); Domain=apple.com; Path=/")
    }
    return out
}

func storeRealSessionCookies(_ lines: [String]) {
    for line in lines {
        let parts = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first else { continue }
        let nv = first.split(separator: "=", maxSplits: 1).map(String.init)
        guard nv.count == 2, !nv[0].isEmpty else { continue }
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: nv[0],
            .value: nv[1],
            .domain: ".apple.com",
            .path: "/"
        ]
        for p in parts.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0].uppercased() {
            case "DOMAIN":
                props[.domain] = kv[1].hasPrefix(".") ? kv[1] : "." + kv[1]
            case "PATH":
                props[.path] = kv[1]
            default:
                break
            }
        }
        if let c = HTTPCookie(properties: props) {
            HTTPCookieStorage.shared.setCookie(c)
        }
    }
}

final class AccountPodCache {
    static let shared = AccountPodCache()
    private var map: [String: String] = [:]
    private let lock = NSLock()
    func set(dsid: String, pod: String) {
        guard !pod.isEmpty else { return }
        lock.lock()
        map[dsid] = pod
        lock.unlock()
    }
    func get(dsid: String) -> String {
        lock.lock()
        let v = map[dsid] ?? ""
        lock.unlock()
        return v
    }
    func clear(dsid: String) {
        lock.lock()
        map.removeValue(forKey: dsid)
        lock.unlock()
    }
}

struct PendingMFACodeHolder {
    static var code: String? = nil
    static let lock = NSLock()
    static func get() -> String? { lock.lock(); defer { lock.unlock() }; return code }
    static func set(_ v: String?) { lock.lock(); defer { lock.unlock() }; code = v }
}

class AppleIDAuthenticator: @unchecked Sendable {
    static let shared = AppleIDAuthenticator()

    private var pendingEmail = ""
    private var pendingPassword = ""
    private var pendingTokens: GSAAuthTokens?
    private var pendingAniHeaders: [String: String] = [:]
    private var pendingAniData: AnisetteData?
    private var pendingCountryCode: String?
    private var pendingStoreFront: String?
    private var pendingClientInfo = ""
    private var lastAuthEmail = ""
    private var lastAuthTime: Date?
    private var authInFlight = false
    private var consecutiveFailures = 0
    private var nextAllowedAuthAt: Date?
    private let maxConsecutiveFailures = 5
    private var pendingGSASession: GSALoginSession?

    private func checkRateLimitForEmail(_ email: String) -> Bool {
        let now = Date()
        if let t = nextAllowedAuthAt, now < t { return true }
        if lastAuthEmail == email, let last = lastAuthTime, now.timeIntervalSince(last) < 60 {
            return true
        }
        return false
    }

    private func markAuthStarted(_ email: String) {
        authInFlight = true
        lastAuthEmail = email
        lastAuthTime = Date()
    }

    private func markAuthEnded(success: Bool) {
        authInFlight = false
        if success {
            consecutiveFailures = 0
            nextAllowedAuthAt = nil
        } else {
            consecutiveFailures += 1
            if consecutiveFailures >= maxConsecutiveFailures {
                nextAllowedAuthAt = Date().addingTimeInterval(5 * 60)
            } else if consecutiveFailures >= 2 {
                let base = pow(2.0, Double(consecutiveFailures))
                nextAllowedAuthAt = Date().addingTimeInterval(min(base, 60))
            }
        }
    }

    func authenticate(email: String, password: String, mfaCode: String? = nil) async throws -> StoreAuthResponse {
        if let mfa = mfaCode, !mfa.trimmingCharacters(in: .whitespaces).isEmpty {
            return try await validate2FACode(mfa)
        }

        if authInFlight { throw StoreError.tooManyRequests }
        if checkRateLimitForEmail(email) {
            throw StoreError.tooManyRequests
        }
        markAuthStarted(email)
        var success = false
        defer { markAuthEnded(success: success) }

        pendingEmail = email
        pendingPassword = password
        PendingAuthHolder.set(password)
        PendingMFACodeHolder.set(nil)
        pendingCountryCode = nil
        pendingStoreFront = nil

        do {
            let aniData = try await AnisetteProvisioner.shared.getAnisette()
            let session = GSALoginSession(email: email, password: password, aniData: aniData)
            let outcome = try await session.beginRound()
            switch outcome {
            case .authenticated(let result):
                success = true
                return try await finalizeGSAAuth(session: session, result: result)
            case .twoFactorRequired(let tokens):
                pendingGSASession = session
                pendingTokens = tokens
                pendingCountryCode = normalizeCountryCode(tokens.countryCode) ?? countryCodeFromStoreFront(tokens.storeFront)
                pendingStoreFront = tokens.storeFront
                do {
                    try await session.requestTrustedDeviceNotification()
                } catch {
                }
                success = true
                throw StoreError.codeRequired
            }
        } catch GSAClientError.lockedAccount(let details) {
            nextAllowedAuthAt = Date().addingTimeInterval(30 * 60)
            consecutiveFailures = maxConsecutiveFailures
            throw StoreError.lockedAccountWithDetails(details)
        } catch GSAClientError.invalidCredentials(let details) {
            throw StoreError.invalidCredentialsWithDetails(details)
        } catch GSAClientError.invalidSecurityCode {
            throw StoreError.invalidVerificationCode
        } catch GSAClientError.tooManyRequests {
            nextAllowedAuthAt = Date().addingTimeInterval(10 * 60)
            throw StoreError.tooManyRequests
        } catch GSAClientError.serverError(let code, let msg) {
            if code >= 500 {
                throw StoreError.authenticationFailedWithDetails("Apple 服务暂时不可用（HTTP \(code)），请稍后重试")
            }
            throw StoreError.serverErrorWithDetails(code, msg)
        } catch GSAClientError.requestFailed(let code, let details) {
            if code == 429 || code == -20210 {
                nextAllowedAuthAt = Date().addingTimeInterval(10 * 60)
                throw StoreError.tooManyRequests
            }
            if code >= 500 {
                throw StoreError.authenticationFailedWithDetails("Apple 服务暂时不可用（HTTP \(code)），请稍后重试")
            }
            throw StoreError.authenticationFailedWithDetails("请求失败(\(code)): \(String(details.prefix(300)))")
        } catch GSAClientError.trustedDeviceNotifyFailed {
            throw StoreError.authenticationFailedWithDetails("无法向受信任设备发送验证码推送")
        } catch GSAClientError.srpKeyUnavailable {
            throw StoreError.authenticationFailedWithDetails("SRP 会话密钥生成失败，请重试")
        } catch GSAClientError.spdDecodeFailed {
            throw StoreError.authenticationFailedWithDetails("会话解密失败，请重试")
        } catch let e as StoreError {
            throw e
        } catch {
            throw StoreError.authenticationFailedWithDetails(error.localizedDescription)
        }
    }

    private func finalizeGSAAuth(session: GSALoginSession, result: GSAClient.GSAuthResult) async throws -> StoreAuthResponse {
        if let pt = result.passwordToken, isTrueCommerceKitPasswordToken(pt),
           let dsid = result.dsPersonId, !dsid.isEmpty {
            pendingGSASession = nil
            seedGSASessionCookies(session: session, dsid: dsid)
            return buildGSAResponse(result, email: pendingEmail.isEmpty ? session.email : pendingEmail)
        }
        let outcome = try await session.beginRound()
        switch outcome {
        case .authenticated(let r2):
            if let pt2 = r2.passwordToken, isTrueCommerceKitPasswordToken(pt2),
               let dsid2 = r2.dsPersonId, !dsid2.isEmpty {
                pendingGSASession = nil
                seedGSASessionCookies(session: session, dsid: dsid2)
                return buildGSAResponse(r2, email: pendingEmail.isEmpty ? session.email : pendingEmail)
            }
            throw StoreError.authenticationFailedWithDetails(
                "Apple 未下发可下载的强 token（\(r2.passwordToken?.count ?? 0)B < 450B）。请退出后重新登录重试。"
            )
        case .twoFactorRequired(let t2):
            pendingGSASession = session
            pendingTokens = t2
            pendingCountryCode = normalizeCountryCode(t2.countryCode) ?? countryCodeFromStoreFront(t2.storeFront)
            pendingStoreFront = t2.storeFront
            do {
                try await session.requestTrustedDeviceNotification()
            } catch {
            }
            throw StoreError.codeRequired
        }
    }

    private func seedGSASessionCookies(session: GSALoginSession, dsid: String) {
        let real = session.sessionCookieLines()
        guard !real.isEmpty else { return }
        AuthCookieCache.shared.set(dsid: dsid, cookies: real)
        storeRealSessionCookies(real)
    }

    private func buildGSAResponse(_ result: GSAClient.GSAuthResult, email: String) -> StoreAuthResponse {
        let info: [String: Any]? = result.accountInfo
        var appleId = email
        var firstName = ""
        var lastName = ""
        var countryCode: String? = nil
        var storeFront: String? = nil
        if let info {
            if let aid = info["appleId"] as? String, !aid.isEmpty { appleId = aid }
            let resolved = Apple.resolveName(roots: [result.raw, info], tag: "GSA-auth")
            firstName = resolved.firstName.isEmpty ? resolved.fallbackFull : resolved.firstName
            lastName = resolved.lastName
            countryCode = (info["countryCode"] as? String) ?? result.tokens?.countryCode
            storeFront = (info["storeFront"] as? String) ?? (info["Storefront"] as? String) ?? result.tokens?.storeFront
        } else {
            let resolved = Apple.resolveName(roots: [result.raw], tag: "GSA-auth-no-info")
            firstName = resolved.firstName.isEmpty ? resolved.fallbackFull : resolved.firstName
            lastName = resolved.lastName
            countryCode = result.tokens?.countryCode
            storeFront = result.tokens?.storeFront
        }
        let normCC = normalizeCountryCode(countryCode) ?? countryCodeFromStoreFront(storeFront)
        let finalSF = storeFront ?? (normCC.flatMap { Apple.storeFrontCodeMap[$0].flatMap { "\($0)-1,29" } })
        let dsid = result.dsPersonId ?? ""
        pendingCountryCode = normCC
        pendingStoreFront = finalSF
        let pt = result.passwordToken ?? ""
        syncCookiesToShared(
            dsPersonId: dsid,
            passwordToken: pt,
            appleId: appleId,
            countryCode: normCC,
            storeFront: finalSF
        )
        return buildStoreAuthResponse(
            dsPersonId: dsid,
            passwordToken: pt,
            appleId: appleId,
            firstName: firstName,
            lastName: lastName,
            countryCode: normCC,
            storeFront: finalSF,
            hsc: 0,
            adsid: result.tokens?.adsid ?? "",
            idmsToken: result.tokens?.idmsToken ?? ""
        )
    }

    static func clearAppleCookies() {
        let storage = HTTPCookieStorage.shared
        for c in storage.cookies ?? [] {
            let d = c.domain.lowercased()
            if d == "apple.com" || d.hasSuffix(".apple.com") ||
               d == "itunes.apple.com" || d.hasSuffix(".itunes.apple.com") ||
               d == "icloud.com" || d.hasSuffix(".icloud.com") {
                storage.deleteCookie(c)
            }
        }
    }

    func resetSession() {
        pendingEmail = ""
        pendingPassword = ""
        PendingAuthHolder.set("")
        pendingGSASession = nil
        PendingMFACodeHolder.set(nil)
        pendingTokens = nil
        pendingAniHeaders = [:]
        pendingAniData = nil
        pendingCountryCode = nil
        pendingStoreFront = nil
        pendingClientInfo = ""
        lastAuthEmail = ""
        lastAuthTime = nil
        AppleIDAuthenticator.clearAppleCookies()
        AnisetteProvisioner.shared.reset()
    }

    func clearFailureCooldown() { resetSession() }
    var canRetryFullSRPForMFA: Bool { !pendingEmail.isEmpty && !pendingPassword.isEmpty }

    func validate2FACode(_ code: String, isSMS: Bool = false, phoneId: String? = nil) async throws -> StoreAuthResponse {
        guard !pendingEmail.isEmpty else { throw StoreError.codeRequired }
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count == 6, Int(clean) != nil else { throw StoreError.invalidVerificationCode }
        PendingMFACodeHolder.set(clean)

        var session = pendingGSASession
        if session == nil {
            let aniData = try await AnisetteProvisioner.shared.getAnisette()
            let fresh = GSALoginSession(email: pendingEmail, password: pendingPassword, aniData: aniData)
            let outcome = try await fresh.beginRound()
            switch outcome {
            case .authenticated(let r):
                pendingGSASession = fresh
                return try await finalizeGSAAuth(session: fresh, result: r)
            case .twoFactorRequired:
                session = fresh
                pendingGSASession = fresh
            }
        }
        guard let session else { throw StoreError.codeRequired }

        do {
            let outcome = try await session.completeAfterCode(clean, isSMS: isSMS, phoneId: phoneId)
            switch outcome {
            case .authenticated(let result):
                return try await finalizeGSAAuth(session: session, result: result)
            case .twoFactorRequired(let t2):
                pendingTokens = t2
                try? await session.requestTrustedDeviceNotification()
                throw StoreError.codeRequired
            }
        } catch GSAClientError.invalidSecurityCode(_) {
            throw StoreError.codeRequired
        } catch GSAClientError.lockedAccount(let d) {
            throw StoreError.lockedAccountWithDetails(d)
        } catch GSAClientError.tooManyRequests {
            throw StoreError.tooManyRequests
        } catch GSAClientError.serverError(let c, let m) {
            if c >= 500 {
                throw StoreError.authenticationFailedWithDetails("Apple 服务暂时不可用（HTTP \(c)），请稍后重试")
            }
            throw StoreError.serverErrorWithDetails(c, m)
        } catch GSAClientError.requestFailed(let c, let d) {
            if c == 429 || c == -20210 { throw StoreError.tooManyRequests }
            if c >= 500 {
                throw StoreError.authenticationFailedWithDetails("Apple 服务暂时不可用（HTTP \(c)），请稍后重试")
            }
            throw StoreError.authenticationFailedWithDetails("请求失败(\(c)): \(String(d.prefix(300)))")
        } catch GSAClientError.spdDecodeFailed {
            throw StoreError.authenticationFailedWithDetails("会话解密失败，请重试")
        } catch let e as StoreError {
            throw e
        } catch {
            throw StoreError.authenticationFailedWithDetails(error.localizedDescription)
        }
    }
}
