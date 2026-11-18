import Foundation
import Security

enum ToolError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

enum SecureKeyValueStore {
    private static let service = "ipadn.securestore"
    private static let lock = NSLock()

    static func setValue(_ value: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        guard let value, !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status != errSecSuccess && status != errSecDuplicateItem {
            UserDefaults.standard.set(value, forKey: fallbackKey(key))
        }
    }

    static func value(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var ref: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
           let data = ref as? Data, let value = String(data: data, encoding: .utf8) {
            return value
        }
        if let fallback = UserDefaults.standard.string(forKey: fallbackKey(key)) {
            return fallback
        }
        return nil
    }

    static func migrateFromDefaults(key: String, defaultsKey: String) {
        if let legacy = UserDefaults.standard.string(forKey: defaultsKey), !legacy.isEmpty {
            if value(forKey: key) == nil {
                setValue(legacy, forKey: key)
            }
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    private static func fallbackKey(_ key: String) -> String { "securestore_fallback_\(key)" }
}

func plistString(_ value: Any?) -> String {
    switch value {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    case let b as Bool: return b ? "1" : "0"
    case .none: return ""
    case .some(let v): return String(describing: v)
    }
}

struct HTTPStatusError: Error { let code: Int }

struct StoreProofRecord: Codable {
    var identifier: String
    var files: [String: String]
    var updatedAt: Date = Date()
}

enum StoreProofStore {
    private static let key = "ipadn.storeProofRecords"
    static func load() -> [String: StoreProofRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode([String: StoreProofRecord].self, from: data) else {
            return [:]
        }
        return value
    }
    static func save(_ value: [String: StoreProofRecord]) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum IPadnLogin {
    static func body(email: String, password: String, code: String, guid: String) throws -> Data {
        try HTTPClient.encodePlist([
            "appleId": email,
            "attempt": code.isEmpty ? "1" : "2",
            "guid": guid,
            "password": password + code,
            "rmp": "0",
            "why": "signIn"
        ])
    }

    static func phoneNumberStorefront(_ appleID: String) -> String? {
        var number = appleID.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        var international = false
        if number.hasPrefix("+") { international = true; number.removeFirst() }
        else if number.hasPrefix("00") { international = true; number.removeFirst(2) }
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let china = "143465", india = "143467"
        if number.count == 13 && number.hasPrefix("861") { return china }
        if number.count == 12 && number.hasPrefix("91") { number.removeFirst(2) }
        else if international { return nil }
        if number.count == 11 && number.hasPrefix("1") { return china }
        if !international && number.count == 11 && number.hasPrefix("0") { number.removeFirst() }
        if number.count == 10, let first = number.first, ("6"..."9").contains(first) { return india }
        return nil
    }

    static func failure(_ response: [String: Any], submittedCode: Bool) -> StoreError? {
        if let failure = HTTPClient.appleFailure(response) {
            return .authenticationFailedWithDetails(failure.errorDescription ?? "auth_err_signin_failed".localized)
        }
        let message = plistString(response["customerMessage"])
        if message == "MZFinance.BadLogin.Configurator_message" {
            return submittedCode ? .invalidVerificationCode : .codeRequired
        }
        if message.hasPrefix("AMD-Action") {
            return .authenticationFailedWithDetails("auth_err_device_verify_incomplete".localized)
        }
        if let info = response["accountInfo"] as? [String: Any], !plistString(info["appleId"]).isEmpty { return nil }
        if message.isEmpty, !plistString(response["passwordToken"]).isEmpty { return nil }
        if message.hasPrefix("MZ") {
            return .authenticationFailedWithDetails("auth_err_signin_unavailable".localized)
        }
        return .authenticationFailedWithDetails(message.isEmpty ? "auth_err_signin_no_info".localized : message)
    }
}
