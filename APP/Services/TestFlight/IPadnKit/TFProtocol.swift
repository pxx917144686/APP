import Foundation

/// Constants decoded from the TestFlight binary. Values, not secrets.
public enum TFConstants {
    /// The `User-Agent` TestFlight itself sends; the service rejects unknown agents.
    public static let agent =
        "Oasis/4.3.0 OasisBuild/659.1 iOS/17.6.1 model/iPhone12,1 hwp/t8030 build/21G101 (6; dt:189) AMS/1 TSE/0"
    /// Salt mixed into `X-Session-Digest`: SHA1(sessionId + requestId + dsid + salt).
    public static let sessionSalt =
        "LWzxL71nAUJTbK9X54DDQU5KC6oTcBFuibEJXIZglPRkhCSmh68PREebiNDZXctOKXpIcOfbnndI2FjMveKfRYOLPfYFRTgua1vg"
    public static let host = "https://testflight.apple.com"
    /// TestFlight's own client info; only the final TestFlight calls use it.
    public static let clientInfo = "OS=27.0.1;model=iPhone16,1;hwp=t8130"

    // GSA/Store identity. These are the values the working probe presents, and the
    // reason they matter: Apple's auth host routes by client info and User-Agent, so
    // an invented pair makes the provisioning lookup answer `404 · 0 B`.
    public static let macModel = "MacBookPro18,3"
    public static let macOSVersion = "15.6"
    public static let macOSBuild = "24G84"
    public static let authClientInfo =
        "<MacBookPro18,3> <macOS;15.6;24G84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    /// The Store/TestFlight user agent for the auth calls.
    ///
    /// Apple routes GrandSlam by user agent: presenting a TestFlight-on-iOS agent
    /// (`Oasis/…`) together with a Mac client-info is treated as an illegal pair and the
    /// SRP step answers `503`. This is the exact line a working Store login sends.
    public static let storeUserAgent =
        "MacAppStore/3.0 TestFlight/4.4.0 (Macintosh; OS X 15.6; 24G84) AppleWebKit/8614.3.7.1.5 AMS/1 (dt:1)"

    /// Platform and client-app name are part of the routing contract, not decoration.
    public static let storePlatform = "iphone"
    public static let clientAppName = "akd"

    /// Diagnostic override for the invariant self-test: `--tf-bad-ua` presents a wrong
    /// user agent on purpose so the check can be seen failing instead of being trusted.
    public static var effectiveUserAgent: String {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--tf-bad-ua")
            ? "TestFlight/4.4.0 (iPhone; iOS 27.0.1)"
            : storeUserAgent
        #else
        return storeUserAgent
        #endif
    }
}

/// The Store context that `testflight.apple.com` accepts.
///
/// `StoreSession.testFlightContext(hardware20:headers:)` builds this natively; it is
/// posted verbatim, so the layer never has to re-derive Apple's schema.
public struct TFContext: Sendable {
    public let body: Data
    public let hardware20: Data
    public let storefront: String
    /// Identity headers that must ride on the authenticate request itself.
    public let headers: [String: String]
    /// The Store DSID this context belongs to; carried explicitly because the body may
    /// hold it as a JSON number, which a string-only read would miss.
    public let dsid: String
    /// The cookie set sent to the service; the download chain needs the same values in
    /// the envelope form the native client takes.
    public let storeCookies: [String: String]

    public init(body: Data, hardware20: Data, storefront: String,
                headers: [String: String] = [:], dsid: String = "",
                storeCookies: [String: String] = [:]) {
        self.body = body
        self.hardware20 = hardware20
        self.storefront = storefront
        self.headers = headers
        self.dsid = dsid
        self.storeCookies = storeCookies
    }

    /// Field names only: logging must never expose a token or cookie value.
    public var summary: String {
        let names = (try? JSONSerialization.jsonObject(with: body))
            .flatMap { $0 as? [String: Any] }?.keys.sorted() ?? []
        return "context \(body.count) B · fields \(names.count) · udid \(hardware20.count * 2) hex · storefront \(storefront)"
    }
}

/// An authenticated TestFlight session. `id` is a bearer-like value: never logged.
public struct TFSession: Sendable {
    public let id: String
    public let dsid: String
    /// TestFlight's own account id (a UUID), which is *not* the Store dsid and is what
    /// the catalog path is keyed by.
    public let account: String
    /// Store identity headers (AMD-M, store front, device model) that every signed call
    /// also has to carry.
    public let baseHeaders: [String: String]
    public init(id: String, dsid: String, account: String = "", baseHeaders: [String: String] = [:]) {
        self.id = id
        self.dsid = dsid
        self.account = account
        self.baseHeaders = baseHeaders
    }
}

