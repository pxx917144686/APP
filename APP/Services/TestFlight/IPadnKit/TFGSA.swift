import Foundation

public struct TFGSAProbe: Sendable {
    public let host: String
    public let addresses: [String]
    public let fakeIP: String?
    public let status: Int?
    public let bytes: Int
    public let elapsedMS: Int
    public let attempts: Int
    public let failure: String?
    public let controlLine: String
    public let sanityStatus: Int?

    public init(host: String, addresses: [String], fakeIP: String?, status: Int?, bytes: Int,
                elapsedMS: Int, attempts: Int, failure: String?, controlLine: String = "",
                sanityStatus: Int? = nil) {
        self.host = host
        self.addresses = addresses
        self.fakeIP = fakeIP
        self.status = status
        self.bytes = bytes
        self.elapsedMS = elapsedMS
        self.attempts = attempts
        self.failure = failure
        self.controlLine = controlLine
        self.sanityStatus = sanityStatus
    }

    public var reachable: Bool {
        guard fakeIP == nil else { return false }
        if let sanityStatus { return sanityStatus == 200 }
        return false
    }

    public var verdict: String {
        if fakeIP != nil { return "被代理接管（命中 fake-IP）" }
        if reachable {
            return status == 404 ? "网络正常；裸 GET 404 属正常（需要 Store UA）" : "网络正常"
        }
        if status == nil { return "无 HTTP 响应（\(failure ?? "连接失败")）" }
        return "网络异常"
    }

    public var summary: String {
        let dns = addresses.isEmpty ? "解析失败" : addresses.joined(separator: ",")
        let fake = fakeIP == nil ? "" : " fake-ip✓"
        let http = status.map(String.init) ?? "—"
        return "gsa: dns=\(dns)\(fake) http=\(http) bytes=\(bytes) \(elapsedMS)ms attempts=\(attempts) → \(verdict)"
    }

    public var advice: String? {
        reachable ? nil : "GSA 不可达：疑似代理/VPN 拦截，请关闭手机上的 VPN 或在代理里放行 gsa.apple.com。"
    }
}

public enum TFGSA {
    public static let url = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!
    static let fakeRange = "198.18.0.0/15"

    struct Attempt: Sendable {
        let label: String
        let urlString: String
        let status: Int?
        let bytes: Int
        let headerNames: [String]
        let responseNote: String
        let failure: String?

        var line: String {
            "gsa/\(label): \(urlString) → \(status.map(String.init) ?? "no-http") · \(bytes) B"
                + (responseNote.isEmpty ? "" : " · \(responseNote)")
                + (failure.map { " · \($0)" } ?? "")
                + (headerNames.isEmpty ? "" : " · sent \(headerNames.joined(separator: ","))")
        }
    }

    static func responseNote(_ response: HTTPURLResponse?) -> String {
        guard let response else { return "" }
        var parts: [String] = []
        for key in ["server", "content-type", "content-length", "via", "x-cache", "x-akamai-transformed"] {
            if let value = response.value(forHTTPHeaderField: key) {
                parts.append("\(key)=\(TFRedaction.clean(value))")
            }
        }
        return parts.joined(separator: " ")
    }

    static func control() async -> Attempt {
        await attempt(label: "control(shared,literal)", session: .shared, extraHeaders: false)
    }

    static func probeRequest() async -> Attempt {
        await attempt(label: "probe(shared+headers)", session: .shared, extraHeaders: true)
    }

    static func ephemeralWithHeaders() async -> Attempt {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return await attempt(label: "ephemeral(旧路径)", session: session, extraHeaders: true)
    }

    static func attempt(label: String, session: URLSession, extraHeaders: Bool,
                        url: URL = TFGSA.url) async -> Attempt {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        if extraHeaders {
            request.setValue("application/x-bml+plist", forHTTPHeaderField: "Accept")
            request.setValue(TFConstants.agent, forHTTPHeaderField: "User-Agent")
        }
        let names = (request.allHTTPHeaderFields ?? [:]).keys.sorted()
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return Attempt(label: label,
                           urlString: request.url?.absoluteString ?? "nil",
                           status: http?.statusCode,
                           bytes: data.count,
                           headerNames: names,
                           responseNote: responseNote(http),
                           failure: nil)
        } catch {
            return Attempt(label: label,
                           urlString: request.url?.absoluteString ?? "nil",
                           status: nil,
                           bytes: 0,
                           headerNames: names,
                           responseNote: "",
                           failure: TFRedaction.clean((error as NSError).localizedDescription))
        }
    }

    static let sanityURL = URL(string: "https://www.apple.com/library/test/success.html")!

    static func sanity() async -> Attempt {
        await attempt(label: "sanity(apple.com)", session: .shared, extraHeaders: false, url: sanityURL)
    }

    public static func probe(log: @escaping @Sendable (String) -> Void) async -> TFGSAProbe {
        let started = Date()
        let addresses = resolve("gsa.apple.com")
        let fake = addresses.first(where: isFakeIP)

        let control = await control()
        log(control.line)
        let sanity = await sanity()
        log(sanity.line)
        if sanity.status != 200 {
            let ephemeral = await ephemeralWithHeaders()
            log(ephemeral.line)
        }

        var attempts = 0
        var status: Int?
        var bytes = 0
        var failure: String?

        while attempts < 2 {
            attempts += 1
            let result = await probeRequest()
            status = result.status
            bytes = result.bytes
            failure = result.failure
            if result.status != nil { break }
        }

        let probe = TFGSAProbe(
            host: "gsa.apple.com",
            addresses: addresses,
            fakeIP: fake,
            status: status,
            bytes: bytes,
            elapsedMS: Int(Date().timeIntervalSince(started) * 1000),
            attempts: attempts,
            failure: failure,
            controlLine: control.line,
            sanityStatus: sanity.status
        )
        log(probe.summary)
        log("gsa: fake-ip 段 \(fakeRange)：" + (fake.map { "命中 \($0)" } ?? "未命中"))
        if let advice = probe.advice { log("gsa: \(advice)") }
        return probe
    }

    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if let address = current.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: buffer)
                    if !addresses.contains(text) { addresses.append(text) }
                }
            }
            node = current.pointee.ai_next
        }
        return addresses
    }

    public static func isFakeIP(_ text: String) -> Bool {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 198 && (parts[1] == 18 || parts[1] == 19)
    }
}
