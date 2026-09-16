import Foundation
import CryptoKit

enum SessionFileStore {
    static let flowVersion = "appstore-sap-v2"
    static let ttlSeconds: TimeInterval = 365 * 24 * 60 * 60

    private struct Envelope: Codable {
        var flowVersion: String
        var savedAt: Double
        var accounts: [Account]
    }

    static var sessionsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "APP", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        return dir
    }

    static var fileURL: URL { sessionsDirectory.appendingPathComponent("accounts.json") }

    static func save(_ accounts: [Account]) {
        do {
            let fm = FileManager.default
            try? fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let env = Envelope(flowVersion: flowVersion, savedAt: Date().timeIntervalSince1970, accounts: accounts)
            let data = try JSONEncoder().encode(env)
            try data.write(to: fileURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
        }
    }

    static func load() -> [Account] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            guard env.flowVersion == flowVersion else {
                clear()
                return []
            }
            let age = Date().timeIntervalSince1970 - env.savedAt
            if age > ttlSeconds {
                clear()
                return []
            }
            return env.accounts
        } catch {
            clear()
            return []
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static let authFailureTypes: Set<String> = ["-5000", "1008", "2002", "2034", "2042"]

    static func isAuthFailure(failureType: String, customerMessage: String, httpStatus: Int = 200) -> Bool {
        if httpStatus == 401 || httpStatus == 403 { return true }
        if authFailureTypes.contains(failureType) { return true }
        let msg = customerMessage
        if msg.range(of: "Your password has changed\\.?", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if msg.range(of: "password token is expired", options: [.caseInsensitive, .regularExpression]) != nil { return true }
        return false
    }
}
