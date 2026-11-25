import Foundation
import Darwin
import apple_auth

internal final class NativeStrings {
    private var values: [UnsafeMutablePointer<CChar>?] = []
    init(_ strings: [String?]) throws {
        for string in strings {
            guard let string else { values.append(nil); continue }
            guard !string.contains("\0"), let value = strdup(string) else {
                for pointer in values { free(pointer) }
                values.removeAll()
                throw AppleAuthError("Invalid string or native allocation failure")
            }
            values.append(value)
        }
    }
    subscript(_ index: Int) -> UnsafePointer<CChar>? { values[index].map { UnsafePointer($0) } }
    deinit { for value in values { free(value) } }
}

public final class Device: @unchecked Sendable {
    public let directory: URL?
    public let info: DeviceInfo
    private let queue = DispatchQueue(label: "apple-auth.device")
    private let bridge: NativeBridge
    private var handle: OpaquePointer?
    private let encryptionKey: Data?

    public init(directory: URL? = nil, initialState: Data? = nil, platform: DevicePlatform? = nil,
                model: String? = nil, macOSVersion: String? = nil, macOSBuild: String? = nil,
                iOSVersion: String? = nil, iOSBuild: String? = nil,
                serialNumber: String? = nil, transport: HTTPTransport? = nil,
                userAgent: String? = nil, clientInfo: String? = nil, headers: [String: String] = [:],
                encryptionKey: Data? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) throws {
        if let encryptionKey { try SessionCrypto.validate(encryptionKey) }
        guard directory == nil || directory?.isFileURL == true else {
            throw AppleAuthError("Device state must use a local directory")
        }
        guard directory == nil || initialState == nil else {
            throw AppleAuthError("Restore state into an in-memory device, without a directory")
        }
        let directory = directory?.standardizedFileURL
        let platform: DevicePlatform = platform ?? (initialState == nil ? .mac : .automatic)
        let state = try initialState.map { try SessionCrypto.decode($0, key: encryptionKey) }
        let bridge = NativeBridge(transport: transport, clock: clock)
        let headersJSON = String(decoding: try JSONEncoder().encode(headers), as: UTF8.self)
        let strings = try NativeStrings([directory?.path, model, macOSVersion, macOSBuild, serialNumber,
                                         iOSVersion, iOSBuild, userAgent, clientInfo, headersJSON])
        var options = aauth_client_options(transport: transportCallback, observer: nil, clock: clockCallback,
                                               context: Unmanaged.passUnretained(bridge).toOpaque())
        var mac = aauth_mac_device(model: strings[1], macos_version: strings[2], macos_build: strings[3])
        var iphone = aauth_iphone_device(model: platform == .iphone ? strings[1] : nil,
                                          ios_version: strings[5], ios_build: strings[6])
        var config = aauth_client_config(directory: strings[0], options: nil,
            platform: aauth_device_platform(rawValue: UInt32(platform.rawValue)),
            mac_device: nil, iphone_device: nil, serial_number: strings[4],
            headers: nil, headers_json: strings[9], state: nil, state_size: 0)
        var native: OpaquePointer?
        var overrides = aauth_device_headers(user_agent: strings[7], client_info: strings[8])
        do {
            try withUnsafePointer(to: &options) { settings in
                config.options = settings
                try withUnsafePointer(to: &mac) { pointer in
                    if macOSVersion != nil || macOSBuild != nil ||
                       (platform != .iphone && (platform == .mac || model != nil)) {
                        config.mac_device = pointer
                    }
                    try withUnsafePointer(to: &iphone) { phone in
                        config.iphone_device = phone
                        try withUnsafePointer(to: &overrides) { headers in
                            config.headers = headers
                            if let state {
                                try state.withUnsafeBytes { bytes in
                                    config.state = bytes.bindMemory(to: UInt8.self).baseAddress
                                    config.state_size = bytes.count
                                    try checkClient(aauth_client_create(&config, &native))
                                }
                            } else {
                                try checkClient(aauth_client_create(&config, &native))
                            }
                        }
                    }
                }
            }
            guard let native else { throw AppleAuthError("Device initialization returned no client") }
            info = try JSONDecoder().decode(DeviceInfo.self, from: clientData { aauth_client_device_info(native, $0) })
        } catch {
            if let native { aauth_client_free(native) }
            bridge.close()
            throw error
        }
        self.directory = directory
        self.encryptionKey = encryptionKey
        self.bridge = bridge
        handle = native
    }

    deinit {
        if let handle { aauth_client_free(handle) }
        bridge.close()
    }

