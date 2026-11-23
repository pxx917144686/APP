import ZsignSwift
import Foundation
import Security
import CryptoKit

struct SigningCertificate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var originalFileName: String
    var fileName: String
    var commonName: String
    var teamID: String
    var expiresAt: Date?
    var serialNumber: String?
    var fingerprint: String?
    var issuer: String?
    var subject: String?
    var notBefore: Date?
    var importedAt: Date
}

struct ProfileCertificate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var commonName: String
    var teamID: String
    var serialNumber: String?
    var fingerprint: String?
    var issuer: String?
    var subject: String
    var notBefore: Date?
    var notAfter: Date?
}

struct SigningProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var originalFileName: String
    var fileName: String
    var applicationIdentifier: String
    var bundleIDPattern: String
    var teamID: String
    var teamName: String
    var expiresAt: Date?
    var deviceCount: Int
    var isEnterprise: Bool
    var provisionsAllDevices: Bool?
    var provisionedDevices: [String]?
    var platforms: [String]
    var certificates: [ProfileCertificate]?
    var entitlementsData: Data?
    var entitlementKeys: [String]?
    var entitlementDescriptions: [String: String]?
    var importedAt: Date

    var isWildcard: Bool { bundleIDPattern.contains("*") }

    func covers(bundleID: String) -> Bool {
        let pattern = bundleIDPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return false }
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") {
            return bundleID.hasPrefix(String(pattern.dropLast()))
        }
        return pattern == bundleID
    }
}

enum SigningStoreError: LocalizedError {
    case badPassword
    case invalidCertificate
    case invalidProfile
    case emptyFile
    case fileWriteFailed

    var errorDescription: String? {
        switch self {
        case .badPassword: return "sign_err_bad_password".localized
        case .invalidCertificate: return "sign_err_invalid_cert".localized
        case .invalidProfile: return "sign_err_invalid_profile".localized
        case .emptyFile: return "sign_err_empty_file".localized
        case .fileWriteFailed: return "sign_err_write_failed".localized
        }
    }
}

private enum SigningKeychain {
    private static let service = "com.pxx917144686.App.signing"

