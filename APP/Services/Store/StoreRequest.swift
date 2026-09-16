import Foundation

final class AuthCookieCache {
    static let shared = AuthCookieCache()
    private let lock = NSLock()
    private var storage: [String: [String]] = [:]

    func set(dsid: String, cookies: [String]) {
        lock.lock()
        defer { lock.unlock() }
        storage[dsid] = cookies
    }

    func get(dsid: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage[dsid] ?? []
    }
}

final class GUIDCache {
    static let shared = GUIDCache()
    private let lock = NSLock()
    private var cachedGUID: String?
    private var accountGUIDMap: [String: String] = [:]
    private static let PERSIST_KEY = "store_legacy_device_guid_v2"

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let g = cachedGUID, !g.isEmpty { return g }

        if let saved = UserDefaults.standard.string(forKey: Self.PERSIST_KEY), !saved.isEmpty {
            cachedGUID = saved
            return saved
        }
        let guid = Self.TRUSTED_DEVICE_GUID
        UserDefaults.standard.set(guid, forKey: Self.PERSIST_KEY)
        cachedGUID = guid
        return guid
    }

    static let TRUSTED_DEVICE_GUID = "7ECD3C78436E"

    func get(for account: Account) -> String {
        lock.lock()
        defer { lock.unlock() }
        let key = account.email
        if let guid = accountGUIDMap[key], !guid.isEmpty {
            return guid
        }
        let guid = account.deviceGUID
        accountGUIDMap[key] = guid
        return guid
    }

    func set(_ guid: String) {
        lock.lock()
        defer { lock.unlock() }
        cachedGUID = guid
        if !guid.isEmpty {
            UserDefaults.standard.set(guid, forKey: Self.PERSIST_KEY)
        }
    }

    func set(_ guid: String, for account: Account) {
        lock.lock()
        defer { lock.unlock() }
        accountGUIDMap[account.email] = guid
    }
}

class StoreRequestDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
class StoreRequest {
    static let shared = StoreRequest()
    private let session: URLSession

    private let authSession: URLSession

    private let bagSession: URLSession
    private let bagManager = BagManager.shared

    private var baseURL: String {
        bagManager.downloadURL
    }

    private var buyBaseURL: String {
        bagManager.buyURL
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.networkServiceType = .responsiveData
        let delegate = StoreRequestDelegate()
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: delegateQueue)

        let authConfig = URLSessionConfiguration.ephemeral
        authConfig.timeoutIntervalForRequest = 30
        authConfig.timeoutIntervalForResource = 30
        let authJar = HTTPCookieStorage()
        authJar.cookieAcceptPolicy = .always
        authConfig.httpCookieStorage = authJar
        authConfig.httpShouldSetCookies = true
        authConfig.httpCookieAcceptPolicy = .always
        authConfig.urlCache = nil
        authConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        authConfig.tlsMinimumSupportedProtocolVersion = .TLSv12
        authConfig.tlsMaximumSupportedProtocolVersion = .TLSv13
        authConfig.networkServiceType = .responsiveData
        self.authSession = URLSession(configuration: authConfig, delegate: delegate, delegateQueue: delegateQueue)

