import Foundation

enum FairPlayDecryptor {

    static var candidateGroups: [String] {
        AppGroupDiagnostics.candidateGroups()
    }

    static func containerURL() -> URL? {
        for group in candidateGroups {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return url
            }
        }
        return nil
    }

    static var isAvailable: Bool { containerURL() != nil }

    enum DecryptError: LocalizedError {
        case noAppGroup
        case badArchive(String)
        case noPayload
        case notDecryptable
        case zipFailed(String)
        case notEnoughSpace(Int64, Int64)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noAppGroup:
                return "dc_err_no_appgroup".localized
            case .badArchive(let detail):
                return "dc_err_unzip".localized + " (\(detail))"
            case .noPayload:
                return "dc_err_no_binary".localized
            case .notDecryptable:
                return "dc_err_not_decryptable".localized
            case .zipFailed(let detail):
                return "dc_err_copy".localized(detail)
            case .cancelled:
                return "dc_err_cancelled".localized
            case .notEnoughSpace(let free, let needed):
                let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                return "dc_err_space".localized(f, n)
            }
        }
    }

    struct Outcome {
        let decrypted: Int
        let plain: Int
        let failed: Int
        let outputURL: URL
        let elapsed: TimeInterval
    }

    static func decrypt(
        ipaURL: URL,
        cancelToken: DecryptCancelToken? = nil,
        onEvent: (@Sendable (DecryptEvent) -> Void)? = nil
    ) throws -> Outcome {
        guard let groupRoot = containerURL() else { throw DecryptError.noAppGroup }

        let logHandle = makeDecryptLogHandle()
        defer { try? logHandle?.close() }
        let emit: @Sendable (DecryptEvent) -> Void = { event in
            appendDecryptLog(logHandle, event)
            onEvent?(event)
        }

        let manager = FileManager.default
        let started = Date()
        let stem = ipaURL.deletingPathExtension().lastPathComponent
        let removedStale = purgeWorkDirectories(in: groupRoot)
        if removedStale > 0 {
            emit(.line("purged \(removedStale) stale work dir(s)", .warning))
        }
        let workRoot = groupRoot.appendingPathComponent("fpwork-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: workRoot) }
        try manager.createDirectory(at: workRoot, withIntermediateDirectories: true)

        let sourceSize = (try? manager.attributesOfItem(atPath: ipaURL.path)[.size] as? Int64) ?? 0

        if let capacity = try? groupRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            let needed = sourceSize * 3
            if capacity < needed {
                emit(.line("not enough space: \(capacity) < \(needed)", .failure))
                throw DecryptError.notEnoughSpace(capacity, needed)
            }
        }

        emit(.phase("EXTRACT"))
        emit(.line("source  \(ipaURL.lastPathComponent)  \(formatBytes(sourceSize))", .info))

        var errBuf = [CChar](repeating: 0, count: 1024)
        let unpackStatus = ipaURL.path.withCString { src in
            workRoot.path.withCString { dst in
                fp_zip_unpack(src, dst, &errBuf, Int32(errBuf.count))
            }
        }
        guard unpackStatus == 0 else {
            let detail = String(cString: errBuf)
            emit(.line("unpack failed: \(detail)", .failure))
            throw DecryptError.badArchive(detail)
        }

        if cancelToken?.isCancelled == true {
            emit(.line("cancelled", .warning))
            throw DecryptError.cancelled
        }

        let payloadRoot = workRoot.appendingPathComponent("Payload", isDirectory: true)
        let entries = (try? manager.contentsOfDirectory(atPath: payloadRoot.path)) ?? []
        guard let bundleName = entries.first(where: { $0.hasSuffix(".app") }) else {
            emit(.line("no Payload/*.app", .failure))
            throw DecryptError.noPayload
        }
        let appDir = payloadRoot.appendingPathComponent(bundleName, isDirectory: true)
        emit(.line("payload  \(bundleName)", .info))

        emit(.phase("SINF"))
        let replicated = replicateSinf(appDir: appDir)
        emit(.line("replicated to \(replicated) paths", replicated > 0 ? .info : .warning))

        var totalBytes: Int64 = 0
        let total = Int(appDir.path.withCString { fp_count_targets($0, &totalBytes) })
        emit(.phase("DECRYPT"))
        emit(.total(total))
        emit(.totalBytes(totalBytes))
        emit(.line("\(total) Mach-O found  \(formatBytes(totalBytes))", .info))

        var failedCount: Int32 = 0
        var skippedCount: Int32 = 0
        let box = EventBox(emit, cancelToken: cancelToken)

        let decrypted = withExtendedLifetime(box) { () -> Int32 in
            appDir.path.withCString { dir in
                fp_decrypt_tree(
                    dir,
                    { ctx, rel, status, size in
                        guard let ctx, let rel else { return }
                        let box = Unmanaged<EventBox>.fromOpaque(ctx).takeUnretainedValue()
                        box.handler?(.entry(String(cString: rel), status, Int64(size)))
                    },
                    { ctx, line in
                        guard let ctx, let line else { return }
                        let box = Unmanaged<EventBox>.fromOpaque(ctx).takeUnretainedValue()
                        box.handler?(.line(String(cString: line), .detail))
                    },
                    { ctx in
                        guard let ctx else { return false }
                        let box = Unmanaged<EventBox>.fromOpaque(ctx).takeUnretainedValue()
                        return box.cancelToken?.isCancelled ?? false
                    },
                    Unmanaged.passUnretained(box).toOpaque(),
                    &failedCount,
                    &skippedCount,
                    &errBuf,
                    Int32(errBuf.count)
                )
            }
        }

        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outDir = documents.appendingPathComponent("Decrypted", isDirectory: true)
        try? manager.createDirectory(at: outDir, withIntermediateDirectories: true)

        if decrypted == 0 && failedCount == 0 {
            emit(.phase("DONE"))
            emit(.line("package is not encrypted, copied as-is", .warning))
            let copyURL = outDir.appendingPathComponent(ipaURL.lastPathComponent)
            try? manager.removeItem(at: copyURL)
            try manager.copyItem(at: ipaURL, to: copyURL)
            return Outcome(
                decrypted: 0,
                plain: Int(skippedCount),
                failed: 0,
                outputURL: copyURL,
                elapsed: Date().timeIntervalSince(started)
            )
        }

        if decrypted == -2 {
            emit(.line("cancelled", .warning))
            throw DecryptError.cancelled
        }

        guard decrypted >= 0 else {
            let detail = String(cString: errBuf)
            emit(.line("walk failed: \(detail)", .failure))
            throw DecryptError.badArchive(detail.isEmpty ? "traversal failed" : detail)
        }

        guard decrypted > 0 else {
            emit(.line("main binary rejected by FairPlay", .failure))
            throw DecryptError.notDecryptable
        }

        emit(.phase("PACK"))
        let suffix = failedCount > 0 ? "-PARTIAL" : "-decrypted"
        let outURL = outDir.appendingPathComponent("\(stem)\(suffix).ipa")
        let tempURL = outDir.appendingPathComponent("\(stem)\(suffix).ipa.tmp")
        try? manager.removeItem(at: tempURL)

        let packStatus = workRoot.path.withCString { src in
            tempURL.path.withCString { dst in
                fp_zip_pack(src, dst, &errBuf, Int32(errBuf.count))
            }
        }
        guard packStatus == 0 else {
            let detail = String(cString: errBuf)
            try? manager.removeItem(at: tempURL)
            emit(.line("pack failed: \(detail)", .failure))
            throw DecryptError.zipFailed(detail)
        }
        try? manager.removeItem(at: outURL)
        do {
            try manager.moveItem(at: tempURL, to: outURL)
        } catch {
            try? manager.removeItem(at: tempURL)
            throw DecryptError.zipFailed(error.localizedDescription)
        }

        let size = (try? manager.attributesOfItem(atPath: outURL.path)[.size] as? Int64) ?? 0
        emit(.line("wrote \(outURL.lastPathComponent)  \(formatBytes(size))", .success))
        emit(.phase("DONE"))

        return Outcome(
            decrypted: Int(decrypted),
            plain: Int(skippedCount),
            failed: Int(failedCount),
            outputURL: outURL,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    private final class EventBox {
        let handler: (@Sendable (DecryptEvent) -> Void)?
        let cancelToken: DecryptCancelToken?

        init(_ handler: (@Sendable (DecryptEvent) -> Void)?,
             cancelToken: DecryptCancelToken?) {
            self.handler = handler
            self.cancelToken = cancelToken
        }
    }

    private static func formatBytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useKB, .useGB]
        return formatter.string(fromByteCount: value)
    }

    private static func makeDecryptLogHandle() -> FileHandle? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Decrypted", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("last-decrypt.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }

    private static func appendDecryptLog(_ handle: FileHandle?, _ event: DecryptEvent) {
        guard let handle else { return }
        let line: String
        switch event {
        case .phase(let value):
            line = "== \(value)"
        case .line(let text, _):
            line = text
        case .entry(let relativePath, let status, let size):
            line = "[\(status)] \(relativePath)  \(size) bytes"
        case .total(let value):
            line = "targets: \(value)"
        case .totalBytes(let value):
            line = "bytes: \(value)"
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    @discardableResult
    private static func purgeWorkDirectories(in root: URL) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let cutoff = Date().addingTimeInterval(-3600)
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix("fpwork-") {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            if (try? manager.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        return removed
    }

    @discardableResult
    private static func replicateSinf(appDir: URL) -> Int {
        let manager = FileManager.default
        let manifestURL = appDir.appendingPathComponent("SC_Info/Manifest.plist")
        guard let data = try? Data(contentsOf: manifestURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let manifest = plist as? [String: Any] else { return 0 }

        let sources = manifest["SinfPaths"] as? [String] ?? []
        guard let first = sources.first else { return 0 }
        let sourceURL = appDir.appendingPathComponent(first)
        guard manager.fileExists(atPath: sourceURL.path) else { return 0 }

        let targets = manifest["SinfReplicationPaths"] as? [String] ?? []
        var copied = 0
        for relative in targets {
            let destination = appDir.appendingPathComponent(relative)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            try? manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if (try? manager.copyItem(at: sourceURL, to: destination)) != nil {
                copied += 1
            }
        }
        return copied
    }
}