    static func set(_ password: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class SigningStore: ObservableObject {
    static let shared = SigningStore()

    @Published private(set) var certificates: [SigningCertificate] = []
    @Published private(set) var profiles: [SigningProfile] = []
    @Published var selectedCertificateID: UUID?
    @Published var selectedProfileID: UUID?

    private let rootURL: URL
    private let certificatesDirectory: URL
    private let profilesDirectory: URL
    private let secretsDirectory: URL
    let importedIPADirectory: URL
    let injectionDirectory: URL
    let signedOutputDirectory: URL

    private let selectedCertificateKey = "signing_selected_certificate"
    private let selectedProfileKey = "signing_selected_profile"

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = documents.appendingPathComponent("Signing", isDirectory: true)
        certificatesDirectory = rootURL.appendingPathComponent("Certificates", isDirectory: true)
        profilesDirectory = rootURL.appendingPathComponent("Profiles", isDirectory: true)
        secretsDirectory = applicationSupport
            .appendingPathComponent("Signing", isDirectory: true)
            .appendingPathComponent("Secrets", isDirectory: true)
        importedIPADirectory = rootURL.appendingPathComponent("IPAs", isDirectory: true)
        injectionDirectory = rootURL.appendingPathComponent("Injections", isDirectory: true)
        signedOutputDirectory = rootURL.appendingPathComponent("Signed", isDirectory: true)

        for directory in [rootURL, certificatesDirectory, profilesDirectory, secretsDirectory, importedIPADirectory, injectionDirectory, signedOutputDirectory] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let legacySecrets = documents.appendingPathComponent("Signing/Secrets", isDirectory: true)
        if let items = try? FileManager.default.contentsOfDirectory(at: legacySecrets, includingPropertiesForKeys: nil) {
            for item in items {
                let target = secretsDirectory.appendingPathComponent(item.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.removeItem(at: item)
                } else {
                    try? FileManager.default.moveItem(at: item, to: target)
                }
                try? FileManager.default.setAttributes([FileAttributeKey(rawValue: "NSFileProtection"): FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            }
            try? FileManager.default.removeItem(at: legacySecrets)
        }

        load()
    }

    var selectedCertificate: SigningCertificate? {
        certificates.first(where: { $0.id == selectedCertificateID })
    }

    var selectedProfile: SigningProfile? {
        profiles.first(where: { $0.id == selectedProfileID })
    }

    func certificateURL(for certificate: SigningCertificate) -> URL {
        certificatesDirectory.appendingPathComponent(certificate.fileName)
    }

    func profileURL(for profile: SigningProfile) -> URL {
        profilesDirectory.appendingPathComponent(profile.fileName)
    }

    func password(for certificate: SigningCertificate) -> String? {
        if let value = SigningKeychain.password(account: certificate.id.uuidString) {
            return value
        }
        let fallback = secretsDirectory.appendingPathComponent("\(certificate.id.uuidString).txt")
        return try? String(contentsOf: fallback, encoding: .utf8)
    }

    func importCertificate(data: Data, originalFileName: String, password: String, displayName: String) throws -> SigningCertificate {
        guard !data.isEmpty else { throw SigningStoreError.emptyFile }
        let metadata: SigningParser.CertificateMetadata
        do {
            metadata = try SigningParser.certificate(data: data, password: password)
        } catch {
            throw error
        }
        let fallbackName = (originalFileName as NSString).deletingPathExtension
        let resolvedCommonName = metadata.commonName.isEmpty ? fallbackName : metadata.commonName
        let id = UUID()
        let fileName = "\(id.uuidString).p12"
        let destination = certificatesDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw SigningStoreError.fileWriteFailed
        }

        let certificate = SigningCertificate(
            id: id,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? resolvedCommonName : displayName,
            originalFileName: originalFileName,
            fileName: fileName,
            commonName: resolvedCommonName,
            teamID: metadata.teamID,
            expiresAt: metadata.expiresAt,
            serialNumber: metadata.serialNumber,
            fingerprint: metadata.fingerprint,
            issuer: metadata.issuer,
            subject: metadata.subject,
            notBefore: metadata.notBefore,
            importedAt: Date()
        )
        if !SigningKeychain.set(password, account: id.uuidString) {
            let fallback = secretsDirectory.appendingPathComponent("\(id.uuidString).txt")
            try? password.write(to: fallback, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([FileAttributeKey(rawValue: "NSFileProtection"): FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fallback.path)
        }
        certificates.append(certificate)
        selectedCertificateID = id
        pairProfileToCertificate()
        save()
        return certificate
    }

    func importProfile(data: Data, originalFileName: String) throws -> SigningProfile {
        guard !data.isEmpty else { throw SigningStoreError.emptyFile }
        let metadata = try SigningParser.profile(data: data)
        let id = UUID()
        let fileName = "\(id.uuidString).mobileprovision"
        let destination = profilesDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw SigningStoreError.fileWriteFailed
        }

        let profile = SigningProfile(
            id: id,
            displayName: metadata.name,
            originalFileName: originalFileName,
            fileName: fileName,
            applicationIdentifier: metadata.applicationIdentifier,
            bundleIDPattern: metadata.bundleIDPattern,
            teamID: metadata.teamID,
            teamName: metadata.teamName,
            expiresAt: metadata.expiresAt,
            deviceCount: metadata.deviceCount,
            isEnterprise: metadata.isEnterprise,
            provisionsAllDevices: metadata.provisionsAllDevices,
            provisionedDevices: metadata.provisionedDevices,
            platforms: metadata.platforms,
            certificates: metadata.certificates,
            entitlementsData: metadata.entitlementsData,
            entitlementKeys: metadata.entitlementKeys,
            entitlementDescriptions: metadata.entitlementDescriptions,
            importedAt: Date()
        )
        profiles.append(profile)
        selectedProfileID = id
        pairCertificateToProfile()
        save()
        return profile
    }

    func importIPABackground(from source: URL) async throws -> URL {
        let fileName = source.lastPathComponent.isEmpty ? UUID().uuidString + ".ipa" : source.lastPathComponent
        let destination = importedIPADirectory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
        let needsScope = source.startAccessingSecurityScopedResource()
        return try await Task.detached(priority: .utility) {
            defer { if needsScope { source.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            } catch {
                throw SigningStoreError.fileWriteFailed
            }
        }.value
    }

    func importIPA(from source: URL) throws -> URL {
        let fileName = source.lastPathComponent.isEmpty ? UUID().uuidString + ".ipa" : source.lastPathComponent
        let destination = importedIPADirectory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
        let needsScope = source.startAccessingSecurityScopedResource()
        defer { if needsScope { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw SigningStoreError.fileWriteFailed
        }
        return destination
    }

    func bestProfile(for bundleID: String, certificate: SigningCertificate?) -> SigningProfile? {
        let now = Date()
        let candidates = profiles.filter { profile in
            guard profile.expiresAt == nil || profile.expiresAt! > now else { return false }
            guard profile.covers(bundleID: bundleID) else { return false }
            if let certificate, !certificate.teamID.isEmpty, !profile.teamID.isEmpty,
               certificate.teamID != profile.teamID {
                return false
            }
            if let certificate,
               let certificates = profile.certificates,
               !certificates.isEmpty,
               let rawFingerprint = certificate.fingerprint,
               !rawFingerprint.isEmpty {
                let fingerprint = rawFingerprint.replacingOccurrences(of: ":", with: "").uppercased()
                let profileFingerprints = certificates.compactMap { $0.fingerprint?.replacingOccurrences(of: ":", with: "").uppercased() }
                if !profileFingerprints.isEmpty, !profileFingerprints.contains(fingerprint) {
                    return false
                }
            }
            return true
        }
        return candidates.sorted { lhs, rhs in
            let lhsExact = lhs.bundleIDPattern == bundleID
            let rhsExact = rhs.bundleIDPattern == bundleID
            if lhsExact != rhsExact { return lhsExact }
            return (lhs.expiresAt ?? .distantFuture) > (rhs.expiresAt ?? .distantFuture)
        }.first
    }

    @discardableResult
    func selectBestProfile(for bundleID: String, certificate: SigningCertificate?) -> SigningProfile? {
        guard let best = bestProfile(for: bundleID, certificate: certificate) else { return nil }
        selectedProfileID = best.id
        if let certificate {
            selectedCertificateID = certificate.id
        } else if let match = certificates.first(where: { $0.teamID == best.teamID }) {
            selectedCertificateID = match.id
        }
        save()
        return best
    }

    func selectCertificate(_ id: UUID?) {
        selectedCertificateID = id
        pairProfileToCertificate()
        save()
    }

    func selectProfile(_ id: UUID?) {
        selectedProfileID = id
        pairCertificateToProfile()
        save()
    }

    private func pairProfileToCertificate() {
        guard let certificate = selectedCertificate else { return }
        if let profile = selectedProfile,
           !certificate.teamID.isEmpty,
           !profile.teamID.isEmpty,
           certificate.teamID == profile.teamID {
            return
        }
        guard !certificate.teamID.isEmpty else { return }
        if let match = profiles.first(where: { $0.teamID == certificate.teamID }) {
            selectedProfileID = match.id
        }
    }

    private func pairCertificateToProfile() {
        guard let profile = selectedProfile else { return }
        if let certificate = selectedCertificate,
           !certificate.teamID.isEmpty,
           certificate.teamID == profile.teamID {
            return
        }
        guard !profile.teamID.isEmpty else { return }
        if let match = certificates.first(where: { $0.teamID == profile.teamID }) {
            selectedCertificateID = match.id
        }
    }

    func importInjection(from source: URL, isFramework: Bool) throws -> URL {
        let destination = injectionDirectory.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw SigningStoreError.fileWriteFailed
        }
        return destination
    }

    func deleteCertificate(_ certificate: SigningCertificate) {
        try? FileManager.default.removeItem(at: certificateURL(for: certificate))
        SigningKeychain.delete(account: certificate.id.uuidString)
        try? FileManager.default.removeItem(at: secretsDirectory.appendingPathComponent("\(certificate.id.uuidString).txt"))
        certificates.removeAll { $0.id == certificate.id }
        if selectedCertificateID == certificate.id {
            selectedCertificateID = certificates.first?.id
        }
        save()
    }

    func deleteProfile(_ profile: SigningProfile) {
        try? FileManager.default.removeItem(at: profileURL(for: profile))
        profiles.removeAll { $0.id == profile.id }
        if selectedProfileID == profile.id {
            selectedProfileID = profiles.first?.id
        }
        save()
    }

    func newSignedOutputURL(for source: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let base = signedOutputDirectory.appendingPathComponent("\(stem)-signed.ipa")
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        let stamp = Int(Date().timeIntervalSince1970)
        return signedOutputDirectory.appendingPathComponent("\(stem)-signed-\(stamp).ipa")
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: rootURL.appendingPathComponent("certificates.json")),
           let decoded = try? decoder.decode([SigningCertificate].self, from: data) {
            certificates = decoded.filter { FileManager.default.fileExists(atPath: certificatesDirectory.appendingPathComponent($0.fileName).path) }
        }
        if let data = try? Data(contentsOf: rootURL.appendingPathComponent("profiles.json")),
           let decoded = try? decoder.decode([SigningProfile].self, from: data) {
            profiles = decoded.filter { FileManager.default.fileExists(atPath: profilesDirectory.appendingPathComponent($0.fileName).path) }
        }

        var enriched = false
        for index in profiles.indices {
            let item = profiles[index]
            guard item.certificates == nil || item.entitlementsData == nil || item.entitlementKeys == nil || item.provisionedDevices == nil else { continue }
            guard let data = try? Data(contentsOf: profilesDirectory.appendingPathComponent(item.fileName)),
                  let metadata = try? SigningParser.profile(data: data) else { continue }
            var updated = item
            updated.certificates = metadata.certificates
            updated.entitlementsData = metadata.entitlementsData
            updated.entitlementKeys = metadata.entitlementKeys
            updated.entitlementDescriptions = metadata.entitlementDescriptions
            updated.provisionsAllDevices = metadata.provisionsAllDevices
            updated.provisionedDevices = metadata.provisionedDevices
            profiles[index] = updated
            enriched = true
        }

        if let raw = UserDefaults.standard.string(forKey: selectedCertificateKey), let id = UUID(uuidString: raw) {
            selectedCertificateID = certificates.contains(where: { $0.id == id }) ? id : certificates.first?.id
        } else {
            selectedCertificateID = certificates.first?.id
        }
        if let raw = UserDefaults.standard.string(forKey: selectedProfileKey), let id = UUID(uuidString: raw) {
            selectedProfileID = profiles.contains(where: { $0.id == id }) ? id : profiles.first?.id
        } else {
            selectedProfileID = profiles.first?.id
        }
        if enriched { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(certificates) {
            try? data.write(to: rootURL.appendingPathComponent("certificates.json"), options: .atomic)
        }
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: rootURL.appendingPathComponent("profiles.json"), options: .atomic)
        }
        UserDefaults.standard.set(selectedCertificateID?.uuidString, forKey: selectedCertificateKey)
        UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: selectedProfileKey)
    }
}

enum SigningParser {
    struct CertificateMetadata {
        let commonName: String
        let teamID: String
        let expiresAt: Date?
        var notBefore: Date? = nil
        var serialNumber: String? = nil
        var fingerprint: String? = nil
        var issuer: String? = nil
        var subject: String? = nil
    }

