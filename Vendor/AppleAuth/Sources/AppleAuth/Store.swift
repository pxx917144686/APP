import Foundation
import apple_auth

public enum StoreProtocol: Int32, Sendable, Codable {
    case androidMusic, macOSAccounts, configurator
}

internal func localPath(_ file: URL) throws -> String {
    guard file.isFileURL, !file.path.contains("\0") else { throw AppleAuthError("Expected a local file URL") }
    return file.path
}

internal func checkedString(_ value: String) throws -> String {
    guard !value.contains("\0") else { throw AppleAuthError("String contains a NUL character") }
    return value
}

internal func decodeStore<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: data)
}

internal func withStore<Value>(_ plist: Data, _ body: (OpaquePointer) throws -> Value) throws -> Value {
    var handle: OpaquePointer?
    try plist.withUnsafeBytes { bytes in
        try checkClient(aauth_store_session_from_plist(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &handle))
    }
    guard let handle else { throw AppleAuthError("Store session returned no handle") }
    defer { aauth_store_session_free(handle) }
    return try body(handle)
}

public struct StoreSession: Sendable, CustomStringConvertible {
    public let plist: Data
    public let accountID: String
    public let storefront: String
    public let `protocol`: StoreProtocol
    public var description: String { "StoreSession(accountID: \(accountID), protocol: \(`protocol`))" }

    public init(plist: Data) throws {
        struct Info: Decodable { let account_id: String; let storefront: String; let `protocol`: Int32 }
        let info = try withStore(plist) { handle in
            try JSONDecoder().decode(Info.self, from: clientData { aauth_store_session_info(handle, $0) })
        }
        guard let kind = StoreProtocol(rawValue: info.protocol) else { throw AppleAuthError("Unknown Store protocol") }
        self.plist = plist; accountID = info.account_id; storefront = info.storefront; self.protocol = kind
    }

    public static func load(from file: URL, encryptionKey: Data? = nil) throws -> StoreSession {
        _ = try localPath(file)
        return try deserialize(SessionCrypto.read(from: file), encryptionKey: encryptionKey)
    }

    public func save(to file: URL, encryptionKey: Data? = nil) throws {
        let path = try localPath(file)
        if let encryptionKey {
            try SessionCrypto.save(plist, to: file, key: encryptionKey)
            return
        }
        try withStore(plist) { try checkClient(aauth_store_session_save($0, path)) }
    }

    public func iosContext(country: String) throws -> Data {
        let country = try checkedString(country)
        return try withStore(plist) { handle in try clientData { aauth_store_session_ios_context(handle, country, $0) } }
    }

    public func headers(for url: URL) throws -> [String: String] {
        let text = try checkedString(url.absoluteString)
        return try withStore(plist) { handle in
            try JSONDecoder().decode([String: String].self,
                from: clientData { aauth_store_session_headers(handle, text, $0) })
        }
    }

    public func testFlightContext(hardware20: Data, headers: [String: String]) throws -> Data {
        let json = String(decoding: try JSONEncoder().encode(headers), as: UTF8.self)
        return try withStore(plist) { handle in
            try hardware20.withUnsafeBytes { hardware in
                try clientData { aauth_store_session_testflight_context(handle,
                    hardware.bindMemory(to: UInt8.self).baseAddress, hardware.count, json, $0) }
            }
        }
    }
}

