import Foundation
import apple_auth

public struct AppleAuthError: Error, LocalizedError, Sendable {
    public let code: Int32
    public let message: String
    public var errorDescription: String? { message }

    internal init(_ message: String, code: Int32 = -1) {
        self.message = message
        self.code = code
    }
}

internal func checkCore(_ status: aauth_status) throws {
    if status != AAUTH_OK {
        throw AppleAuthError(String(cString: aauth_last_error()), code: Int32(status.rawValue))
    }
}

internal func checkClient(_ status: aauth_status) throws {
    if status != AAUTH_OK {
        throw AppleAuthError(String(cString: aauth_client_last_error()), code: Int32(status.rawValue))
    }
}

internal func clientData(_ body: (UnsafeMutablePointer<aauth_client_buffer>) -> aauth_status) throws -> Data {
    var buffer = aauth_client_buffer(data: nil, size: 0)
    defer { aauth_client_buffer_free(&buffer) }
    try checkClient(body(&buffer))
    guard let bytes = buffer.data else { return Data() }
    return Data(bytes: bytes, count: buffer.size)
}

internal func withAccount<Value>(_ plist: Data, _ body: (OpaquePointer) throws -> Value) throws -> Value {
    var handle: OpaquePointer?
    try plist.withUnsafeBytes { raw in
        try checkClient(aauth_account_session_from_plist(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &handle))
    }
    guard let handle else { throw AppleAuthError("Account session returned no handle") }
    defer { aauth_account_session_free(handle) }
    return try body(handle)
}

private func coreData(_ body: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>) -> aauth_status) throws -> Data {
    var count = 0
    try checkCore(body(nil, 0, &count))
    var output = Data(count: count)
    try output.withUnsafeMutableBytes { raw in
        try checkCore(body(raw.bindMemory(to: UInt8.self).baseAddress, count, &count))
    }
    return output.prefix(count)
}

public final class SRPHandshake {
    public enum PasswordProtocol: String, Sendable { case s2k, s2k_fo }
    private let handle: OpaquePointer

    public convenience init() throws { try self.init(secret: Data()) }

    internal init(secret: Data) throws {
        var value: OpaquePointer?
        try secret.withUnsafeBytes { raw in
            try checkCore(aauth_srp_create(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &value))
        }
        guard let value else { throw AppleAuthError("SRP initialization returned no session") }
        handle = value
    }

    deinit { aauth_srp_free(handle) }

    public var publicKey: Data {
        get throws { try coreData { aauth_srp_public_key(handle, $0, $1, $2) } }
    }

    public func complete(user: String, password: String, salt: Data, serverPublicKey: Data,
                         iterations: Int32, protocol method: PasswordProtocol) throws -> SRPProof {
        guard !user.contains("\0"), !password.contains("\0") else {
            throw AppleAuthError("Credentials must not contain a NUL character")
        }
        var value: OpaquePointer?
        try salt.withUnsafeBytes { saltBytes in
            try serverPublicKey.withUnsafeBytes { serverBytes in
                try checkCore(aauth_srp_complete(handle, user, password,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, saltBytes.count,
                    serverBytes.bindMemory(to: UInt8.self).baseAddress, serverBytes.count,
                    iterations, method.rawValue, &value))
            }
        }
        guard let value else { throw AppleAuthError("SRP challenge returned no proof") }
        return SRPProof(handle: value)
    }
}

public final class SRPProof {
    private let handle: OpaquePointer
    internal init(handle: OpaquePointer) { self.handle = handle }
    deinit { aauth_srp_proof_free(handle) }

    public var clientProof: Data {
        get throws { try coreData { aauth_srp_client_proof(handle, $0, $1, $2) } }
    }

    public func verify(serverProof: Data, decrypt encryptedSession: Data) throws -> Data {
        try serverProof.withUnsafeBytes { proof in
            try encryptedSession.withUnsafeBytes { encrypted in
                try coreData {
                    aauth_srp_verify_session(handle,
                        proof.bindMemory(to: UInt8.self).baseAddress, proof.count,
                        encrypted.bindMemory(to: UInt8.self).baseAddress, encrypted.count, $0, $1, $2)
                }
            }
        }
    }
}
