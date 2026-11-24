import Foundation

struct SigningHistoryRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let inputName: String
    let outputName: String
    let bundleId: String
    let version: String
    let displayName: String
    let certificateName: String?
    let profileName: String?
    let profileExpiresAt: Date?
    let injectionNames: [String]
    var certificateID: UUID? = nil
    var profileID: UUID? = nil
    var sourceFileName: String? = nil
    var isHidden: Bool? = nil
}

@MainActor
final class SigningHistoryStore: ObservableObject {
    static let shared = SigningHistoryStore()

    @Published private(set) var records: [SigningHistoryRecord] = []

    private let signedDirectory: URL
    private let sourcesDirectory: URL
    private let store: VersionedStore<[SigningHistoryRecord]>

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let signingDirectory = documents.appendingPathComponent("Signing", isDirectory: true)
        signedDirectory = SigningStore.shared.signedOutputDirectory
        sourcesDirectory = signingDirectory.appendingPathComponent("RefreshSources", isDirectory: true)
        store = VersionedStore(
            fileURL: signingDirectory.appendingPathComponent("history.json"),
            currentVersion: 1
        )
        try? FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        load()
    }

    func refresh() {
        load()
    }

    func outputURL(for record: SigningHistoryRecord) -> URL {
        signedDirectory.appendingPathComponent(record.outputName)
    }

    func retainedSourceURL(for record: SigningHistoryRecord) -> URL? {
        guard let sourceFileName = record.sourceFileName, !sourceFileName.isEmpty else { return nil }
        let url = sourcesDirectory.appendingPathComponent(sourceFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func hasRetainedSource(for record: SigningHistoryRecord) -> Bool {
        retainedSourceURL(for: record) != nil
    }

    func fileExists(for record: SigningHistoryRecord) -> Bool {
        FileManager.default.fileExists(atPath: outputURL(for: record).path)
    }

    var totalBytes: Int64 {
        records.reduce(0) { partial, record in
            let path = outputURL(for: record).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return partial + size
        }
    }

    @discardableResult
    func append(
        inputName: String,
        outputName: String,
        bundleId: String,
        version: String,
        displayName: String,
        certificateName: String?,
        profileName: String?,
        profileExpiresAt: Date?,
        injectionNames: [String],
        certificateID: UUID? = nil,
        profileID: UUID? = nil
    ) -> SigningHistoryRecord {
        if let index = records.firstIndex(where: { $0.outputName == outputName }) {
            let stale = records.remove(at: index)
            if let source = retainedSourceURL(for: stale) {
                try? FileManager.default.removeItem(at: source)
            }
        }
        let record = SigningHistoryRecord(
            id: UUID(),
            date: Date(),
            inputName: inputName,
            outputName: outputName,
            bundleId: bundleId,
            version: version,
            displayName: displayName,
            certificateName: certificateName,
            profileName: profileName,
            profileExpiresAt: profileExpiresAt,
            injectionNames: injectionNames,
            certificateID: certificateID,
            profileID: profileID
        )
        records.insert(record, at: 0)
        save()
        return record
    }

    func setHidden(_ record: SigningHistoryRecord, hidden: Bool) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].isHidden = hidden
        save()
    }

    func delete(_ record: SigningHistoryRecord) -> Bool {
        let url = outputURL(for: record)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                return false
            }
        }
        if let source = retainedSourceURL(for: record) {
            try? FileManager.default.removeItem(at: source)
        }
        records.removeAll { $0.id == record.id }
        save()
        return true
    }

    func retainSource(from sourceURL: URL, for recordID: UUID) {
        let destination = sourcesDirectory.appendingPathComponent("\(recordID.uuidString).ipa")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            if let index = records.firstIndex(where: { $0.id == recordID }) {
                records[index].sourceFileName = destination.lastPathComponent
                save()
            }
            return
        }
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        Task.detached(priority: .utility) {
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            } catch {
                return
            }
            await MainActor.run {
                guard let index = self.records.firstIndex(where: { $0.id == recordID }) else { return }
                self.records[index].sourceFileName = destination.lastPathComponent
                self.save()
            }
        }
    }

    private func load() {
        var loaded: [SigningHistoryRecord] = []
        if let decoded = store.load() {
            loaded = decoded
        }

        let existingNames = Set(loaded.map(\.outputName))
        if let files = try? FileManager.default.contentsOfDirectory(
            at: signedDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in files where url.pathExtension.lowercased() == "ipa" {
                guard !existingNames.contains(url.lastPathComponent) else { continue }
                let info = try? SigningIPAInfo.read(url: url)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                loaded.append(
                    SigningHistoryRecord(
                        id: UUID(),
                        date: modified,
                        inputName: url.lastPathComponent,
                        outputName: url.lastPathComponent,
                        bundleId: info?.bundleIdentifier ?? "",
                        version: info?.version ?? "",
                        displayName: info?.displayName ?? url.deletingPathExtension().lastPathComponent,
                        certificateName: nil,
                        profileName: nil,
                        profileExpiresAt: nil,
                        injectionNames: [],
                    )
                )
            }
        }

        let sorted = loaded.sorted { $0.date > $1.date }
        let changed = sorted.count != loaded.count || sorted.map(\.outputName) != records.map(\.outputName)
        records = sorted
        if changed { save() }
    }

    private func save() {
        store.save(records)
    }
}
