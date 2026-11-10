import Foundation

enum ToolError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
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
