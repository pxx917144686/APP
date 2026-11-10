import Foundation

final class HTTPClient: Sendable {
    static let shared = HTTPClient()
    static let userAgent = "Configurator/2.21 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    private let session: URLSession

    init(protocolClasses: [AnyClass]? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        if let protocolClasses { config.protocolClasses = protocolClasses }
        self.session = URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let status = error as? HTTPStatusError { return [408, 429, 500, 502, 503, 504].contains(status.code) }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorSecureConnectionFailed].contains(ns.code)
    }

    func request(_ url: URL, method: String = "GET", body: Data? = nil,
                 headers: [String: String] = [:], appleRedirects: Bool = false,
                 authentication: Bool = false, allowRedirects: Bool = true,
                 retryTransient: Bool? = nil,
                 refreshHeaders: ((URL) async throws -> [String: String])? = nil) async throws -> (Data, HTTPURLResponse) {
        let retries = (retryTransient ?? (method == "GET")) ? 2 : 0
        var attempt = 0
        while true {
            do {
                return try await requestOnce(url, method: method, body: body, headers: headers, appleRedirects: appleRedirects,
                                             authentication: authentication, allowRedirects: allowRedirects,
                                             refreshHeaders: refreshHeaders)
            } catch {
                guard attempt < retries, Self.isTransient(error), !Task.isCancelled else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }
    }

    private func requestOnce(_ url: URL, method: String, body: Data?,
                             headers: [String: String], appleRedirects: Bool,
                             authentication: Bool, allowRedirects: Bool,
                             refreshHeaders: ((URL) async throws -> [String: String])?) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw ToolError.message("auth_err_invalid_link".localized)
        }
        var current = url
        var activeMethod = method
        var activeBody = body
        var activeHeaders = headers
        let initialHost = url.host?.lowercased()
        for _ in 0..<5 {
            try Task.checkCancellation()
            var request = URLRequest(url: current)
            request.httpMethod = activeMethod; request.httpBody = activeBody
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            activeHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ToolError.message("auth_err_server_response".localized) }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard allowRedirects else { throw HTTPStatusError(code: response.statusCode) }
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let rawNext = URL(string: location, relativeTo: current)?.absoluteURL,
                      rawNext.scheme?.lowercased() == "https", let host = rawNext.host?.lowercased(),
                      rawNext.user == nil, rawNext.password == nil else {
                    throw ToolError.message("auth_err_server_response".localized)
                }
                let next: URL
                if authentication {
                    guard [301, 302, 307, 308].contains(response.statusCode),
                          let normalized = AppleAuthentication.normalizedEndpoint(rawNext) else {
                        throw ToolError.message("auth_err_invalid_signin_url_retry".localized)
                    }
                    next = normalized
                } else if appleRedirects {
                    guard host == "itunes.apple.com" || host.hasSuffix(".itunes.apple.com") else {
                        throw ToolError.message("auth_err_server_response".localized)
                    }
                    next = rawNext
                    if response.statusCode == 303 && activeMethod != "GET" && activeMethod != "HEAD" {
                        activeMethod = "GET"
                        activeBody = nil
                        activeHeaders = activeHeaders.filter { $0.key.lowercased() != "content-type" }
                    }
                } else {
                    guard host == initialHost else { throw ToolError.message("auth_err_server_response".localized) }
                    next = rawNext
                    if response.statusCode == 303 && activeMethod != "GET" && activeMethod != "HEAD" {
                        activeMethod = "GET"
                        activeBody = nil
                        activeHeaders = activeHeaders.filter { $0.key.lowercased() != "content-type" }
                    }
                }
                if let refreshHeaders {
                    activeHeaders = try await refreshHeaders(next)
                } else if !AppleAuthentication.needsStoreProof(next, method: activeMethod) {
                    activeHeaders = activeHeaders.filter {
                        !["x-apple-amd", "x-apple-amd-m"].contains($0.key.lowercased())
                    }
                }
                current = next
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw HTTPStatusError(code: response.statusCode)
            }
            return (data, response)
        }
        throw ToolError.message("auth_err_server_response".localized)
    }

    func range(_ url: URL, _ value: String, limit: Int) async throws -> (Data, String) {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ToolError.message("auth_err_invalid_link".localized) }
        var current = url
        for _ in 0..<5 {
            try Task.checkCancellation()
            var request = URLRequest(url: current)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=" + value, forHTTPHeaderField: "Range")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                bytes.task.cancel(); throw ToolError.message("auth_err_server_response".localized)
            }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                bytes.task.cancel()
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL,
                      next.scheme == "https", let host = next.host?.lowercased(), next.user == nil, next.password == nil,
                      host == "apple.com" || host.hasSuffix(".apple.com") || host.hasSuffix(".cdn-apple.com") else {
                    throw ToolError.message("auth_err_server_response".localized)
                }
                current = next
                continue
            }
            guard response.statusCode == 206, let contentRange = response.value(forHTTPHeaderField: "Content-Range") else {
                bytes.task.cancel(); throw HTTPStatusError(code: response.statusCode)
            }
            var data = Data()
            data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { bytes.task.cancel(); throw ToolError.message("auth_err_server_response".localized) }
            }
            return (data, contentRange)
        }
        throw ToolError.message("auth_err_server_response".localized)
    }

    func json(_ url: URL) async throws -> Any {
        let (data, _) = try await request(url)
        return try JSONSerialization.jsonObject(with: data)
    }

    func plist(_ url: URL, body: Data, headers: [String: String], allowRedirects: Bool = true,
               retryTransient: Bool = false,
               refreshHeaders: ((URL) async throws -> [String: String])? = nil) async throws -> ([String: Any], HTTPURLResponse) {
        let (data, response) = try await request(url, method: "POST", body: body, headers: headers,
                                                 appleRedirects: allowRedirects, allowRedirects: allowRedirects,
                                                 retryTransient: retryTransient, refreshHeaders: refreshHeaders)
        do {
            let dictionary = try ApplePropertyList.dictionary(data)
            return (dictionary, response)
        } catch {
            if response.statusCode == 200, AppleAuthentication.storeMachineAction(raw: [:], response: response) != nil {
                return ([:], response)
            }
            throw error
        }
    }

    static func encodePlist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    static func appleFailure(_ response: [String: Any]) -> ToolError? {
        let code = plistString(response["failureType"])
        guard !code.isEmpty else { return nil }
        let messages = [
            "2002": "auth_err_reauth_check_password".localized,
            "5002": "auth_err_service_unavailable".localized,
            "2040": "auth_err_app_cannot_download".localized,
            "-5000": "auth_err_bad_credentials".localized,
            "2059": "auth_err_app_download_unavailable".localized,
            "1010": "auth_err_app_not_in_region".localized,
            "2034": "auth_err_expired".localized,
            "2042": "auth_err_expired".localized,
            "2019": "auth_err_paid_app_purchase".localized,
            "9610": "auth_err_no_license".localized
        ]
        return .message(messages[code] ?? "auth_err_operation_failed".localized)
    }
}
