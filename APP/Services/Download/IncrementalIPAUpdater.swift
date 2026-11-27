import Foundation

final class IncrementalIPAUpdater {
    struct Entry: Equatable {
        let name: String
        let crc32: UInt32
        let compressedSize: UInt32
        let method: UInt16
        let flags: UInt16
        let localOffset: Int64
        let segmentLength: Int64
    }

    struct Directory {
        let entries: [Entry]
        let cdOffset: Int64
        let cdSize: Int64
        let tail: Data
        let tailStart: Int64
        let fileSize: Int64
    }

    struct Plan {
        let newSize: Int64
        let cdOffset: Int64
        let cdSize: Int64
        let tail: Data
        let tailStart: Int64
        let reuse: [(source: Int64, target: Int64, length: Int64)]
        let downloads: [(start: Int64, end: Int64)]
        let expected: [Entry]

        var downloadBytes: Int64 {
            downloads.reduce(Int64(0)) { $0 + ($1.end - $1.start + 1) }
        }

        var reusedBytes: Int64 {
            reuse.reduce(Int64(0)) { $0 + $1.length }
        }

        var savingRatio: Double {
            guard newSize > 0 else { return 0 }
            return 1 - Double(downloadBytes) / Double(newSize)
        }
    }

    enum UpdateError: LocalizedError {
        case baseUnavailable
        case archiveInvalid
        case rangeUnsupported
        case dataIncomplete
        case verifyFailed

        var errorDescription: String? {
            switch self {
            case .baseUnavailable: return "本地旧安装包不可用"
            case .archiveInvalid: return "安装包结构无法解析"
            case .rangeUnsupported: return "服务器不支持分段下载"
            case .dataIncomplete: return "增量数据不完整"
            case .verifyFailed: return "增量合并校验失败"
            }
        }
    }

    private static let probeSize: Int64 = 262_144
    private static let chunkSize = 1 << 20
    private static let sliceSize: Int64 = 4 << 20
    private static let mergeGap: Int64 = 131_072

    static func makePlan(
        baseURL: URL,
        newURL: URL,
        newSize: Int64,
        session: URLSession
    ) async throws -> Plan {
        guard newSize > 1024 else { throw UpdateError.archiveInvalid }
        let base = try readLocalDirectory(url: baseURL)
        guard base.entries.count > 0 else { throw UpdateError.baseUnavailable }
        let remote = try await readRemoteDirectory(url: newURL, fileSize: newSize, session: session)
        guard remote.entries.count > 0 else { throw UpdateError.archiveInvalid }

        var baseMap: [String: Entry] = [:]
        baseMap.reserveCapacity(base.entries.count)
        for entry in base.entries { baseMap[entry.name] = entry }

        var reuse: [(source: Int64, target: Int64, length: Int64)] = []
        var downloads: [(start: Int64, end: Int64)] = []
        for entry in remote.entries {
            if let old = baseMap[entry.name],
               old.crc32 == entry.crc32,
               old.compressedSize == entry.compressedSize,
               old.method == entry.method,
               old.flags == entry.flags,
               old.segmentLength == entry.segmentLength {
                reuse.append((old.localOffset, entry.localOffset, entry.segmentLength))
            } else {
                downloads.append((entry.localOffset, entry.localOffset + entry.segmentLength - 1))
            }
        }

        return Plan(
            newSize: remote.fileSize,
            cdOffset: remote.cdOffset,
            cdSize: remote.cdSize,
            tail: remote.tail,
            tailStart: remote.tailStart,
            reuse: reuse,
            downloads: mergeRanges(downloads),
            expected: remote.entries
        )
    }