// Owns callback lifetime and serializes every native operation off the caller's executor.
internal final class StoreRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "apple-auth.store")
    let bridge: NativeBridge
    private var handle: OpaquePointer?
    private let release: @Sendable (OpaquePointer?) -> Void

    init(transport: HTTPTransport?, clock: @escaping @Sendable () -> Date = { Date() },
         release: @escaping @Sendable (OpaquePointer?) -> Void) {
        bridge = NativeBridge(transport: transport, clock: clock)
        self.release = release
    }

    deinit { release(handle); bridge.close() }

    func perform<Value: Sendable>(allowEmpty: Bool = false,
        _ body: @escaping @Sendable (OpaquePointer?, NativeBridge) throws -> Value) async throws -> Value {
        guard NativeCallbackContext.deviceID != bridge.deviceID else {
            throw AppleAuthError("A native callback cannot re-enter the same Store client")
        }
        let operation = NativeOperation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.bridge.operation = operation; self.bridge.failure = nil
                    defer { self.bridge.operation = nil; self.bridge.failure = nil }
                    do {
                        try operation.checkCancellation()
                        guard allowEmpty || self.handle != nil else { throw AppleAuthError("Store client is closed") }
                        let result = try body(self.handle, self.bridge)
                        try operation.checkCancellation()
                        if let failure = self.bridge.failure { throw failure }
                        continuation.resume(returning: result)
                    } catch {
                        do {
                            try operation.checkCancellation()
                            continuation.resume(throwing: self.bridge.failure ?? error)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: { operation.cancel() }
    }

    func initialize(_ create: @escaping @Sendable (NativeBridge, UnsafeMutablePointer<OpaquePointer?>) throws -> Void) async throws {
        try await perform(allowEmpty: true) { _, bridge in
            try create(bridge, &self.handle)
            guard self.handle != nil else { throw AppleAuthError("Initialization returned no native handle") }
        }
    }

    func close() async throws {
        try await perform(allowEmpty: true) { handle, bridge in
            self.release(handle); self.handle = nil; bridge.close()
        }
    }
}

internal func withStoreOptions<Value>(_ bridge: NativeBridge, userAgent: String? = nil,
    clientInfo: String? = nil, headers: [String: String] = [:],
    _ body: (UnsafePointer<aauth_client_options>, UnsafePointer<aauth_device_headers>, String) throws -> Value) throws -> Value {
    let strings = try NativeStrings([userAgent, clientInfo])
    var options = aauth_client_options(transport: transportCallback, observer: nil, clock: clockCallback,
        context: Unmanaged.passUnretained(bridge).toOpaque())
    var overrides = aauth_device_headers(user_agent: strings[0], client_info: strings[1])
    let json = String(decoding: try JSONEncoder().encode(headers), as: UTF8.self)
    return try withUnsafePointer(to: &options) { options in
        try withUnsafePointer(to: &overrides) { try body(options, $0, json) }
    }
}

public struct StoreRequestResult: Sendable {
    public let response: HTTPResponse
    public let session: StoreSession
}

public final class StoreClient: Sendable {
    private let runner: StoreRunner

    public init(directory: URL, protocol kind: StoreProtocol = .androidMusic,
                transport: HTTPTransport? = nil, userAgent: String? = nil,
                clientInfo: String? = nil, headers: [String: String] = [:],
                clock: @escaping @Sendable () -> Date = { Date() }) async throws {
        let path = try localPath(directory)
        let runner = StoreRunner(transport: transport, clock: clock, release: { aauth_store_client_free($0) })
        self.runner = runner
        try await runner.initialize { bridge, output in
            try withStoreOptions(bridge, userAgent: userAgent, clientInfo: clientInfo, headers: headers) {
                try checkClient(aauth_store_client_create(path, aauth_store_protocol(rawValue: UInt32(kind.rawValue)), $0, $1, $2, output))
            }
        }
    }

    public func close() async throws { try await runner.close() }

    public func provision() async throws {
        try await runner.perform { handle, _ in try checkClient(aauth_store_client_provision(handle)) }
    }

    public func headers() async throws -> [String: String] {
        try await runner.perform { handle, _ in
            try JSONDecoder().decode([String: String].self, from: clientData { aauth_store_client_headers(handle, $0) })
        }
    }

    public func login(email: String, password: String, verification: Verification? = nil) async throws -> StoreSession {
        // Store protocols accept a code callback; SMS selection belongs to GrandSlam Device.login.
        let email = try checkedString(email), password = try checkedString(password)
        return try await runner.perform { handle, bridge in
            bridge.verification = verification
            defer { bridge.verification = nil }
            var result: OpaquePointer?
            try checkClient(aauth_store_client_login(handle, email, password,
                verification == nil ? nil : codeCallback, Unmanaged.passUnretained(bridge).toOpaque(), &result))
            guard let result else { throw AppleAuthError("Login returned no Store session") }
            defer { aauth_store_session_free(result) }
            return try StoreSession(plist: clientData { aauth_store_session_plist(result, $0) })
        }
    }

    public func request(session: StoreSession, request: URLRequest) async throws -> StoreRequestResult {
        guard let url = request.url else { throw AppleAuthError("Missing request URL") }
        let urlText = try checkedString(url.absoluteString)
        let method = try checkedString(request.httpMethod ?? "GET")
        let headers = String(decoding: try JSONEncoder().encode(request.allHTTPHeaderFields ?? [:]), as: UTF8.self)
        let body = request.httpBody ?? Data()
        return try await runner.perform { handle, _ in
            try withStore(session.plist) { store in
                let strings = try NativeStrings([urlText, method, headers])
                let response = try body.withUnsafeBytes { bytes in
                    var input = aauth_http_request(url: strings[0], method: strings[1], headers_json: strings[2],
                        body: bytes.bindMemory(to: UInt8.self).baseAddress, body_size: bytes.count)
                    return try clientData { aauth_store_client_request(handle, store, &input, $0) }
                }
                struct Response: Decodable { let status: Int; let body: Data; let headers: [[String]] }
                let decoded = try JSONDecoder().decode(Response.self, from: response)
                guard decoded.headers.allSatisfy({ $0.count == 2 }) else { throw AppleAuthError("Invalid response headers") }
                let updated = try StoreSession(plist: clientData { aauth_store_session_plist(store, $0) })
                return StoreRequestResult(response: HTTPResponse(status: decoded.status, body: decoded.body,
                    headers: decoded.headers.map { HTTPHeader($0[0], $0[1]) }), session: updated)
            }
        }
    }
}

public struct TestFlightArchiveInfo: Codable, Sendable {
    public let bundle: String
    public let members: UInt64
    public let encryptedImages: UInt64
    public let clearImages: UInt64
}

public struct TestFlightDownload: Codable, Sendable {
    public let archive: TestFlightArchiveInfo
    public let downloadedBytes: UInt64
    public let artifacts: String
}

public struct AppStoreOffer: Codable, Sendable {
    public let appId: UInt64
    public let bundle: String
    public let version: String?
    public let externalVersionId: String
}

public struct AppStoreDownload: Codable, Sendable {
    public let offer: AppStoreOffer
    public let path: String
    public let materialDirectory: String
    public let originalPath: String?
    public let bytes: UInt64
    public let members: UInt64?
    public let version: String?
    public let sha256: String
    public let mainCryptids: [UInt32]?
    public let versionIds: [String]
    public let transportWrapped: Bool?
    public let packageValidated: Bool?
}

public struct TestFlightOptions: Sendable, Encodable {
    public var headers: [String: String]
    public var deviceModel: String?
    public var deviceName: String?
    public init(headers: [String: String] = [:], deviceModel: String? = nil, deviceName: String? = nil) {
        self.headers = headers; self.deviceModel = deviceModel; self.deviceName = deviceName
    }
}

public final class TestFlightClient: Sendable {
    private let runner: StoreRunner

    public init(savedSession: Data, encryptionKey: Data? = nil, transport: HTTPTransport? = nil,
                options: TestFlightOptions = TestFlightOptions()) async throws {
        let savedSession = try SessionCrypto.decode(savedSession, key: encryptionKey)
        let runner = StoreRunner(transport: transport, release: { aauth_testflight_client_free($0) })
        self.runner = runner
        let json = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        try await runner.initialize { bridge, output in
            try withStoreOptions(bridge) { transport, _, _ in
                try savedSession.withUnsafeBytes { bytes in
                    try checkClient(aauth_testflight_client_create(bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count, transport, json, output))
                }
            }
        }
    }

    private init(runner: StoreRunner) { self.runner = runner }

    public static func fromStoreCookies(_ context: Data, transport: HTTPTransport? = nil,
        options: TestFlightOptions = TestFlightOptions()) async throws -> TestFlightClient {
        let runner = StoreRunner(transport: transport, release: { aauth_testflight_client_free($0) })
        let json = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        try await runner.initialize { bridge, output in
            try withStoreOptions(bridge) { transport, _, _ in
                try context.withUnsafeBytes { bytes in
                    try checkClient(aauth_testflight_client_from_store_cookies(bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count, transport, json, output))
                }
            }
        }
        return TestFlightClient(runner: runner)
    }

    public static func fromStoreSession(_ session: StoreSession, hardware20: Data,
        macHeaders: [String: String], transport: HTTPTransport? = nil,
        options: TestFlightOptions = TestFlightOptions()) async throws -> TestFlightClient {
        try await fromStoreCookies(session.testFlightContext(hardware20: hardware20, headers: macHeaders),
            transport: transport, options: options)
    }

    public func close() async throws { try await runner.close() }
    public func serialize(encryptionKey: Data? = nil) async throws -> Data {
        try await runner.perform { handle, _ in
            try SessionCrypto.encode(clientData { aauth_testflight_client_serialize(handle, $0) }, key: encryptionKey)
        }
    }

    public static func deserialize(_ data: Data, encryptionKey: Data? = nil,
        transport: HTTPTransport? = nil, options: TestFlightOptions = TestFlightOptions()) async throws -> TestFlightClient {
        try await TestFlightClient(savedSession: data, encryptionKey: encryptionKey, transport: transport, options: options)
    }

    public static func load(from file: URL, encryptionKey: Data? = nil,
        transport: HTTPTransport? = nil, options: TestFlightOptions = TestFlightOptions()) async throws -> TestFlightClient {
        _ = try localPath(file)
        return try await deserialize(SessionCrypto.read(from: file), encryptionKey: encryptionKey, transport: transport, options: options)
    }

    public func save(to file: URL, encryptionKey: Data? = nil) async throws {
        let path = try localPath(file)
        if let encryptionKey {
            try await runner.perform { handle, _ in
                try SessionCrypto.save(clientData { aauth_testflight_client_serialize(handle, $0) },
                    to: file, key: encryptionKey, overwrite: false)
            }
            return
        }
        try await runner.perform { handle, _ in try checkClient(aauth_testflight_client_save(handle, path)) }
    }
    public func catalog() async throws -> Data {
        try await runner.perform { handle, _ in try clientData { aauth_testflight_client_catalog(handle, $0) } }
    }
    public func installMetadata(bundle: String) async throws -> Data {
        let bundle = try checkedString(bundle)
        return try await runner.perform { handle, _ in
            try clientData { aauth_testflight_client_install_metadata(handle, bundle, $0) }
        }
    }
    public func download(bundle: String, to file: URL, includeSinf: Bool = true) async throws -> TestFlightDownload {
        let bundle = try checkedString(bundle), path = try localPath(file)
        return try await runner.perform { handle, _ in
            try decodeStore(TestFlightDownload.self, clientData { aauth_testflight_client_download_ipa(handle, bundle, path, includeSinf ? 1 : 0, $0) })
        }
    }
}

public final class AppStoreIosClient: Sendable {
    private let runner: StoreRunner
    public init(context: Data, transport: HTTPTransport? = nil, headers: [String: String] = [:]) async throws {
        let runner = StoreRunner(transport: transport, release: { aauth_appstore_ios_client_free($0) })
        self.runner = runner
        try await runner.initialize { bridge, output in
            try withStoreOptions(bridge, headers: headers) { transport, _, json in
                try context.withUnsafeBytes { bytes in
                    try checkClient(aauth_appstore_ios_client_create(bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count, transport, json, output))
                }
            }
        }
    }
    public convenience init(session: StoreSession, country: String, transport: HTTPTransport? = nil,
                            headers: [String: String] = [:]) async throws {
        try await self.init(context: session.iosContext(country: country), transport: transport, headers: headers)
    }
    public func close() async throws { try await runner.close() }
    public func catalog(appID: UInt64) async throws -> Data {
        try await runner.perform { handle, _ in try clientData { aauth_appstore_ios_client_catalog(handle, appID, $0) } }
    }
    public func offer(appID: UInt64) async throws -> AppStoreOffer {
        try await runner.perform { handle, _ in
            try decodeStore(AppStoreOffer.self, clientData { aauth_appstore_ios_client_offer(handle, appID, $0) })
        }
    }
    public func metadata(appID: UInt64) async throws -> Data {
        try await runner.perform { handle, _ in try clientData { aauth_appstore_ios_client_metadata(handle, appID, $0) } }
    }
    public func acquireFree(appID: UInt64) async throws -> Data {
        try await runner.perform { handle, _ in try clientData { aauth_appstore_ios_client_acquire_free(handle, appID, $0) } }
    }
    public func download(appID: UInt64, to file: URL, includeSinf: Bool = true) async throws -> AppStoreDownload {
        let path = try localPath(file)
        return try await runner.perform { handle, _ in
            try decodeStore(AppStoreDownload.self, clientData { aauth_appstore_ios_client_download_ipa(handle, appID, path, includeSinf ? 1 : 0, $0) })
        }
    }
}

public final class AppStoreMacClient: Sendable {
    private let runner: StoreRunner
    public init(session: StoreSession, storeDirectory: URL, country: String, transport: HTTPTransport? = nil,
                userAgent: String? = nil, clientInfo: String? = nil, headers: [String: String] = [:],
                clock: @escaping @Sendable () -> Date = { Date() }) async throws {
        let runner = StoreRunner(transport: transport, clock: clock, release: { aauth_appstore_mac_client_free($0) })
        self.runner = runner
        let path = try localPath(storeDirectory), country = try checkedString(country)
        try await runner.initialize { bridge, output in
            try withStoreOptions(bridge, userAgent: userAgent, clientInfo: clientInfo, headers: headers) { options, overrides, json in
                try withStore(session.plist) { store in
                    try checkClient(aauth_appstore_mac_client_create(store, path, country, options, overrides, json, output))
                }
            }
        }
    }
    public func close() async throws { try await runner.close() }
    public func catalog(appID: UInt64) async throws -> Data {
        try await runner.perform { handle, _ in try clientData { aauth_appstore_mac_client_catalog(handle, appID, $0) } }
    }
    public func offer(appID: UInt64) async throws -> AppStoreOffer {
        try await runner.perform { handle, _ in
            try decodeStore(AppStoreOffer.self, clientData { aauth_appstore_mac_client_offer(handle, appID, $0) })
        }
    }
    public func metadata(appID: UInt64) async throws -> Data {
        try await runner.perform { handle, _ in try clientData { aauth_appstore_mac_client_metadata(handle, appID, $0) } }
    }
    public func download(appID: UInt64, to file: URL) async throws -> AppStoreDownload {
        try await download(appID: appID, to: file, package: false)
    }
    public func downloadPackage(appID: UInt64, to file: URL) async throws -> AppStoreDownload {
        try await download(appID: appID, to: file, package: true)
    }
    private func download(appID: UInt64, to file: URL, package: Bool) async throws -> AppStoreDownload {
        let path = try localPath(file)
        return try await runner.perform { handle, _ in
            try decodeStore(AppStoreDownload.self, clientData { aauth_appstore_mac_client_download(handle, appID, path, package ? 1 : 0, $0) })
        }
    }
}

public enum StoreSupport {
    public static func features() throws -> [String: Bool] {
        try JSONDecoder().decode([String: Bool].self, from: clientData { aauth_client_features($0) })
    }

    public static func generateKBSync(dsid: UInt64, hardware: Data, entropy: Data = Data()) throws -> Data {
        try hardware.withUnsafeBytes { hardware in
            try entropy.withUnsafeBytes { entropy in
                try clientData { aauth_generate_kbsync(dsid, hardware.bindMemory(to: UInt8.self).baseAddress,
                    hardware.count, entropy.bindMemory(to: UInt8.self).baseAddress, entropy.count, $0) }
            }
        }
    }

    // Metadata uses the same JSON result schema as the C API; archive bytes stay in files.
    public static func unwrapTestFlight(source: URL, destination: URL, hardware20: Data, dpInfo88: Data) throws -> Data {
        try unwrap(source: source, destination: destination, hardware: hardware20, dpInfo: dpInfo88, mac: false)
    }
    public static func unwrapMacPackage(source: URL, destination: URL, hardware6: Data, dpInfo88: Data) throws -> Data {
        try unwrap(source: source, destination: destination, hardware: hardware6, dpInfo: dpInfo88, mac: true)
    }
    private static func unwrap(source: URL, destination: URL, hardware: Data, dpInfo: Data, mac: Bool) throws -> Data {
        let source = try localPath(source), destination = try localPath(destination)
        return try hardware.withUnsafeBytes { hardware in
            try dpInfo.withUnsafeBytes { info in
                try clientData {
                    let function = mac ? aauth_unwrap_appstore_mac_package : aauth_unwrap_testflight_transport
                    return function(source, destination, hardware.bindMemory(to: UInt8.self).baseAddress,
                        hardware.count, info.bindMemory(to: UInt8.self).baseAddress, info.count, $0)
                }
            }
        }
    }
    public static func normalizeIPA(source: URL, destination: URL, expectedBundle: String = "") throws -> TestFlightArchiveInfo {
        let source = try localPath(source), destination = try localPath(destination), bundle = try checkedString(expectedBundle)
        return try decodeStore(TestFlightArchiveInfo.self, clientData { aauth_normalize_testflight_ipa(source, destination, bundle, $0) })
    }
}
