import Foundation
import apple_auth

public enum DevicePlatform: Int32, Sendable { case automatic, windows, mac, iphone, android }
public enum VerificationMethod: Int32, Sendable { case automatic, trustedDevice, sms }

public struct TrustedPhoneNumber: Codable, Sendable, Equatable {
    public let id: Int64
    public let displayNumber: String
    enum CodingKeys: String, CodingKey { case id; case displayNumber = "display_number" }
}

public struct Verification: Sendable {
    public var method: VerificationMethod
    public var phoneNumberID: Int64
    public var selectPhone: (@Sendable ([TrustedPhoneNumber]) async throws -> Int64)?
    public var code: @Sendable () async throws -> String

    public init(method: VerificationMethod = .automatic, phoneNumberID: Int64 = 0,
                selectPhone: (@Sendable ([TrustedPhoneNumber]) async throws -> Int64)? = nil,
                code: @escaping @Sendable () async throws -> String) {
        self.method = method
        self.phoneNumberID = phoneNumberID
        self.selectPhone = selectPhone
        self.code = code
    }
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    public let platform: String
    public let model: String?
    public let osVersion: String?
    public let osBuild: String?
    public let serialNumber: String?
    enum CodingKeys: String, CodingKey {
        case platform, model
        case osVersion = "os_version", osBuild = "os_build", serialNumber = "serial_number"
    }
}

public struct AccountSession: Sendable, CustomStringConvertible {
    public let accountID: String
    public let passwordEquivalentToken: String
    public let plist: Data
    public var description: String { "AccountSession(accountID: \(accountID))" }

    public init(plist: Data) throws {
        guard plist.count <= 16 * 1024 * 1024,
              let fields = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let account = fields["adsid"] as? String,
              let tokens = fields["t"] as? [String: Any],
              let entry = tokens["com.apple.gs.idms.pet"] as? [String: Any],
              let token = entry["token"] as? String, !account.isEmpty, !token.isEmpty,
              (fields["status-code"] as? Int ?? 200) == 200 else {
            throw AppleAuthError("Invalid saved account session")
        }
        accountID = account
        passwordEquivalentToken = token
        self.plist = plist
    }

    public func save(to file: URL, encryptionKey: Data? = nil) throws {
        guard file.isFileURL, !file.path.contains("\0") else { throw AppleAuthError("Invalid session file path") }
        if let encryptionKey {
            try SessionCrypto.save(plist, to: file, key: encryptionKey)
            return
        }
        try withAccount(plist) { try checkClient(aauth_account_session_save($0, file.path)) }
    }
}

public struct DeveloperSession: Codable, Sendable, CustomStringConvertible {
    public let accountID: String
    public let token: String
    public let expiresAtMilliseconds: Int64
    public var expiration: Date? {
        expiresAtMilliseconds == 0 ? nil : Date(timeIntervalSince1970: Double(expiresAtMilliseconds) / 1000)
    }
    public var description: String { "DeveloperSession(accountID: \(accountID))" }
    enum CodingKeys: String, CodingKey {
        case accountID = "account_id", token, expiresAtMilliseconds = "expires_at_ms"
    }
}

public struct HTTPHeader: Sendable, Equatable {
    public let name: String
    public let value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let headers: [HTTPHeader]
    public init(status: Int, body: Data, headers: [HTTPHeader] = []) {
        self.status = status; self.body = body; self.headers = headers
    }
}

public typealias HTTPTransport = @Sendable (URLRequest) async throws -> HTTPResponse
