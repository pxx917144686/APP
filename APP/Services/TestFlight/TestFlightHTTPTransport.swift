import Foundation
import AppleAuth

enum TestFlightHTTPError: LocalizedError {
    case invalidURL
    case invalidResponse
    case oversizedResponse
    case invalidAccount
    case missingProof
    case missingCookies

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Only HTTPS is supported"
        case .invalidResponse: return "Invalid HTTP response"
        case .oversizedResponse: return "HTTP response exceeds 16 MiB"
        case .invalidAccount: return "Saved Apple ID account is invalid"
        case .missingProof: return "SAP device proof is unavailable"
        case .missingCookies: return "Saved Apple ID cookies are missing"
        }
    }
}

final class TestFlightHTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let continuation: CheckedContinuation<HTTPResponse, Error>
        var response: HTTPURLResponse?
        var body = Data()
        init(_ continuation: CheckedContinuation<HTTPResponse, Error>) {
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var pending: [ObjectIdentifier: Pending] = [:]
    private let maximumBytes = 16 * 1024 * 1024
    private let configuration = URLSessionConfiguration.ephemeral
    private let directConfiguration = URLSessionConfiguration.ephemeral
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    private lazy var directSession = URLSession(configuration: directConfiguration, delegate: self, delegateQueue: nil)
    private let logLock = NSLock()

    override init() {
        super.init()
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 90
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        directConfiguration.urlCache = nil
        directConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        directConfiguration.timeoutIntervalForRequest = 90
        directConfiguration.timeoutIntervalForResource = 90
        directConfiguration.httpShouldSetCookies = true
        directConfiguration.httpCookieAcceptPolicy = .always
        directConfiguration.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0
        ]
    }

    var transport: HTTPTransport {
        { [weak self] request in
            guard let self else { throw CancellationError() }
            return try await self.send(request)
        }
    }

    var diagnosticsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TestFlight", isDirectory: true)
            .appendingPathComponent("diagnostics.log")
    }

    func logStage(_ text: String) {
        append("=== \(timestamp()) \(text) ===")
    }

    func execute(_ request: URLRequest) async throws -> HTTPResponse {
        try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            attempt += 1
            let activeSession = attempt == 1 ? session : directSession
            do {
                let response = try await perform(request, session: activeSession)
                if response.status == 503 && attempt < 3 {
                    append("!!! 503 retry \(attempt) -> direct session: \(request.url?.absoluteString ?? "")")
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                    continue
                }
                return response
            } catch {
                guard attempt < 3, Self.isTransient(error), !Task.isCancelled else { throw error }
                append("!!! transient error retry \(attempt) -> direct session: \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        }
    }

    private func perform(_ request: URLRequest, session: URLSession) async throws -> HTTPResponse {
        guard let url = request.url, url.scheme == "https" else {
            throw TestFlightHTTPError.invalidURL
        }

        let started = Date()
        append("")
        append(">>> \(request.httpMethod ?? "GET") \(url.absoluteString)")
        append(">>> headers: \(safeHeaders(request.allHTTPHeaderFields ?? [:]))")
        if let body = request.httpBody {
            append(">>> body: \(body.count) bytes")
        }

        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                pending[ObjectIdentifier(task)] = Pending(continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            session.getAllTasks { tasks in
                tasks.forEach { $0.cancel() }
            }
        }

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        append("<<< \(response.status) \(url.absoluteString) \(elapsed)ms")
        append("<<< headers: " + response.headers.map { header in
            safeHeader(header.name, header.value)
        }.joined(separator: "; "))
        if response.status >= 400 {
            let text = String(decoding: response.body.prefix(1024), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            append("<<< body: \(text)")
        }

        return response
    }

    private static func isTransient(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorSecureConnectionFailed
        ].contains(ns.code)
    }

    private func finish(_ task: URLSessionTask, _ result: Result<HTTPResponse, Error>) {
        lock.lock()
        let value = pending.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
        value?.continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= Int64(maximumBytes) else {
            finish(dataTask, .failure(TestFlightHTTPError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        pending[ObjectIdentifier(dataTask)]?.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let value = pending[ObjectIdentifier(dataTask)]
        let oversized = (value?.body.count ?? 0) + data.count > maximumBytes
        if !oversized {
            value?.body.append(data)
        }
        lock.unlock()
        if oversized {
            finish(dataTask, .failure(TestFlightHTTPError.oversizedResponse))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(task, .failure(error))
            return
        }
        lock.lock()
        let value = pending[ObjectIdentifier(task)]
        lock.unlock()
        guard let value, let response = value.response else {
            finish(task, .failure(TestFlightHTTPError.invalidResponse))
            return
        }
        let headers = response.allHeaderFields.map { key, value in
            HTTPHeader(String(describing: key), String(describing: value))
        }
        finish(task, .success(HTTPResponse(status: response.statusCode, body: value.body, headers: headers)))
    }

    private func safeHeaders(_ headers: [String: String]) -> String {
        headers.sorted { $0.key < $1.key }
            .map { safeHeader($0.key, $0.value) }
            .joined(separator: "; ")
    }

    private func safeHeader(_ name: String, _ value: String) -> String {
        let secretKeys = ["cookie", "authorization", "token", "password", "x-apple-i-md", "x-apple-i-srl", "x-apple-identity", "x-apple-amd-m"]
        let lower = name.lowercased()
        if secretKeys.contains(where: { lower.contains($0) }) {
            return "\(name)=<redacted>"
        }
        return "\(name)=\(value)"
    }

    private func append(_ line: String) {
        logLock.lock()
        defer { logLock.unlock() }
        let fileManager = FileManager.default
        let directory = diagnosticsURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: diagnosticsURL.path) {
            fileManager.createFile(atPath: diagnosticsURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: diagnosticsURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
