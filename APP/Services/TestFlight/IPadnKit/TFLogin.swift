import AppleAuth
import Foundation

/// Bridges the system Apple ID login to a TestFlight session.
///
/// The chain is the one the working probe proved on this device: Mac device first
/// (its `headers()` carry the User-Agent Apple's GSA routes on), iPhone device built
/// with that User-Agent, GSA login with two-factor, the Mac device imports the PET,
/// the PET buys a Store session, and the Store session mints the TestFlight context.
/// Nothing is written to disk except AppleAuth's own device state; the password never
/// leaves the caller, and no cookie or session id is ever logged.
public enum TFLogin {
    /// Masked trusted phone number offered by Apple's GSA SMS challenge.
    public struct TrustedPhone: Identifiable, Sendable, Equatable {
        public let id: Int64
        public let displayNumber: String

        public init(id: Int64, displayNumber: String) {
            self.id = id
            self.displayNumber = displayNumber
        }
    }

    /// Which 2FA delivery channel Apple selected for the active login attempt.
    public enum VerificationChannel: Sendable, Equatable {
        case trustedDevice
        case sms(phoneDisplay: String?)
    }

    /// Hands a multi-phone SMS selection prompt to the UI and waits for the chosen phone ID.
    public actor PhoneRelay {
        private var waiting: CheckedContinuation<Int64, Error>?
        private var cancelled = false
        private let onRequest: (@Sendable ([TrustedPhone]) -> Void)?

        public init(onRequest: (@Sendable ([TrustedPhone]) -> Void)? = nil) {
            self.onRequest = onRequest
        }

        public func request(_ phones: [TrustedPhone]) async throws -> Int64 {
            if cancelled || Task.isCancelled {
                throw TFError.cancelled
            }
            onRequest?(phones)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if cancelled || Task.isCancelled {
                        continuation.resume(throwing: TFError.cancelled)
                        return
                    }
                    if let previous = waiting {
                        previous.resume(throwing: TFError.cancelled)
                    }
                    waiting = continuation
                }
            } onCancel: {
                Task { await self.cancel() }
            }
        }

        public func select(_ phoneID: Int64) {
            guard !cancelled else { return }
            if let waiting {
                self.waiting = nil
                waiting.resume(returning: phoneID)
            }
        }

        public func cancel() {
            cancelled = true
            waiting?.resume(throwing: TFError.cancelled)
            waiting = nil
        }
    }

    /// Hands a 2FA prompt to the UI and waits for the code.
    public actor CodeRelay {
        private var waiting: CheckedContinuation<String, Error>?
        private var pending: String?
        private var cancelled = false
        private let onRequest: (@Sendable () -> Void)?

        public init(onRequest: (@Sendable () -> Void)? = nil) {
            self.onRequest = onRequest
        }

        public func request() async throws -> String {
            if cancelled || Task.isCancelled {
                throw TFError.cancelled
            }
            if let pending {
                self.pending = nil
                return pending
            }
            onRequest?()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if cancelled || Task.isCancelled {
                        continuation.resume(throwing: TFError.cancelled)
                        return
                    }
                    if let previous = waiting {
                        previous.resume(throwing: TFError.cancelled)
                    }
                    waiting = continuation
                }
            } onCancel: {
                Task { await self.cancel() }
            }
        }

        public func submit(_ code: String) {
            guard !cancelled else { return }
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let waiting {
                self.waiting = nil
                waiting.resume(returning: trimmed)
            } else {
                pending = trimmed
            }
        }

        public func cancel() {
            cancelled = true
            pending = nil
            waiting?.resume(throwing: TFError.cancelled)
            waiting = nil
        }
    }

    /// Per-sign-in capture of redacted Apple `/auth` error codes and post-2FA state (never holds secrets).
    private final class AuthDiagnosticBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lastSummary: String?
        private var confirmed2FA = false
        private var retriedPost2FA503 = false

        func record(_ summary: String) {
            lock.lock()
            lastSummary = summary
            lock.unlock()
        }

        func snapshot() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return lastSummary
        }

        func mark2FAConfirmed() {
            lock.lock()
            confirmed2FA = true
            lock.unlock()
        }

        func consumePost2FA503Retry() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard confirmed2FA, !retriedPost2FA503 else { return false }
            retriedPost2FA503 = true
            return true
        }
    }

    public static func signIn(email: String,
                              password: String,
                              relay: CodeRelay,
                              phoneRelay: PhoneRelay? = nil,
                              onChallenge: (@Sendable (VerificationChannel) -> Void)? = nil,
                              log: @escaping @Sendable (String) -> Void) async throws -> TFContext {
        // Four routing values first: nothing leaves the device until they match.
        try TFInvariants.check(log: log)
        let root = try supportDirectory()
        log("sign-in: prepare device identities")
        // A jar that still holds an earlier run's X-Token/X-Dsid makes the service reject
        // the whole credential set ("The credentials for this app are invalid"), and the
        // duplicates also block the cookies this run sets. Start from empty.
        let stale = HTTPCookieStorage.shared.cookies?.count ?? 0
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        TFStoreCapture.reset()
        log("sign-in: cleared " + String(stale) + " stored cookies")

        // Mac identity first. Its headers() carry the User-Agent Apple's GSA expects;
        // presenting the iPhone identity with our own TestFlight user agent makes the
        // provisioning lookup answer 404 with an empty body, which reads exactly like a
        // blocked network. Same order and headers as the working probe.
        let diagnostics = AuthDiagnosticBox()
        let mac = try makeMacDevice(root: root, diagnostics: diagnostics, onChallenge: onChallenge, log: log)
        try await mac.provision()
        let macHeaders = try await mac.headers()
        let userAgent = TFConstants.storeUserAgent
        let rinfo = macHeaders["X-Apple-I-MD-RINFO"] ?? "?"
        log("sign-in: mac identity ready, rinfo " + rinfo + ", user agent pinned to the Store line")

        let iphone = try await makeIPhoneDevice(root: root, userAgent: userAgent,
                                                diagnostics: diagnostics, onChallenge: onChallenge, log: log)
        let selectPhoneCallback: (@Sendable ([TrustedPhoneNumber]) async throws -> Int64)? = phoneRelay.map { phoneRelay in
            { @Sendable phones in
                let choices = phones.map { TrustedPhone(id: $0.id, displayNumber: $0.displayNumber) }
                if choices.count == 1, let only = choices.first {
                    log("sign-in: single trusted SMS number, auto-selecting")
                    onChallenge?(.sms(phoneDisplay: only.displayNumber))
                    return only.id
                }
                log("sign-in: SMS phone selection requested (" + String(choices.count) + " number(s))")
                let chosen = try await phoneRelay.request(choices)
                if let match = choices.first(where: { $0.id == chosen }) {
                    onChallenge?(.sms(phoneDisplay: match.displayNumber))
                }
                return chosen
            }
        }
        let verification = Verification(selectPhone: selectPhoneCallback,
                                        code: { try await relay.request() })
        log("sign-in: GSA login (two-factor may be required)")
        let account: AccountSession
        do {
            account = try await iphone.login(email: email, password: password, verification: verification)
        } catch {
            if case TFError.cancelled = error { throw error }
            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { throw error }
            if let detail = diagnostics.snapshot(), !detail.isEmpty {
                let base = shortDescription(error)
                throw TFError.malformed("\(base) [\(detail)]")
            }
            throw error
        }
        log("sign-in: account session established, id length " + String(account.accountID.count))
        guard let accountDsid = dsid(from: account) else {
            throw TFError.malformed("PET 里没有 DsPrsId，无法确定本次登录的 dsid")
        }
        log("sign-in: PET dsid …" + String(accountDsid.suffix(4)))

        // Switch jars before the store exchange: the exchange writes the cookies this
        // account owns, so a foreign snapshot must be gone first.
        AccountScope.activate(dsid: accountDsid, log: log)

        // The store exchange is called as instructed; its parse of the new
        // `/auth/v1/native/fast` response may throw, and the Set-Cookie headers have
        // already reached URLSession's jar, which is what the context is built from.
        log("sign-in: exchange PET for a store session (a throw here is tolerated)")
        do {
            let store = try await mac.loginStoreWithPET(email: email, account: account)
            log("sign-in: store session ready, storefront " + store.storefront)
        } catch {
            log("sign-in: store exchange threw (" + shortDescription(error) + "), cookies are the source of truth")
        }

        let context = try StoreContextBuilder.contextFromCookies(dsid: accountDsid,
                                                                 macHeaders: macHeaders, log: log)
        // Snapshot from the auth response's Set-Cookie (never re-read from the shared jar).
        do {
            try AccountScope.store(dsid: accountDsid, wireCookies: TFStoreCapture.cookies, log: log)
        } catch {
            log("jar: 快照未写入（" + shortDescription(error) + "），本次仍可继续")
        }
        log("sign-in: " + context.summary)
        return context
    }

    /// Rebuilds a `TFContext` strictly from this account's persisted 10-cookie snapshot
    /// (`AccountScope.cookies(for:)`) and stored Mac Store headers, passing through
    /// `TFInvariants.check()` and the single `StoreContextBuilder.contextFromCookies` entry.
    /// Never calls GSA and never touches another account's jar.
    public static func restoreContextFromSnapshot(dsid: String,
                                                  currentDsid: String? = nil,
                                                  amdm: String,
                                                  storeFront: String?,
                                                  log: @escaping @Sendable (String) -> Void) throws -> TFContext {
        try TFInvariants.check(log: log)
        // Always flush prior account cookies before validating the target snapshot so a missing
        // snapshot can never leave account A's cookies in HTTPCookieStorage.shared.
        if let currentDsid, currentDsid != dsid {
            AccountScope.writeBack(dsid: currentDsid)
        }
        AccountScope.clearSharedCookies()
        TFStoreCapture.reset()
        defer { TFStoreCapture.reset() }
        guard !dsid.isEmpty, !amdm.isEmpty else {
            throw TFError.malformed("缺少可复用的 TestFlight 会话凭据")
        }
        guard let snapshot = AccountScope.cookies(for: dsid) else {
            throw TFError.malformed("账号未保存 cookie 快照")
        }
        AccountScope.activate(dsid: dsid, currentDsid: nil, log: log)
        TFStoreCapture.amdm = amdm
        TFStoreCapture.storeFront = storeFront
        TFStoreCapture.cookies = snapshot
        let context = try StoreContextBuilder.contextFromCookies(dsid: dsid, macHeaders: [:], log: log)
        log("restore: " + context.summary)
        return context
    }

    /// The PET carries the authoritative DSID for this login (`DsPrsId`, e.g.
    /// "19318358872"). The cookie jar can hold several accounts at once, so this value —
    /// not a guess over X-Dsid cookies — decides which cookies belong to the session.
    static func dsid(from account: AccountSession) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: account.plist, format: nil),
              let fields = plist as? [String: Any] else { return nil }
        if let text = fields["DsPrsId"] as? String, !text.isEmpty { return text }
        if let number = fields["DsPrsId"] as? Int { return String(number) }
        if let number = fields["DsPrsId"] as? Int64 { return String(number) }
        if let number = fields["DsPrsId"] as? NSNumber { return number.stringValue }
        return nil
    }

    /// True when the cookie carries no dsid suffix at all, or the suffix is this account's.
    /// Only a cookie bound to a *different* dsid is treated as foreign — dropping the
    /// unsuffixed ones (hsaccnt, X-Token, geo …) makes the install POST answer 500.
    static func cookieBelongs(_ name: String, dsid: String) -> Bool {
        let tail = name.split(separator: "-").last.map(String.init) ?? ""
        guard tail.count >= 6, tail.allSatisfy(\.isNumber) else { return true }
        return tail == dsid
    }

    /// Drops every apple.com cookie that belongs to a different account, both from the
    /// set we send and from the shared jar (so the next run cannot pick them up again).
    static func purgeForeignCookies(dsid: String, log: @escaping @Sendable (String) -> Void) {
        let all = HTTPCookieStorage.shared.cookies ?? []
        var dropped = 0
        for cookie in all where cookie.domain.contains("apple.com") {
            let isOurs = cookie.name == "X-Dsid"
                ? cookie.value == dsid
                : cookieBelongs(cookie.name, dsid: dsid)
            if !isOurs {
                HTTPCookieStorage.shared.deleteCookie(cookie)
                dropped += 1
            }
        }
        if dropped > 0 { log("sign-in: dropped " + String(dropped) + " cookie(s) from another account") }
    }

    /// Assembles the authenticate body from the store cookies of *this* dsid instead of
    /// asking the native store session for it: a PET session has no `myacinfo`, so
    /// `testFlightContext` refuses, while these cookies are what the service consumes.
    /// Retired entry point. The body was moved to `StoreContextBuilder`, which also owns
    /// the cookie whitelist, the numeric `dsId` and the identity check.
    @available(*, unavailable, message: "唯一入口是 StoreContextBuilder.contextFromCookies")
    static func legacyContextFromCookies(dsid: String,
                                         macHeaders: [String: String],
                                         log: @escaping @Sendable (String) -> Void) throws -> TFContext {
        throw TFError.malformed("retired: use StoreContextBuilder.contextFromCookies")
    }

    // MARK: - devices

    private static func supportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = base.appendingPathComponent("TestFlightKit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The system hands a fresh anonymous device state per directory; a handful of them
    /// is enough to dodge a rate-limited one (`67437824`).
    ///
    /// `model` and `iOSVersion` are deliberately left to AppleAuth's defaults, and the
    /// user agent comes from the mac identity: a self-chosen pair is what turned the
    /// provisioning lookup into a bare 404.
    private static func makeIPhoneDevice(root: URL, userAgent: String?,
                                         diagnostics: AuthDiagnosticBox,
                                         onChallenge: (@Sendable (VerificationChannel) -> Void)?,
                                         log: @escaping @Sendable (String) -> Void) async throws -> Device {
        var lastError: Error?
        var fallbackDevice: Device?
        func createDevice(in directory: URL) throws -> Device {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try Device(directory: directory,
                              platform: .iphone,
                              transport: transport(diagnostics: diagnostics, onChallenge: onChallenge, log: log),
                              userAgent: userAgent,
                              clientInfo: TFConstants.authClientInfo,
                              headers: ["X-Apple-Locale": "en_US",
                                        "Accept-Language": "en-US",
                                        "X-Apple-I-TimeZone": "UTC"])
        }
        for index in 1...4 {
            let directory = root.appendingPathComponent("iphone-" + String(index), isDirectory: true)
            let hadCachedState = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == false)
            do {
                var device = try createDevice(in: directory)
                try await device.provision()
                var headers = try await device.headers()
                var rinfo = headers["X-Apple-I-MD-RINFO"] ?? "?"
                log("sign-in: iphone identity attempt " + String(index) + ", rinfo " + rinfo)
                if rinfo == "67437824", hadCachedState {
                    // Cached provisioning state on disk already has the throttled rinfo; wipe the
                    // slot and re-provision once so retries actually obtain fresh state from Apple.
                    try? FileManager.default.removeItem(at: directory)
                    device = try createDevice(in: directory)
                    try await device.provision()
                    headers = try await device.headers()
                    rinfo = headers["X-Apple-I-MD-RINFO"] ?? "?"
                    log("sign-in: iphone identity attempt " + String(index) + " refreshed, rinfo " + rinfo)
                }
                if rinfo != "67437824" { return device }
                fallbackDevice = device
            } catch {
                lastError = error
                log("sign-in: iphone identity " + String(index) + " unusable, " + shortDescription(error))
            }
        }
        if let fallbackDevice {
            log("sign-in: all iphone slots returned rinfo 67437824, proceeding with fallback identity")
            return fallbackDevice
        }
        throw lastError ?? TFError.malformed("no usable iphone identity")
    }

    private static func makeMacDevice(root: URL,
                                      diagnostics: AuthDiagnosticBox,
                                      onChallenge: (@Sendable (VerificationChannel) -> Void)?,
                                      log: @escaping @Sendable (String) -> Void) throws -> Device {
        let directory = root.appendingPathComponent("mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try Device(directory: directory,
                          platform: .mac,
                          model: TFConstants.macModel,
                          macOSVersion: TFConstants.macOSVersion,
                          macOSBuild: TFConstants.macOSBuild,
                          transport: transport(diagnostics: diagnostics, onChallenge: onChallenge, log: log),
                          userAgent: TFConstants.storeUserAgent,
                          clientInfo: TFConstants.authClientInfo)
    }

    // MARK: - transport

    /// Logs method/host/path/status only: request bodies carry credentials.
    ///
    /// For `/grandslam/` calls it also prints the identity headers Apple routes on —
    /// user agent, client info, client app name, time zone, RINFO, locale — plus the
    /// body's byte count. Those are device fingerprints, never secrets; the body itself
    /// is hashed by length only, so an SRP mismatch shows up as a size delta.
    private static func transport(diagnostics: AuthDiagnosticBox,
                                  onChallenge: (@Sendable (VerificationChannel) -> Void)?,
                                  log: @escaping @Sendable (String) -> Void) -> HTTPTransport {
        { request in
            var request = request
            request.timeoutInterval = 30
            var (data, http) = try await TFNet.data(for: request, cookieStorage: .shared, acceptCookies: true)
            let host = request.url?.host ?? "?"
            let path = request.url?.path ?? "/"
            let method = request.httpMethod ?? "GET"
            if path.contains("/grandslam/"), http.statusCode == 503, diagnostics.consumePost2FA503Retry() {
                log("  request " + method + " " + host + path + " -> 503 right after 2FA, waiting 1.5s and retrying once")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                (data, http) = try await TFNet.data(for: request, cookieStorage: .shared, acceptCookies: true)
            }
            let status = http.statusCode
            log("  request " + method + " " + host + path
                + " -> " + String(status) + ", " + String(data.count) + " B")

            if path.contains("/grandslam/") {
                let fields = request.allHTTPHeaderFields ?? [:]
                let bodyBytes = request.httpBody?.count ?? -1
                let ua = fields["User-Agent"] ?? "-"
                let ci = fields["X-MMe-Client-Info"] ?? fields["X-Apple-Client-Info"] ?? "-"
                let app = fields["X-Apple-Client-App-Name"] ?? "-"
                let tz = fields["X-Apple-I-TimeZone"] ?? "-"
                let rinfo = fields["X-Apple-I-MD-RINFO"] ?? "-"
                let locale = fields["X-Apple-I-Locale"] ?? "-"
                let lang = fields["Accept-Language"] ?? "-"
                let names = fields.keys.sorted().joined(separator: ",")
                log("    gs body=" + String(bodyBytes) + " headers=" + String(fields.count))
                log("    gs ua=[" + ua + "]")
                log("    gs ci=[" + ci + "] app=[" + app + "]")
                log("    gs tz=[" + tz + "] rinfo=[" + rinfo + "] locale=[" + locale + "] lang=[" + lang + "]")
                log("    gs names=" + names)
            }

            if host.lowercased().hasSuffix("apple.com") {
                if path.contains("trustedDeviceSecondaryAuth") {
                    onChallenge?(.trustedDevice)
                } else if path == "/auth" || path.hasPrefix("/auth/verify/phone") {
                    inspectGSAAuthResponse(data: data, status: status, method: method, path: path,
                                           diagnostics: diagnostics, onChallenge: onChallenge, log: log)
                }
                let is2FAConfirm = status == 200
                    && (path == "/auth/verify/phone/securitycode" || path.contains("validateCode"))
                if is2FAConfirm {
                    diagnostics.mark2FAConfirmed()
                    // Drop web `/auth` cookies so the follow-up SRP handshake matches native curl
                    // transport, and give Apple's GSA backend a brief moment to propagate 2FA trust.
                    for cookie in HTTPCookieStorage.shared.cookies ?? []
                    where cookie.domain.contains("gsa.apple.com") {
                        HTTPCookieStorage.shared.deleteCookie(cookie)
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }

            let headers = http.allHeaderFields.compactMap { key, value -> HTTPHeader? in
                guard let key = key as? String else { return nil }
                return HTTPHeader(key, String(describing: value))
            }
            // Cookie *names* only: proves whether the store login delivered root cookies
            // (myacinfo/dsid/…) without ever writing their values.
            if path.contains("/auth/v1/") {
                if let amdm = request.value(forHTTPHeaderField: "X-Apple-AMD-M"), !amdm.isEmpty {
                    TFStoreCapture.amdm = amdm
                    log("    captured X-Apple-AMD-M (" + String(amdm.count) + " chars)")
                }
                if let front = http.value(forHTTPHeaderField: "x-set-apple-store-front") {
                    TFStoreCapture.storeFront = front
                    log("    captured store front " + front)
                }
                // Parse Set-Cookie from the wire, not from the shared jar: the jar
                // silently drops several of them on this OS.
                let raw = http.value(forHTTPHeaderField: "Set-Cookie") ?? ""
                for pair in raw.split(separator: ",") {
                    let head = pair.split(separator: ";").first.map(String.init) ?? ""
                    let parts = head.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    let name = parts[0].trimmingCharacters(in: .whitespaces)
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, !value.isEmpty { TFStoreCapture.cookies[name] = value }
                }
            }
            let cookieNames = HTTPCookie.cookies(withResponseHeaderFields: http.allHeaderFields as? [String: String] ?? [:],
                                                 for: request.url ?? TFGSA.url)
                .map(\.name)
                .sorted()
            if !cookieNames.isEmpty {
                log("    cookies set: " + cookieNames.joined(separator: ","))
            }
            return HTTPResponse(status: status, body: data, headers: headers)
        }
    }

    /// Extracts strictly non-sensitive diagnostic fields (`serviceErrors` codes, boolean rate-limit
    /// flags, trusted phone count) from Apple's GSA `/auth` JSON responses without ever logging
    /// phone numbers, tokens, cookies, or verification codes.
    private static func inspectGSAAuthResponse(data: Data,
                                               status: Int,
                                               method: String,
                                               path: String,
                                               diagnostics: AuthDiagnosticBox,
                                               onChallenge: (@Sendable (VerificationChannel) -> Void)?,
                                               log: @escaping @Sendable (String) -> Void) {
        guard !data.isEmpty,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        let container = (json["phoneNumberVerification"] as? [String: Any]) ?? json
        let phones = container["trustedPhoneNumbers"] as? [[String: Any]] ?? []
        if method == "GET", path == "/auth", status == 200 || status == 201 {
            let singleDisplay: String? = phones.count == 1
                ? (phones.first?["numberWithDialCode"] as? String)
                : nil
            onChallenge?(.sms(phoneDisplay: singleDisplay))
        }

        var parts: [String] = []
        var summaryBits: [String] = []
        if !phones.isEmpty {
            parts.append("phones=\(phones.count)")
        }
        if let authType = json["authenticationType"] as? String, !authType.isEmpty {
            parts.append("type=\(authType)")
        }
        if let noTrusted = json["noTrustedDevices"] as? Bool, noTrusted {
            parts.append("noTrustedDevices=true")
        }
        if let sec = (container["securityCode"] as? [String: Any]) ?? (json["securityCode"] as? [String: Any]) {
            for key in ["tooManyCodesSent", "tooManyCodesValidated", "securityCodeLocked", "securityCodeCooldown"] {
                if let flag = sec[key] as? Bool, flag {
                    parts.append("\(key)=true")
                    summaryBits.append(key)
                }
            }
        }
        let rawErrors = (json["serviceErrors"] as? [[String: Any]])
            ?? (container["serviceErrors"] as? [[String: Any]])
            ?? []
        if !rawErrors.isEmpty {
            var errorTexts: [String] = []
            for item in rawErrors.prefix(3) {
                let codeStr: String
                if let c = item["code"] as? String, !c.isEmpty {
                    codeStr = c
                } else if let c = item["code"] as? Int {
                    codeStr = String(c)
                } else {
                    codeStr = "?"
                }
                let rawMsg = (item["message"] as? String) ?? (item["title"] as? String) ?? ""
                let cleanMsg = TFRedaction.clean(rawMsg.replacingOccurrences(of: "\n", with: " "))
                let shortMsg = String(cleanMsg.prefix(120))
                errorTexts.append(shortMsg.isEmpty ? "code=\(codeStr)" : "code=\(codeStr) \(shortMsg)")
                summaryBits.append("code=\(codeStr)")
            }
            parts.append("errors=[\(errorTexts.joined(separator: "; "))]")
        }
        if !parts.isEmpty {
            log("    auth meta: " + parts.joined(separator: " "))
        }
        if status >= 400 || !rawErrors.isEmpty {
            if !summaryBits.isEmpty {
                diagnostics.record(summaryBits.joined(separator: ", "))
            }
        }
    }

    public static func shortDescription(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return TFRedaction.clean(text.replacingOccurrences(of: "\n", with: " "))
    }
}
