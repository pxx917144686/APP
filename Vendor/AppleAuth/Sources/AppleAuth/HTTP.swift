import Foundation

private final class NetworkTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    private var task: URLSessionTask?
    func start(_ task: URLSessionTask) {
        lock.lock(); self.task = task; let value = canceled; lock.unlock()
        if value { task.cancel() }
        task.resume()
    }
    func cancel() {
        lock.lock(); canceled = true; let task = task; lock.unlock()
        task?.cancel()
    }
}

internal final class SystemHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let continuation: CheckedContinuation<HTTPResponse, Error>
        var response: HTTPURLResponse?
        var body = Data()
        init(_ continuation: CheckedContinuation<HTTPResponse, Error>) { self.continuation = continuation }
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private let maximumBytes = 16 * 1024 * 1024
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 90
    }
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

    func close() { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard request.url?.scheme == "https" else { throw AppleAuthError("Only HTTPS is supported") }
        let ticket = NetworkTicket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock(); pending[task.taskIdentifier] = Pending(continuation); lock.unlock()
                ticket.start(task)
            }
        } onCancel: { ticket.cancel() }
    }

    private func finish(_ task: URLSessionTask, _ result: Result<HTTPResponse, Error>) {
        lock.lock(); let value = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        value?.continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= Int64(maximumBytes) else {
            finish(dataTask, .failure(AppleAuthError("Invalid or oversized HTTP response")))
            completionHandler(.cancel)
            return
        }
        lock.lock(); pending[dataTask.taskIdentifier]?.response = response; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let value = pending[dataTask.taskIdentifier]
        let oversized = (value?.body.count ?? 0) + data.count > maximumBytes
        if !oversized { value?.body.append(data) }
        lock.unlock()
        if oversized {
            finish(dataTask, .failure(AppleAuthError("HTTP response exceeds 16 MiB")))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(task, .failure(error)); return }
        lock.lock(); let value = pending[task.taskIdentifier]; lock.unlock()
        guard let value, let response = value.response else {
            finish(task, .failure(AppleAuthError("Missing HTTP response")))
            return
        }
        var headers: [HTTPHeader] = []
        var size = 0
        for (key, field) in response.allHeaderFields {
            let name = String(describing: key), text = String(describing: field)
            size += name.utf8.count + text.utf8.count
            if size > 64 * 1024 {
                finish(task, .failure(AppleAuthError("HTTP headers exceed 64 KiB")))
                return
            }
            if name.lowercased() == "set-cookie" {
                let separator = try! NSRegularExpression(pattern: #",(?=\s*[^;,=\s]+\s*=)"#)
                let separated = separator.stringByReplacingMatches(in: text,
                    range: NSRange(text.startIndex..., in: text), withTemplate: "\n")
                headers += separated.split(separator: "\n").map { HTTPHeader(name, $0.trimmingCharacters(in: .whitespaces)) }
            } else { headers.append(HTTPHeader(name, text)) }
        }
        finish(task, .success(HTTPResponse(status: response.statusCode, body: value.body, headers: headers)))
    }
}
