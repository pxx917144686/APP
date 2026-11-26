import Foundation

public enum TFConstants {
    public static let agent =
        "Oasis/4.3.0 OasisBuild/659.1 iOS/17.6.1 model/iPhone12,1 hwp/t8030 build/21G101 (6; dt:189) AMS/1 TSE/0"
    public static let sessionSalt =
        "LWzxL71nAUJTbK9X54DDQU5KC6oTcBFuibEJXIZglPRkhCSmh68PREebiNDZXctOKXpIcOfbnndI2FjMveKfRYOLPfYFRTgua1vg"
    public static let host = "https://testflight.apple.com"
    public static let clientInfo = "OS=27.0.1;model=iPhone16,1;hwp=t8130"

    public static let macModel = "MacBookPro18,3"
    public static let macOSVersion = "15.6"
    public static let macOSBuild = "24G84"
    public static let authClientInfo =
        "<MacBookPro18,3> <macOS;15.6;24G84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    public static let storeUserAgent =
        "MacAppStore/3.0 TestFlight/4.4.0 (Macintosh; OS X 15.6; 24G84) AppleWebKit/8614.3.7.1.5 AMS/1 (dt:1)"

    public static let storePlatform = "iphone"
    public static let clientAppName = "akd"

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

public struct TFContext: Sendable {
    public let body: Data
    public let hardware20: Data
    public let storefront: String
    public let headers: [String: String]
    public let dsid: String
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

    public var summary: String {
        let names = (try? JSONSerialization.jsonObject(with: body))
            .flatMap { $0 as? [String: Any] }?.keys.sorted() ?? []
        return "context \(body.count) B · fields \(names.count) · udid \(hardware20.count * 2) hex · storefront \(storefront)"
    }
}

public struct TFSession: Sendable {
    public let id: String
    public let dsid: String
    public let account: String
    public let baseHeaders: [String: String]
    public let storefrontOverride: String?
    public init(id: String, dsid: String, account: String = "", baseHeaders: [String: String] = [:],
                storefrontOverride: String? = nil) {
        self.id = id
        self.dsid = dsid
        self.account = account
        self.baseHeaders = baseHeaders
        self.storefrontOverride = storefrontOverride
    }

    public var effectiveHeaders: [String: String] {
        guard let storefrontOverride, !storefrontOverride.isEmpty else { return baseHeaders }
        var headers = baseHeaders
        headers["X-Apple-Store-Front"] = storefrontOverride
        return headers
    }
}

public struct TFBetaApp: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let latestVersion: String?
    public let buildCount: Int
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

public enum TFAppAvailability: String, Codable, Equatable, Sendable {
    case testing
    case incompatible
    case previouslyTested
}

public struct TFPlatformBuild: Codable, Equatable, Hashable, Sendable, Identifiable {
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

    public var supportsIPADownload: Bool {
        let p = platform.lowercased()
        return (p == "ios" && !isWatchOnly) || p == "appletvos" || p == "xros"
    }

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
    public let incompatiblePlatforms: [String]?
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

    public var downloadablePlatformBuilds: [TFPlatformBuild] {
        (platformBuilds ?? []).filter(\.supportsIPADownload)
    }

    public static func cleanDeveloperName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pipe = trimmed.firstIndex(of: "|") else { return trimmed }
        let head = trimmed[..<pipe].trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? trimmed : head
    }

    public var versionSummary: String {
        if !shortVersion.isEmpty && !buildVersion.isEmpty {
            return "\(shortVersion) (\(buildVersion))"
        }
        return !shortVersion.isEmpty ? shortVersion : buildVersion
    }

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
    case noBuild(String)
    case networkLost
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
        case let .noBuild(platform):
            return "没有可用的 \(platform) build"
        case .cancelled:
            return "已取消"
        case .networkLost:
            return "网络中断，请稍后重试"
        case let .invariant(item, expected, actual):
            return "不变量 " + item + "：期望 " + expected + "，实际 " + actual
        }
    }
}

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
