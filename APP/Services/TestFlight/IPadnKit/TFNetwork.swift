import Foundation

public enum TFNetworkMode: String, CaseIterable, Identifiable {
    case auto, direct, proxy

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "跟随系统"
        case .direct: return "强制直连"
        case .proxy: return "强制代理"
        }
    }
}

public enum TFError2 {}
extension TFError {}

public enum TFNet {
    private static let modeKey = "tf.network.mode"

    public static var mode: TFNetworkMode {
        get { TFNetworkMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .auto }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
            didBypassProxy = false
        }
    }

    private static let stateLock = NSLock()
    private static var _didBypassProxy = false
    private static var sessionPool: [SessionKey: URLSession] = [:]

    private struct SessionKey: Hashable {
        let mode: TFNetworkMode
        let direct: Bool
        let sharedCookies: Bool
        let acceptCookies: Bool
    }

    public static var didBypassProxy: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _didBypassProxy
        }
        set {
            stateLock.lock()
            _didBypassProxy = newValue
            stateLock.unlock()
        }
    }

    public static func configuration(mode: TFNetworkMode = TFNet.mode,
                                     direct: Bool = false,
                                     cookieStorage: HTTPCookieStorage? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        if let cookieStorage { configuration.httpCookieStorage = cookieStorage }
        switch mode {
        case .proxy:
            break
        case .direct:
            configuration.connectionProxyDictionary = [:]
        case .auto:
            if direct { configuration.connectionProxyDictionary = [:] }
        }
        return configuration
    }

    public static func session(mode: TFNetworkMode = TFNet.mode,
                               direct: Bool = false,
                               cookieStorage: HTTPCookieStorage? = nil) -> URLSession {
        URLSession(configuration: configuration(mode: mode, direct: direct, cookieStorage: cookieStorage))
    }

    private static func pooledSession(mode: TFNetworkMode,
                                      direct: Bool,
                                      cookieStorage: HTTPCookieStorage?,
                                      acceptCookies: Bool) -> (session: URLSession, ephemeral: Bool) {
        let isSharedOrNil = (cookieStorage == nil) || (cookieStorage === HTTPCookieStorage.shared)
        if isSharedOrNil {
            let key = SessionKey(mode: mode, direct: direct, sharedCookies: cookieStorage != nil, acceptCookies: acceptCookies)
            stateLock.lock()
            if let existing = sessionPool[key] {
                stateLock.unlock()
                return (existing, false)
            }
            let cfg = configuration(mode: mode, direct: direct, cookieStorage: cookieStorage)
            if acceptCookies {
                cfg.httpCookieAcceptPolicy = .always
                cfg.httpShouldSetCookies = true
            } else {
                cfg.httpCookieAcceptPolicy = .never
                cfg.httpShouldSetCookies = false
            }
            let created = URLSession(configuration: cfg)
            sessionPool[key] = created
            stateLock.unlock()
            return (created, false)
        }
        let cfg = configuration(mode: mode, direct: direct, cookieStorage: cookieStorage)
        if acceptCookies {
            cfg.httpCookieAcceptPolicy = .always
            cfg.httpShouldSetCookies = true
        }
        return (URLSession(configuration: cfg), true)
    }

    public static func data(for request: URLRequest,
                            cookieStorage: HTTPCookieStorage? = .shared,
                            acceptCookies: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let startDirect = (mode == .direct) || (mode == .auto && didBypassProxy)
        do {
            let (data, http) = try await performOnce(request, direct: startDirect,
                                                     cookieStorage: cookieStorage,
                                                     acceptCookies: acceptCookies)
            if mode == .auto, !startDirect, (http.statusCode == 0 || http.statusCode >= 500) {
                if let (retryData, retryHTTP) = try? await performOnce(request, direct: true,
                                                                       cookieStorage: cookieStorage,
                                                                       acceptCookies: acceptCookies),
                   retryHTTP.statusCode > 0, retryHTTP.statusCode < 500 {
                    didBypassProxy = true
                    TFLog.append("net: proxy bypass（系统代理返回 \(http.statusCode)，改走直连）")
                    return (retryData, retryHTTP)
                }
            }
            return (data, http)
        } catch {
            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled || Task.isCancelled {
                throw error
            }
            guard mode == .auto, !startDirect else { throw error }
            let (retryData, retryHTTP) = try await performOnce(request, direct: true,
                                                               cookieStorage: cookieStorage,
                                                               acceptCookies: acceptCookies)
            didBypassProxy = true
            TFLog.append("net: proxy bypass（系统代理不可用时改走直连）")
            return (retryData, retryHTTP)
        }
    }

    private static func performOnce(_ request: URLRequest, direct: Bool,
                                    cookieStorage: HTTPCookieStorage?,
                                    acceptCookies: Bool) async throws -> (Data, HTTPURLResponse) {
        let (session, ephemeral) = pooledSession(mode: mode, direct: direct,
                                                 cookieStorage: cookieStorage,
                                                 acceptCookies: acceptCookies)
        defer { if ephemeral { session.finishTasksAndInvalidate() } }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TFError.malformed("没有 HTTP 响应")
        }
        return (data, http)
    }

    public static func looksBlocked(status: Int?, error: Error?, hosts: [String]) -> Bool {
        if let error {
            let code = (error as NSError).code
            return [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                    NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                    NSURLErrorDNSLookupFailed].contains(code)
        }
        guard let status else { return true }
        return status == 0 || status >= 500
    }
}

