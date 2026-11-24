import Foundation

struct VersionedStoreMigration {
    let fromVersion: Int
    let apply: (Any) throws -> Any
}

@MainActor
final class VersionedStore<Payload: Codable> {
    let fileURL: URL
    let currentVersion: Int
    let backupURL: URL

    private let migrations: [Int: (Any) throws -> Any]
    private let legacyVersion: Int
    private let fileManager: FileManager
    private var isPrepared = false

    init(
        fileURL: URL,
        currentVersion: Int,
        legacyVersion: Int = 1,
        migrations: [VersionedStoreMigration] = [],
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.currentVersion = currentVersion
        self.legacyVersion = legacyVersion
        self.backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".bak")
        self.migrations = Dictionary(uniqueKeysWithValues: migrations.map { ($0.fromVersion, $0.apply) })
        self.fileManager = fileManager
    }

    func load() -> Payload? {
        prepareDirectory()
        if let payload = decode(fileAt: fileURL) {
            return payload
        }
        if let recovered = decode(fileAt: backupURL) {
            try? fileManager.removeItem(at: fileURL)
            try? fileManager.copyItem(at: backupURL, to: fileURL)
            protect(fileURL)
            return recovered
        }
        return nil
    }

    func save(_ payload: Payload) {
        prepareDirectory()
        guard let payloadData = try? JSONEncoder().encode(payload),
              let payloadObject = try? JSONSerialization.jsonObject(with: payloadData) else { return }
        let envelope: [String: Any] = [
            "schemaVersion": currentVersion,
            "payload": payloadObject
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.copyItem(at: fileURL, to: backupURL)
            protect(backupURL)
        }
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        protect(fileURL)
    }

    private func decode(fileAt url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var payloadObject: Any
        var version: Int
        if let envelope = raw as? [String: Any], let storedVersion = envelope["schemaVersion"] as? Int {
            payloadObject = envelope["payload"] ?? NSNull()
            version = storedVersion
        } else {
            payloadObject = raw
            version = legacyVersion
        }
        if version > currentVersion { return nil }
        while version < currentVersion {
            guard let migration = migrations[version] else { return nil }
            guard let migrated = try? migration(payloadObject) else { return nil }
            payloadObject = migrated
            version += 1
        }
        guard JSONSerialization.isValidJSONObject(payloadObject),
              let data = try? JSONSerialization.data(withJSONObject: payloadObject),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return payload
    }

    private func prepareDirectory() {
        guard !isPrepared else { return }
        isPrepared = true
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func protect(_ url: URL) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}