    struct ProfileMetadata {
        let name: String
        let applicationIdentifier: String
        let bundleIDPattern: String
        let teamID: String
        let teamName: String
        let expiresAt: Date?
        let deviceCount: Int
        let isEnterprise: Bool
        var provisionsAllDevices: Bool = false
        var provisionedDevices: [String] = []
        let platforms: [String]
        var certificates: [ProfileCertificate] = []
        var entitlementsData: Data? = nil
        var entitlementKeys: [String] = []
        var entitlementDescriptions: [String: String] = [:]
    }

    static func certificate(data: Data, password: String) throws -> CertificateMetadata {
        CertImportLog.add("p12 \(data.count) bytes, password length \(password.count)")

        // 先走 OpenSSL：它同时支持老式 PBE-SHA1/3DES 和新式 PBES2 + AES-256，
        // 而苹果的 SecPKCS12Import 遇到后者只会返回 errSecDecode。
        let openssl = Zsign.certificateDERWithError(p12Data: data, password: password)
        var der = openssl.data
        let opensslResult = der == nil ? "nil (\(openssl.error))" : "\(der!.count) bytes"
        CertImportLog.add("openssl -> " + opensslResult)

        var status: OSStatus = errSecSuccess
        if der == nil {
            var items: CFArray?
            let options = [kSecImportExportPassphrase as String: password] as CFDictionary
            status = SecPKCS12Import(data as CFData, options, &items)
            CertImportLog.add("SecPKCS12Import -> \(status)")

            if status == errSecSuccess,
               let list = items as? [[String: Any]],
               let identityValue = list.first?[kSecImportItemIdentity as String] {
                let identity = identityValue as! SecIdentity
                var certificate: SecCertificate?
                if SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate {
                    der = SecCertificateCopyData(certificate) as Data
                }
            }
        }

        guard let der else {
            CertImportLog.add("both parsers failed")
            if status == errSecAuthFailed {
                throw SigningStoreError.badPassword
            }
            throw SigningStoreError.invalidCertificate
        }
        let parsed = SigningX509.parse(der)
        return CertificateMetadata(
            commonName: parsed.commonName ?? "Certificate",
            teamID: parsed.teamID ?? "",
            expiresAt: parsed.notAfter,
            notBefore: parsed.notBefore,
            serialNumber: parsed.serialNumber,
            fingerprint: parsed.fingerprint,
            issuer: parsed.issuer,
            subject: parsed.subject
        )
    }

