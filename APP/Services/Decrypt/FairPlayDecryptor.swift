import Foundation

enum FairPlayDecryptor {

    static var candidateGroups: [String] {
        AppGroupDiagnostics.candidateGroups()
    }

    /// 工作目录顺序（按历史验证过的优先级）：
    /// 1. App Group 容器 —— 之前一直能解密，FairPlay 在这里工作正常
    /// 2. Documents —— 同样受数据保护，group 不可写时用
    /// 3. Caches —— 最后兜底（实测这里 mremap_encrypted 会返回 ENOMEM，尽量别用）
    static func containerURL() -> URL? {
        if let group = firstWritableGroup() { return group }

        let manager = FileManager.default
        if let docs = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let dir = docs.appendingPathComponent("FairPlayedWork", isDirectory: true)
            if (try? manager.createDirectory(at: dir, withIntermediateDirectories: true)) != nil {
                return dir
            }
        }

        guard let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent("FairPlayedWork", isDirectory: true)
        try? manager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 拿到第一个真的能写进去的 group 容器。
    private static func firstWritableGroup() -> URL? {
        let manager = FileManager.default
        for group in candidateGroups {
            guard let url = manager.containerURL(forSecurityApplicationGroupIdentifier: group) else { continue }
            let probe = url.appendingPathComponent(".fp-probe-\(UUID().uuidString)", isDirectory: true)
            guard (try? manager.createDirectory(at: probe, withIntermediateDirectories: true)) != nil else { continue }
            try? manager.removeItem(at: probe)
            return url
        }
        return nil
    }

    static var isAvailable: Bool { containerURL() != nil }

    enum DecryptError: LocalizedError {
        case noAppGroup
        case badArchive(String)
        case noPayload
        case notDecryptable(String)
        case noEntitlement
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
            case .noEntitlement:
                return "dc_err_no_entitlement".localized
            case .notDecryptable(let detail):
                let base = "dc_err_not_decryptable".localized
                return detail.isEmpty ? base : base + "\n" + detail
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

        let canExec = fp_exec_memory_available() == 1
        emit(.line("exec-memory (dynamic-codesigning): \(canExec ? "yes" : "NO")", canExec ? .info : .warning))
        guard canExec else {
            emit(.line("abort: 当前签名缺少 dynamic-codesigning，内核不会解密任何页面", .failure))
            throw DecryptError.noEntitlement
        }
        guard canExec else {
            emit(.line("abort: 当前签名缺少 dynamic-codesigning，内核不会解密任何页面", .failure))
            throw DecryptError.noEntitlement
        }

        emit(.phase("EXTRACT"))
        emit(.line("root    \(groupRoot.path)", .info))
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
        box.onFailureDetail = { detail in
            // 只留第一条，够定位就行
            if Self.firstFailure == nil { Self.firstFailure = detail }
        }

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
                        let text = String(cString: line)
                        if text.contains("mremap="), text.contains("pages=") {
                            box.onFailureDetail?(text)
                        }
                        box.handler?(.line(text, .detail))
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
            emit(.line(skippedCount == 0 ? "no Mach-O binaries found in package" : "package is not encrypted, copied as-is", .warning))
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
            let raw = Self.firstFailure ?? ""
            Self.firstFailure = nil
            let detail = Self.humanReason(for: raw)
            emit(.line("main binary rejected by FairPlay", .failure))
            if !raw.isEmpty { emit(.line("  \(raw)", .failure)) }
            if !detail.isEmpty { emit(.line("  → \(detail)", .warning)) }
            throw DecryptError.notDecryptable(detail)
        }
        Self.firstFailure = nil

        emit(.phase("PACK"))
        let suffix = failedCount > 0 ? "-PARTIAL" : "-decrypted"
        let outURL = outDir.appendingPathComponent("\(stem)\(suffix).ipa")
        let tempURL = outDir.appendingPathComponent("\(stem)\(suffix)-\(UUID().uuidString).ipa.tmp")
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
        var onFailureDetail: (@Sendable (String) -> Void)?

        init(_ handler: (@Sendable (DecryptEvent) -> Void)?,
             cancelToken: DecryptCancelToken?) {
            self.handler = handler
            self.cancelToken = cancelToken
        }
    }

    /// C 核心每次尝试都会打一行 "R/cryptid1: sig=.. mmap=.. mremap=.. pages=x/y ..."，
    /// 留下第一条失败的，用来告诉用户为什么没解出来。
    nonisolated(unsafe) private static var firstFailure: String?

    private static func humanReason(for raw: String) -> String {
        // 探针能申请到可执行内存 = 签名带 dynamic-codesigning，权限没问题
        let hasEntitlement = fp_exec_memory_available() == 1
        guard !raw.isEmpty else {
            return hasEntitlement ? "" : "dc_reason_entitlement".localized
        }
        let lower = raw.lowercased()
        if !hasEntitlement {
            return "dc_reason_entitlement".localized
        }
        // 有权限却被拒（EPERM）：是这个包的 FairPlay 票据对不上当前设备/账号
        if lower.contains("errno 1 ") || lower.contains("operation not permitted") {
            return "dc_reason_ticket".localized
        }
        if lower.contains("errno 12 ") || lower.contains("cannot allocate memory") {
            return "dc_reason_enomem".localized
        }
        if lower.contains("errno 1 ") || lower.contains("operation not permitted") {
            return "dc_reason_eperm".localized
        }
        if lower.contains("mremap=0") && lower.contains("pages=0/") {
            return "dc_reason_pages".localized
        }
        if lower.contains("changed=0") {
            return "dc_reason_unchanged".localized
        }
        if lower.contains("unsupported magic") || lower.contains("parse failed") {
            return "dc_reason_parse".localized
        }
        return ""
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
