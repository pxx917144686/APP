import Foundation
import Network
import WebKit

final class WasmSAPSigner: NSObject {

    static var progress: ((String) -> Void)?
    private static func report(_ message: String) {
        print("SAP Web: \(message)")
        progress?(message)
    }

    private static let wasmRemoteURL = URL(string:
        "https://github.com/dompling/Jsbox-Ipa/raw/refs/heads/main/sap-signer/sap.wasm")!

    private static var server: SAPLocalHTTPServer?
    private static var serverBase = ""
    private static var container: (webView: WKWebView, handler: SAPPageNavDelegate)?
    private static var pageLoadTask: Task<WKWebView, Error>?

    private let guid: String
    private let webView: WKWebView

    private init(guid: String, webView: WKWebView) {
        self.guid = guid
        self.webView = webView
    }

    static func signOnce(guid: String, body: Data) async throws -> Data {
        do {
            return try await signWithCurrentPage(guid: guid, body: body)
        } catch {
            teardownPage()
            report("签名失败（\(error.localizedDescription)），已重建签名环境并重试一次")
            return try await signWithCurrentPage(guid: guid, body: body)
        }
    }

    private static func signWithCurrentPage(guid: String, body: Data) async throws -> Data {
        _ = try await ensureWasmCached()
        try startLocalServerIfNeeded()

        let webView = try await ensurePageLoaded()
        report("页面就绪，开始签名")

        let optionsJSON = Self.jsonString([
            "proxyURL": "\(serverBase)/proxy",
            "wasmURL": "\(serverBase)/sap.wasm"
        ])
        let bodyB64 = body.base64EncodedString()

        guard let result = try await Self.callJS(
            "return await sapSignOnce(guid, options, bodyB64);",
            arguments: ["guid": guid, "options": optionsJSON, "bodyB64": bodyB64],
            on: webView, timeout: 240, label: "SAP 签名") as? String,
            !result.isEmpty,
            let signature = Data(base64Encoded: result) else {
            throw SAPSignerError.signFailed("SAP 引擎返回空签名")
        }
        report("签名完成")
        return signature
    }

    private static func teardownPage() {
        container = nil
        pageLoadTask = nil
    }

    static func openSession(guid: String) async throws -> WasmSAPSigner {
        do {
            return try await prepareOnCurrentPage(guid: guid)
        } catch {
            teardownPage()
            report("会话初始化失败（\(error.localizedDescription)），已重建签名环境并重试一次")
            return try await prepareOnCurrentPage(guid: guid)
        }
    }

    private static func prepareOnCurrentPage(guid: String) async throws -> WasmSAPSigner {
        _ = try await ensureWasmCached()
        try startLocalServerIfNeeded()

        let webView = try await ensurePageLoaded()

        let optionsJSON = Self.jsonString([
            "proxyURL": "\(serverBase)/proxy",
            "wasmURL": "\(serverBase)/sap.wasm"
        ])
        _ = try? await callJS("return await sapCloseAsync();", arguments: [:],
                              on: webView, timeout: 15, label: "SAP 清理")
        _ = try await callJS("return await sapInitAsync(guid, options);",
                             arguments: ["guid": guid, "options": optionsJSON],
                             on: webView, timeout: 180, label: "SAP 引擎初始化")
        report("签名会话已建立")
        return WasmSAPSigner(guid: guid, webView: webView)
    }

    private static func startLocalServerIfNeeded() throws {
        if server != nil { return }
        let wasmFile = Bundle.main.url(forResource: "sap", withExtension: "wasm") ?? wasmCacheURL
        let s = SAPLocalHTTPServer(wasmFileURL: wasmFile)
        try s.start()
        server = s
        serverBase = "http://127.0.0.1:\(s.port)"
        report("本地签名服务已启动 \(serverBase)")
    }

    func sign(_ data: Data) async throws -> Data {
        let b64 = data.base64EncodedString()
        guard let result = try await Self.callJS("return await sapSignAsync(bodyB64);",
                                                 arguments: ["bodyB64": b64],
                                                 on: webView, timeout: 90, label: "SAP 签名") as? String,
              !result.isEmpty,
              let signature = Data(base64Encoded: result) else {
            throw SAPSignerError.signFailed("SAP 引擎返回空签名")
        }
        return signature
    }

    func close() async {
        _ = try? await Self.callJS("return await sapCloseAsync();", arguments: [:],
                                   on: webView, timeout: 30, label: "SAP 关闭")
    }

