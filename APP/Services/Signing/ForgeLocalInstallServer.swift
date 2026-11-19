import Foundation
import Darwin
import os
import Security

enum LocalHTTPRange: Equatable {
    case absent
    case bounded(start: UInt64, end: UInt64)
    case openEnded(start: UInt64)
    case suffix(UInt64)
    case invalid

    static func parse(_ header: String?) -> LocalHTTPRange {
        guard let header else { return .absent }
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("bytes=") else { return .invalid }
        let spec = String(value.dropFirst(6))
        guard !spec.contains(",") else { return .invalid }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .invalid }
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { return .invalid }
            return .suffix(suffix)
        }
        guard let start = UInt64(parts[0]) else { return .invalid }
        if parts[1].isEmpty { return .openEnded(start: start) }
        guard let end = UInt64(parts[1]) else { return .invalid }
        return .bounded(start: start, end: end)
    }
}

enum LocalHTTPRoute {
    static func request(_ requestLine: String) -> (method: String, path: String)? {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2] == "HTTP/1.0" || parts[2] == "HTTP/1.1" else { return nil }
        let rawTarget = String(parts[1])
        let path = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard path.hasPrefix("/") else { return nil }
        return (String(parts[0]).uppercased(), path)
    }
}

struct LocalIPAProgress {
    private(set) var ranges: [Range<UInt64>] = []

    mutating func record(offset: UInt64, length: UInt64, total: UInt64) -> Double {
        guard total > 0, length > 0, offset < total else { return fraction(total: total) }
        ranges.append(offset..<(offset + min(length, total - offset)))
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<UInt64>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        ranges = merged
        return fraction(total: total)
    }