public struct TFBetaApp: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let latestVersion: String?
    public let buildCount: Int
    /// Templated icon URL (`…/{w}x{h}{c}.{f}`) from `build.iconSet`; nil for TestFlight-only
    /// apps that publish no icon of their own.
    public let iconTemplate: String?
    public let developerName: String?

    public init(id: String, name: String, bundleID: String, latestVersion: String?,
                buildCount: Int, iconTemplate: String? = nil, developerName: String? = nil) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.latestVersion = latestVersion
        self.buildCount = buildCount
        self.iconTemplate = iconTemplate
        self.developerName = developerName
    }
}

/// Official TestFlight availability bucket matching the three sections on the home list:
/// `正在测试` (`testing`), `不兼容` (`incompatible`), and `以前测试过` (`previouslyTested`).
public enum TFAppAvailability: String, Codable, Equatable, Sendable {
    case testing
    case incompatible
    case previouslyTested
}

/// Active per-platform build returned inside `/v3/accounts/{account}/apps/{appID}` `platforms[]`.
public struct TFPlatformBuild: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Canonical platform key from Apple TestFlight API: `"ios"`, `"appletvos"`, `"xros"`, `"osx"`, `"watchos"`.
    public let platform: String
    public let buildID: String
    public let shortVersion: String
    public let buildVersion: String
    public let expirationISO: String?
    public let releaseDateISO: String?
    public let fileSizeBytes: Int64?
    public let fileSizeUncompressedBytes: Int64?
    public let compatibilityStatement: String?
    public let whatsNew: String?
    public let isIPadOnly: Bool
    public let isWatchOnly: Bool

    public init(platform: String, buildID: String, shortVersion: String, buildVersion: String,
                expirationISO: String? = nil, releaseDateISO: String? = nil,
                fileSizeBytes: Int64? = nil, fileSizeUncompressedBytes: Int64? = nil,
                compatibilityStatement: String? = nil, whatsNew: String? = nil,
                isIPadOnly: Bool = false, isWatchOnly: Bool = false) {
        self.platform = platform
        self.buildID = buildID
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.expirationISO = expirationISO
        self.releaseDateISO = releaseDateISO
        self.fileSizeBytes = fileSizeBytes
        self.fileSizeUncompressedBytes = fileSizeUncompressedBytes
        self.compatibilityStatement = compatibilityStatement
        self.whatsNew = whatsNew
        self.isIPadOnly = isIPadOnly
        self.isWatchOnly = isWatchOnly
    }

    public var id: String { "\(platform):\(buildID)" }

    /// Platforms whose TestFlight package is an IPA (`Payload/<App>.app`).
    public var supportsIPADownload: Bool {
        let p = platform.lowercased()
        return (p == "ios" && !isWatchOnly) || p == "appletvos" || p == "xros"
    }

    /// True when the build can run natively on iPhone (not Apple TV, visionOS, macOS, watchOS, or iPad-only).
    public var isNativeToPhone: Bool {
        platform.lowercased() == "ios" && !isIPadOnly && !isWatchOnly
    }

    public var displayName: String {
        switch platform.lowercased() {
        case "ios": return isWatchOnly ? "Apple Watch" : (isIPadOnly ? "iPad" : "iOS")
        case "appletvos", "tvos": return "Apple TV"
        case "xros", "visionos": return "visionOS"
        case "osx", "macos": return "macOS"
        case "watchos": return "Apple Watch"
        default: return platform.uppercased()
        }
    }

    public var versionSummary: String {
        if !shortVersion.isEmpty && !buildVersion.isEmpty {
            return "\(shortVersion) (\(buildVersion))"
        }
        return !shortVersion.isEmpty ? shortVersion : buildVersion
    }

    public func daysRemaining(from now: Date = Date()) -> Int? {
        guard let expiration = TFAppDetail.parseISO8601(expirationISO) else { return nil }
        let seconds = expiration.timeIntervalSince(now)
        if seconds <= 0 { return 0 }
        return max(1, Int(ceil(seconds / 86_400)))
    }

    public var releaseDate: Date? {
        TFAppDetail.parseISO8601(releaseDateISO)
    }
}