        let bagConfig = URLSessionConfiguration.ephemeral
        bagConfig.timeoutIntervalForRequest = 15
        bagConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.bagSession = URLSession(configuration: bagConfig)
    }

    func resetAuthCookieJar() {
        if let jar = authSession.configuration.httpCookieStorage {
            for c in jar.cookies ?? [] {
                jar.deleteCookie(c)
            }
        }
    }

    func ensureBagLoaded(storeFront: String? = nil) async {
        let sf = storeFront ?? "143441-1,32"
        await bagManager.loadBagIfNeeded(storeFront: sf)
    }

    func authenticate(
        email: String,
        password: String,
        mfa: String? = nil
    ) async throws -> StoreAuthResponse {
        try await sapAuthenticate(email: email, password: password, authCode: mfa ?? "")
    }

    func authenticateWith2FA(
        code: String,
        isSMS: Bool = false,
        phoneId: String? = nil
    ) async throws -> StoreAuthResponse {
        let pending = PendingSAPAuth.pop()
        guard let p = pending else {
            throw StoreError.codeRequired
        }
        return try await sapAuthenticate(
            email: p.email,
            password: p.password,
            authCode: code
        )
    }

    func download(
        appIdentifier: String,
        directoryServicesIdentifier: String,
        appVersion: String? = nil,
        passwordToken: String? = nil,
        storeFront: String? = nil
    ) async throws -> StoreDownloadResponse {
        let guid = GUIDCache.shared.get()
        return try await downloadInternal(
            appIdentifier: appIdentifier,
            directoryServicesIdentifier: directoryServicesIdentifier,
            appVersion: appVersion,
            passwordToken: passwordToken,
            storeFront: storeFront,
            guid: guid
        )
    }

    func download(
        appIdentifier: String,
        account: Account,
        appVersion: String? = nil
    ) async throws -> StoreDownloadResponse {
        do {
            return try await downloadOnce(appIdentifier: appIdentifier, account: account, appVersion: appVersion)
        } catch StoreError.invalidCredentials, StoreError.authenticationFailed {
            if let refreshed = try await refreshPasswordToken(account: account) {
                return try await downloadOnce(appIdentifier: appIdentifier, account: refreshed, appVersion: appVersion)
            }
            throw StoreError.authenticationFailedWithDetails("iTunes 会话已失效且无法自动刷新")
        }
    }

    private func downloadOnce(appIdentifier: String, account: Account, appVersion: String?) async throws -> StoreDownloadResponse {
        let guid = GUIDCache.shared.get(for: account)
        let pod = !account.pod.isEmpty ? account.pod : AccountPodCache.shared.get(dsid: account.directoryServicesIdentifier)
        return try await downloadInternal(
            appIdentifier: appIdentifier,
            directoryServicesIdentifier: account.directoryServicesIdentifier,
            appVersion: appVersion,
            passwordToken: account.passwordToken,
            storeFront: account.storeResponse.storeFront,
            guid: guid,
            pod: pod
        )
    }

    func redownload(
        appIdentifier: String,
        account: Account,
        appVersion: String? = nil
    ) async throws -> StoreDownloadResponse {
        do {
            return try await downloadOnce(appIdentifier: appIdentifier, account: account, appVersion: appVersion)
        } catch StoreError.invalidCredentials, StoreError.authenticationFailed {
            if let refreshed = try await refreshPasswordToken(account: account) {
                return try await downloadOnce(appIdentifier: appIdentifier, account: refreshed, appVersion: appVersion)
            }
            throw StoreError.authenticationFailedWithDetails("iTunes 会话已失效且无法自动刷新")
        }
    }

    static let savedPasswordKeyPrefix = "sap_saved_password_"

    func savePassword(_ password: String, for email: String) {
        UserDefaults.standard.set(password, forKey: Self.savedPasswordKeyPrefix + email)
    }

    func ensureITunesSession(account: Account) async {
        let dsid = account.directoryServicesIdentifier
        let key = "itunes_session_ts_\(dsid)"
        if let ts = UserDefaults.standard.object(forKey: key) as? Date,
           Date().timeIntervalSince(ts) < 3600,
           !AuthCookieCache.shared.get(dsid: dsid).isEmpty {
            return
        }
        let pw = UserDefaults.standard.string(forKey: Self.savedPasswordKeyPrefix + account.email) ?? ""
        guard !pw.isEmpty else { return }
        let guid = account.deviceGUID.isEmpty ? GUIDCache.shared.get() : account.deviceGUID
        do {
            _ = try await storeAuthenticate(
                email: account.email, password: pw, code: "", guid: guid, clearSession: false)
            UserDefaults.standard.set(Date(), forKey: key)
        } catch {
        }
    }

    func refreshPasswordToken(account: Account) async throws -> Account? {
        let pw = UserDefaults.standard.string(forKey: Self.savedPasswordKeyPrefix + account.email) ?? ""
        guard !pw.isEmpty else {
            return nil
        }
        let aniData: AnisetteData
        do {
            aniData = try await AnisetteProvisioner.shared.getAnisette()
        } catch {
            return nil
        }
        let session = GSALoginSession(email: account.email, password: pw, aniData: aniData)
        let outcome: GSARoundOutcome
        do {
            outcome = try await session.beginRound()
        } catch {
            return nil
        }
        guard case .authenticated(let result) = outcome else {
            return nil
        }
        guard let token = result.passwordToken, isTrueCommerceKitPasswordToken(token),
              let dsid = result.dsPersonId, !dsid.isEmpty else {
            return nil
        }
        let pod = account.pod
        var cookieLines = composeCookieLines(dsid: dsid, storeFront: account.storeResponse.storeFront, pod: pod, passwordToken: token)
        let real = session.sessionCookieLines()
        if !real.isEmpty {
            cookieLines.append(contentsOf: real)
            storeRealSessionCookies(real)
        }
        AuthCookieCache.shared.set(dsid: dsid, cookies: cookieLines)
        syncCookiesToShared(dsPersonId: dsid, passwordToken: token, appleId: account.email, storeFront: account.storeResponse.storeFront)
        let refreshed = Account(
            name: account.name,
            email: account.email,
            firstName: account.firstName,
            lastName: account.lastName,
            passwordToken: token,
            directoryServicesIdentifier: dsid,
            dsPersonId: account.dsPersonId.isEmpty ? dsid : account.dsPersonId,
            cookies: account.cookies,
            countryCode: account.countryCode,
            pod: pod,
            storeResponse: Account.AccountStoreResponse(
                directoryServicesIdentifier: dsid,
                passwordToken: token,
                storeFront: account.storeResponse.storeFront
            ),
            deviceGUID: account.deviceGUID,
            hsc: account.hsc,
            adsid: result.tokens?.adsid.isEmpty == false ? result.tokens!.adsid : account.adsid,
            idmsToken: result.tokens?.idmsToken.isEmpty == false ? result.tokens!.idmsToken : account.idmsToken
        )
        await ensureITunesSession(account: refreshed)
        return refreshed
    }

    private func downloadInternal(
        appIdentifier: String,
        directoryServicesIdentifier: String,
        appVersion: String? = nil,
        passwordToken: String? = nil,
        storeFront: String? = nil,
        guid: String,
        pod initialPod: String = ""
    ) async throws -> StoreDownloadResponse {
        var pod = initialPod.isEmpty ? AccountPodCache.shared.get(dsid: directoryServicesIdentifier) : initialPod
        var body: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": appIdentifier
        ]
        var requestedVersionId: String? = nil
        if let vid = appVersion, !vid.isEmpty {
            body["externalVersionId"] = vid
            requestedVersionId = vid
        }
        let query = "?guid=\(guid)"
        var (plist, h) = try await postCommercePlist(
            path: "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct",
            query: query,
            body: body,
            dsid: directoryServicesIdentifier,
            passwordToken: passwordToken ?? "",
            storeFront: storeFront ?? "",
            pod: &pod
        )
        let ft = plist["failureType"] as? String ?? ""
        if !ft.isEmpty, requestedVersionId != nil {
            var bodyLatest = body
            bodyLatest.removeValue(forKey: "externalVersionId")
            let (p2, h2) = try await postCommercePlist(
                path: "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct",
                query: query,
                body: bodyLatest,
                dsid: directoryServicesIdentifier,
                passwordToken: passwordToken ?? "",
                storeFront: storeFront ?? "",
                pod: &pod
            )
            plist = p2
            h = h2
        }
        AccountPodCache.shared.set(dsid: directoryServicesIdentifier, pod: pod)
        return try parseDownloadResponse(plist: plist, httpResponse: h)
    }

    func purchase(
        appIdentifier: String,
        directoryServicesIdentifier: String,
        passwordToken: String,
        storeFront: String
    ) async throws -> StorePurchaseResponse {
        let guid = GUIDCache.shared.get()
        return try await purchaseInternal(
            appIdentifier: appIdentifier,
            directoryServicesIdentifier: directoryServicesIdentifier,
            passwordToken: passwordToken,
            storeFront: storeFront,
            guid: guid
        )
    }

    func purchase(
        appIdentifier: String,
        account: Account
    ) async throws -> StorePurchaseResponse {
        do {
            return try await purchaseOnce(appIdentifier: appIdentifier, account: account)
        } catch StoreError.invalidCredentials, StoreError.authenticationFailed {
            if let refreshed = try await refreshPasswordToken(account: account) {
                return try await purchaseOnce(appIdentifier: appIdentifier, account: refreshed)
            }
            throw StoreError.authenticationFailedWithDetails("iTunes 会话已失效且无法自动刷新")
        }
    }

    private func purchaseOnce(appIdentifier: String, account: Account) async throws -> StorePurchaseResponse {
        let guid = GUIDCache.shared.get(for: account)
        let pod = !account.pod.isEmpty ? account.pod : AccountPodCache.shared.get(dsid: account.directoryServicesIdentifier)
        return try await purchaseInternal(
            appIdentifier: appIdentifier,
            directoryServicesIdentifier: account.directoryServicesIdentifier,
            passwordToken: account.passwordToken,
            storeFront: account.storeResponse.storeFront,
            guid: guid,
            pod: pod
        )
    }

    private func purchaseInternal(
        appIdentifier: String,
        directoryServicesIdentifier: String,
        passwordToken: String,
        storeFront: String,
        guid: String,
        pod initialPod: String = ""
    ) async throws -> StorePurchaseResponse {
        var pod = initialPod.isEmpty ? AccountPodCache.shared.get(dsid: directoryServicesIdentifier) : initialPod
        func buildBody(_ pricingParameters: String) -> [String: Any] {
            [
                "appExtVrsId": "0",
                "hasAskedToFulfillPreorder": "true",
                "buyWithoutAuthorization": "true",
                "hasDoneAgeCheck": "true",
                "guid": guid,
                "needDiv": "0",
                "origPage": "Software-\(appIdentifier)",
                "origPageLocation": "Buy",
                "price": "0",
                "pricingParameters": pricingParameters,
                "productType": "C",
                "salableAdamId": appIdentifier
            ]
        }
        var lastPlist: [String: Any] = [:]
        var lastH: HTTPURLResponse?
        for pricing in ["STDQ", "GAME"] {
            let (plist, h) = try await postCommercePlist(
                path: "/WebObjects/MZFinance.woa/wa/buyProduct",
                query: "",
                body: buildBody(pricing),
                dsid: directoryServicesIdentifier,
                passwordToken: passwordToken,
                storeFront: storeFront,
                pod: &pod
            )
            lastPlist = plist
            lastH = h
            let jingleType = plist["jingleDocType"] as? String ?? ""
            let ft = plist["failureType"] as? String ?? ""
            if h.statusCode == 200 && (jingleType == "purchaseSuccess" || ft == "5002" || ft == "2040" || plist["status"] as? String == "0") {
                AccountPodCache.shared.set(dsid: directoryServicesIdentifier, pod: pod)
                let dsPersonId = (plist["dsPersonId"] as? String) ?? (plist["dsPersonID"] as? String) ?? ""
                return StorePurchaseResponse(
                    dsPersonId: dsPersonId,
                    jingleDocType: plist["jingleDocType"] as? String,
                    jingleAction: plist["jingleAction"] as? String,
                    pings: plist["pings"] as? [String]
                )
            }
            let cm = plist["customerMessage"] as? String ?? ""
            if SessionFileStore.isAuthFailure(failureType: ft, customerMessage: cm, httpStatus: h.statusCode) {
                throw StoreError.invalidCredentials
            }
            if pricing == "STDQ" {
                continue
            }
        }
        AccountPodCache.shared.set(dsid: directoryServicesIdentifier, pod: pod)
        let plist = lastPlist
        let h = lastH!
        return try parsePurchaseResponse(plist: plist, httpResponse: h)
    }

    func commerceUserAgent() -> String {
        "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    }

    func storeAuthenticate(
        email: String,
        password: String,
        code: String,
        guid: String,
        clearSession: Bool = true
    ) async throws -> StoreAuthResponse {
        await ensureBagLoaded()
        if clearSession {
            for c in HTTPCookieStorage.shared.cookies ?? [] where c.domain.lowercased().contains("apple.com") {
                HTTPCookieStorage.shared.deleteCookie(c)
            }
        }
        let body: [String: String] = [
            "appleId": email,
            "attempt": "1",
            "guid": guid,
            "password": password + code.filter { !$0.isWhitespace },
            "rmp": "0",
            "why": "signIn"
        ]
        let bodyData = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        let signer = RemoteSAPSigner(guid: guid)
        defer { signer.close() }
        let signature = try signer.sign(bodyData)

        let endpoints: [(name: String, url: String)] = [
            ("native/fast", "https://auth.itunes.apple.com/auth/v1/native/fast/?guid=\(guid)"),
            ("MZFinance", "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?guid=\(guid)"),
        ]
        var attempts: [String] = []

        for (candidateIndex, endpoint) in endpoints.enumerated() {
            for authAttempt in 1...3 {
                if authAttempt > 1 {
                    try? await Task.sleep(nanoseconds: UInt64((authAttempt == 2 ? 3 : 8) * 1_000_000_000))
                }
                var req = URLRequest(url: URL(string: endpoint.url)!)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                req.setValue("en-us", forHTTPHeaderField: "Accept-Language")
                req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                req.setValue(commerceUserAgent(), forHTTPHeaderField: "User-Agent")
                req.setValue(signature.base64EncodedString(), forHTTPHeaderField: "x-apple-actionsignature")
                req.httpBody = bodyData
                req.httpShouldHandleCookies = true

                var (data, response) = try await session.data(for: req)
                var hops = 0
                while let httpResp = response as? HTTPURLResponse,
                      (300..<400).contains(httpResp.statusCode),
                      let loc = httpResp.value(forHTTPHeaderField: "Location"),
                      let base = req.url,
                      var next = URLComponents(url: URL(string: loc, relativeTo: base)!, resolvingAgainstBaseURL: false),
                      hops < 3 {
                    if (next.queryItems ?? []).isEmpty {
                        next.queryItems = [URLQueryItem(name: "guid", value: guid)]
                    }
                    hops += 1
                    var req2 = req
                    req2.url = next.url
                    (data, response) = try await session.data(for: req2)
                }
                guard let http = response as? HTTPURLResponse else {
                    throw StoreError.invalidResponse
                }

                let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]) ?? [:]
                let ft = plist["failureType"] as? String ?? ""
                let cm = plist["customerMessage"] as? String ?? ""

                if cm == "MZFinance.BadLogin.Configurator_message" {
                    if candidateIndex == endpoints.count - 1 {
                        throw code.isEmpty ? StoreError.codeRequired : StoreError.invalidCredentialsWithDetails(cm)
                    }
                    attempts.append("\(endpoint.name): Configurator")
                    break
                }
                if ft == "5005" {
                    throw StoreError.invalidVerificationCode
                }

                let token = plist["passwordToken"] as? String ?? ""
                let dsid = (plist["dsPersonId"] as? String) ?? (plist["dsPersonID"] as? String) ?? ""
                if !token.isEmpty, !dsid.isEmpty {
                    let jar = (HTTPCookieStorage.shared.cookies ?? []).filter { $0.domain.lowercased().contains("apple.com") }
                    let lines = jar.map { c -> String in
                        var line = "\(c.name)=\(c.value); Domain=\(c.domain); Path=\(c.path)"
                        if c.isSecure { line += "; Secure" }
                        return line
                    }
                    mergeRealCookies(dsid: dsid, lines: lines)

                    let info = plist["accountInfo"] as? [String: Any]
                    let addr = (info?["address"] as? [String: Any]) ?? [:]
                    return StoreAuthResponse(
                        accountInfo: .init(
                            appleId: (info?["appleId"] as? String) ?? email,
                            address: .init(firstName: (addr["firstName"] as? String) ?? "",
                                           lastName: (addr["lastName"] as? String) ?? ""),
                            dsPersonId: dsid,
                            countryCode: info?["countryCode"] as? String,
                            storeFront: http.value(forHTTPHeaderField: "X-Set-Apple-Store-Front")
                        ),
                        passwordToken: token,
                        dsPersonId: dsid,
                        pings: nil
                    )
                }

                if http.statusCode == 204 && authAttempt < 3 {
                    continue
                }
                attempts.append("\(endpoint.name): HTTP \(http.statusCode)")
                break
            }
        }
        throw StoreError.authenticationFailedWithDetails("登录失败：端点均未返回 token [\(attempts.joined(separator: " | "))]。建议切换网络（Wi-Fi↔蜂窝、关闭代理）后重试")
    }

    private func seedAccountCookies(dsid: String) {
        restorePersistedCookiesIfNeeded(dsid: dsid)
        let cookies = AuthCookieCache.shared.get(dsid: dsid)
        guard !cookies.isEmpty else { return }
        let origins = [
            "https://auth.itunes.apple.com",
            "https://buy.itunes.apple.com",
            "https://p-buy.itunes.apple.com"
        ]
        let headers = ["Set-Cookie": cookies.joined(separator: ", ")]
        for s in origins {
            guard let origin = URL(string: s) else { continue }
            let parsed = HTTPCookie.cookies(withResponseHeaderFields: headers, for: origin)
            for c in parsed { HTTPCookieStorage.shared.setCookie(c) }
        }
    }

    private func syncAuthSessionCookiesToShared() {
        guard let src = authSession.configuration.httpCookieStorage else { return }
        let dst = HTTPCookieStorage.shared
        for c in src.cookies ?? [] {
            if let existing = dst.cookies?.first(where: { $0.name == c.name && $0.domain == c.domain && $0.path == c.path }) {
                dst.deleteCookie(existing)
            }
            dst.setCookie(c)
        }
        let names = (src.cookies ?? []).map { $0.name }.sorted()
        if !names.isEmpty {
        }
    }

    private func postCommercePlist(
        path: String,
        query: String,
        body: [String: Any],
        dsid: String,
        passwordToken: String,
        storeFront: String,
        pod: inout String
    ) async throws -> ([String: Any], HTTPURLResponse) {
        seedAccountCookies(dsid: dsid)
        let ua = commerceUserAgent()
        let sf = storeFront.isEmpty ? "143441-1" : storeFront
        func makeHeaders(_ r: inout URLRequest, _ pwdTok: String) {
            r.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            r.setValue("*/*", forHTTPHeaderField: "Accept")
            r.setValue("en-us", forHTTPHeaderField: "Accept-Language")
            r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            r.setValue(ua, forHTTPHeaderField: "User-Agent")
            r.setValue(dsid, forHTTPHeaderField: "X-Dsid")
            r.setValue(dsid, forHTTPHeaderField: "iCloud-DSID")
            if !pwdTok.isEmpty {
                r.setValue(pwdTok, forHTTPHeaderField: "X-Token")
            }
            r.setValue(sf, forHTTPHeaderField: "X-Apple-Store-Front")
        }
        let host = pod.isEmpty ? "https://buy.itunes.apple.com" : "https://p\(pod)-buy.itunes.apple.com"
        let firstURL = URL(string: "\(host)\(path)\(query)")!
        var req = URLRequest(url: firstURL)
        req.httpMethod = "POST"
        makeHeaders(&req, passwordToken)
        let bodyData = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        req.httpBody = bodyData
        if path.contains("volumeStore") {
        }
        let (data, response) = try await session.data(for: req)
        guard let h = response as? HTTPURLResponse else { throw StoreError.invalidResponse }
        if h.statusCode == 301 || h.statusCode == 302 {
            let locRaw = (h.allHeaderFields["Location"] as? String) ?? (h.allHeaderFields["location"] as? String) ?? ""
            guard !locRaw.isEmpty, let loc = URL(string: locRaw) else {
                throw StoreError.authenticationFailed
            }

            var extractedPod = ""
            if let host = loc.host {
                let m = try? NSRegularExpression(pattern: #"^p(\d+)-buy\.itunes\.apple\.com$"#, options: [])
                if let m, let r = m.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)),
                   let r2 = Range(r.range(at: 1), in: host) {
                    extractedPod = String(host[r2])
                }
            }
            if extractedPod.isEmpty { extractedPod = pod }
            var comps = URLComponents(url: loc, resolvingAgainstBaseURL: false)
            comps?.scheme = "https"
            let retryURL = comps?.url ?? loc
            if !extractedPod.isEmpty { pod = extractedPod }
            var req2 = URLRequest(url: retryURL)
            req2.httpMethod = "POST"
            makeHeaders(&req2, passwordToken)
            req2.httpBody = bodyData
            let (d2, r2) = try await session.data(for: req2)
            guard let h2 = r2 as? HTTPURLResponse else { throw StoreError.invalidResponse }
            let p2 = (try? PropertyListSerialization.propertyList(from: d2, options: [], format: nil) as? [String: Any]) ?? [:]
            return (p2, h2)
        }
        let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]) ?? [:]
        let ft = plist["failureType"] as? String ?? ""
        let cm = plist["customerMessage"] as? String ?? ""
        let isErr = !ft.isEmpty || !cm.isEmpty
        if pod.isEmpty && isErr {
            var newPod = ""
            for (k, v) in h.allHeaderFields {
                let key = String(describing: k).lowercased()
                if key == "pod", let s = v as? String { newPod = s; break }
            }
            if newPod.isEmpty {
                let lines: [String]
                if let arr = h.allHeaderFields["Set-Cookie"] as? [String] {
                    lines = arr
                } else if let single = h.allHeaderFields["Set-Cookie"] as? String {
                    lines = [single]
                } else {
                    lines = []
                }
                for line in lines {
                    if line.starts(with: "itspod=") {
                        let p = line.dropFirst(7).split(separator: ";").first ?? ""
                        newPod = String(p).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            if !newPod.isEmpty {
                pod = newPod
                let retryURL = URL(string: "https://p\(pod)-buy.itunes.apple.com\(path)\(query)")!
                var req2 = URLRequest(url: retryURL)
                req2.httpMethod = "POST"
                makeHeaders(&req2, passwordToken)
                req2.httpBody = bodyData
                let (d2, r2) = try await session.data(for: req2)
                guard let h2 = r2 as? HTTPURLResponse else { throw StoreError.invalidResponse }
                let p2 = (try? PropertyListSerialization.propertyList(from: d2, options: [], format: nil) as? [String: Any]) ?? [:]
                return (p2, h2)
            }
        }
        if isErr {
        }
        return (plist, h)
    }

    private func acquireGUID() -> String {
        GUIDCache.shared.get()
    }

    func currentGUID() -> String { acquireGUID() }

    nonisolated static func setGUID(_ guid: String) {
        GUIDCache.shared.set(guid)
    }

    private func parseAuthResponse(
        plist: [String: Any],
        httpResponse: HTTPURLResponse
    ) throws -> StoreAuthResponse {
        if httpResponse.statusCode == 200 {
            let accountInfo = parseAccountInfo(from: plist)
            let passwordToken = plist["passwordToken"] as? String ?? ""
            let dsPersonId = (plist["dsPersonId"] as? String) ??
                           (plist["dsPersonID"] as? String) ??
                           (plist["dsid"] as? String) ??
                           (plist["DSID"] as? String) ??
                           (plist["directoryServicesIdentifier"] as? String) ?? ""
            let pings = plist["pings"] as? [String]
            let accountDsPersonId = accountInfo?.dsPersonId ?? ""
            let finalDsPersonId = !dsPersonId.isEmpty ? dsPersonId : accountDsPersonId
            let response = StoreAuthResponse(
                accountInfo: accountInfo ?? StoreAuthResponse.AccountInfo(
                    appleId: "",
                    address: StoreAuthResponse.AccountInfo.Address(
                        firstName: "",
                        lastName: ""
                    ),
                    dsPersonId: finalDsPersonId,
                    countryCode: nil,
                    storeFront: nil
                ),
                passwordToken: passwordToken,
                dsPersonId: finalDsPersonId,
                pings: pings
            )
            return response
        } else {
            let failureType = plist["failureType"] as? String ?? ""
            let customerMessage = plist["customerMessage"] as? String ?? ""
            if !failureType.isEmpty {
                throw StoreError.fromFailureType(failureType)
            } else if customerMessage == "MZFinance.BadLogin.Configurator_message" {
                throw StoreError.codeRequired
            } else if customerMessage.contains("AMD-Action") {
                let emptyResponse = StoreAuthResponse(
                    accountInfo: StoreAuthResponse.AccountInfo(
                        appleId: "",
                        address: StoreAuthResponse.AccountInfo.Address(
                            firstName: "",
                            lastName: ""
                        ),
                        dsPersonId: "",
                        countryCode: "",
                        storeFront: nil
                    ),
                    passwordToken: "",
                    dsPersonId: "",
                    pings: []
                )
                return emptyResponse
            } else {
                throw StoreError.unknownError
            }
        }
    }

    private func parseAccountInfo(from plist: [String: Any]) -> StoreAuthResponse.AccountInfo? {
        guard let accountInfo = plist["accountInfo"] as? [String: Any] else {
            return nil
        }
        let appleId = accountInfo["appleId"] as? String ?? ""
        let resolved = Apple.resolveName(roots: [plist, accountInfo], tag: "parseAccountInfo")
        let firstName = resolved.firstName.isEmpty ? resolved.fallbackFull : resolved.firstName
        let lastName = resolved.lastName
        let dsPersonId = (accountInfo["dsPersonId"] as? String) ??
                        (accountInfo["dsPersonID"] as? String) ??
                        (accountInfo["dsid"] as? String) ??
                        (accountInfo["DSID"] as? String) ??
                        (accountInfo["directoryServicesIdentifier"] as? String) ?? ""
        let countryCode = detectCountryCodeFromAccountInfo(accountInfo)
        let storeFront = detectStoreFrontFromAccountInfo(accountInfo)
        return StoreAuthResponse.AccountInfo(
            appleId: appleId,
            address: StoreAuthResponse.AccountInfo.Address(
                firstName: firstName,
                lastName: lastName
            ),
            dsPersonId: dsPersonId,
            countryCode: countryCode,
            storeFront: storeFront
        )
    }

    private func detectCountryCodeFromAccountInfo(_ accountInfo: [String: Any]) -> String? {
        if let countryCode = accountInfo["countryCode"] as? String, !countryCode.isEmpty {
            return countryCode
        }
        if let storeFront = accountInfo["storeFront"] as? String, !storeFront.isEmpty {
            return inferCountryCodeFromStoreFront(storeFront)
        }
        let regionFields = ["region", "country", "locale", "territory", "market"]
        for field in regionFields {
            if let value = accountInfo[field] as? String, !value.isEmpty {
                return value.uppercased()
            }
        }
        return nil
    }

    private func detectStoreFrontFromAccountInfo(_ accountInfo: [String: Any]) -> String? {
        if let storeFront = accountInfo["storeFront"] as? String, !storeFront.isEmpty {
            return storeFront
        }
        let storeFields = ["storefront", "storeFront", "store_front", "marketId", "market_id"]
        for field in storeFields {
            if let value = accountInfo[field] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
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

    private func parseDownloadResponse(
        plist: [String: Any],
        httpResponse: HTTPURLResponse
    ) throws -> StoreDownloadResponse {

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

    private func parsePurchaseResponse(
        plist: [String: Any],
        httpResponse: HTTPURLResponse
    ) throws -> StorePurchaseResponse {

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

    private func sapAuthenticate(
        email: String,
        password: String,
        authCode: String,
        skipGo: Bool = false
    ) async throws -> StoreAuthResponse {
        let identity = try MachineIdentityProvider.resolve()
        GUIDCache.shared.set(identity.guid)

        let knownPod = UserDefaults.standard.string(forKey: "sap_last_pod") ?? ""
        if !skipGo, !RemoteSAPConfig.isActive, let r = SAPGoLogin.login(email: email, password: password, guid: identity.guid, authCode: authCode, pod: knownPod) {
            if let token = r.passwordToken, !token.isEmpty, let dsid = r.dsPersonId, !dsid.isEmpty {
                if token.count < 450 {
                    if authCode.isEmpty {
                        PendingSAPAuth.push(email: email, password: password)
                        throw StoreError.codeRequired
                    }
                    throw StoreError.authenticationFailedWithDetails("Apple 接受了验证码但返回降级会话（token \(token.count)B，需≥450B），暂时无法下载。请稍后重试或更换网络环境后重新登录")
                }
                let pod = r.pod ?? ""
                let storeFront = r.storeFront ?? ""
                if !pod.isEmpty {
                    UserDefaults.standard.set(pod, forKey: "sap_last_pod")
                }
                var cookieLines: [String] = []
                if !pod.isEmpty {
                    AccountPodCache.shared.set(dsid: dsid, pod: pod)
                    cookieLines = composeCookieLines(dsid: dsid, storeFront: storeFront, pod: pod, passwordToken: token)
                }
                if let real = r.cookies, !real.isEmpty {
                    cookieLines.append(contentsOf: real)
                    storeRealSessionCookies(real)
                }
                if !cookieLines.isEmpty {
                    AuthCookieCache.shared.set(dsid: dsid, cookies: cookieLines)
                }
                if !pod.isEmpty {
                    syncCookiesToShared(dsPersonId: dsid, passwordToken: token, appleId: email, storeFront: storeFront)
                }
                let info = StoreAuthResponse.AccountInfo(
                    appleId: email,
                    address: StoreAuthResponse.AccountInfo.Address(firstName: "", lastName: ""),
                    dsPersonId: dsid,
                    countryCode: nil,
                    storeFront: storeFront.isEmpty ? nil : storeFront
                )
                var resp = StoreAuthResponse(
                    accountInfo: info,
                    passwordToken: token,
                    dsPersonId: dsid,
                    pings: nil
                )
                resp.pod = pod
                return resp
            }
            if r.error == "2FA_REQUIRED" || r.error == "2FA_CODE_INVALID" {
                PendingSAPAuth.push(email: email, password: password)
                throw StoreError.codeRequired
            }
            if r.error?.hasPrefix("WEAK_TOKEN") == true {
                if authCode.isEmpty {
                    PendingSAPAuth.push(email: email, password: password)
                    throw StoreError.codeRequired
                }
                throw StoreError.authenticationFailedWithDetails("Apple 返回降级会话（\(r.error ?? "")），验证码已接受但拿不到下载权限。请稍后重试或更换网络环境后重新登录")
            }
        }

        await ensureBagLoaded()
        let sap = bagManager.sapConfig

        resetAuthCookieJar()
        AppleIDAuthenticator.clearAppleCookies()

        let signer: SAPActionSigner
        do {
            signer = RemoteSAPConfig.isActive
                ? RemoteSAPSigner(guid: identity.guid)
                : try await DefaultSAPSignerFactory.shared
                    .makeSigner(config: sap, machineID: identity.machineID)
        } catch {
            throw StoreError.authenticationFailedWithDetails("SAP signer init: \(error.localizedDescription)")
        }
        defer { signer.close() }

        let endpoint = sap.authEndpoint
        var redirect: String? = nil
        var lastResponse: (plist: [String: Any], http: HTTPURLResponse)?

        for attempt in 1...4 {
            let actualAttempt = redirect != nil ? 1 : attempt
            let payload: [String: Any] = [
                "appleId": email,
                "attempt": "\(actualAttempt)",
                "guid": identity.guid,
                "password": "\(password)\(authCode.filter { !$0.isWhitespace })",
                "rmp": "0",
                "why": "signIn"
            ]
            let url = redirect ?? endpoint
            let bodyData = try PropertyListSerialization.data(
                fromPropertyList: payload,
                format: .xml,
                options: 0
            )

            let signature: Data
            do {
                signature = try signer.sign(bodyData)
            } catch {
                throw StoreError.authenticationFailedWithDetails("SAP sign: \(error.localizedDescription)")
            }

            var req = URLRequest(url: URL(string: url)!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue(commerceUserAgent(), forHTTPHeaderField: "User-Agent")
            req.setValue(signature.base64EncodedString(), forHTTPHeaderField: "X-Apple-ActionSignature")
            req.httpBody = bodyData
            req.httpShouldHandleCookies = true

            let (data, response) = try await authSession.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw StoreError.invalidResponse
            }

            if http.statusCode == 301 || http.statusCode == 302 {
                let loc = (http.allHeaderFields["Location"] as? String)
                        ?? (http.allHeaderFields["location"] as? String) ?? ""
                guard !loc.isEmpty else {
                    throw StoreError.authenticationFailedWithDetails("Apple 重定向(\(http.statusCode))缺少 Location")
                }
                guard let validated = try? Self.validateAuthenticationRedirect(loc) else {
                    throw StoreError.authenticationFailedWithDetails("invalid auth redirect: \(loc)")
                }
                redirect = validated
                continue
            }

            let plist = (try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]) ?? [:]

            if plist.isEmpty {
                let snippet = String(data: data.prefix(200), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ") ?? ""
                throw StoreError.authenticationFailedWithDetails(
                    "非 plist 响应: HTTP=\(http.statusCode) len=\(data.count) body=\(snippet.isEmpty ? "<empty>" : snippet)"
                )
            }

            let ft = plist["failureType"] as? String ?? ""
            let cm = plist["customerMessage"] as? String ?? ""

            if attempt == 1 && ft == "-5000" {
                continue
            }
            if ft.isEmpty && cm == "MZFinance.BadLogin.Configurator_message" {
                PendingSAPAuth.push(email: email, password: password)
                throw StoreError.codeRequired
            }
            if ft.isEmpty && cm == "Your account is disabled." {
                throw StoreError.lockedAccount
            }
            if !ft.isEmpty {
                if !cm.isEmpty {
                    if ft == "5002" || ft == "2040" {
                        lastResponse = (plist, http)
                        break
                    }
                    throw StoreError.authenticationFailedWithDetails(cm)
                }
                throw StoreError.authenticationFailedWithDetails(
                    "failureType=\(ft) HTTP=\(http.statusCode) keys=\(plist.keys.sorted().prefix(8).joined(separator: ","))"
                )
            }
            if http.statusCode == 200
                && !(plist["passwordToken"] as? String ?? "").isEmpty
                && !(plist["dsPersonId"] as? String ?? "").isEmpty {
                lastResponse = (plist, http)
                break
            }
            lastResponse = (plist, http)
        }

        guard let last = lastResponse else {
            throw StoreError.authenticationFailedWithDetails("too many attempts")
        }

        let lastToken = last.plist["passwordToken"] as? String ?? ""
        if lastToken.isEmpty {
            let lastCm = last.plist["customerMessage"] as? String ?? ""
            throw StoreError.authenticationFailedWithDetails(
                "无 passwordToken: HTTP=\(last.http.statusCode) cm=\(lastCm.isEmpty ? "-" : lastCm) keys=\(last.plist.keys.sorted().prefix(8).joined(separator: ","))"
            )
        }
        if lastToken.count < 450 {
            if authCode.isEmpty {
                PendingSAPAuth.push(email: email, password: password)
                throw StoreError.codeRequired
            }
            throw StoreError.authenticationFailedWithDetails("Apple 返回降级会话（token \(lastToken.count)B，需≥450B），验证码已接受但拿不到下载权限。请稍后重试或更换网络环境后重新登录")
        }

        let (plist, http) = last
        let storeFront = (http.allHeaderFields["X-Set-Apple-Store-Front"] as? String)
            ?? (http.allHeaderFields["x-set-apple-store-front"] as? String) ?? ""

        var pod = ""
        for (k, v) in http.allHeaderFields {
            if String(describing: k).lowercased() == "pod", let s = v as? String {
                pod = s; break
            }
        }
        if pod.isEmpty {
            let cookies = authSession.configuration.httpCookieStorage?.cookies ?? []
            for c in cookies {
                if c.name == "itspod" { pod = c.value; break }
            }
        }

        let dsid = (plist["dsPersonId"] as? String)
            ?? (plist["dsPersonID"] as? String)
            ?? (plist["dsid"] as? String) ?? ""
        let token = plist["passwordToken"] as? String ?? ""
        let firstName: String
        let lastName: String
        if let accountInfo = plist["accountInfo"] as? [String: Any] {
            let addr = accountInfo["address"] as? [String: Any] ?? [:]
            firstName = addr["firstName"] as? String ?? ""
            lastName = addr["lastName"] as? String ?? ""
        } else {
            firstName = ""
            lastName = ""
        }

        if !dsid.isEmpty, !token.isEmpty {
            AuthCookieCache.shared.set(
                dsid: dsid,
                cookies: composeCookieLines(dsid: dsid, storeFront: storeFront, pod: pod, passwordToken: token)
            )
            syncCookiesToShared(
                dsPersonId: dsid,
                passwordToken: token,
                appleId: email,
                storeFront: storeFront
            )
            AccountPodCache.shared.set(dsid: dsid, pod: pod)
            syncAuthSessionCookiesToShared()
        }

        let addr = StoreAuthResponse.AccountInfo.Address(firstName: firstName, lastName: lastName)
        let info = StoreAuthResponse.AccountInfo(
            appleId: email,
            address: addr,
            dsPersonId: dsid,
            countryCode: nil,
            storeFront: storeFront.isEmpty ? nil : storeFront
        )
        var resp = StoreAuthResponse(
            accountInfo: info,
            passwordToken: token,
            dsPersonId: dsid,
            pings: plist["pings"] as? [String]
        )
        resp.pod = pod
        return resp
    }

    private static func validateAuthenticationRedirect(_ location: String) throws -> String {
        guard let url = URL(string: location),
              url.scheme == "https",
              let host = url.host?.lowercased() else {
            throw SAPSignerError.invalidConfig("bad redirect: \(location)")
        }
        guard host == "buy.itunes.apple.com" || host.hasSuffix("-buy.itunes.apple.com") else {
            throw SAPSignerError.invalidConfig("bad redirect host: \(host)")
        }
        guard url.path == "/WebObjects/MZFinance.woa/wa/authenticate" else {
            throw SAPSignerError.invalidConfig("bad redirect path: \(url.path)")
        }
        return location
    }
}

struct PendingSAPAuth {
    private static let lock = NSLock()
    private static var email: String = ""
    private static var password: String = ""

    static func push(email: String, password: String) {
        lock.lock(); defer { lock.unlock() }
        Self.email = email
        Self.password = password
    }

    static func pop() -> (email: String, password: String)? {
        lock.lock(); defer { lock.unlock() }
        guard !email.isEmpty else { return nil }
        let (e, p) = (email, password)
        email = ""; password = ""
        return (e, p)
    }
}

private struct _StoreAuthPodKey {
    static var podKey: UInt8 = 0
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
            return "Apple ID 需要身份验证"
        case .invalidVerificationCode:
            return "验证码错误，请检查后重试"
        case .licenseExpired:
            return "许可证已过期，需要重新认证"
        case .paymentVerificationRequired:
            return "需要验证付款信息"
        case .termsOfServiceUpdateRequired:
            return "需要同意新的服务条款"
        case .storefrontChangeRequired:
            return "需要切换到正确的商店地区"
        case .ageVerificationRequired:
            return "需要进行年龄验证"
        case .tooManyRequests:
            return "请求过于频繁，请稍后再试"
        case .appNotAvailableInStorefront:
            return "此应用在当前地区商店不可用"
        case .notOwned:
            return "用户未购买此应用"
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
        case "notOwned", "notOwnedLicense", "noLicense":
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

    init(accountInfo: AccountInfo, passwordToken: String, dsPersonId: String, pings: [String]?, hsc: Int = 0, adsid: String = "", idmsToken: String = "", pod: String = "") {
        self.accountInfo = accountInfo
        self.passwordToken = passwordToken
        self.dsPersonId = dsPersonId
        self.pings = pings
        self.hsc = hsc
        self.adsid = adsid
        self.idmsToken = idmsToken
        self.pod = pod
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
