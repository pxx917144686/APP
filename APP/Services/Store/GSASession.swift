import Foundation

enum GSARoundOutcome {
    case authenticated(GSAClient.GSAuthResult)
    case twoFactorRequired(GSAAuthTokens)
}

final class GSALoginSession: @unchecked Sendable {
    let email: String
    let password: String

    private let cookieStorage: HTTPCookieStorage
    private let session: URLSession

    private var aniData: AnisetteData?
    private var aniFetchedAt: Date?

    private var srpUser: PySRPUser?
    private var initResp: GSAInitResponse?
    private var srpM1: [UInt8]?

    private var didValidate = false

    private(set) var tokens: GSAAuthTokens?

    init(email: String, password: String, aniData: AnisetteData? = nil) {
        self.email = email
        self.password = password
        let storage = HTTPCookieStorage()
        storage.cookieAcceptPolicy = .always
        self.cookieStorage = storage
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.httpCookieStorage = storage
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCredentialStorage = nil
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        cfg.tlsMaximumSupportedProtocolVersion = .TLSv13
        self.session = URLSession(configuration: cfg)
        self.aniData = aniData
        self.aniFetchedAt = (aniData != nil) ? Date() : nil
    }

    func sessionCookieLines() -> [String] {
        (cookieStorage.cookies ?? []).map { c in
            "\(c.name)=\(c.value); Domain=\(c.domain.hasPrefix(".") ? c.domain : "." + c.domain); Path=\(c.path)"
        }
    }

    func beginRound(securityCode: String? = nil) async throws -> GSARoundOutcome {
        didValidate = false
        try await refreshAnisetteIfNeeded()
        var user = PySRPUser(username: email)
        let initResp = try await withRetry("SRP init") {
            try await GSAClient.shared.grandSlamInit(
                email: email,
                publicA: user.startAuthentication(),
                aniData: try currentAnisette(),
                urlSession: session
            )
        }
        let derived = try encryptPassword(
            password: password,
            salt: [UInt8](initResp.s),
            iterations: initResp.iterations,
            proto: initResp.proto
        )
        guard let m1 = user.processChallenge(
            salt: [UInt8](initResp.s),
            serverB_bytes: [UInt8](initResp.B),
            derivedPassword: derived
        ) else {
            throw GSAClientError.srpKeyUnavailable
        }
        srpUser = user
        self.initResp = initResp
        srpM1 = m1
        let complete = try await withRetry("complete") {
            try await GSAClient.shared.grandSlamComplete(
                email: email,
                initC: initResp.c,
                srpM1: m1,
                aniData: try currentAnisette(),
                securityCode: securityCode,
                urlSession: session
            )
        }
        return try parseRoundOutcome(complete, srpUser: user)
    }

    func completeAfterCode(_ code: String, isSMS: Bool = false, phoneId: String? = nil) async throws -> GSARoundOutcome {
        guard srpUser != nil, initResp != nil, srpM1 != nil else {
            throw GSAClientError.requestFailed(0, "no active SRP round")
        }
        if didValidate {
            let complete = try await withRetry("recomplete") { try await recomplete() }
            return try parseRoundOutcome(complete, srpUser: srpUser!)
        }
        do {
            try await refreshAnisetteIfNeeded()
            try await idmsaVerifySecurityCode(code: code, isSMS: isSMS, phoneId: phoneId)
            didValidate = true
        } catch let e as GSAClientError {
            switch e {
            case .invalidSecurityCode, .requestFailed(404, _), .requestFailed(410, _):
                return try await beginRound(securityCode: code)
            default:
                throw e
            }
        }
        let complete = try await withRetry("recomplete") { try await recomplete() }
        let outcome = try parseRoundOutcome(complete, srpUser: srpUser!)
        if case .twoFactorRequired = outcome {
            didValidate = false
        }
        return outcome
    }

    func recomplete() async throws -> GSAClient.CompleteResult {
        guard srpUser != nil, let resp = initResp, let m1 = srpM1 else {
            throw GSAClientError.requestFailed(0, "no active SRP round")
        }
        return try await GSAClient.shared.grandSlamComplete(
            email: email,
            initC: resp.c,
            srpM1: m1,
            aniData: try currentAnisette(),
            urlSession: session
        )
    }

