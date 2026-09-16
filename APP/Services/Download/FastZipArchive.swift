import Foundation
import Compression

extension Data {
    func loadLEUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) |
               (UInt16(self[offset + 1]) << 8)
    }

    func loadLEUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) |
               (UInt32(self[offset + 1]) << 8) |
               (UInt32(self[offset + 2]) << 16) |
               (UInt32(self[offset + 3]) << 24)
    }
}

@objcMembers
final class FastZipArchive: NSObject, @unchecked Sendable {

    static let shared = FastZipArchive()

    private override init() {}

    func unzipFile(atPath path: String, toDestination destination: String) -> Bool {
        let fileManager = FileManager.default
        let destURL = URL(fileURLWithPath: destination)

        do {
            try fileManager.createDirectory(at: destURL, withIntermediateDirectories: true)

            guard let zipHandle = FileHandle(forReadingAtPath: path) else {

                return false
            }
            defer { zipHandle.closeFile() }

            let fileData = try Data(contentsOf: URL(fileURLWithPath: path))

            guard let eocd = Self.findEndOfCentralDirectoryImpl(in: fileData) else {

                return false
            }

            let entries = try Self.readCentralDirectoryImpl(from: fileData, eocd: eocd)

            let group = DispatchGroup()
            let queue = DispatchQueue(label: "com.fastzip.unzip", attributes: .concurrent)
            var hasError = false
            let errorLock = NSLock()

            for entry in entries {
                if hasError { break }

                queue.async(group: group) {
                    autoreleasepool {
                        do {
                            try self.extractEntry(
                                entry,
                                from: fileData,
                                to: destURL
                            )
                        } catch {
                            errorLock.lock()
                            hasError = true
                            errorLock.unlock()

                        }
                    }
                }
            }

            group.wait()

            return !hasError

        } catch {

            return false
        }
    }

    func createZipFile(atPath path: String, withContentsOfDirectory directory: String) -> Bool {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: directory)

        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {

            return false
        }

