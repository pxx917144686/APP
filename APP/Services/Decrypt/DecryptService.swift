import Foundation
import Combine

struct MachOEncryptionInfo {
    let cpuType: UInt32
    let cryptid: UInt32
    let cryptSize: UInt32

    var isEncrypted: Bool { cryptid != 0 && cryptSize > 0 }
}

enum MachOScanner {
    private static let magic64: UInt32 = 0xFEEDFACF
    private static let magic32: UInt32 = 0xFEEDFACE
    private static let magicFat: UInt32 = 0xCAFEBABE
    private static let lcEncryptionInfo: UInt32 = 0x21
    private static let lcEncryptionInfo64: UInt32 = 0x2C

    private static let magicFat64: UInt32 = 0xBEBAFECA

    static func looksLikeMachO(_ header: Data) -> Bool {
        guard header.count >= 4 else { return false }
        let be = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.byteSwapped
        let le = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return be == magic64 || be == magic32 || be == magicFat || be == magicFat64 || le == magic64 || le == magic32
    }

    static func scan(fileURL: URL) -> [MachOEncryptionInfo] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count >= 8 else { return [] }

        let bigEndian = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.byteSwapped
        if bigEndian == magicFat || bigEndian == magicFat64 {
            return scanFat(handle: handle)
        }
        let littleEndian = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if littleEndian == magic64 || littleEndian == magic32 {
            if let info = parseThin(handle: handle, offset: 0, is64: littleEndian == magic64) {
                return [info]
            }
        }
        return []
    }

    private static func scanFat(handle: FileHandle) -> [MachOEncryptionInfo] {
        guard let countData = try? handle.read(upToCount: 4),
              countData.count == 4 else { return [] }
        let archCount = Int(countData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.byteSwapped)
        guard archCount > 0, archCount < 32 else { return [] }

        var offsets: [UInt64] = []
        for _ in 0..<archCount {
            guard let entry = try? handle.read(upToCount: 20), entry.count == 20 else { break }
            let offset = entry.withUnsafeBytes { raw -> UInt32 in
                raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).byteSwapped
            }
            offsets.append(UInt64(offset))
        }

        var results: [MachOEncryptionInfo] = []
        for offset in offsets {
            var is64Slice = true
            if (try? handle.seek(toOffset: offset)) != nil,
               let magicData = try? handle.read(upToCount: 4), magicData.count == 4 {
                let magic = magicData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.byteSwapped
                guard magic == magic64 || magic == magic32 else { continue }
                is64Slice = (magic == magic64)
            }
            if let info = parseThin(handle: handle, offset: offset, is64: is64Slice) {
                results.append(info)
            }
        }
        return results
    }

    private static func parseThin(handle: FileHandle, offset: UInt64, is64: Bool) -> MachOEncryptionInfo? {
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        let headerSize = is64 ? 32 : 28
        guard let header = try? handle.read(upToCount: headerSize), header.count == headerSize else { return nil }

        let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard magic == magic64 || magic == magic32 else { return nil }

        let cpuType = header.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        }
        let ncmds = header.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        }
        guard ncmds > 0, ncmds < 4096 else { return nil }

        var position = offset + UInt64(headerSize)
        for _ in 0..<ncmds {
            guard (try? handle.seek(toOffset: position)) != nil,
                  let cmdData = try? handle.read(upToCount: 8),
                  cmdData.count == 8 else { return nil }

            let cmd = cmdData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let cmdSize = cmdData.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            }
            guard cmdSize >= 8, cmdSize < 65536 else { return nil }

            if cmd == lcEncryptionInfo || cmd == lcEncryptionInfo64 {
                let extra = Int(cmdSize) - 8
                guard extra >= 12,
                      let body = try? handle.read(upToCount: extra),
                      body.count >= 12 else { return nil }
                let cryptSize = body.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                }
                let cryptid = body.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
                }
                return MachOEncryptionInfo(cpuType: cpuType, cryptid: cryptid, cryptSize: cryptSize)
            }

            position += UInt64(cmdSize)
        }
        return MachOEncryptionInfo(cpuType: cpuType, cryptid: 0, cryptSize: 0)
    }
}

enum DecryptStatus: String, Codable {
    case completed
    case pending
    case blocked
    case failed
}

struct DecryptRecord: Identifiable, Codable {
    let id: UUID
    let name: String
    var appName: String
    var bundleIdentifier: String
    var binaryCount: Int
    var encryptedCount: Int
    var status: DecryptStatus
    var message: String?
    var outputPath: String?
    var sourcePath: String?
    let createdAt: Date

    var isCompleted: Bool { status == .completed }
}

struct DecryptScanResult {
    let binaryCount: Int
    let encryptedCount: Int
    let appName: String
    let bundleIdentifier: String
}

@MainActor
final class DecryptStore: ObservableObject {
    static let shared = DecryptStore()

    @Published private(set) var records: [DecryptRecord] = []

    private let fileManager = FileManager.default