public enum TFDoh {
    private struct Entry { let source: String; let date: Date }
    private static let lock = NSLock()
    private static var cache: [String: Entry] = [:]
    private static let ttl: TimeInterval = 300
    private static let servers = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]

    private static func cached(_ host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let hit = cache[host], Date().timeIntervalSince(hit.date) < ttl else { return nil }
        return hit.source
    }

    private static func store(_ source: String, for host: String) {
        lock.lock()
        cache[host] = Entry(source: source, date: Date())
        lock.unlock()
    }

    public static func probe(_ host: String,
                             log: @escaping @Sendable (String) -> Void) async -> String {
        if let hit = cached(host) {
            return hit
        }
        let mode = TFNet.mode
        let resolvedDoH = await withTaskGroup(of: Bool.self) { group in
            for server in servers {
                group.addTask {
                    guard var components = URLComponents(string: server) else { return false }
                    components.queryItems = [
                        URLQueryItem(name: "name", value: host),
                        URLQueryItem(name: "type", value: "A"),
                    ]
                    guard let url = components.url else { return false }
                    let cfg = URLSessionConfiguration.ephemeral
                    cfg.timeoutIntervalForRequest = 2.0
                    cfg.timeoutIntervalForResource = 2.5
                    cfg.httpCookieAcceptPolicy = .never
                    cfg.httpShouldSetCookies = false
                    if mode == .direct { cfg.connectionProxyDictionary = [:] }
                    let session = URLSession(configuration: cfg)
                    defer { session.finishTasksAndInvalidate() }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 2.0
                    request.setValue("application/dns-json", forHTTPHeaderField: "accept")
                    guard let (data, response) = try? await session.data(for: request),
                          let http = response as? HTTPURLResponse,
                          http.statusCode == 200,
                          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let answers = payload["Answer"] as? [[String: Any]], !answers.isEmpty else {
                        return false
                    }
                    return true
                }
            }
            for await ok in group {
                if ok {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
        if resolvedDoH {
            store("DoH", for: host)
            log("dns: " + host + " 走 DoH")
            return "DoH"
        }
        store("系统 DNS", for: host)
        log("dns: " + host + " 走 系统 DNS")
        return "系统 DNS"
    }
}

public struct TFNetDiagnosis {
    public var summary: String
    public var facts: [String]

    public static func bothFailed(_ failures: [String]) -> TFNetDiagnosis {
        TFNetDiagnosis(
            summary: "无法连接 Apple 服务（gsa / testflight）。请检查代理规则是否拦截 *.apple.com，"
                + "或在设置中把 TF 网络模式改为「强制直连」",
            facts: failures)
    }
}