        var entries: [(path: String, url: URL)] = []
        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: sourceURL.path + "/", with: "")
            entries.append((relativePath, fileURL))
        }

        return createZipFile(atPath: path, withFiles: entries)
    }

    func createZipFile(atPath path: String, withFiles files: [(path: String, url: URL)]) -> Bool {
        var outputData = Data()
        var centralDirectory = Data()
        var offset: UInt64 = 0

        for (relativePath, fileURL) in files {
            let isDirectory = relativePath.hasSuffix("/")

            do {
                if isDirectory {
                    let (header, central) = try createLocalFileHeader(
                        filename: relativePath,
                        compressedSize: 0,
                        uncompressedSize: 0,
                        crc32: 0,
                        compressionMethod: 0,
                        offset: offset
                    )
                    outputData.append(header)
                    offset += UInt64(header.count)
                    centralDirectory.append(central)
                } else {
                    let fileData = try Data(contentsOf: fileURL)
                    let (compressedData, crc32) = compressData(data: fileData)

                    let (header, central) = try createLocalFileHeader(
                        filename: relativePath,
                        compressedSize: UInt64(compressedData.count),
                        uncompressedSize: UInt64(fileData.count),
                        crc32: crc32,
                        compressionMethod: 8,
                        offset: offset
                    )

                    outputData.append(header)
                    outputData.append(compressedData)
                    offset += UInt64(header.count + compressedData.count)
                    centralDirectory.append(central)
                }
            } catch {

                return false
            }
        }

        let centralDirOffset = offset
        let centralDirSize = UInt64(centralDirectory.count)
        outputData.append(centralDirectory)

        let eocd = createEndOfCentralDirectoryRecord(
            entryCount: UInt16(files.count),
            centralDirSize: centralDirSize,
            centralDirOffset: centralDirOffset
        )
        outputData.append(eocd)

        return FileManager.default.createFile(atPath: path, contents: outputData)
    }

    func addFiles(toZipAtPath zipPath: String, files: [(path: String, data: Data)]) -> Bool {
        let fileManager = FileManager.default
        let tempPath = zipPath + ".tmp"

        guard fileManager.fileExists(atPath: zipPath) else {

            return false
        }

        do {
            let sourceData = try Data(contentsOf: URL(fileURLWithPath: zipPath))

            guard let eocd = Self.findEndOfCentralDirectoryImpl(in: sourceData) else {

                return false
            }

            let existingEntries = try Self.readCentralDirectoryImpl(from: sourceData, eocd: eocd)

            var outputData = Data()
            var newCentralDir = Data()
            var currentOffset: UInt64 = 0

            for entry in existingEntries {
                let localData = try extractLocalFileData(
                    from: sourceData,
                    entry: entry
                )
                outputData.append(localData)

                let centralHeader = createCentralDirectoryHeader(
                    from: entry,
                    newOffset: currentOffset
                )
                newCentralDir.append(centralHeader)

                currentOffset += UInt64(localData.count)
            }

            for (filePath, fileData) in files {
                let (compressedData, crc32) = compressData(data: fileData)

                let (localHeader, centralHeader) = try createLocalFileHeader(
                    filename: filePath,
                    compressedSize: UInt64(compressedData.count),
                    uncompressedSize: UInt64(fileData.count),
                    crc32: crc32,
                    compressionMethod: 8,
                    offset: currentOffset
                )

                outputData.append(localHeader)
                outputData.append(compressedData)
                currentOffset += UInt64(localHeader.count + compressedData.count)

                newCentralDir.append(centralHeader)

            }

            let centralDirOffset = currentOffset
            let centralDirSize = UInt64(newCentralDir.count)

            outputData.append(newCentralDir)

            let totalEntries = UInt16(existingEntries.count + files.count)
            let eocdRecord = createEndOfCentralDirectoryRecord(
                entryCount: totalEntries,
                centralDirSize: centralDirSize,
                centralDirOffset: centralDirOffset
            )
            outputData.append(eocdRecord)

            try outputData.write(to: URL(fileURLWithPath: tempPath))

            try fileManager.removeItem(atPath: zipPath)
            try fileManager.moveItem(atPath: tempPath, toPath: zipPath)

            return true

        } catch {

            try? fileManager.removeItem(atPath: tempPath)
            return false
        }
    }

    private func compressData(data: Data) -> (Data, UInt32) {
        let crc = crc32(data: data)

        guard data.count > 1024 else {
            return (data, crc)
        }

        let sourceBuffer = [UInt8](data)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: data.count
        )
        defer { destinationBuffer.deallocate() }

        let compressedSize = compression_encode_buffer(
            destinationBuffer,
            data.count,
            sourceBuffer,
            data.count,
            nil,
            COMPRESSION_ZLIB
        )

        guard compressedSize > 0 && compressedSize < data.count else {
            return (data, crc)
        }

        let compressedData = Data(bytes: destinationBuffer, count: compressedSize)
        return (compressedData, crc)
    }

    private func decompressData(data: Data, expectedSize: Int) -> Data? {
        guard data.count > 0 && expectedSize > 0 else { return Data() }

        let sourceBuffer = [UInt8](data)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = compression_decode_buffer(
            destinationBuffer,
            expectedSize,
            sourceBuffer,
            data.count,
            nil,
            COMPRESSION_ZLIB
        )

        guard decompressedSize == expectedSize else {
            return nil
        }

        return Data(bytes: destinationBuffer, count: decompressedSize)
    }

    private func crc32(data: Data) -> UInt32 {
        return data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var crc: UInt32 = 0xFFFFFFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    if crc & 1 != 0 {
                        crc = (crc >> 1) ^ 0xEDB88320
                    } else {
                        crc >>= 1
                    }
                }
            }
            return ~crc
        }
    }

    struct CentralDirectoryEntry {
        let signature: UInt32
        let versionMadeBy: UInt16
        let versionNeeded: UInt16
        let flags: UInt16
        let compressionMethod: UInt16
        let lastModTime: UInt16
        let lastModDate: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let filenameLength: UInt16
        let extraFieldLength: UInt16
        let commentLength: UInt16
        let diskNumberStart: UInt16
        let internalAttrs: UInt16
        let externalAttrs: UInt32
        let localHeaderOffset: UInt32
        let filename: String
        let extraField: Data
        let comment: String
    }

    struct EndOfCentralDirectory {
        let signature: UInt32
        let diskNumber: UInt16
        let centralDirDisk: UInt16
        let entriesOnDisk: UInt16
        let totalEntries: UInt16
        let centralDirSize: UInt32
        let centralDirOffset: UInt32
        let commentLength: UInt16
        let fileOffset: Int
    }

    static func findEndOfCentralDirectory(in data: Data) -> EndOfCentralDirectory? {
        return findEndOfCentralDirectoryImpl(in: data)
    }

    static func readCentralDirectory(from data: Data, eocd: EndOfCentralDirectory) throws -> [CentralDirectoryEntry] {
        return try readCentralDirectoryImpl(from: data, eocd: eocd)
    }

    static func extractSingleEntry(
        from data: Data,
        entry: CentralDirectoryEntry
    ) throws -> Data {
        return try extractSingleEntryImpl(from: data, entry: entry)
    }

    private static func findEndOfCentralDirectoryImpl(in data: Data) -> EndOfCentralDirectory? {
        guard data.count >= 22 else { return nil }

        let searchLength = min(65535 + 22, data.count)
        let startSearch = data.count - searchLength

        for i in startSearch...(data.count - 22) {
            if data[i] == 0x50 && data[i+1] == 0x4B &&
               data[i+2] == 0x05 && data[i+3] == 0x06 {

                let diskNumber = data.loadLEUInt16(at: i + 4)
                let centralDirDisk = data.loadLEUInt16(at: i + 6)
                let entriesOnDisk = data.loadLEUInt16(at: i + 8)
                let totalEntries = data.loadLEUInt16(at: i + 10)
                let centralDirSize = data.loadLEUInt32(at: i + 12)
                let centralDirOffset = data.loadLEUInt32(at: i + 16)
                let commentLength = data.loadLEUInt16(at: i + 20)

                return EndOfCentralDirectory(
                    signature: 0x06054b50,
                    diskNumber: diskNumber,
                    centralDirDisk: centralDirDisk,
                    entriesOnDisk: entriesOnDisk,
                    totalEntries: totalEntries,
                    centralDirSize: centralDirSize,
                    centralDirOffset: centralDirOffset,
                    commentLength: commentLength,
                    fileOffset: i
                )
            }
        }

        return nil
    }

    private static func readCentralDirectoryImpl(from data: Data, eocd: EndOfCentralDirectory) throws -> [CentralDirectoryEntry] {
        var entries: [CentralDirectoryEntry] = []

        var offset = Int(eocd.centralDirOffset)
        let endOffset = offset + Int(eocd.centralDirSize)

        while offset < endOffset {
            guard offset + 46 <= data.count else { break }

            let signature = data.loadLEUInt32(at: offset)
            guard signature == 0x02014b50 else {
                offset += 1
                continue
            }

            let filenameLength = data.loadLEUInt16(at: offset + 28)
            let extraFieldLength = data.loadLEUInt16(at: offset + 30)
            let commentLength = data.loadLEUInt16(at: offset + 32)

            let entrySize = 46 + Int(filenameLength) + Int(extraFieldLength) + Int(commentLength)
            guard offset + entrySize <= data.count else { break }

            let versionMadeBy = data.loadLEUInt16(at: offset + 4)
            let versionNeeded = data.loadLEUInt16(at: offset + 6)
            let flags = data.loadLEUInt16(at: offset + 8)
            let compressionMethod = data.loadLEUInt16(at: offset + 10)
            let lastModTime = data.loadLEUInt16(at: offset + 12)
            let lastModDate = data.loadLEUInt16(at: offset + 14)
            let crc32 = data.loadLEUInt32(at: offset + 16)
            let compressedSize = data.loadLEUInt32(at: offset + 20)
            let uncompressedSize = data.loadLEUInt32(at: offset + 24)
            let diskNumberStart = data.loadLEUInt16(at: offset + 34)
            let internalAttrs = data.loadLEUInt16(at: offset + 36)
            let externalAttrs = data.loadLEUInt32(at: offset + 38)
            let localHeaderOffset = data.loadLEUInt32(at: offset + 42)

            let filenameStart = offset + 46
            let filenameData = data[filenameStart..<filenameStart+Int(filenameLength)]
            let filename = String(data: filenameData, encoding: .utf8) ?? ""

            let extraStart = filenameStart + Int(filenameLength)
            let extraField = data[extraStart..<extraStart+Int(extraFieldLength)]

            let commentStart = extraStart + Int(extraFieldLength)
            let commentData = data[commentStart..<commentStart+Int(commentLength)]
            let comment = String(data: commentData, encoding: .utf8) ?? ""

            let entry = CentralDirectoryEntry(
                signature: signature,
                versionMadeBy: versionMadeBy,
                versionNeeded: versionNeeded,
                flags: flags,
                compressionMethod: compressionMethod,
                lastModTime: lastModTime,
                lastModDate: lastModDate,
                crc32: crc32,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                filenameLength: filenameLength,
                extraFieldLength: extraFieldLength,
                commentLength: commentLength,
                diskNumberStart: diskNumberStart,
                internalAttrs: internalAttrs,
                externalAttrs: externalAttrs,
                localHeaderOffset: localHeaderOffset,
                filename: filename,
                extraField: extraField,
                comment: comment
            )

            entries.append(entry)
            offset += entrySize
        }

        return entries
    }

    private static func extractSingleEntryImpl(
        from data: Data,
        entry: CentralDirectoryEntry
    ) throws -> Data {
        let localHeaderOffset = Int(entry.localHeaderOffset)
        guard localHeaderOffset + 30 <= data.count else {
            throw NSError(domain: "FastZip", code: -10, userInfo: [NSLocalizedDescriptionKey: "本地文件头越界"])
        }

        let filenameLen = data.loadLEUInt16(at: localHeaderOffset + 26)
        let extraFieldLen = data.loadLEUInt16(at: localHeaderOffset + 28)

        let dataOffset = localHeaderOffset + 30 + Int(filenameLen) + Int(extraFieldLen)
        let compressedSize = Int(entry.compressedSize)

        guard dataOffset + compressedSize <= data.count else {
            throw NSError(domain: "FastZip", code: -11, userInfo: [NSLocalizedDescriptionKey: "压缩数据越界"])
        }

        let compressedData = data[dataOffset..<dataOffset+compressedSize]

        if entry.compressionMethod == 0 {
            return compressedData
        } else if entry.compressionMethod == 8 {
            let sourceBuffer = [UInt8](compressedData)
            let expectedSize = Int(entry.uncompressedSize)
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
            defer { destinationBuffer.deallocate() }

            let decompressedSize = compression_decode_buffer(
                destinationBuffer,
                expectedSize,
                sourceBuffer,
                compressedData.count,
                nil,
                COMPRESSION_ZLIB
            )

            guard decompressedSize == expectedSize else {
                throw NSError(domain: "FastZip", code: -12, userInfo: [NSLocalizedDescriptionKey: "解压失败"])
            }

            return Data(bytes: destinationBuffer, count: decompressedSize)
        } else {
            throw NSError(domain: "FastZip", code: -13, userInfo: [NSLocalizedDescriptionKey: "不支持的压缩方法"])
        }
    }

    private func extractEntry(
        _ entry: CentralDirectoryEntry,
        from data: Data,
        to destURL: URL
    ) throws {
        let fileManager = FileManager.default
        let destPath = destURL.appendingPathComponent(entry.filename)

        if entry.filename.hasSuffix("/") {
            try fileManager.createDirectory(at: destPath, withIntermediateDirectories: true)
            return
        }

        let dirPath = destPath.deletingLastPathComponent()
        try fileManager.createDirectory(at: dirPath, withIntermediateDirectories: true)

        let localHeaderOffset = Int(entry.localHeaderOffset)
        guard localHeaderOffset + 30 <= data.count else {
            throw NSError(domain: "FastZip", code: -1, userInfo: [NSLocalizedDescriptionKey: "本地文件头越界"])
        }

        let filenameLen = data.loadLEUInt16(at: localHeaderOffset + 26)
        let extraFieldLen = data.loadLEUInt16(at: localHeaderOffset + 28)

        let dataOffset = localHeaderOffset + 30 + Int(filenameLen) + Int(extraFieldLen)
        let compressedSize = Int(entry.compressedSize)

        guard dataOffset + compressedSize <= data.count else {
            throw NSError(domain: "FastZip", code: -2, userInfo: [NSLocalizedDescriptionKey: "压缩数据越界"])
        }

        let compressedData = data[dataOffset..<dataOffset+compressedSize]

        let decompressedData: Data

        if entry.compressionMethod == 0 {
            decompressedData = compressedData
        } else if entry.compressionMethod == 8 {
            guard let decompressed = decompressData(
                data: compressedData,
                expectedSize: Int(entry.uncompressedSize)
            ) else {
                throw NSError(domain: "FastZip", code: -3, userInfo: [NSLocalizedDescriptionKey: "解压失败: \(entry.filename)"])
            }
            decompressedData = decompressed
        } else {
            throw NSError(domain: "FastZip", code: -4, userInfo: [NSLocalizedDescriptionKey: "不支持的压缩方法: \(entry.compressionMethod)"])
        }

        try decompressedData.write(to: destPath)
    }

    private func extractLocalFileData(
        from data: Data,
        entry: CentralDirectoryEntry
    ) throws -> Data {
        let localHeaderOffset = Int(entry.localHeaderOffset)
        guard localHeaderOffset + 30 <= data.count else {
            throw NSError(domain: "FastZip", code: -5, userInfo: [NSLocalizedDescriptionKey: "本地文件头越界"])
        }

        let filenameLen = data.loadLEUInt16(at: localHeaderOffset + 26)
        let extraFieldLen = data.loadLEUInt16(at: localHeaderOffset + 28)

        let totalEntrySize = 30 + Int(filenameLen) + Int(extraFieldLen) + Int(entry.compressedSize)

        guard localHeaderOffset + totalEntrySize <= data.count else {
            throw NSError(domain: "FastZip", code: -6, userInfo: [NSLocalizedDescriptionKey: "文件条目越界"])
        }

        return data[localHeaderOffset..<localHeaderOffset+totalEntrySize]
    }

    private func createLocalFileHeader(
        filename: String,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        crc32: UInt32,
        compressionMethod: UInt16,
        offset: UInt64
    ) throws -> (localHeader: Data, centralHeader: Data) {
        guard let filenameData = filename.data(using: .utf8) else {
            throw NSError(domain: "FastZip", code: -7, userInfo: [NSLocalizedDescriptionKey: "文件名编码失败"])
        }

        var filenameLen = UInt16(filenameData.count)
        var extraFieldLen: UInt16 = 0

        var localHeader = Data()
        localHeader.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])

        var version: UInt16 = 20
        withUnsafeBytes(of: &version) { localHeader.append(contentsOf: $0) }

        var flags: UInt16 = 0
        withUnsafeBytes(of: &flags) { localHeader.append(contentsOf: $0) }

        var method = compressionMethod
        withUnsafeBytes(of: &method) { localHeader.append(contentsOf: $0) }

        var modTime: UInt16 = 0
        withUnsafeBytes(of: &modTime) { localHeader.append(contentsOf: $0) }

        var modDate: UInt16 = 0
        withUnsafeBytes(of: &modDate) { localHeader.append(contentsOf: $0) }

        withUnsafeBytes(of: crc32) { localHeader.append(contentsOf: $0) }

        var compSize = UInt32(truncatingIfNeeded: compressedSize)
        withUnsafeBytes(of: &compSize) { localHeader.append(contentsOf: $0) }

        var uncompSize = UInt32(truncatingIfNeeded: uncompressedSize)
        withUnsafeBytes(of: &uncompSize) { localHeader.append(contentsOf: $0) }

        withUnsafeBytes(of: &filenameLen) { localHeader.append(contentsOf: $0) }

        withUnsafeBytes(of: &extraFieldLen) { localHeader.append(contentsOf: $0) }

        localHeader.append(filenameData)

        var centralHeader = Data()
        centralHeader.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])

        var versionMade: UInt16 = 20
        withUnsafeBytes(of: &versionMade) { centralHeader.append(contentsOf: $0) }

        var versionNeed: UInt16 = 20
        withUnsafeBytes(of: &versionNeed) { centralHeader.append(contentsOf: $0) }

        withUnsafeBytes(of: &flags) { centralHeader.append(contentsOf: $0) }
        withUnsafeBytes(of: &method) { centralHeader.append(contentsOf: $0) }
        withUnsafeBytes(of: &modTime) { centralHeader.append(contentsOf: $0) }
        withUnsafeBytes(of: &modDate) { centralHeader.append(contentsOf: $0) }
        withUnsafeBytes(of: crc32) { centralHeader.append(contentsOf: $0) }
        withUnsafeBytes(of: &compSize) { centralHeader.append(contentsOf: $0) }
        withUnsafeBytes(of: &uncompSize) { centralHeader.append(contentsOf: $0) }
        withUnsafeBytes(of: &filenameLen) { centralHeader.append(contentsOf: $0) }
        withUnsafeBytes(of: &extraFieldLen) { centralHeader.append(contentsOf: $0) }

        var commentLen: UInt16 = 0
        withUnsafeBytes(of: &commentLen) { centralHeader.append(contentsOf: $0) }

        var diskStart: UInt16 = 0
        withUnsafeBytes(of: &diskStart) { centralHeader.append(contentsOf: $0) }

        var internalAttr: UInt16 = 0
        withUnsafeBytes(of: &internalAttr) { centralHeader.append(contentsOf: $0) }

        var externalAttr: UInt32 = 0
        withUnsafeBytes(of: &externalAttr) { centralHeader.append(contentsOf: $0) }

        var localOffset = UInt32(truncatingIfNeeded: offset)
        withUnsafeBytes(of: &localOffset) { centralHeader.append(contentsOf: $0) }

        centralHeader.append(filenameData)

        return (localHeader, centralHeader)
    }

    private func createCentralDirectoryHeader(
        from entry: CentralDirectoryEntry,
        newOffset: UInt64
    ) -> Data {
        var data = Data()
        data.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])

        var versionMade = entry.versionMadeBy
        withUnsafeBytes(of: &versionMade) { data.append(contentsOf: $0) }

        var versionNeed = entry.versionNeeded
        withUnsafeBytes(of: &versionNeed) { data.append(contentsOf: $0) }

        var flags = entry.flags
        withUnsafeBytes(of: &flags) { data.append(contentsOf: $0) }

        var method = entry.compressionMethod
        withUnsafeBytes(of: &method) { data.append(contentsOf: $0) }

        var modTime = entry.lastModTime
        withUnsafeBytes(of: &modTime) { data.append(contentsOf: $0) }

        var modDate = entry.lastModDate
        withUnsafeBytes(of: &modDate) { data.append(contentsOf: $0) }

        var crc = entry.crc32
        withUnsafeBytes(of: &crc) { data.append(contentsOf: $0) }

        var compSize = entry.compressedSize
        withUnsafeBytes(of: &compSize) { data.append(contentsOf: $0) }

        var uncompSize = entry.uncompressedSize
        withUnsafeBytes(of: &uncompSize) { data.append(contentsOf: $0) }

        var fnameLen = entry.filenameLength
        withUnsafeBytes(of: &fnameLen) { data.append(contentsOf: $0) }

        var extraLen = entry.extraFieldLength
        withUnsafeBytes(of: &extraLen) { data.append(contentsOf: $0) }

        var commLen = entry.commentLength
        withUnsafeBytes(of: &commLen) { data.append(contentsOf: $0) }

        var diskStart = entry.diskNumberStart
        withUnsafeBytes(of: &diskStart) { data.append(contentsOf: $0) }

        var intAttr = entry.internalAttrs
        withUnsafeBytes(of: &intAttr) { data.append(contentsOf: $0) }

        var extAttr = entry.externalAttrs
        withUnsafeBytes(of: &extAttr) { data.append(contentsOf: $0) }

        var localOffset = UInt32(truncatingIfNeeded: newOffset)
        withUnsafeBytes(of: &localOffset) { data.append(contentsOf: $0) }

        if let fnameData = entry.filename.data(using: .utf8) {
            data.append(fnameData)
        }
        data.append(entry.extraField)
        if let commData = entry.comment.data(using: .utf8) {
            data.append(commData)
        }

        return data
    }

    private func createEndOfCentralDirectoryRecord(
        entryCount: UInt16,
        centralDirSize: UInt64,
        centralDirOffset: UInt64
    ) -> Data {
        var data = Data()
        data.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])

        var diskNum: UInt16 = 0
        withUnsafeBytes(of: &diskNum) { data.append(contentsOf: $0) }

        var cdDisk: UInt16 = 0
        withUnsafeBytes(of: &cdDisk) { data.append(contentsOf: $0) }

        withUnsafeBytes(of: entryCount) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: entryCount) { data.append(contentsOf: $0) }

        var cdSize = UInt32(truncatingIfNeeded: centralDirSize)
        withUnsafeBytes(of: &cdSize) { data.append(contentsOf: $0) }

        var cdOffset = UInt32(truncatingIfNeeded: centralDirOffset)
        withUnsafeBytes(of: &cdOffset) { data.append(contentsOf: $0) }

        var commentLen: UInt16 = 0
        withUnsafeBytes(of: &commentLen) { data.append(contentsOf: $0) }

        return data
    }
}
