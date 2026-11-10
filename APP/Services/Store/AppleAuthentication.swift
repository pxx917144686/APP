import Foundation

enum AppleAuthentication {
    static let path = "/WebObjects/MZFinance.woa/wa/authenticate"
    static let nativePaths: Set<String> = [
        "/auth/v1/native", "/auth/v1/native/",
        "/auth/v1/native/fast", "/auth/v1/native/fast/"
    ]
    private static let downloadDispatchPaths: Set<String> = [
        "/WebObjects/DownloadDispatch.woa/wa/ent/download",
        "/WebObjects/DownloadDispatch.woa/wa/ent/download/",
        "/r/redownload", "/r/redownload/",
        "/up/updateProduct", "/up/updateProduct/",
        "/up/backgroundUpdateProduct", "/up/backgroundUpdateProduct/"
    ]
    private static let buyProofPaths: Set<String> = [
        "/WebObjects/MZFinance.woa/wa/buyProduct",
        "/WebObjects/MZFinance.woa/wa/buyProduct/",
        "/WebObjects/MZBuy.woa/wa/buyProduct",
        "/WebObjects/MZBuy.woa/wa/buyProduct/",
        "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct",
        "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct/"
    ]

    static func isBuyHost(_ host: String) -> Bool {
        if host == "buy.itunes.apple.com" { return true }
        guard host.hasPrefix("p"), host.hasSuffix("-buy.itunes.apple.com") else { return false }
        let digits = host.dropFirst().dropLast("-buy.itunes.apple.com".count)
        return !digits.isEmpty && digits.allSatisfy({ $0.isASCII && $0.isNumber })
    }

    private static func hasSafePath(_ rawPath: String) -> Bool {
        let lower = rawPath.lowercased()
        return !lower.contains("%2f") && !lower.contains("%5c") && !rawPath.contains("..")
    }

    static func bagURL(guid: String) -> URL {
        var url = URLComponents(string: "https://init.itunes.apple.com/bag.xml")!
        url.queryItems = [URLQueryItem(name: "guid", value: guid)]
        return url.url!
    }

