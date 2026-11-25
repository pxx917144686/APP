import Foundation

public enum AccountScope {
    private static let lock = NSLock()

    public static func directory() -> URL {
        if let resolved = SigningCapability.resolved {
            let root = resolved.url.appendingPathComponent("tf-jars", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? setProtection(root)
            var shouldLog = false
            logLock.lock()
            if !didLogGroup { didLogGroup = true; shouldLog = true }
            logLock.unlock()
            if shouldLog {
                TFLog.append("jar: 使用已授权分组 " + resolved.identifier)
            }
            return root
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("tf-jars", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? setProtection(root)
        var shouldLog = false
        logLock.lock()
        if !didLogFallback { didLogFallback = true; shouldLog = true }
        logLock.unlock()
        if shouldLog {
            TFLog.append("jar: 降级到 Application Support（签名无 App Group）")
        }
        return root
    }

    private static func setProtection(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }

    private static let logLock = NSLock()
    nonisolated(unsafe) private static var didLogGroup = false
    nonisolated(unsafe) private static var didLogFallback = false

    private static func safeDsid(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return trimmed
    }

    public static func snapshotURL(dsid: String) -> URL {
        let safe = safeDsid(dsid) ?? "_invalid"
        return directory().appendingPathComponent(safe + ".json")
    }

    public static func store(dsid: String, wireCookies: [String: String],
                             log: @escaping @Sendable (String) -> Void) throws {
        guard let safe = safeDsid(dsid) else {
            throw TFError.malformed("无效的 dsid")
        }
        let cookies = try StoreContextBuilder.whitelist(wireCookies, dsid: safe, log: log)
        try StoreContextBuilder.assertSigned(cookies, dsid: safe)
        lock.lock()
        defer { lock.unlock() }
        let data = try JSONSerialization.data(withJSONObject: cookies, options: [.sortedKeys])
        let target = snapshotURL(dsid: safe)
        try data.write(to: target, options: .atomic)
        try? setProtection(target)
        log("jar: 写入 …" + String(safe.suffix(4)) + " 快照 " + String(data.count) + " B（" + String(cookies.count) + " 个 cookie）")
    }

    public static func cookies(for dsid: String) -> [String: String]? {
        guard let safe = safeDsid(dsid) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: snapshotURL(dsid: safe)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return payload
    }

    public static func remove(dsid: String) {
        guard let safe = safeDsid(dsid) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: snapshotURL(dsid: safe))
    }

    public static func clearSharedCookies() {
        clearAppleCookies()
    }

    public static func activate(dsid: String, currentDsid: String? = nil,
                                log: @escaping @Sendable (String) -> Void) {
        if let currentDsid, currentDsid != dsid {
            writeBack(dsid: currentDsid)
        }
        clearAppleCookies()
        guard let cookies = cookies(for: dsid) else {
            log("jar: " + String(dsid.suffix(4)) + " 无快照，按全新登录处理")
            return
        }
        load(cookies)
        log("jar: 载入 " + String(dsid.suffix(4)) + " 快照 " + String(cookies.count) + " 个 cookie")
        inventory(log: log)
    }

    public static func writeBack(dsid: String) {
        guard let safe = safeDsid(dsid) else { return }
        var cookies: [String: String] = [:]
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.contains("apple.com") {
            let isOurs = cookie.name == "X-Dsid"
                ? cookie.value == safe
                : TFLogin.cookieBelongs(cookie.name, dsid: safe)
            if isOurs, !cookie.value.isEmpty { cookies[cookie.name] = cookie.value }
        }
        guard !cookies.isEmpty,
              let filtered = try? StoreContextBuilder.whitelist(cookies, dsid: safe, log: { _ in }) else { return }
        lock.lock()
        defer { lock.unlock() }
        if let data = try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys]) {
            let target = snapshotURL(dsid: safe)
            try? data.write(to: target, options: .atomic)
            try? setProtection(target)
        }
    }

    static func clearAppleCookies() {
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.contains("apple.com") {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    static func load(_ cookies: [String: String]) {
        for (name, value) in cookies {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: ".apple.com", .path: "/",
                .secure: "TRUE", .expires: Date().addingTimeInterval(86_400),
            ]
            if let cookie = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }
    public static func inventory(log: @escaping @Sendable (String) -> Void) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory().path) else { return }
        var parts: [String] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let path = directory().appendingPathComponent(name).path
            let size = (try? manager.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            let raw = name.replacingOccurrences(of: ".json", with: "")
            let label = raw.count > 4 ? ("…" + String(raw.suffix(4))) : raw
            parts.append(label + "=" + String(size) + "B")
        }
        log("jar: 快照清单 " + (parts.isEmpty ? "空" : parts.joined(separator: " ")))
    }
}