    static func profile(data: Data) throws -> ProfileMetadata {
        guard let start = data.range(of: Data("<?xml".utf8)) ?? data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            throw SigningStoreError.invalidProfile
        }
        let xml = Data(data[start.lowerBound..<end.upperBound])
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else {
            throw SigningStoreError.invalidProfile
        }

        let name = (plist["Name"] as? String) ?? "Provisioning Profile"
        let teamNames = plist["TeamIdentifier"] as? [String] ?? []
        let teamName = (plist["TeamName"] as? String) ?? ""
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let applicationIdentifier = (entitlements["application-identifier"] as? String) ?? ""
        let bundleIDPattern: String
        if let dot = applicationIdentifier.firstIndex(of: ".") {
            bundleIDPattern = String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
        } else {
            bundleIDPattern = applicationIdentifier
        }
        let devices = plist["ProvisionedDevices"] as? [String] ?? []
        let provisionsAllDevices = (plist["ProvisionsAllDevices"] as? Bool) ?? false
        let isEnterprise = provisionsAllDevices
        let platforms = plist["Platform"] as? [String] ?? []
        let expiresAt = plist["ExpirationDate"] as? Date
        let developerCertificates = (plist["DeveloperCertificates"] as? [Data] ?? []).map { der -> ProfileCertificate in
            let parsed = SigningX509.parse(der)
            return ProfileCertificate(
                id: UUID(),
                commonName: parsed.commonName ?? "Certificate",
                teamID: parsed.teamID ?? "",
                serialNumber: parsed.serialNumber,
                fingerprint: parsed.fingerprint,
                issuer: parsed.issuer,
                subject: parsed.subject,
                notBefore: parsed.notBefore,
                notAfter: parsed.notAfter
            )
        }
        let entitlementsData = try? PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        let entitlementKeys = entitlements.keys.sorted()
        var entitlementDescriptions: [String: String] = [:]
        for (key, value) in entitlements {
            entitlementDescriptions[key] = describeValue(value)
        }