    static func isEndpoint(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return false }
        let urlPath = url.path(percentEncoded: true)
        guard hasSafePath(urlPath) else { return false }
        if host == "auth.itunes.apple.com" {
            return nativePaths.contains(urlPath)
        }
        guard urlPath == path || urlPath == path + "/" else { return false }
        return isBuyHost(host)
    }

    static func needsStoreProof(_ url: URL, method: String = "POST") -> Bool {
        guard method.uppercased() == "POST",
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return false }
        let urlPath = url.path(percentEncoded: true)
        guard hasSafePath(urlPath) else { return false }
        if host == "auth.itunes.apple.com" { return nativePaths.contains(urlPath) }
        if host == "downloaddispatch.itunes.apple.com" { return downloadDispatchPaths.contains(urlPath) }
        if isBuyHost(host) { return buyProofPaths.contains(urlPath) }
        return false
    }

    enum StoreMachineAction: Equatable {
        case provision(String)
        case reset
        case invalidChallenge
    }

    static func storeMachineAction(raw: [String: Any], response: HTTPURLResponse) -> StoreMachineAction? {
        var action = response.value(forHTTPHeaderField: "X-Apple-AMD-Action")?
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        if action.isEmpty {
            let message = plistString(raw["customerMessage"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.hasPrefix("AMD-Action:") {
                action = String(message.split(separator: ":").last ?? "").uppercased()
            }
        }
        if action == "RP" { return .reset }
        guard action == "SP" else { return nil }
        let challenge = response.value(forHTTPHeaderField: "X-Apple-AMD-Data")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !challenge.isEmpty, challenge.count <= 16_384, challenge.count % 4 == 0,
              let decoded = Data(base64Encoded: challenge), !decoded.isEmpty,
              decoded.base64EncodedString() == challenge else {
            return .invalidChallenge
        }
        return .provision(challenge)
    }

    private static let proofHeaderNames: Set<String> = ["x-apple-amd", "x-apple-amd-m"]

    @MainActor
    private final class ProofState {
        var buffered: [String: String]?
        var isProvisioned = false
    }

    @MainActor
    static func withStoreProof(
        endpoint: URL,
        baseHeaders: [String: String],
        loadProof: @escaping () async throws -> [String: String]?,
        provisionProof: (String) async throws -> [String: String],
        resetProof: () -> Void,
        execute: (@escaping (URL) async throws -> [String: String]) async throws -> ([String: Any], HTTPURLResponse)
    ) async throws -> ([String: Any], HTTPURLResponse) {
        let strippedBase = baseHeaders.filter { !proofHeaderNames.contains($0.key.lowercased()) }
        guard needsStoreProof(endpoint) else {
            return try await execute { _ in strippedBase }
        }
        let state = ProofState()
        do {
            if let initial = try await loadProof() {
                state.buffered = initial
                state.isProvisioned = true
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            resetProof()
            state.buffered = nil
            state.isProvisioned = false
        }
        var didReset = false
        var didProvision = false
        for _ in 0..<3 {
            try Task.checkCancellation()
            let headerProvider: (URL) async throws -> [String: String] = { @MainActor targetURL in
                guard needsStoreProof(targetURL) else { return strippedBase }
                var merged = strippedBase
                if let unspent = state.buffered {
                    state.buffered = nil
                    for (key, value) in unspent where !value.isEmpty { merged[key] = value }
                    return merged
                }
                guard state.isProvisioned else { return merged }
                if let fresh = try await loadProof() {
                    for (key, value) in fresh where !value.isEmpty { merged[key] = value }
                } else {
                    state.isProvisioned = false
                }
                return merged
            }
            let (raw, response) = try await execute(headerProvider)
            switch storeMachineAction(raw: raw, response: response) {
            case .reset:
                guard !didReset, state.isProvisioned else {
                    throw ToolError.message("auth_err_device_verify_incomplete".localized)
                }
                didReset = true
                resetProof()
                state.buffered = nil
                state.isProvisioned = false
            case .provision(let challenge):
                guard !didProvision else {
                    throw ToolError.message("auth_err_device_verify_incomplete".localized)
                }
                didProvision = true
                state.buffered = try await provisionProof(challenge)
                state.isProvisioned = true
            case .invalidChallenge:
                throw ToolError.message("auth_err_device_verify_incomplete".localized)
            case nil:
                return (raw, response)
            }
        }
        throw ToolError.message("auth_err_device_verify_incomplete".localized)
    }

    static func normalizedEndpoint(_ url: URL) -> URL? {
        guard isEndpoint(url),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if url.host?.lowercased() != "auth.itunes.apple.com" {
            parts.path = path + "/"
        }
        return parts.url
    }

    static func endpoint(from data: Data) throws -> URL {
        let raw = try ApplePropertyList.dictionary(data)
        let bag = raw["urlBag"] as? [String: Any] ?? raw
        guard let address = bag["authenticateAccount"] as? String else { throw ConfigurationError.missingEndpoint }
        guard let url = URL(string: address), let endpoint = normalizedEndpoint(url) else {
            throw ConfigurationError.invalidEndpoint
        }
        return endpoint
    }

    enum ConfigurationError: String, LocalizedError {
        case missingEndpoint, invalidEndpoint
        var errorDescription: String? { "auth_err_no_signin_url".localized }
    }

    @MainActor
    static func configuration(guid: String,
        send: (URL) async throws -> (Data, HTTPURLResponse), report: (String) -> Void) async throws -> URL {
        report("stage=configuration-request")
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await send(bagURL(guid: guid)) }
        catch {
            report("stage=configuration-request; " + errorCode(error))
            throw error
        }
        let metadata = "http=\(response.statusCode); format=\(ApplePropertyList.format(data)); bytes=\(data.count)"
        do {
            let url = try endpoint(from: data)
            report("stage=configuration-decode; " + metadata + "; result=valid")
            return url
        } catch {
            report("stage=configuration-decode; " + metadata + "; " + errorCode(error))
            throw error
        }
    }

    static func errorCode(_ error: Error) -> String {
        if let error = error as? ApplePropertyListError { return "error=plist-" + error.rawValue }
        if let error = error as? ConfigurationError { return "error=configuration-" + error.rawValue }
        if let error = error as? HTTPStatusError { return "http=\(error.code)" }
        let ns = error as NSError
        let domains = [NSURLErrorDomain, NSCocoaErrorDomain, "WebKitErrorDomain"]
        return "error=\(domains.contains(ns.domain) ? ns.domain : "application"); code=\(ns.code)"
    }

    enum ResponseKind: String {
        case empty, plist, html, json, other
    }

    static func kind(_ data: Data) -> ResponseKind {
        if data.isEmpty { return .empty }
        if (try? ApplePropertyList.dictionary(data)) != nil { return .plist }
        let prefix = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") { return .html }
        if prefix.hasPrefix("{") || prefix.hasPrefix("[") { return .json }
        return .other
    }

    @MainActor
    static func authenticate(endpoint: URL, body: Data, headers: [String: String] = [:],
        makeHeaders: (() async throws -> [String: String])? = nil,
        send: (URL, Data, [String: String]) async throws -> (Data, HTTPURLResponse),
        pause: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
        report: (String) -> Void) async throws -> ([String: Any], HTTPURLResponse) {
        guard isEndpoint(endpoint) else { throw ToolError.message("auth_err_invalid_signin_url".localized) }
        for attempt in 1...2 {
            try Task.checkCancellation()
            let requestHeaders = try await (makeHeaders?() ?? headers)
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await send(endpoint, body, requestHeaders)
            } catch {
                let status = (error as? HTTPStatusError)?.code
                report("stage=authentication; request=\(attempt); " + (status.map { "http=\($0)" } ?? errorCode(error)))
                if attempt == 1, let status, status == 403 || status == 404 || (500...599).contains(status) {
                    try await pause(); continue
                }
                throw error
            }
            let format = kind(data)
            report("stage=authentication; request=\(attempt); http=\(response.statusCode); format=\(format.rawValue); envelope=\(ApplePropertyList.format(data)); bytes=\(data.count)")
            if response.statusCode == 200 {
                if format == .plist, let raw = try? ApplePropertyList.dictionary(data) {
                    return (raw, response)
                }
                if storeMachineAction(raw: [:], response: response) != nil {
                    return ([:], response)
                }
            }
            if attempt == 1, response.statusCode == 200 || response.statusCode == 204 {
                try await pause(); continue
            }
            throw ToolError.message("auth_err_no_valid_data".localized)
        }
        throw ToolError.message("auth_err_unavailable".localized)
    }
}