/// Rich per-app metadata from `/v3/accounts/{account}/apps/{appID}`, matching the official
/// TestFlight list subtitle (`1.1.0 (931) · 90 天`) and detail page fields.
public struct TFAppDetail: Codable, Equatable, Sendable {
    public let appID: String
    public var name: String
    public let bundleID: String
    public let developerName: String
    public let buildID: String
    public let shortVersion: String
    public let buildVersion: String
    public let expirationISO: String?
    public let releaseDateISO: String?
    public var whatsNew: String?
    public let description: String?
    public let fileSizeBytes: Int64?
    public let fileSizeUncompressedBytes: Int64?
    public let compatibilityStatement: String?
    public let supportEmail: String?
    public let shareURL: String?
    public let privacyPolicyURL: String?
    public let supportedDevices: [String]?
    public let termsOfService: String?
    public let availability: TFAppAvailability?
    /// Human platform names when `availability == .incompatible` (e.g. `["macOS"]`, `["Apple TV"]`).
    public let incompatiblePlatforms: [String]?
    /// All active platform builds advertised for this app (e.g. iOS + Apple TV + visionOS + macOS).
    public let platformBuilds: [TFPlatformBuild]?
    public let iconAsset: TFIconAsset?
    public let cachedAt: Date

    public init(appID: String, name: String, bundleID: String, developerName: String,
                buildID: String, shortVersion: String, buildVersion: String,
                expirationISO: String?, releaseDateISO: String?,
                whatsNew: String?, description: String?, fileSizeBytes: Int64?,
                fileSizeUncompressedBytes: Int64? = nil,
                compatibilityStatement: String?, supportEmail: String? = nil,
                shareURL: String? = nil, privacyPolicyURL: String? = nil,
                supportedDevices: [String]? = nil, termsOfService: String? = nil,
                availability: TFAppAvailability? = nil,
                incompatiblePlatforms: [String]? = nil,
                platformBuilds: [TFPlatformBuild]? = nil,
                iconAsset: TFIconAsset?, cachedAt: Date = Date()) {
        self.appID = appID
        self.name = name
        self.bundleID = bundleID
        self.developerName = Self.cleanDeveloperName(developerName)
        self.buildID = buildID
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.expirationISO = expirationISO
        self.releaseDateISO = releaseDateISO
        self.whatsNew = whatsNew
        self.description = description
        self.fileSizeBytes = fileSizeBytes
        self.fileSizeUncompressedBytes = fileSizeUncompressedBytes
        self.compatibilityStatement = compatibilityStatement
        self.supportEmail = supportEmail
        self.shareURL = shareURL
        self.privacyPolicyURL = privacyPolicyURL
        self.supportedDevices = supportedDevices
        self.termsOfService = termsOfService
        self.availability = availability
        self.incompatiblePlatforms = incompatiblePlatforms
        self.platformBuilds = platformBuilds
        self.iconAsset = iconAsset
        self.cachedAt = cachedAt
    }

    /// Downloadable IPA platform builds (native iOS first, then iPad, Apple TV, visionOS).
    public var downloadablePlatformBuilds: [TFPlatformBuild] {
        (platformBuilds ?? []).filter(\.supportsIPADownload)
    }

    /// Strips Apple's internal `|<teamId>|<flag>` suffix from developer names when present.
    public static func cleanDeveloperName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pipe = trimmed.firstIndex(of: "|") else { return trimmed }
        let head = trimmed[..<pipe].trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? trimmed : head
    }

    /// Version string in TestFlight style, e.g. `1.1.0 (931)`.
    public var versionSummary: String {
        if !shortVersion.isEmpty && !buildVersion.isEmpty {
            return "\(shortVersion) (\(buildVersion))"
        }
        return !shortVersion.isEmpty ? shortVersion : buildVersion
    }

    /// Remaining test days derived from `expirationISO` (clamped at 0 when expired).
    public func daysRemaining(from now: Date = Date()) -> Int? {
        guard let expiration = Self.parseISO8601(expirationISO) else { return nil }
        let seconds = expiration.timeIntervalSince(now)
        if seconds <= 0 { return 0 }
        return max(1, Int(ceil(seconds / 86_400)))
    }

    public var releaseDate: Date? {
        Self.parseISO8601(releaseDateISO)
    }

    private static let isoLock = NSLock()
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        isoLock.lock()
        defer { isoLock.unlock() }
        if let date = isoWithFraction.date(from: raw) { return date }
        return isoPlain.date(from: raw)
    }
}

public enum TFError: LocalizedError {
    case http(status: Int, path: String, body: String)
    case malformed(String)
    case noAccount
    case cancelled
    case appUnavailable(String)
    /// All transfer attempts failed: the UI words this as a network interruption.
    case networkLost
    /// A routing value differs from what Apple expects; names item, expected and actual.
    case invariant(String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case let .http(status, path, body):
            let hint: String
            switch status {
            case 401, 403: hint = "会话被拒绝（签名头或会话 ID 与 Apple 预期不一致）"
            case 429: hint = "请求过于频繁，被限流"
            case 500...599: hint = "服务端暂时不可用"
            default: hint = "请求被拒绝"
            }
            let excerpt = body.isEmpty ? "" : " · " + String(body.prefix(120))
            return "\(hint) [\(status) \(path)]\(excerpt)"
        case let .malformed(what):
            return "返回内容无法解析：\(what)"
        case .noAccount:
            return "请先在「账号」里登录 Apple 账号，TestFlight 会复用它"
        case let .appUnavailable(name):
            return "\(name) 在 TestFlight 上已失效或不可用，无法下载"
        case .cancelled:
            return "已取消"
        case .networkLost:
            return "网络中断，请稍后重试"
        case let .invariant(item, expected, actual):
            return "不变量 " + item + "：期望 " + expected + "，实际 " + actual
        }
    }
}