        return ProfileMetadata(
            name: name,
            applicationIdentifier: applicationIdentifier,
            bundleIDPattern: bundleIDPattern,
            teamID: teamNames.first ?? "",
            teamName: teamName,
            expiresAt: expiresAt,
            deviceCount: devices.count,
            isEnterprise: isEnterprise,
            provisionsAllDevices: provisionsAllDevices,
            provisionedDevices: devices,
            platforms: platforms,
            certificates: developerCertificates,
            entitlementsData: entitlementsData,
            entitlementKeys: entitlementKeys,
            entitlementDescriptions: entitlementDescriptions
        )
    }

    private static func describeValue(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [Any] {
            let parts = array.prefix(4).map { describeValue($0) }
            let suffix = array.count > 4 ? ", …" : ""
            return "[" + parts.joined(separator: ", ") + suffix + "]"
        }
        if let dict = value as? [String: Any] {
            let parts = dict.keys.sorted().prefix(4).map { key in
                "\(key): \(describeValue(dict[key]!))"
            }
            let suffix = dict.count > 4 ? ", …" : ""
            return "{" + parts.joined(separator: ", ") + suffix + "}"
        }
        if let data = value as? Data { return "<\(data.count) bytes>" }
        return String(describing: value)
    }

    private static func dateValue(_ raw: Any?) -> Date? {
        if let date = raw as? Date { return date }
        if let number = raw as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        if let string = raw as? String {
            let iso = ISO8601DateFormatter()
            return iso.date(from: string)
        }
        return nil
    }
}