    public static func open(directory: URL, transport: HTTPTransport? = nil,
                            userAgent: String? = nil, clientInfo: String? = nil, headers: [String: String] = [:],
                            encryptionKey: Data? = nil,
                            clock: @escaping @Sendable () -> Date = { Date() }) throws -> Device {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("identity.json").path) else {
            throw AppleAuthError("No saved device in this directory")
        }
        return try Device(directory: directory, platform: .automatic, transport: transport,
                          userAgent: userAgent, clientInfo: clientInfo, headers: headers,
                          encryptionKey: encryptionKey, clock: clock)
    }

    private func perform<Value: Sendable>(allowClosed: Bool = false,
                                           _ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        guard NativeCallbackContext.deviceID != bridge.deviceID else {
            throw AppleAuthError("A native callback cannot call another operation on the same device")
        }
        let operation = NativeOperation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.bridge.operation = operation
                    self.bridge.failure = nil
                    defer { self.bridge.operation = nil; self.bridge.failure = nil }
                    do {
                        try operation.checkCancellation()
                        guard allowClosed || self.handle != nil else { throw AppleAuthError("Device is closed") }
                        let value = try body()
                        try operation.checkCancellation()
                        continuation.resume(returning: value)
                    } catch let nativeError {
                        do {
                            try operation.checkCancellation()
                            continuation.resume(throwing: self.bridge.failure ?? nativeError)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: { operation.cancel() }
    }

    public func close() async throws {
        try await perform(allowClosed: true) {
            if let handle = self.handle { aauth_client_free(handle); self.handle = nil }
            self.bridge.close()
        }
    }

    public func provision() async throws {
        try await perform { try checkClient(aauth_client_provision(self.handle)) }
    }

    public func headers() async throws -> [String: String] {
        try await perform {
            try JSONDecoder().decode([String: String].self, from: clientData { aauth_client_headers(self.handle, $0) })
        }
    }

    public func login(email: String, password: String, verification: Verification? = nil) async throws -> AccountSession {
        guard !email.contains("\0"), !password.contains("\0") else { throw AppleAuthError("Credentials contain a NUL character") }
        return try await perform {
            self.bridge.verification = verification
            defer { self.bridge.verification = nil }
            var options = aauth_verification_options(
                method: aauth_verification_method(rawValue: UInt32(verification?.method.rawValue ?? 0)),
                phone_number_id: verification?.phoneNumberID ?? 0,
                code: verification == nil ? nil : codeCallback,
                select_phone: verification?.selectPhone == nil ? nil : phoneCallback,
                context: Unmanaged.passUnretained(self.bridge).toOpaque())
            var session: OpaquePointer?
            try checkClient(aauth_client_login(self.handle, email, password, &options, &session))
            guard let session else { throw AppleAuthError("Login returned no session") }
            defer { aauth_account_session_free(session) }
            try self.bridge.activeOperation().checkCancellation()
            let result = try AccountSession(plist: clientData { aauth_account_session_plist(session, $0) })
            let saved = try result.serialize(encryptionKey: self.encryptionKey)
            try saved.withUnsafeBytes { bytes in
                try checkClient(aauth_client_set_session_data(self.handle, AAUTH_SESSION_ACCOUNT,
                    bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count))
            }
            return result
        }
    }

    /// Snapshot identity, ADI, Store provisioning and automatically saved account bytes.
    /// Uses this device's optional encryption key; callbacks and HTTP caches are not saved.
    public func serializeState() async throws -> Data {
        try await perform {
            let data = try clientData { aauth_client_state(self.handle, $0) }
            return try SessionCrypto.encode(data, key: self.encryptionKey)
        }
    }

    public func loadSession() async throws -> AccountSession? {
        try await perform {
            let data = try clientData { aauth_client_session_data(self.handle, AAUTH_SESSION_ACCOUNT, $0) }
            guard !data.isEmpty else { return nil }
            return try AccountSession.deserialize(data, encryptionKey: self.encryptionKey)
        }
    }

    public func developerSession(account: AccountSession) async throws -> DeveloperSession {
        try await perform {
            try withAccount(account.plist) { session in
                try JSONDecoder().decode(DeveloperSession.self,
                    from: clientData { aauth_client_developer_session(self.handle, session, $0) })
            }
        }
    }

    public func loginStoreWithPET(email: String, account: AccountSession) async throws -> StoreSession {
        guard !email.contains("\0") else { throw AppleAuthError("Apple ID contains a NUL character") }
        return try await perform {
            try withAccount(account.plist) { accountHandle in
                var result: OpaquePointer?
                try checkClient(aauth_client_store_login_with_pet(self.handle, email, accountHandle, &result))
                guard let result else { throw AppleAuthError("Store login returned no session") }
                defer { aauth_store_session_free(result) }
                return try StoreSession(plist: clientData { aauth_store_session_plist(result, $0) })
            }
        }
    }

    public func developerHeaders(session: DeveloperSession) async throws -> [String: String] {
        guard !session.accountID.contains("\0"), !session.token.contains("\0") else {
            throw AppleAuthError("Invalid Developer Session")
        }
        return try await perform {
            try JSONDecoder().decode([String: String].self, from: clientData {
                aauth_client_developer_headers(self.handle, session.accountID, session.token,
                                                session.expiresAtMilliseconds, $0)
            })
        }
    }
}