    private func withRetry<T>(_ label: String, _ op: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await op()
            } catch let e as GSAClientError {
                let code: Int
                switch e {
                case .serverError(let c, _), .requestFailed(let c, _): code = c
                default: throw e
                }
                guard code >= 500 || code == 404, attempt < 3 else { throw e }
                let delay = attempt == 1 ? 0.6 : 1.5
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func requestTrustedDeviceNotification() async throws {
        guard let t = tokens, !t.adsid.isEmpty, !t.idmsToken.isEmpty else {
            throw GSAClientError.trustedDeviceNotifyFailed
        }
        try await refreshAnisetteIfNeeded()
        try await GSAClient.shared.requestTrustedDeviceNotification(
            adsid: t.adsid,
            idmsToken: t.idmsToken,
            aniHeaders: try currentAnisette().aniHeaders(),
            clientInfo: GSA_CLIENT_INFO,
            urlSession: session
        )
    }

    private func parseRoundOutcome(_ complete: GSAClient.CompleteResult, srpUser user: PySRPUser) throws -> GSARoundOutcome {
        let ec = complete.raw["ec"] as? Int
        let statusBox = complete.raw["Status"] as? [String: Any]
        let au = (statusBox?["au"] as? String) ?? (complete.raw["au"] as? String)
        let hsc = (statusBox?["hsc"] as? Int) ?? (complete.raw["hsc"] as? Int) ?? 0
        let hasSPD = (complete.raw["spd"] as? Data) != nil
        let hasM2 = complete.raw["M2"] != nil
        let twoFactorTriggered = (hsc == 409 || au == "trustedDeviceSecondaryAuth" || ec == -21669)

        if let e = ec, e == -20209 || e == -20205 || e == -20201 {
            throw GSAClientError.lockedAccount("ec=\(e)")
        }

        if hasSPD, hasM2, let spdBytes = complete.raw["spd"] as? Data {
            let spdPlain = try decryptSPD(K: Data(user.K), spd: spdBytes)
            if let parsed = try? parsePlistAuto(spdPlain), let t = extractTokens(parsed) {
                tokens = t
                if twoFactorTriggered {
                    return .twoFactorRequired(t)
                }
                let rawPT = complete.passwordToken ?? ""
                let extractedPT = (t.extraPlist["__extracted_password_token"] as? String) ?? ""
                var best: String? = nil
                for cand in [rawPT, extractedPT] where isTrueCommerceKitPasswordToken(cand) {
                    if best == nil || cand.count > best!.count { best = cand }
                }
                let dsid = complete.dsPersonId ?? t.dsPersonId
                return .authenticated(GSAClient.GSAuthResult(
                    tokens: t,
                    passwordToken: best,
                    dsPersonId: dsid.isEmpty ? nil : dsid,
                    accountInfo: complete.accountInfo,
                    raw: complete.raw
                ))
            }
        }

        if twoFactorTriggered {
            let t = tokens ?? GSAAuthTokens(adsid: "", idmsToken: "", extraPlist: [:], dsPersonId: "", countryCode: nil, storeFront: nil)
            return .twoFactorRequired(t)
        }

        if let e = ec, e != 0 {
            if e == -21669 {
                return .twoFactorRequired(tokens ?? GSAAuthTokens(adsid: "", idmsToken: "", extraPlist: [:], dsPersonId: "", countryCode: nil, storeFront: nil))
            }
            let em = complete.raw["em"] as? String ?? ""
            throw GSAClientError.serverError(e, em)
        }

        return .authenticated(GSAClient.GSAuthResult(
            tokens: nil,
            passwordToken: complete.passwordToken,
            dsPersonId: complete.dsPersonId,
            accountInfo: complete.accountInfo,
            raw: complete.raw
        ))
    }

    private func idmsaVerifySecurityCode(code: String, isSMS: Bool, phoneId: String?) async throws {
        guard let t = tokens, !t.adsid.isEmpty, !t.idmsToken.isEmpty else {
            throw GSAClientError.requestFailed(0, "missing adsid/idmsToken for 2FA validate")
        }
        let pathSuffix = isSMS ? "phone/securitycode" : "trusteddevice/securitycode"
        let identityToken = Data("\(t.adsid):\(t.idmsToken)".utf8).base64EncodedString()

        struct SecurityCode: Encodable { let code: String }
        struct TrustedNumber: Encodable { let id: Int }
        struct Body: Encodable {
            let securityCode: SecurityCode
            let phoneNumber: TrustedNumber?
            enum CodingKeys: String, CodingKey { case securityCode, phoneNumber }
        }
        let bodyData = try JSONEncoder().encode(Body(
            securityCode: SecurityCode(code: code),
            phoneNumber: isSMS ? phoneId.flatMap(Int.init).map { TrustedNumber(id: $0) } : nil
        ))

        var lastError: Error?
        for host in ["idmsa.apple.com", "gsa.apple.com"] {
            guard let url = URL(string: "https://\(host)/appleauth/auth/verify/\(pathSuffix)") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 45)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/x-xml-plist, */*", forHTTPHeaderField: "Accept")
            req.setValue("en-us", forHTTPHeaderField: "Accept-Language")
            req.setValue(GSA_UA, forHTTPHeaderField: "User-Agent")
            req.setValue(GSA_CLIENT_INFO, forHTTPHeaderField: "X-MMe-Client-Info")
            req.setValue(identityToken, forHTTPHeaderField: "X-Apple-Identity-Token")
            for (k, v) in (try? currentAnisette())?.aniHeaders() ?? [:] {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.httpShouldHandleCookies = true
            req.httpBody = bodyData
            do {
                let (d, r) = try await session.data(for: req)
                guard let http = r as? HTTPURLResponse else {
                    lastError = GSAClientError.invalidPlist
                    continue
                }
                switch http.statusCode {
                case 200..<300:
                    return
                case 409, 400:
                    let s = String(data: d.prefix(800), encoding: .utf8) ?? ""
                    if s.contains("tooManyCodesValidated") || s.contains("securityCodeLocked") {
                        throw GSAClientError.tooManyRequests
                    }
                    if s.contains("\"valid\" : true") || s.contains("\"valid\":true") {
                        return
                    }
                    lastError = GSAClientError.invalidSecurityCode(s.isEmpty ? "rejected" : String(s.prefix(200)))
                case 429:
                    throw GSAClientError.tooManyRequests
                case 401, 403, 404, 410, 412, 423:
                    lastError = GSAClientError.invalidSecurityCode("HTTP \(http.statusCode)")
                default:
                    lastError = GSAClientError.requestFailed(http.statusCode, String(data: d.prefix(200), encoding: .utf8) ?? "")
                }
            } catch let e as GSAClientError {
                throw e
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? GSAClientError.invalidSecurityCode("all hosts failed")
    }

    private func currentAnisette() throws -> AnisetteData {
        guard let a = aniData else {
            throw GSAClientError.requestFailed(0, "anisette missing")
        }
        return a
    }

    private func refreshAnisetteIfNeeded() async throws {
        if let t = aniFetchedAt, aniData != nil, Date().timeIntervalSince(t) < 240 {
            return
        }
        let fresh = try await AnisetteProvisioner.shared.getAnisette()
        aniData = fresh
        aniFetchedAt = Date()
    }
}
