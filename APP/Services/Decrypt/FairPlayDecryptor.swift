import Foundation

/// In-app FairPlay decryption.
///
/// fairplayd refuses to read a binary that sits in an app's data container
/// (Documents / Library / tmp) and returns EPERM or EINVAL. It *does* read
/// files under the shared App Group container, which is why this decryptor
/// works entirely inside `containerURLForSecurityApplicationGroupIdentifier`.
///
/// Verified on iOS 27.0.1: 16/16 encrypted Mach-O decrypted, 0 failures.
enum FairPlayDecryptor {

    /// Candidate group identifiers, tried in order. The first one that resolves wins.
    /// Override with `AppGroupIdentifier` in Info.plist if your signing profile differs.
    static var candidateGroups: [String] {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !configured.isEmpty {
            return [configured]
        }
        return [
            "group.b26d9af3ffccda33.1",
            "group.b26d9af3ffccda33.2",
            "group.b26d9af3ffccda33.3",
            "group.b26d9af3ffccda33.4",
            "group.b26d9af3ffccda33.5"
        ]
    }

    /// The shared container, or nil when the app was signed without App Group entitlements.
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

    /// Decrypt an IPA in place inside the shared container and write the result to Documents/Decrypted.
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

        // Extraction plus repack needs roughly three times the IPA on disk.
        // Failing early beats dying mid-write with a half-written container.
        if let capacity = try? groupRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            let needed = sourceSize * 3
            if capacity < needed {
                onEvent?(.line("not enough space: \(capacity) < \(needed)", .failure))
                throw DecryptError.notEnoughSpace(capacity, needed)
            }
        }

        // 1. extract
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

        // Unpacking is one long C call with no cancel point; honour a cancel
        // request as soon as it returns.
        if cancelToken?.isCancelled == true {
            onEvent?(.line("cancelled", .warning))
            throw DecryptError.cancelled
        }

        // 2. locate Payload/*.app
        let payloadRoot = workRoot.appendingPathComponent("Payload", isDirectory: true)
        let entries = (try? manager.contentsOfDirectory(atPath: payloadRoot.path)) ?? []
        guard let bundleName = entries.first(where: { $0.hasSuffix(".app") }) else {
            onEvent?(.line("no Payload/*.app", .failure))
            throw DecryptError.noPayload
        }
        let appDir = payloadRoot.appendingPathComponent(bundleName, isDirectory: true)
        onEvent?(.line("payload  \(bundleName)", .info))

        // 3. replicate SINF so every nested Mach-O has <dir>/SC_Info/<name>.sinf
        onEvent?(.phase("SINF"))
        let replicated = replicateSinf(appDir: appDir)
        onEvent?(.line("replicated to \(replicated) paths", replicated > 0 ? .info : .warning))

        // 4. decrypt every Mach-O
        let total = countMachOs(in: appDir)
        onEvent?(.phase("DECRYPT"))
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

        // Nothing encrypted and nothing failed: the package is already plain.
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

        // 5. repack
        onEvent?(.phase("PACK"))
        let suffix = failedCount > 0 ? "-PARTIAL" : "-decrypted"
        let outURL = outDir.appendingPathComponent("\(stem)\(suffix).ipa")
        // Pack into a temp file first: re-running a decryption must not destroy
        // the previous good result if this attempt fails.
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

        return Outcome(
            decrypted: Int(decrypted),
            plain: Int(skippedCount),
            failed: Int(failedCount),
            outputURL: outURL,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    // MARK: - helpers

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

    /// Copies SC_Info/<name>.sinf to every path listed in SC_Info/Manifest.plist.
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