    static func apply(
        plan: Plan,
        baseURL: URL,
        newURL: URL,
        targetURL: URL,
        session: URLSession,
        progress: @escaping (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: targetURL.path) {
            try? fm.removeItem(at: targetURL)
        }
        guard fm.createFile(atPath: targetURL.path, contents: nil) else {
            throw UpdateError.dataIncomplete
        }

        let output = try FileHandle(forWritingTo: targetURL)
        defer { try? output.close() }
        try output.truncate(atOffset: UInt64(plan.newSize))

        let base = try FileHandle(forReadingFrom: baseURL)
        defer { try? base.close() }

        for segment in plan.reuse {
            try Task.checkCancellation()
            try base.seek(toOffset: UInt64(segment.source))
            try output.seek(toOffset: UInt64(segment.target))
            var remaining = segment.length
            while remaining > 0 {
                let want = Int(min(Int64(chunkSize), remaining))
                guard let chunk = try base.read(upToCount: want), !chunk.isEmpty else {
                    throw UpdateError.dataIncomplete
                }
                try output.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
        }

        let totalDownload = max(plan.downloadBytes, 1)
        var done: Int64 = 0
        for range in plan.downloads {
            try Task.checkCancellation()
            var cursor = range.start
            while cursor <= range.end {
                try Task.checkCancellation()
                let sliceEnd = min(cursor + sliceSize - 1, range.end)
                let data = try await fetchRange(
                    url: newURL,
                    start: cursor,
                    end: sliceEnd,
                    session: session
                )
                try output.seek(toOffset: UInt64(cursor))
                try output.write(contentsOf: data)
                done += Int64(data.count)
                progress(min(0.99, Double(done) / Double(totalDownload)))
                cursor = sliceEnd + 1
            }
        }

        let cdStart = Int(plan.cdOffset - plan.tailStart)
        guard cdStart >= 0, cdStart <= plan.tail.count else {
            throw UpdateError.archiveInvalid
        }
        try output.seek(toOffset: UInt64(plan.cdOffset))
        try output.write(contentsOf: plan.tail.subdata(in: cdStart..<plan.tail.count))
        try output.synchronize()

        let merged = try readLocalDirectory(url: targetURL)
        guard merged.entries.count == plan.expected.count else {
            throw UpdateError.verifyFailed
        }
        for (actual, wanted) in zip(merged.entries, plan.expected) {
            guard actual.name == wanted.name,
                  actual.crc32 == wanted.crc32,
                  actual.compressedSize == wanted.compressedSize,
                  actual.localOffset == wanted.localOffset,
                  actual.segmentLength == wanted.segmentLength else {
                throw UpdateError.verifyFailed
            }
        }
        progress(1)
    }

    private static func readLocalDirectory(url: URL) throws -> Directory {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        guard size > 1024 else { throw UpdateError.baseUnavailable }

        var probe = min(size, probeSize)
        while true {
            try handle.seek(toOffset: UInt64(size - probe))
            guard let data = try handle.read(upToCount: Int(probe)), Int64(data.count) == probe else {
                throw UpdateError.archiveInvalid
            }
            if let eocd = findEOCD(in: data) {
                let cdOffset = Int64(le32(data, eocd + 16))
                let cdSize = Int64(le32(data, eocd + 12))
                if cdOffset >= size - probe, cdOffset + cdSize <= size {
                    return try parseDirectory(
                        data: data,
                        tailStart: size - probe,
                        fileSize: size,
                        cdOffset: cdOffset,
                        cdSize: cdSize
                    )
                }
                if probe < size {
                    probe = min(size, max(probe * 2, cdSize + 22))
                    continue
                }
            }
            throw UpdateError.archiveInvalid
        }
    }

    private static func readRemoteDirectory(
        url: URL,
        fileSize: Int64,
        session: URLSession
    ) async throws -> Directory {
        var probe = min(fileSize, probeSize)
        while true {
            try Task.checkCancellation()
            let start = fileSize - probe
            let data = try await fetchRange(url: url, start: start, end: fileSize - 1, session: session)
            if let eocd = findEOCD(in: data) {
                let cdOffset = Int64(le32(data, eocd + 16))
                let cdSize = Int64(le32(data, eocd + 12))
                if cdOffset >= start, cdOffset + cdSize <= fileSize {
                    return try parseDirectory(
                        data: data,
                        tailStart: start,
                        fileSize: fileSize,
                        cdOffset: cdOffset,
                        cdSize: cdSize
                    )
                }
                if probe < fileSize {
                    probe = min(fileSize, max(probe * 2, cdSize + 22))
                    continue
                }
            }
            throw UpdateError.archiveInvalid
        }
    }

    private static func parseDirectory(
        data: Data,
        tailStart: Int64,
        fileSize: Int64,
        cdOffset: Int64,
        cdSize: Int64
    ) throws -> Directory {
        let start = Int(cdOffset - tailStart)
        let end = start + Int(cdSize)
        guard start >= 0, end <= data.count else { throw UpdateError.archiveInvalid }

        var raw: [Entry] = []
        var offset = start
        while offset + 46 <= end {
            guard le32(data, offset) == 0x0201_4b50 else { break }
            let flags = le16(data, offset + 8)
            let method = le16(data, offset + 10)
            let crc = le32(data, offset + 16)
            let compressed = le32(data, offset + 20)
            let nameLength = Int(le16(data, offset + 28))
            let extraLength = Int(le16(data, offset + 30))
            let commentLength = Int(le16(data, offset + 32))
            let localOffset = Int64(le32(data, offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            raw.append(Entry(
                name: name,
                crc32: crc,
                compressedSize: compressed,
                method: method,
                flags: flags,
                localOffset: localOffset,
                segmentLength: 0
            ))
            offset = nameStart + nameLength + extraLength + commentLength
        }

        guard !raw.isEmpty else { throw UpdateError.archiveInvalid }
        raw.sort { $0.localOffset < $1.localOffset }

        var entries: [Entry] = []
        entries.reserveCapacity(raw.count)
        for index in raw.indices {
            let current = raw[index]
            let next = index + 1 < raw.count ? raw[index + 1].localOffset : cdOffset
            let length = next - current.localOffset
            guard length > 0 else { throw UpdateError.archiveInvalid }
            entries.append(Entry(
                name: current.name,
                crc32: current.crc32,
                compressedSize: current.compressedSize,
                method: current.method,
                flags: current.flags,
                localOffset: current.localOffset,
                segmentLength: length
            ))
        }

        return Directory(
            entries: entries,
            cdOffset: cdOffset,
            cdSize: cdSize,
            tail: data,
            tailStart: tailStart,
            fileSize: fileSize
        )
    }

    private static func mergeRanges(_ ranges: [(start: Int64, end: Int64)]) -> [(start: Int64, end: Int64)] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [(start: Int64, end: Int64)] = [sorted[0]]
        for range in sorted.dropFirst() {
            if range.start <= merged[merged.count - 1].end + mergeGap {
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, range.end)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func fetchRange(
        url: URL,
        start: Int64,
        end: Int64,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 180
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.dataIncomplete
        }
        guard http.statusCode == 206 || http.statusCode == 200 else {
            throw UpdateError.rangeUnsupported
        }
        if http.statusCode == 200 {
            guard Int64(data.count) == end - start + 1 else {
                throw UpdateError.rangeUnsupported
            }
            return data
        }
        guard Int64(data.count) == end - start + 1 else {
            throw UpdateError.dataIncomplete
        }
        return data
    }

    private static func findEOCD(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var index = data.count - 22
        let lower = max(0, data.count - 22 - 65_535)
        while index >= lower {
            if le32(data, index) == 0x0605_4b50 {
                let commentLength = Int(le16(data, index + 20))
                if index + 22 + commentLength <= data.count {
                    return index
                }
            }
            index -= 1
        }
        return nil
    }

    private static func le16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
