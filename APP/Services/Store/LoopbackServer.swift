import Foundation
import Network
import Security

struct HTTPByteRange: Equatable {
    let start: UInt64
    let end: UInt64
    var count: UInt64 { end - start + 1 }
    static func parse(_ header: String, size: UInt64) throws -> HTTPByteRange {
        guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else { throw ToolError.message("loop_err_invalid_range".localized) }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ToolError.message("loop_err_invalid_range".localized) }
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { throw ToolError.message("loop_err_invalid_range".localized) }
            return HTTPByteRange(start: size - min(size, suffix), end: size - 1)
        }
        guard let start = UInt64(parts[0]), start < size,
              parts[1].isEmpty || UInt64(parts[1]) != nil else { throw ToolError.message("loop_err_range_out_of_bounds".localized) }
        let end = parts[1].isEmpty ? size - 1 : min(UInt64(parts[1])!, size - 1)
        guard end >= start else { throw ToolError.message("loop_err_range_out_of_bounds".localized) }
        return HTTPByteRange(start: start, end: end)
    }
}

final class InstallLog: @unchecked Sendable {
    static let shared = InstallLog()
    static let insideLiveContainer = ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil
    private let lock = NSLock()
    private var lines: [String] = []
    private(set) var manifestServed = 0
    func add(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        lock.lock(); lines.append(stamp + " " + line)
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
        lock.unlock()
    }
    func servedManifest() { lock.lock(); manifestServed += 1; progress.readManifest = true; lock.unlock() }
    var manifestCount: Int { lock.lock(); defer { lock.unlock() }; return manifestServed }
    struct Progress: Equatable {
        var readManifest = false
        var sent: UInt64 = 0
        var total: UInt64 = 0
        var started: Bool { total > 0 }
        var finished: Bool { total > 0 && sent >= total }
        var fraction: Double { total > 0 ? min(1, Double(sent) / Double(total)) : 0 }
    }
    private var progress = Progress()
    var currentProgress: Progress { lock.lock(); defer { lock.unlock() }; return progress }
    func beginInstallation() { lock.lock(); progress = Progress(); lock.unlock() }
    func packageRequested(size: UInt64, from start: UInt64 = 0) {
        lock.lock(); progress.total = size; progress.sent = start == 0 ? 0 : max(progress.sent, start); lock.unlock()
    }
    func packageSent(_ count: Int) { lock.lock(); progress.sent += UInt64(count); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "iPadn.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var starters: [CheckedContinuation<Void, Error>] = []
    private var registeredFiles: [String: URL] = [:]
    private var registeredData: [String: (Data, String)] = [:]
    private var compatibilityFiles: [String: URL] = [:]
    private let identity: SecIdentity?
    private let chain: [SecCertificate]
    private let publicHost: String
    private let port: UInt16?
    private let compatibilityMode: Bool
    private let token = UUID().uuidString
    private var readyURL: URL?
    private var lastActivity: [ObjectIdentifier: DispatchTime] = [:]
    private let idleTimeout: UInt64 = 120
    var baseURL: URL? {
        lock.lock(); defer { lock.unlock() }; return readyURL
    }
    private let upstreams: Set<String> = [
        "https://s.mzstatic.com/sap/setupCert.plist",
        "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy",
        "https://auth.itunes.apple.com/auth/v1/otp/1.5/finish"
    ]

    init(port: UInt16? = nil, compatibilityMode: Bool = false, identity: SecIdentity? = nil,
         certificates: [SecCertificate] = [], publicHost: String = "127.0.0.1") {
        self.port = port; self.compatibilityMode = compatibilityMode
        self.identity = identity; self.chain = certificates; self.publicHost = publicHost
    }

    func start() async throws {
        if let url = baseURL, let port = url.port.flatMap({ UInt16(exactly: $0) }) {
            if await Self.isListening(port: port) { return }
            InstallLog.shared.add((identity == nil ? "http" : "https") + " server unreachable, restarting")
            await reset()
            do { try await startListener() }
            catch {
                guard self.port != nil else { throw error }
                try await Task.sleep(nanoseconds: 500_000_000)
                try await startListener()
            }
            return
        }
        try await startListener()
    }

    func reset() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                let old = self.listener
                self.listener = nil
                self.lock.lock(); self.readyURL = nil; self.lock.unlock()
                old?.newConnectionHandler = nil
                old?.cancel()
                continuation.resume()
            }
        }
    }

    static func isListening(port: UInt16, timeout: TimeInterval = 1.5) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        final class Probe: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Bool, Never>?
            let connection: NWConnection
            init(_ connection: NWConnection, _ continuation: CheckedContinuation<Bool, Never>) {
                self.connection = connection; self.continuation = continuation
            }
            func finish(_ value: Bool) {
                lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
                guard let pending else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                pending.resume(returning: value)
            }
        }
        let probeQueue = DispatchQueue(label: "iPadn.loopback.probe")
        return await withCheckedContinuation { continuation in
            let probe = Probe(NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp), continuation)
            probe.connection.stateUpdateHandler = { state in
                switch state {
                case .ready: probe.finish(true)
                case .failed, .waiting, .cancelled: probe.finish(false)
                default: break
                }
            }
            probe.connection.start(queue: probeQueue)
            probeQueue.asyncAfter(deadline: .now() + timeout) { probe.finish(false) }
        }
    }

    private func startListener() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if self.baseURL != nil { continuation.resume(); return }
                self.starters.append(continuation)
                guard self.listener == nil else { return }
                do {
                    let parameters: NWParameters
                    if let identity = self.identity {
                        let created = self.chain.count > 1
                            ? sec_identity_create_with_certificates(identity, self.chain as CFArray)
                            : sec_identity_create(identity)
                        guard let localIdentity = created else { throw ToolError.message("loop_err_certificate".localized) }
                        let tls = NWProtocolTLS.Options()
                        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
                        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
                        parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
                    } else { parameters = .tcp }
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: self.port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
                    if self.port != nil { parameters.allowLocalEndpointReuse = true }
                    let listener = try NWListener(using: parameters, on: .any)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self, let listener, self.listener === listener else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port else { return }
                            self.lock.lock()
                            var address = URLComponents()
                            address.scheme = self.identity == nil ? "http" : "https"
                            address.host = self.publicHost; address.port = Int(port.rawValue)
                            address.path = "/\(self.token)/"
                            self.readyURL = address.url
                            self.lock.unlock()
                            self.finishStart(.success(()))
                        case .failed(let error):
                            InstallLog.shared.add((self.identity == nil ? "http" : "https") + " server stopped: \(error)")
                            self.lock.lock(); self.readyURL = nil; self.lock.unlock()
                            self.listener = nil
                            self.finishStart(.failure(error))
                            listener.cancel()
                        case .cancelled:
                            InstallLog.shared.add((self.identity == nil ? "http" : "https") + " server closed")
                            self.lock.lock(); self.readyURL = nil; self.lock.unlock()
                            self.listener = nil
                            self.finishStart(.failure(ToolError.message("loop_err_install_interrupted".localized)))
                        case .waiting(let error):
                            self.lock.lock(); self.readyURL = nil; self.lock.unlock()
                            self.listener = nil
                            self.finishStart(.failure(error))
                            listener.cancel()
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }
                        let id = ObjectIdentifier(connection)
                        let secure = self.identity != nil
                        let kind = secure ? "https" : "http"
                        if secure { InstallLog.shared.add("https connection accepted") }
                        connection.stateUpdateHandler = { [weak self] state in
                            switch state {
                            case .ready: if secure { InstallLog.shared.add("https connection ready (TLS done)") }
                            case .waiting(let error): InstallLog.shared.add(kind + " connection waiting: \(error)")
                            case .failed(let error):
                                InstallLog.shared.add(kind + " connection failed: \(error)")
                                self?.lastActivity.removeValue(forKey: id)
                            case .cancelled: self?.lastActivity.removeValue(forKey: id)
                            default: break
                            }
                        }
                        connection.start(queue: self.queue)
                        self.touch(connection)
                        self.read(connection, accumulated: Data())
                        self.watchIdle(connection)
                    }
                    listener.start(queue: self.queue)
                } catch { self.listener = nil; self.finishStart(.failure(error)) }
            }
        }
    }
    private func touch(_ connection: NWConnection) {
        lastActivity[ObjectIdentifier(connection)] = .now()
    }
    private func watchIdle(_ connection: NWConnection) {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let last = self.lastActivity[ObjectIdentifier(connection)] else { return }
            if DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds >= self.idleTimeout * 1_000_000_000 {
                self.lastActivity.removeValue(forKey: ObjectIdentifier(connection))
                connection.cancel()
            } else { self.watchIdle(connection) }
        }
    }
    private func finishStart(_ result: Result<Void, Error>) {
        let pending = starters; starters.removeAll()
        for continuation in pending { continuation.resume(with: result) }
    }
    deinit { listener?.cancel() }

    func register(_ url: URL) throws -> URL {
        guard let baseURL = baseURL, url.isFileURL else { throw ToolError.message("loop_err_service_not_ready".localized) }
        let key = UUID().uuidString
        lock.lock(); registeredFiles[key] = url
        if compatibilityMode { compatibilityFiles[url.lastPathComponent] = url }
        lock.unlock()
        return baseURL.appendingPathComponent("files").appendingPathComponent(key).appendingPathComponent(url.lastPathComponent)
    }

    func register(data: Data, contentType: String) throws -> URL {
        guard let baseURL else { throw ToolError.message("loop_err_service_not_ready".localized) }
        let key = UUID().uuidString
        lock.lock(); registeredData[key] = (data, contentType); lock.unlock()
        return baseURL.appendingPathComponent("data").appendingPathComponent(key)
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, ended, error in
            if let error {
                InstallLog.shared.add((self.identity == nil ? "http" : "https") + " receive error: \(error)")
                connection.cancel(); return
            }
            self.touch(connection)
            var buffer = accumulated; if let data = data { buffer.append(data) }
            guard buffer.count <= 2 * 1024 * 1024 else { self.reply(connection, status: 413); return }
            let separator = Data("\r\n\r\n".utf8)
            if let boundary = buffer.range(of: separator),
               let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                let first = (lines.first ?? "").split(separator: " ")
                guard first.count == 3 else { self.reply(connection, status: 400); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
                guard headers["transfer-encoding"] == nil else { self.reply(connection, status: 400); return }
                let contentLength = Int(headers["content-length"] ?? "0") ?? -1
                guard contentLength >= 0, contentLength <= 1024 * 1024 else { self.reply(connection, status: 413); return }
                let start = boundary.upperBound
                if buffer.count - start >= contentLength {
                    self.route(connection, method: String(first[0]), target: String(first[1]),
                               headers: headers, body: Data(buffer[start..<(start + contentLength)]))
                    return
                }
            }
            if ended { connection.cancel() } else { self.read(connection, accumulated: buffer) }
        }
    }

    static func runtimeResource(_ name: String) -> URL? {
        if let dir = Bundle.main.url(forResource: "SAPRuntime", withExtension: nil) {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let ns = name as NSString
        return Bundle.main.url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension)
    }

    private func route(_ connection: NWConnection, method: String, target: String, headers: [String: String], body: Data) {
        guard let components = URLComponents(string: "http://localhost" + target) else { reply(connection, status: 400); return }
        if compatibilityMode, ["GET", "HEAD"].contains(method), components.path.split(separator: "/").count == 1 {
            let name = String(components.path.dropFirst())
            lock.lock(); let file = compatibilityFiles[name]; lock.unlock()
            if let file = file {
                sendFile(connection, url: file, range: headers["range"], head: method == "HEAD", package: true); return
            }
        }
        guard components.path.hasPrefix("/\(token)/") else { InstallLog.shared.add("\(method) unknown path: 404"); reply(connection, status: 404); return }
        let path = String(components.path.dropFirst(token.count + 2))
        if method == "OPTIONS" { reply(connection, status: 204); return }
        if path == "proxy" {
            let isFinish = components.queryItems?.first(where: { $0.name == "url" })?.value?.hasSuffix("/finish") == true
            guard let address = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  upstreams.contains(address), let url = URL(string: address),
                  (method == "GET" && address.hasSuffix("setupCert.plist")) ||
                  (method == "POST" && (address.hasSuffix("/legacy") || isFinish)) else { reply(connection, status: 403); return }
            Task {
                do {
                    let proxyHeaders = isFinish
                        ? ["Content-Type": "application/x-apple-plist", "Accept": "*/*"]
                        : ["Content-Type": "application/x-plist"]
                    let (rawData, response) = try await HTTPClient.shared.request(
                        url, method: method,
                        body: method == "POST" ? body : nil,
                        headers: proxyHeaders,
                        allowRedirects: !isFinish
                    )
                    var outData = rawData
                    var outType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                    if isFinish,
                       let dict = try? ApplePropertyList.dictionary(rawData),
                       let xmlData = try? HTTPClient.encodePlist(dict) {
                        outData = xmlData
                        outType = "application/x-apple-plist"
                    }
                    self.reply(connection, status: response.statusCode, body: outData, contentType: outType)
                } catch let statusError as HTTPStatusError {
                    self.reply(connection, status: statusError.code, body: Data("loop_err_upstream_status".localized.utf8))
                } catch {
                    self.reply(connection, status: 502, body: Data("loop_err_sign_upstream".localized.utf8))
                }
            }
            return
        }
        guard method == "GET" || method == "HEAD" else { reply(connection, status: 405); return }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "data" {
            lock.lock(); let resource = registeredData[parts[1]]; lock.unlock()
            guard let resource else { InstallLog.shared.add("\(method) data: 404"); reply(connection, status: 404); return }
            InstallLog.shared.add("\(method) data (\(resource.1)): 200")
            if resource.1 == "application/xml" { InstallLog.shared.servedManifest() }
            let header = responseHeader(status: 200, length: UInt64(resource.0.count), contentType: resource.1, extra: [:])
            var response = header
            if method != "HEAD" { response.append(resource.0) }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        } else if parts.count == 2, parts[0] == "runtime", !parts[1].contains(".."),
           ["index.html", "sap-signer.js", "wasm_exec.js", "unicorn_x86.js", "sap.wasm", "libCoreADI.so", "libstoreservicescore.so"].contains(parts[1]),
           let file = Self.runtimeResource(parts[1]) {
            sendFile(connection, url: file, range: headers["range"], head: method == "HEAD")
        } else if parts.count == 3, parts[0] == "files" {
            lock.lock(); let file = registeredFiles[parts[1]]; lock.unlock()
            guard let file = file, file.lastPathComponent == parts[2] else { InstallLog.shared.add("\(method) package: 404"); reply(connection, status: 404); return }
            InstallLog.shared.add("\(method) package" + (headers["range"] == nil ? "" : " (range)"))
            sendFile(connection, url: file, range: headers["range"], head: method == "HEAD", package: true)
        } else { reply(connection, status: 404) }
    }

    private func sendFile(_ connection: NWConnection, url: URL, range: String?, head: Bool, package: Bool = false) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let selected: HTTPByteRange?
            do { selected = try range.map { try HTTPByteRange.parse($0, size: size) } }
            catch { reply(connection, status: 416, extra: ["Content-Range": "bytes */\(size)"]); return }
            let length = selected?.count ?? size
            var extra = ["Accept-Ranges": "bytes"]
            if let selected = selected { extra["Content-Range"] = "bytes \(selected.start)-\(selected.end)/\(size)" }
            let mime = ["html": "text/html; charset=utf-8", "js": "text/javascript", "wasm": "application/wasm", "ipa": "application/octet-stream", "plist": "application/xml", "png": "image/png"][url.pathExtension] ?? "application/octet-stream"
            let header = responseHeader(status: selected == nil ? 200 : 206, length: length, contentType: mime, extra: extra)
            let file = try FileHandle(forReadingFrom: url)
            try file.seek(toOffset: selected?.start ?? 0)
            if package && !head { InstallLog.shared.packageRequested(size: size, from: selected?.start ?? 0) }
            connection.send(content: header, completion: .contentProcessed { error in
                if error != nil || head { try? file.close(); connection.cancel(); return }
                self.sendChunk(connection, file: file, remaining: length, package: package)
            })
        } catch { reply(connection, status: 404) }
    }
    private func sendChunk(_ connection: NWConnection, file: FileHandle, remaining: UInt64, package: Bool) {
        guard remaining > 0 else { try? file.close(); connection.cancel(); return }
        do {
            let chunk = try file.read(upToCount: Int(min(remaining, 262_144))) ?? Data()
            guard !chunk.isEmpty else { try? file.close(); connection.cancel(); return }
            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil { try? file.close(); connection.cancel() }
                else {
                    self.touch(connection)
                    if package { InstallLog.shared.packageSent(chunk.count) }
                    self.sendChunk(connection, file: file, remaining: remaining - UInt64(chunk.count), package: package)
                }
            })
        } catch { try? file.close(); connection.cancel() }
    }
    private func responseHeader(status: Int, length: UInt64, contentType: String, extra: [String: String]) -> Data {
        let phrases = [200: "OK", 204: "No Content", 206: "Partial Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 416: "Range Not Satisfiable", 502: "Bad Gateway"]
        var header = "HTTP/1.1 \(status) \(phrases[status] ?? "Error")\r\nContent-Length: \(length)\r\nContent-Type: \(contentType)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        extra.forEach { header += "\($0.key): \($0.value)\r\n" }
        header += "\r\n"
        return Data(header.utf8)
    }
    private func reply(_ connection: NWConnection, status: Int, body: Data = Data(), contentType: String = "text/plain; charset=utf-8", extra: [String: String] = [:]) {
        var data = responseHeader(status: status, length: UInt64(body.count), contentType: contentType, extra: extra)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