/// Per-install device identity (40 hex chars).
///
/// Persisted because TestFlight binds a session to the device it was created on;
/// it is not a credential and never leaves the app except as part of the context.
public enum TFIdentity {
    private static let key = "tf.hardware20"

    public static func hardware20() -> Data {
        if let stored = UserDefaults.standard.data(forKey: key), stored.count == 20 {
            return stored
        }
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data = Data(bytes)
        UserDefaults.standard.set(data, forKey: key)
        return data
    }
}

/// Append-only log for the TestFlight page.
///
/// Every line goes through `TFRedaction`, so a stray cookie or token can never
/// reach the file even if a caller formats one by accident.
public enum TFLog {
    private static let lock = NSLock()
    private static let maxBytes = 256 * 1024
    private static let keepTailBytes = 128 * 1024
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Self-contained on purpose: the kit must not reach into app types.
    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("testflight.log")
    }

    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    public static func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(timeFormatter.string(from: Date())) \(TFRedaction.clean(text))\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = fileURL
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int),
           size > maxBytes,
           let existing = try? Data(contentsOf: url) {
            let tail = existing.suffix(keepTailBytes)
            let trimmed: Data
            if let nl = tail.firstIndex(of: 0x0A), tail.index(after: nl) < tail.endIndex {
                trimmed = tail[tail.index(after: nl)...]
            } else {
                trimmed = Data(tail)
            }
            var rotated = Data(trimmed)
            rotated.append(data)
            try? rotated.write(to: url, options: .atomic)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

public enum TFRedaction {
    private static let rules: [(regex: NSRegularExpression, template: String)] = {
        let specs: [(String, String)] = [
            ("(?i)(cookie\\s*[:=]\\s*)[^;\\n]{4,}", "$1‹redacted›"),
            ("(?i)(x-session-id\\s*[:=]\\s*)[^\\s,;]{4,}", "$1‹redacted›"),
            ("(?i)(x-session-digest\\s*[:=]\\s*)[^\\s,;]{4,}", "$1‹redacted›"),
            ("(?i)(x-apple-amd-m\\s*[:=]\\s*)\\S+", "$1‹redacted›"),
            ("(?i)(x-token\\s*[:=]\\s*)[^\\s,;]{4,}", "$1‹redacted›"),
            ("(?i)(authorization\\s*[:=]\\s*(?:bearer\\s+)?)\\S+", "$1‹redacted›"),
            ("(?i)(password\\s*[:=]\\s*)\\S+", "$1‹redacted›"),
            ("(?i)(\"?dpInfo\"?\\s*[:=]\\s*\"?)[A-Za-z0-9+/=_-]{8,}", "$1‹redacted›"),
            ("(?i)(\"?sinf\"?\\s*[:=]\\s*\"?)[A-Za-z0-9+/=<>_-]{12,}", "$1‹redacted›"),
            ("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b", "‹jwt›"),
            ("(?i)([?&](?:accessKey|signature|expires|policy|token|key|sig|auth)=)[^&\\s\"']+", "$1‹redacted›"),
            ("(?i)(adsid\\s*[:=]\\s*)\\d{4,}", "$1‹redacted›"),
            ("(?i)(dsId\\s*=\\s*)\\d{5,}(\\d{4})\\b", "$1…$2"),
            ("(?i)(vendor\\s*=\\s*)[0-9a-f]{12,}", "$1‹redacted›"),
            ("(?i)(identity\\s+)\\d{5,}(\\d{4}):[0-9a-f]{16,}", "$1…$2:‹udid›"),
            ("(/accounts/)[0-9a-fA-F-]{6,}(/)", "$1‹account›$2"),
            ("(?i)(mt-tkn-|mz_at0-|mz_at_mau-|mz_at_ssl-)\\d{5,}(\\d{4})\\b", "$1…$2"),
            ("\\b\\d{5,}(\\d{4})(=\\d+B)\\b", "…$1$2"),
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "‹email›"),
        ]
        return specs.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    public static func clean(_ text: String) -> String {
        var output = text
        for rule in rules {
            let range = NSRange(output.startIndex..., in: output)
            output = rule.regex.stringByReplacingMatches(in: output, range: range, withTemplate: rule.template)
        }
        return output
    }
}