private enum SigningX509 {
    struct Parsed {
        let commonName: String?
        let organization: String?
        let teamID: String?
        let issuerCommonName: String?
        let issuerOrganization: String?
        let serialNumber: String?
        let notBefore: Date?
        let notAfter: Date?
        let fingerprint: String
        let subject: String
        let issuer: String
    }

    private struct Node {
        let tag: UInt8
        let contentStart: Int
        let contentLength: Int
        var end: Int { contentStart + contentLength }
    }

    private struct NameInfo {
        var commonName: String?
        var organization: String?
        var organizationalUnit: String?

        var text: String {
            var parts: [String] = []
            if let commonName { parts.append("CN=\(commonName)") }
            if let organizationalUnit { parts.append("OU=\(organizationalUnit)") }
            if let organization { parts.append("O=\(organization)") }
            return parts.joined(separator: ", ")
        }
    }

    static func parse(_ data: Data) -> Parsed {
        let fingerprint = sha256(data)
        let empty = Parsed(
            commonName: nil,
            organization: nil,
            teamID: nil,
            issuerCommonName: nil,
            issuerOrganization: nil,
            serialNumber: nil,
            notBefore: nil,
            notAfter: nil,
            fingerprint: fingerprint,
            subject: "",
            issuer: ""
        )

        guard let outer = node(data, 0), outer.tag == 0x30,
              let tbs = node(data, outer.contentStart), tbs.tag == 0x30,
              let children = optionalChildren(data, tbs) else {
            return empty
        }

        var index = 0
        if children.first?.tag == 0xA0 { index = 1 }
        guard children.count > index + 4 else { return empty }

        let serialNode = children[index]
        let issuerNode = children[index + 2]
        let validityNode = children[index + 3]
        let subjectNode = children[index + 4]

        let serial = hex(data[serialNode.contentStart..<serialNode.end])
        let times = optionalChildren(data, validityNode) ?? []
        let notBefore = times.count > 0 ? timeValue(data, times[0]) : nil
        let notAfter = times.count > 1 ? timeValue(data, times[1]) : nil
        let subject = nameInfo(data, subjectNode)
        let issuer = nameInfo(data, issuerNode)

        return Parsed(
            commonName: subject.commonName,
            organization: subject.organization,
            teamID: subject.organizationalUnit,
            issuerCommonName: issuer.commonName,
            issuerOrganization: issuer.organization,
            serialNumber: serial,
            notBefore: notBefore,
            notAfter: notAfter,
            fingerprint: fingerprint,
            subject: subject.text,
            issuer: issuer.text
        )
    }

