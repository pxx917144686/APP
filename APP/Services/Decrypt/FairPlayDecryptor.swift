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

        let manager = FileManager.default
        let started = Date()
        let stem = ipaURL.deletingPathExtension().lastPathComponent
        let workRoot = groupRoot.appendingPathComponent("fpwork-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: workRoot) }
        try manager.createDirectory(at: workRoot, withIntermediateDirectories: true)

        let sourceSize = (try? manager.attributesOfItem(atPath: ipaURL.path)[.size] as? Int64) ?? 0

        if let capacity = try? groupRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            let needed = sourceSize * 3
            if capacity < needed {
                onEvent?(.line("not enough space: \(capacity) < \(needed)", .failure))
                throw DecryptError.notEnoughSpace(capacity, needed)
            }
        }

        onEvent?(.phase("EXTRACT"))
        onEvent?(.line("source  \(ipaURL.lastPathComponent)  \(formatBytes(sourceSize))", .info))

        var errBuf = [CChar](repeating: 0, count: 1024)
        let unpackStatus = ipaURL.path.withCString { src in
            workRoot.path.withCString { dst in
                fp_zip_unpack(src, dst, &errBuf, Int32(errBuf.count))
            }
        }
        guard unpackStatus == 0 else {
            let detail = String(cString: errBuf)
            onEvent?(.line("unpack failed: \(detail)", .failure))
            throw DecryptError.badArchive(detail)
        }

        if cancelToken?.isCancelled == true {
            onEvent?(.line("cancelled", .warning))
            throw DecryptError.cancelled
        }

        let payloadRoot = workRoot.appendingPathComponent("Payload", isDirectory: true)
        let entries = (try? manager.contentsOfDirectory(atPath: payloadRoot.path)) ?? []
        guard let bundleName = entries.first(where: { $0.hasSuffix(".app") }) else {
            onEvent?(.line("no Payload/*.app", .failure))
            throw DecryptError.noPayload
        }
        let appDir = payloadRoot.appendingPathComponent(bundleName, isDirectory: true)
        onEvent?(.line("payload  \(bundleName)", .info))

        onEvent?(.phase("SINF"))
        let replicated = replicateSinf(appDir: appDir)
        onEvent?(.line("replicated to \(replicated) paths", replicated > 0 ? .info : .warning))

        let total = countMachOs(in: appDir)
        onEvent?(.phase("DECRYPT"))
        onEvent?(.total(total))
        onEvent?(.line("\(total) Mach-O found", .info))

        var failedCount: Int32 = 0
        var skippedCount: Int32 = 0
        let box = EventBox(onEvent, cancelToken: cancelToken)

        let decrypted = withExtendedLifetime(box) { () -> Int32 in
            appDir.path.withCString { dir in
                fp_decrypt_tree(
                    dir,
                    { ctx, rel, status in
                        guard let ctx, let rel else { return }
                        let box = Unmanaged<EventBox>.fromOpaque(ctx).takeUnretainedValue()
                        box.handler?(.entry(String(cString: rel), status))
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
            onEvent?(.phase("DONE"))
            onEvent?(.line("package is not encrypted, copied as-is", .warning))
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
            onEvent?(.line("cancelled", .warning))
            throw DecryptError.cancelled
        }

        guard decrypted >= 0 else {
            let detail = String(cString: errBuf)
            onEvent?(.line("walk failed: \(detail)", .failure))
            throw DecryptError.badArchive(detail.isEmpty ? "traversal failed" : detail)
        }

        guard decrypted > 0 else {
            onEvent?(.line("main binary rejected by FairPlay", .failure))
            throw DecryptError.notDecryptable
        }

        onEvent?(.phase("PACK"))
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
            onEvent?(.line("pack failed: \(detail)", .failure))
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
        onEvent?(.line("wrote \(outURL.lastPathComponent)  \(formatBytes(size))", .success))
        onEvent?(.phase("DONE"))

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

    private static func countMachOs(in appDir: URL) -> Int {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: appDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let head = try? handle.read(upToCount: 4) else { continue }
            try? handle.close()
            guard head.count == 4 else { continue }
            let le = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let be = le.byteSwapped
            if be == 0xFEEDFACF || be == 0xFEEDFACE || be == 0xCAFEBABE
                || le == 0xFEEDFACF || le == 0xFEEDFACE {
                count += 1
            }
        }
        return count
    }
}