    func fraction(total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        let covered = ranges.reduce(UInt64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
        return min(1, Double(covered) / Double(total))
    }

    func isComplete(total: UInt64) -> Bool {
        total > 0 && ranges.count == 1 && ranges[0] == 0..<total
    }
}

final class LocalInstallServer: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var listenerFD: Int32 = -1
        var running = false
        var port: UInt16 = 0
        var ipaURL: URL?
        var bundleId = ""
        var bundleVersion = "1.0"
        var title = "App"
        var onIPADelivered: (@Sendable () -> Void)?
        var onIPAProgress: (@Sendable (Double) -> Void)?
        var ipaProgress = LocalIPAProgress()
        var didDeliverIPA = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let installToken: String = {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    private let connectionSlots = DispatchSemaphore(value: 4)

    private let connectionQueue = DispatchQueue(
        label: "com.forgesign.installserver.connections",
        qos: .userInitiated,
        attributes: .concurrent
    )

    var installBaseURL: String {
        "http://127.0.0.1:\(port)"
    }

    var payloadURL: String {
        "\(installBaseURL)/\(installToken)/app.ipa"
    }

    var remoteManifestURL: String {
        let config = state.withLock { ($0.bundleId, $0.title, $0.bundleVersion, $0.port) }
        var comps = URLComponents(string: "https://api.palera.in/genPlist")!
        comps.queryItems = [
            URLQueryItem(name: "bundleid", value: config.0),
            URLQueryItem(name: "name", value: config.1),
            URLQueryItem(name: "version", value: config.2),
            URLQueryItem(name: "fetchurl", value: "http://127.0.0.1:\(config.3)/\(installToken)/app.ipa"),
        ]
        return comps.url?.absoluteString ?? "https://api.palera.in/genPlist"
    }

    var port: UInt16 {
        state.withLock { $0.port }
    }

    func start(ipa: URL, bundleId: String, bundleVersion: String, title: String) async throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
        }
        guard listen(fd, 8) == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getsockname(fd, withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &len) == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
        }
        let boundPort = UInt16(boundAddr.sin_port.bigEndian)

        state.withLock {
            $0.ipaURL = ipa
            $0.bundleId = bundleId
            $0.bundleVersion = bundleVersion.isEmpty ? "1.0" : bundleVersion
            $0.title = title.isEmpty ? "App" : title
            $0.didDeliverIPA = false
            $0.ipaProgress = LocalIPAProgress()
            $0.listenerFD = fd
            $0.port = boundPort
            $0.running = true
        }

        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "forgesign.installserver"
        t.start()

        return boundPort
    }

    func stop() {
        let fd = state.withLock { state -> Int32 in
            state.running = false
            let fd = state.listenerFD
            state.listenerFD = -1
            state.port = 0
            state.ipaURL = nil
            state.onIPADelivered = nil
            state.onIPAProgress = nil
            state.ipaProgress = LocalIPAProgress()
            state.didDeliverIPA = false
            return fd
        }
        if fd >= 0 { close(fd) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let shouldRun = state.withLock { $0.running && $0.listenerFD == fd }
            guard shouldRun else { break }

            var pollSet = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollSet, 1, 500)
            guard ready > 0, pollSet.revents & Int16(POLLIN) != 0 else { continue }

            let client = accept(fd, nil, nil)
            if client >= 0 {
                let flags = fcntl(client, F_GETFL, 0)
                guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
                    close(client)
                    continue
                }
                var noSignal: Int32 = 1
                var readTimeout = timeval(tv_sec: 15, tv_usec: 0)
                var writeTimeout = timeval(tv_sec: 30, tv_usec: 0)
                guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
                      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                      setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                    close(client)
                    continue
                }
                let slots = connectionSlots
                slots.wait()
                connectionQueue.async { [weak self] in
                    defer { slots.signal() }
                    guard let self else { close(client); return }
                    self.handleConnection(client)
                }
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        var buffer = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(15)
        while buffer.count < 64 * 1024, Date() < deadline {
            let n = recv(fd, &raw, raw.count, 0)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return }
            buffer.append(contentsOf: raw[0..<n])
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)),
              let request = String(data: buffer.subdata(in: 0..<headerRange.lowerBound), encoding: .utf8) else {
            return
        }

        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first,
              let route = LocalHTTPRoute.request(firstLine) else {
            sendResponse(fd, status: "400 Bad Request", contentType: "text/plain", body: Data("bad request".utf8), headOnly: false)
            return
        }
        let method = route.method
        let path = route.path
        guard method == "GET" || method == "HEAD" else {
            sendResponse(fd, status: "405 Method Not Allowed", contentType: "text/plain", body: Data("method not allowed".utf8), headOnly: false, extraHeaders: "Allow: GET, HEAD\r\n")
            return
        }
        let headOnly = method == "HEAD"
        let rangeHeader = lines.dropFirst().compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "range" else { return nil }
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }.first
        let range = LocalHTTPRange.parse(rangeHeader)

        switch path {
        case "/\(installToken)/app.ipa":
            guard let ipa = state.withLock({ $0.ipaURL }),
                  FileManager.default.fileExists(atPath: ipa.path) else {
                sendResponse(fd, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8), headOnly: false)
                return
            }
            sendFile(fd, url: ipa, headOnly: headOnly, range: range)
        case "/\(installToken)/install":
            sendResponse(fd, status: "200 OK", contentType: "text/html", body: Data(installPage().utf8), headOnly: headOnly)
        case "/health":
            sendResponse(fd, status: "200 OK", contentType: "text/plain", body: Data("ok".utf8), headOnly: headOnly)
        default:
            sendResponse(fd, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8), headOnly: false)
        }
    }

    var onIPADelivered: (@Sendable () -> Void)? {
        get { state.withLock { $0.onIPADelivered } }
        set {
            let alreadyDelivered = state.withLock { state -> Bool in
                state.onIPADelivered = newValue
                return state.didDeliverIPA
            }
            if alreadyDelivered { newValue?() }
        }
    }

    var onIPAProgress: (@Sendable (Double) -> Void)? {
        get { state.withLock { $0.onIPAProgress } }
        set { state.withLock { $0.onIPAProgress = newValue } }
    }

    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        var success = true
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let n = send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n < 0, errno == EINTR { continue }
                if n <= 0 {
                    success = false
                    return
                }
                sent += n
            }
        }
        return success
    }

    private func sendResponse(_ fd: Int32, status: String, contentType: String, body: Data, headOnly: Bool, extraHeaders: String = "") {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += extraHeaders
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        if !headOnly { response.append(body) }
        _ = sendAll(fd, response)
    }

    private func sendFile(_ fd: Int32, url: URL, headOnly: Bool, range: LocalHTTPRange) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            sendResponse(fd, status: "404 Not Found", contentType: "text/plain", body: Data(), headOnly: false)
            return
        }
        guard let fileSize = try? handle.seekToEnd() else {
            try? handle.close()
            sendResponse(fd, status: "500 Internal Server Error", contentType: "text/plain", body: Data(), headOnly: false)
            return
        }
        let resolved: (offset: UInt64, length: UInt64, headers: String, full: Bool)?
        switch range {
        case .absent, .invalid:
            resolved = (0, fileSize, "", true)
        case .bounded(let start, let requestedEnd) where requestedEnd < start:
            resolved = (0, fileSize, "", true)
        case .bounded(let start, let requestedEnd):
            guard fileSize > 0, start < fileSize else { resolved = nil; break }
            let end = min(requestedEnd, fileSize - 1)
            resolved = (start, end - start + 1, "Content-Range: bytes \(start)-\(end)/\(fileSize)\r\n", false)
        case .openEnded(let start):
            guard fileSize > 0, start < fileSize else { resolved = nil; break }
            resolved = (start, fileSize - start, "Content-Range: bytes \(start)-\(fileSize - 1)/\(fileSize)\r\n", false)
        case .suffix(let suffix):
            guard fileSize > 0 else { resolved = nil; break }
            let length = min(suffix, fileSize)
            let start = fileSize - length
            resolved = (start, length, "Content-Range: bytes \(start)-\(fileSize - 1)/\(fileSize)\r\n", false)
        }
        guard let resolved else {
            try? handle.close()
            sendResponse(fd, status: "416 Range Not Satisfiable", contentType: "text/plain", body: Data(), headOnly: true,
                         extraHeaders: "Content-Range: bytes */\(fileSize)\r\n")
            return
        }

        guard (try? handle.seek(toOffset: resolved.offset)) != nil else {
            try? handle.close()
            sendResponse(fd, status: "500 Internal Server Error", contentType: "text/plain", body: Data(), headOnly: false)
            return
        }
        let status = resolved.full ? "200 OK" : "206 Partial Content"
        var header = "HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(resolved.length)\r\n"
        header += resolved.headers + "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        guard sendAll(fd, Data(header.utf8)) else { try? handle.close(); return }
        if headOnly { try? handle.close(); return }

        var remaining = resolved.length
        while remaining > 0, state.withLock({ $0.running }) {
            guard let chunk = try? handle.read(upToCount: Int(min(UInt64(1024 * 1024), remaining))),
                  !chunk.isEmpty, UInt64(chunk.count) <= remaining, sendAll(fd, chunk) else { break }
            let offset = resolved.offset + (resolved.length - remaining)
            remaining -= UInt64(chunk.count)
            let callbacks = state.withLock { state -> ((@Sendable (Double) -> Void)?, (@Sendable () -> Void)?, Double) in
                guard state.running else { return (nil, nil, 0) }
                let fraction = state.ipaProgress.record(offset: offset, length: UInt64(chunk.count), total: fileSize)
                let completed = state.ipaProgress.isComplete(total: fileSize) && !state.didDeliverIPA
                if completed { state.didDeliverIPA = true }
                return (state.onIPAProgress, completed ? state.onIPADelivered : nil, fraction)
            }
            callbacks.0?(callbacks.2)
            callbacks.1?()
        }
        try? handle.close()
    }

    private func installPage() -> String {
        let itms = itmsServicesURL
        func html(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
             .replacingOccurrences(of: "\"", with: "&quot;")
             .replacingOccurrences(of: "'", with: "&#39;")
        }
        let safeTitle = html(state.withLock { $0.title })
        let safeItms = html(itms)
        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Installing \(safeTitle)</title>
        <style>body{font-family:-apple-system,sans-serif;color:#1c1c1e;margin:0;min-height:100vh;
        display:flex;justify-content:center;align-items:center;background:#f7f9fd;overflow:hidden}
        .bloom{position:fixed;border-radius:50%;filter:blur(70px);pointer-events:none;z-index:0}
        .b1{width:80vw;height:80vw;background:rgba(0,122,255,.14);top:-30vw;left:-25vw}
        .b2{width:65vw;height:65vw;background:rgba(107,199,184,.14);bottom:-20vw;right:-18vw}
        .card{position:relative;z-index:1;background:rgba(255,255,255,.55);
        backdrop-filter:blur(24px) saturate(1.5);-webkit-backdrop-filter:blur(24px) saturate(1.5);
        border:1px solid rgba(0,0,0,.08);border-radius:22px;padding:28px 24px;max-width:320px;
        text-align:center;box-shadow:0 18px 40px rgba(0,0,0,.12)}
        h1{font-size:18px;font-weight:600;margin:0 0 6px}
        p{font-size:14px;color:#6d6d72;margin:0}
        a{display:inline-block;margin-top:16px;padding:12px 28px;border-radius:14px;color:#fff;
        background:linear-gradient(135deg,#338fff 0%,#0066e6 100%);text-decoration:none;
        font-weight:600;font-size:15px;box-shadow:0 8px 16px rgba(0,122,255,.28)}
        @media (prefers-color-scheme:dark){
        body{background:#242830;color:#ededef}
        .b1{background:rgba(56,153,255,.18)}.b2{background:rgba(107,199,184,.13)}
        .card{background:rgba(255,255,255,.10);border-color:rgba(255,255,255,.15)}
        p{color:#b4b4ba}}
        </style>
        </head>
        <body><div class="bloom b1"></div><div class="bloom b2"></div><div class="card">
        <h1>Install \(safeTitle)</h1>
        <p>Tap Install, accept the iOS prompt, then return to ForgeSign to see whether the IPA was delivered.</p>
        <a id="install" href="\(safeItms)">Install</a>
        </div>
        </body></html>
        """
    }

    var itmsServicesURL: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = remoteManifestURL.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? remoteManifestURL
        return "itms-services://?action=download-manifest&url=\(encoded)"
    }
}