    var decryptedDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Decrypted", isDirectory: true)
    }

    private var indexURL: URL {
        decryptedDirectory.appendingPathComponent("index.json")
    }

    private init() {
        try? fileManager.createDirectory(at: decryptedDirectory, withIntermediateDirectories: true)
        load()
    }

    func upsert(_ record: DecryptRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        save()
    }

    func remove(id: UUID) {
        if let record = records.first(where: { $0.id == id }),
           let path = record.outputPath {
            try? fileManager.removeItem(atPath: path)
        }
        records.removeAll { $0.id == id }
        save()
    }

    func record(forIPAPath path: String) -> DecryptRecord? {
        records.first { $0.name == URL(fileURLWithPath: path).lastPathComponent && $0.isCompleted }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([DecryptRecord].self, from: data) else {
            return
        }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

enum DecryptService {
    static func scan(ipaPath: String) -> DecryptScanResult? {
        let manager = FileManager.default
        let ipaURL = URL(fileURLWithPath: ipaPath)
        let workDirectory = manager.temporaryDirectory
            .appendingPathComponent("dcscan-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: workDirectory) }
        try? manager.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        var errBuf = [CChar](repeating: 0, count: 512)
        let status = ipaURL.path.withCString { source in
            workDirectory.path.withCString { destination in
                fp_zip_unpack(source, destination, &errBuf, Int32(errBuf.count))
            }
        }
        guard status == 0 else { return nil }

        var binaries = 0
        var encrypted = 0
        var appName = ipaURL.deletingPathExtension().lastPathComponent
        var bundleIdentifier = ""

        if let payload = try? manager.contentsOfDirectory(atPath: workDirectory.appendingPathComponent("Payload").path),
           let appBundle = payload.first(where: { $0.hasSuffix(".app") }) {
            appName = String(appBundle.dropLast(4))
            let infoPath = workDirectory.appendingPathComponent("Payload/\(appBundle)/Info.plist").path
            if let info = NSDictionary(contentsOfFile: infoPath) {
                bundleIdentifier = info["CFBundleIdentifier"] as? String ?? ""
            }
        }

        guard let enumerator = manager.enumerator(
            at: workDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 4096 else { continue }
            guard let handle = try? FileHandle(forReadingFrom: file),
                  let head = try? handle.read(upToCount: 8) else { continue }
            try? handle.close()
            guard MachOScanner.looksLikeMachO(head) else { continue }
            binaries += 1
            if MachOScanner.scan(fileURL: file).contains(where: { $0.isEncrypted }) {
                encrypted += 1
            }
        }

        return DecryptScanResult(
            binaryCount: binaries,
            encryptedCount: encrypted,
            appName: appName,
            bundleIdentifier: bundleIdentifier
        )
    }

    static func analyze(ipaPath: String) async -> DecryptRecord {
        let fileManager = FileManager.default
        let ipaURL = URL(fileURLWithPath: ipaPath)
        var record = DecryptRecord(
            id: UUID(),
            name: ipaURL.lastPathComponent,
            appName: ipaURL.deletingPathExtension().lastPathComponent,
            bundleIdentifier: "",
            binaryCount: 0,
            encryptedCount: 0,
            status: .failed,
            message: nil,
            outputPath: nil,
            sourcePath: ipaPath,
            createdAt: Date()
        )

        guard fileManager.fileExists(atPath: ipaPath) else {
            record.message = "dc_err_missing".localized
            return record
        }

        record.status = .pending
        record.message = "dc_pending_hint".localized
        return record
    }

    static func decrypt(
        _ record: DecryptRecord,
        cancelToken: DecryptCancelToken? = nil,
        onEvent: (@Sendable (DecryptEvent) -> Void)? = nil
    ) async -> DecryptRecord {
        var updated = record
        guard let path = record.sourcePath else {
            updated.status = .failed
            updated.message = "dc_err_missing".localized
            return updated
        }

        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                try FairPlayDecryptor.decrypt(
                    ipaURL: URL(fileURLWithPath: path),
                    cancelToken: cancelToken,
                    onEvent: onEvent
                )
            }.value
            updated.status = .completed
            updated.outputPath = outcome.outputURL.path
            updated.binaryCount = outcome.decrypted + outcome.plain + outcome.failed
            updated.encryptedCount = outcome.decrypted
            updated.message = outcome.decrypted == 0
                ? "dc_done_plain".localized
                : "dc_done_detail".localized(outcome.decrypted, outcome.failed)
        } catch {
            updated.status = .failed
            updated.message = error.localizedDescription
        }
        return updated
    }

    static func decryptBatch(
        _ records: [DecryptRecord],
        onEvent: (@Sendable (DecryptEvent) -> Void)? = nil
    ) async -> [DecryptRecord] {
        var results: [DecryptRecord] = []
        for record in records {
            results.append(await decrypt(record, onEvent: onEvent))
        }
        return results
    }

    static func decryptFull(
        ipaPath: String,
        cancelToken: DecryptCancelToken? = nil,
        onEvent: (@Sendable (DecryptEvent) -> Void)? = nil
    ) async -> DecryptRecord {
        let fileManager = FileManager.default
        let ipaURL = URL(fileURLWithPath: ipaPath)
        var record = DecryptRecord(
            id: UUID(),
            name: ipaURL.lastPathComponent,
            appName: ipaURL.deletingPathExtension().lastPathComponent,
            bundleIdentifier: "",
            binaryCount: 0,
            encryptedCount: 0,
            status: .failed,
            message: nil,
            outputPath: nil,
            sourcePath: ipaPath,
            createdAt: Date()
        )
        guard fileManager.fileExists(atPath: ipaPath) else {
            record.message = "dc_err_missing".localized
            return record
        }
        return await decrypt(record, cancelToken: cancelToken, onEvent: onEvent)
    }
}