    private static func nameInfo(_ data: Data, _ node: Node) -> NameInfo {
        var info = NameInfo()
        guard let rdns = optionalChildren(data, node) else { return info }
        for rdn in rdns {
            guard let attributes = optionalChildren(data, rdn) else { continue }
            for attribute in attributes {
                guard let parts = optionalChildren(data, attribute), parts.count >= 2, parts[0].tag == 0x06 else { continue }
                let oid = data[parts[0].contentStart..<parts[0].end]
                guard let value = stringValue(data, parts[1]) else { continue }
                if oid.elementsEqual([0x55, 0x04, 0x03]) {
                    info.commonName = value
                } else if oid.elementsEqual([0x55, 0x04, 0x0A]) {
                    info.organization = value
                } else if oid.elementsEqual([0x55, 0x04, 0x0B]) {
                    info.organizationalUnit = value
                }
            }
        }
        return info
    }

    private static func node(_ data: Data, _ offset: Int) -> Node? {
        guard offset + 2 <= data.count else { return nil }
        let tag = data[offset]
        let first = data[offset + 1]
        var headerLength = 2
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, offset + 2 + count <= data.count else { return nil }
            headerLength = 2 + count
            for i in 0..<count {
                length = (length << 8) | Int(data[offset + 2 + i])
            }
        }
        let contentStart = offset + headerLength
        guard length >= 0, contentStart + length <= data.count else { return nil }
        return Node(tag: tag, contentStart: contentStart, contentLength: length)
    }

    private static func optionalChildren(_ data: Data, _ parent: Node) -> [Node]? {
        guard parent.contentLength > 0 else { return [] }
        var result: [Node] = []
        var offset = parent.contentStart
        while offset < parent.end {
            guard let child = node(data, offset), child.end > offset else { return nil }
            result.append(child)
            offset = child.end
        }
        return result
    }

    private static func stringValue(_ data: Data, _ node: Node) -> String? {
        let value = data[node.contentStart..<node.end]
        switch node.tag {
        case 0x0C:
            return String(data: value, encoding: .utf8)
        case 0x13, 0x16:
            return String(data: value, encoding: .ascii)
        case 0x14, 0x1E:
            return String(data: value, encoding: .isoLatin1)
        default:
            return String(data: value, encoding: .utf8) ?? String(data: value, encoding: .ascii)
        }
    }

    private static func timeValue(_ data: Data, _ node: Node) -> Date? {
        guard let raw = String(data: data[node.contentStart..<node.end], encoding: .ascii) else { return nil }
        let value = raw.hasSuffix("Z") ? String(raw.dropLast()) : raw
        guard value.count == 12 || value.count == 14 || value.count == 10 else { return nil }
        let isGeneralized = node.tag == 0x18
        let year: Int
        let rest: Substring
        if isGeneralized {
            guard value.count >= 14, let parsed = Int(value.prefix(4)) else { return nil }
            year = parsed
            rest = value.dropFirst(4)
        } else {
            guard value.count >= 10, let parsed = Int(value.prefix(2)) else { return nil }
            year = parsed < 50 ? 2000 + parsed : 1900 + parsed
            rest = value.dropFirst(2)
        }
        guard rest.count >= 8 else { return nil }
        let chars = Array(rest)
        guard let month = Int(String(chars[0...1])),
              let day = Int(String(chars[2...3])),
              let hour = Int(String(chars[4...5])),
              let minute = Int(String(chars[6...7])) else { return nil }
        let second = chars.count >= 10 ? Int(String(chars[8...9])) ?? 0 : 0
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