    private static var wasmCacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SAPWeb", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sap.wasm")
    }

    private static func ensureWasmCached() async throws -> URL {
        if let bundled = Bundle.main.url(forResource: "sap", withExtension: "wasm") {
            report("使用内置签名引擎")
            return bundled
        }
        let target = wasmCacheURL
        if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int,
           size > 1_000_000 {
            return target
        }
        report("开始下载签名引擎（约 45MB，仅首次）…")
        var request = URLRequest(url: wasmRemoteURL)
        request.timeoutInterval = 600
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count > 1_000_000 else {
            throw SAPSignerError.signFailed("签名引擎下载失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        try data.write(to: target, options: .atomic)
        report("签名引擎下载完成 \(data.count / 1_000_000)MB")
        return target
    }

    private static func ensurePageLoaded() async throws -> WKWebView {
        if let container { return container.webView }
        if let pageLoadTask { return try await pageLoadTask.value }

        let task = Task<WKWebView, Error> { try await buildPage() }
        pageLoadTask = task
        do {
            let webView = try await task.value
            return webView
        } catch {
            pageLoadTask = nil
            throw error
        }
    }

    private static func buildPage() async throws -> WKWebView {
        let handler = SAPPageNavDelegate()
        let config = WKWebViewConfiguration()

        let consoleScript = WKUserScript(source: """
        ["log","info","warn","error"].forEach(function(level){
          var original = console[level];
          console[level] = function(message){
            try { window.webkit.messageHandlers.sapConsole.postMessage("[" + level + "] " + message); } catch (_e) {}
            try { original.call(console, message); } catch (_e) {}
          };
        });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(consoleScript)
        config.userContentController.add(handler, name: "sapConsole")

        let webView = await MainActor.run {
            let wv = WKWebView(frame: .zero, configuration: config)
            wv.isHidden = true
            wv.navigationDelegate = handler
            return wv
        }
        container = (webView, handler)

        guard let pageURL = URL(string: "\(serverBase)/index.html") else {
            throw SAPSignerError.signFailed("签名页面地址无效")
        }

        let loaded: Void = try await withTimeout(seconds: 60, label: "签名页面加载") {
            try await loadPageAndWait(webView: webView, pageURL: pageURL, handler: handler)
        }
        _ = loaded
        return webView
    }

    private static func loadPageAndWait(webView: WKWebView, pageURL: URL,
                                        handler: SAPPageNavDelegate) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            handler.onPageLoaded = { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
            Task { @MainActor in
                webView.load(URLRequest(url: pageURL))
            }
        }
    }

    fileprivate static func callJS(_ body: String, arguments: [String: Any], on webView: WKWebView,
                                   timeout: TimeInterval, label: String) async throws -> Any? {
        try await withTimeout(seconds: timeout, label: label) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
                DispatchQueue.main.async {
                    webView.callAsyncJavaScript(body, arguments: arguments, in: nil,
                                                in: .page, completionHandler: { result in
                        switch result {
                        case .success(let value):
                            cont.resume(returning: value)
                        case .failure(let error):
                            let info = (error as NSError).userInfo
                                .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " | ")
                            let message = info.isEmpty ? error.localizedDescription : info
                            cont.resume(throwing: SAPSignerError.signFailed("\(label)失败: \(message)"))
                        }
                    })
                }
            }
        }
    }

    private static func withTimeout<T>(seconds: TimeInterval, label: String,
                                       _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SAPSignerError.signFailed("\(label)超时（\(Int(seconds))s）")
            }
            guard let first = try await group.next() else {
                throw SAPSignerError.signFailed("\(label)无结果")
            }
            group.cancelAll()
            return first
        }
    }

    fileprivate static func jsonString(_ value: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

final class SAPPageNavDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var onPageLoaded: ((Error?) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("SAP Web [nav]: 页面加载完成")
        onPageLoaded?(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("SAP Web [nav]: 失败 \(error.localizedDescription)")
        onPageLoaded?(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("SAP Web [nav]: provisional 失败 \(error.localizedDescription)")
        onPageLoaded?(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("SAP Web [nav]: WebContent 进程被终止（通常为内存不足）")
        onPageLoaded?(SAPSignerError.signFailed("WebContent 进程被终止"))
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        print("SAP Web [js]: \(message.body)")
    }
}

final class SAPLocalHTTPServer {
    private let queue = DispatchQueue(label: "sapweb.http")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let wasmFileURL: URL

    init(wasmFileURL: URL) {
        self.wasmFileURL = wasmFileURL
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        let listener = try NWListener(using: params)
        var announced = false
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !announced else { return }
            if case .ready = state {
                announced = true
                self.port = self.listener?.port?.rawValue ?? 0
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: queue)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                if !announced {
                    announced = true
                    self?.port = listener?.port?.rawValue ?? 0
                    ready.signal()
                }
            case .failed(let error):
                if !announced {
                    announced = true
                    ready.signal()
                    print("SAP Web: 本地服务启动失败 \(error)")
                }
            default:
                break
            }
        }
        ready.wait()
        guard port != 0 else {
            throw SAPSignerError.signFailed("本地签名服务启动失败")
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                let headerText = String(decoding: headerData, as: UTF8.self)
                let contentLength = Self.headerValue(headerText, "Content-Length").flatMap(Int.init) ?? 0
                let bodyStart = headerEnd.upperBound
                let bodyLength = buffer.count - bodyStart
                if bodyLength >= contentLength {
                    let body = buffer.subdata(in: bodyStart..<bodyStart + contentLength)
                    self.respond(connection, headerText: headerText, body: body)
                    return
                }
            }
            if error == nil && !isComplete {
                self.receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, headerText: String, body: Data) {
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : "GET"
        let rawTarget = parts.count > 1 ? parts[1] : "/"

        let target = URLComponents(string: rawTarget.isEmpty ? "/" : rawTarget)
        let path = target?.path.isEmpty == false ? target!.path : "/"
        let queryItems = target?.queryItems ?? []

        let response: (status: Int, type: String, data: Data)
        switch path {
        case "/proxy":
            let upstreamString = queryItems.first(where: { $0.name == "url" })?.value ?? ""
            response = Self.blockingProxy(upstreamString: upstreamString,
                                          method: method,
                                          contentType: Self.headerValue(headerText, "Content-Type") ?? "",
                                          body: body)
        case "/sap.wasm":
            response = (200, "application/wasm", (try? Data(contentsOf: wasmFileURL)) ?? Data())
        case "/sap-signer.js":
            response = (200, "text/javascript", bundled("sap-signer.js"))
        case "/unicorn_x86.js":
            response = (200, "text/javascript", bundled("unicorn_x86.js"))
        case "/wasm_exec.js":
            response = (200, "text/javascript", bundled("wasm_exec.js"))
        default:
            response = (200, "text/html", bundled("index.html"))
        }

        var head = "HTTP/1.1 \(response.status) \(Self.statusText(response.status))\r\n"
        head += "Content-Type: \(response.type)\r\n"
        head += "Content-Length: \(response.data.count)\r\n"
        head += "Cache-Control: no-store, no-cache, must-revalidate\r\n"
        head += "Pragma: no-cache\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(response.data)

        connection.send(content: payload, completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
    }

    private func bundled(_ name: String) -> Data {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext) else { return Data() }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    private static func headerValue(_ headerText: String, _ name: String) -> String? {
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            let kv = line.components(separatedBy: ": ")
            if kv.count == 2, kv[0].caseInsensitiveCompare(name) == .orderedSame {
                return kv[1]
            }
        }
        return nil
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        default: return "Error"
        }
    }

    private static func blockingProxy(upstreamString: String, method: String,
                                      contentType: String, body: Data) -> (status: Int, type: String, data: Data) {
        guard let upstream = URL(string: upstreamString),
              upstream.scheme == "https",
              let host = upstream.host?.lowercased(),
              host == "apple.com" || host.hasSuffix(".apple.com") ||
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com") else {
            return (403, "text/plain", Data("host not allowed".utf8))
        }

        var request = URLRequest(url: upstream)
        request.httpMethod = method
        if !contentType.isEmpty {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6",
                         forHTTPHeaderField: "User-Agent")
        if method != "GET" && !body.isEmpty {
            request.httpBody = body
        }
        request.timeoutInterval = 60

        var lastResult: (status: Int, data: Data) = (502, Data("proxy error".utf8))
        for attempt in 1...3 {
            let semaphore = DispatchSemaphore(value: 0)
            var result: (status: Int, data: Data) = (502, Data("proxy error".utf8))
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    result = (502, Data("proxy: \(error.localizedDescription)".utf8))
                } else {
                    result = ((response as? HTTPURLResponse)?.statusCode ?? 502, data ?? Data())
                }
                semaphore.signal()
            }.resume()
            semaphore.wait()
            lastResult = result
            let timedOut = result.status == 502 && (result.data.count == 0 ||
                String(decoding: result.data, as: UTF8.self).contains("timed out") ||
                String(decoding: result.data, as: UTF8.self).contains("超时"))
            let serverError = result.status >= 500
            if !(timedOut || serverError) || attempt == 3 {
                break
            }
            Thread.sleep(forTimeInterval: attempt == 1 ? 1.0 : 2.5)
        }
        return (lastResult.status, "application/octet-stream", lastResult.data)
    }
}

