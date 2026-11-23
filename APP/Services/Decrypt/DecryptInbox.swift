import Foundation
import SwiftUI
import UIKit

enum DecryptJobState {
    case importing
    case ready
    case running
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .importing: return "decrypt_state_importing".localized
        case .ready: return "decrypt_state_ready".localized
        case .running: return "decrypt_state_running".localized
        case .completed: return "decrypt_state_completed".localized
        case .failed: return "decrypt_state_failed".localized
        case .cancelled: return "decrypt_state_cancelled".localized
        }
    }

    var consoleOutcome: DecryptConsoleOutcome {
        switch self {
        case .importing, .ready: return .idle
        case .running: return .running
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    var isFinished: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

struct IPAMetadata {
    let appName: String
    let bundleIdentifier: String
    let version: String
    let iconPNG: Data?

    static func read(at url: URL) -> IPAMetadata? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let eocd = FastZipArchive.findEndOfCentralDirectory(in: data),
              let entries = try? FastZipArchive.readCentralDirectory(from: data, eocd: eocd),
              let infoEntry = entries.first(where: { entry in
                  let parts = entry.filename.split(separator: "/")
                  return parts.count == 3
                      && parts[0] == "Payload"
                      && parts[1].hasSuffix(".app")
                      && parts[2] == "Info.plist"
              }),
              let infoData = try? FastZipArchive.extractSingleEntry(from: data, entry: infoEntry),
              let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        else { return nil }

        let bundleIdentifier = info["CFBundleIdentifier"] as? String ?? ""
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? ""

        let iconEntry = entries
            .filter { entry in
                let parts = entry.filename.split(separator: "/")
                guard parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app") else { return false }
                let name = parts[2].lowercased()
                return name.hasPrefix("appicon") && name.hasSuffix(".png")
            }
            .max(by: { $0.uncompressedSize < $1.uncompressedSize })

        var iconPNG: Data?
        if let iconEntry, iconEntry.uncompressedSize > 0, iconEntry.uncompressedSize < 4 * 1024 * 1024 {
            iconPNG = try? FastZipArchive.extractSingleEntry(from: data, entry: iconEntry)
        }

        return IPAMetadata(
            appName: name,
            bundleIdentifier: bundleIdentifier,
            version: version,
            iconPNG: iconPNG
        )
    }
}

enum DecryptInboxError: LocalizedError {
    case notIPA
    case copyFailed(String)
    case duplicate

    var errorDescription: String? {
        switch self {
        case .notIPA: return "decrypt_err_not_ipa".localized
        case .copyFailed(let detail): return "decrypt_err_copy".localized + " (\(detail))"
        case .duplicate: return "decrypt_dup_skipped".localized
        }
    }
}

@MainActor
final class DecryptJob: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let createdAt: Date
    let size: Int64
    let metadata: IPAMetadata

    @Published var state: DecryptJobState = .ready
    @Published var message: String?
    @Published var outputURL: URL?
    @Published var outputSize: Int64 = 0
    @Published private(set) var failedPaths: [String] = []

    let log = DecryptLog()

    init(url: URL, size: Int64, metadata: IPAMetadata, createdAt: Date = Date()) {
        self.url = url
        self.size = size
        self.metadata = metadata
        self.createdAt = createdAt
    }

    var displayName: String {
        metadata.appName.isEmpty ? url.deletingPathExtension().lastPathComponent : metadata.appName
    }

    var subtitle: String {
        var parts: [String] = []
        if !metadata.version.isEmpty { parts.append(metadata.version) }
        if !metadata.bundleIdentifier.isEmpty { parts.append(metadata.bundleIdentifier) }
        if size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    var fileName: String {
        url.lastPathComponent
    }

    var outputSizeText: String? {
        guard outputSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: outputSize, countStyle: .file)
    }

    func resetFailures() {
        failedPaths = []
    }

    func recordFailure(_ path: String) {
        guard !failedPaths.contains(path) else { return }
        failedPaths.append(path)
    }
}

@MainActor
final class DecryptInboxStore: ObservableObject {
    static let shared = DecryptInboxStore()

    @Published private(set) var jobs: [DecryptJob] = []
    @Published private(set) var isImporting = false
    /// 脱壳失败时给弹窗用：应用名 + 原因
    @Published var failureAlert: String?

    private let fileManager = FileManager.default
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var inboxURL: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("DecryptInbox", isDirectory: true)
    }

    private var outputURL: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Decrypted", isDirectory: true)
    }

    var readyCount: Int {
        jobs.filter { $0.state == .ready }.count
    }

    private init() {
        try? fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        reload()
        if ProcessInfo.processInfo.arguments.contains("--fp-selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let job = self.jobs.first(where: { $0.state == .ready }) else { return }
                self.start(job)
            }
        }
    }

    func reload() {
        let contents = (try? fileManager.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let urls = contents.filter { $0.pathExtension.lowercased() == "ipa" }
        let paths = Set(urls.map { $0.standardizedFileURL.path })

        jobs.removeAll { !paths.contains($0.url.standardizedFileURL.path) }

        var added: [DecryptJob] = []
        for url in urls where !jobs.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let metadata = IPAMetadata.read(at: url)
                ?? IPAMetadata(appName: url.deletingPathExtension().lastPathComponent, bundleIdentifier: "", version: "", iconPNG: nil)
            let job = DecryptJob(
                url: url,
                size: size,
                metadata: metadata,
                createdAt: values?.creationDate ?? Date.distantPast
            )
            if let existing = existingOutput(for: url) {
                job.state = .completed
                job.outputURL = existing
            }
            added.append(job)
        }
        if !added.isEmpty {
            jobs.append(contentsOf: added)
            sortJobs()
        }
    }

    @discardableResult
    func importIPAs(from sources: [URL]) async -> [String] {
        guard !sources.isEmpty else { return [] }
        isImporting = true
        defer { isImporting = false }

        var failures: [String] = []
        for source in sources {
            do {
                let job = try await importIPA(from: source)
                jobs.insert(job, at: 0)
                SoundEffects.play(.rise)
                pump()
            } catch {
                failures.append("\(source.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return failures
    }

    private func importIPA(from source: URL) async throws -> DecryptJob {
        var name = source.lastPathComponent
        if !name.lowercased().hasSuffix(".ipa") { name += ".ipa" }
        let destination = uniqueDestination(for: name)

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            }.value
        } catch {
            try? fileManager.removeItem(at: destination)
            throw DecryptInboxError.copyFailed(error.localizedDescription)
        }

        let metadata = await Task.detached(priority: .userInitiated) {
            IPAMetadata.read(at: destination)
        }.value

        guard let metadata else {
            try? fileManager.removeItem(at: destination)
            throw DecryptInboxError.notIPA
        }

        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)

        let isDuplicate = jobs.contains { existing in
            existing.metadata.bundleIdentifier == metadata.bundleIdentifier
                && existing.metadata.version == metadata.version
                && existing.size == size
        }
        if isDuplicate {
            try? fileManager.removeItem(at: destination)
            throw DecryptInboxError.duplicate
        }

        let job = DecryptJob(url: destination, size: size, metadata: metadata)
        if let existing = existingOutput(for: destination) {
            job.state = .completed
            job.outputURL = existing
        }
        return job
    }

    func start(_ job: DecryptJob) {
        guard job.state != .running, job.state != .importing else { return }
        if job.state.isFinished {
            job.state = .ready
            job.message = nil
            job.outputURL = nil
            job.log.reset(title: "INIT")
        }
        if DecryptCoordinator.shared.isBusy {
            pump()
        } else {
            run(job)
        }
    }

    func startAll() {
        for job in jobs where job.state.isFinished {
            job.state = .ready
            job.message = nil
            job.outputURL = nil
            job.log.reset(title: "INIT")
        }
        pump()
    }

    func cancel(_ job: DecryptJob) {
        guard job.state == .running else { return }
        DecryptCoordinator.shared.cancel()
    }

    func remove(_ job: DecryptJob) {
        if job.state == .running { DecryptCoordinator.shared.cancel() }
        try? fileManager.removeItem(at: job.url)
        jobs.removeAll { $0.id == job.id }
        pump()
    }

    func clearFinished() {
        for job in jobs where job.state.isFinished {
            try? fileManager.removeItem(at: job.url)
        }
        jobs.removeAll { $0.state.isFinished }
    }

    private func pump() {
        guard !DecryptCoordinator.shared.isBusy else { return }
        guard let next = jobs
            .filter({ $0.state == .ready })
            .min(by: { $0.createdAt < $1.createdAt }) else { return }
        run(next)
    }

    private func run(_ job: DecryptJob) {
        SoundEffects.play(.press)
        let token = DecryptCoordinator.shared.begin(requestID: job.id)
        job.state = .running
        job.message = nil
        job.outputURL = nil
        job.log.reset(title: "INIT")
        job.log.isExpanded = true
        job.resetFailures()

        DecryptActivityManager.shared.start(
            key: IslandTaskKey.decrypt(job.id),
            title: job.displayName,
            step: "preparing".localized
        )

        beginBackgroundAssertion()

        Task { @MainActor in
            let record = await DecryptService.decryptFull(
                ipaPath: job.url.path,
                cancelToken: token,
                onEvent: { event in
                    job.log.consume(event)
                    if case .phase(let phase) = event {
                        Task { @MainActor in
                            DecryptActivityManager.shared.update(
                                key: IslandTaskKey.decrypt(job.id),
                                step: phase
                            )
                        }
                    }
                    if case .entry(let relativePath, let status, _) = event, status < 0 {
                        Task { @MainActor in job.recordFailure(relativePath) }
                    }
                }
            )
            job.log.finish()
            DecryptCoordinator.shared.finish(requestID: job.id)
            endBackgroundAssertion()

            if token.isCancelled {
                job.state = .cancelled
                job.message = "dc_err_cancelled".localized
                SoundEffects.play(.fall)
            } else if record.status == .completed {
                SoundEffects.play(.success)
                job.state = .completed
                if let path = record.outputPath {
                    job.outputURL = URL(fileURLWithPath: path)
                    job.outputSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                }
                job.message = record.message
            } else {
                job.state = .failed
                job.message = record.message
                let reason = record.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                failureAlert = reason.isEmpty
                    ? job.displayName
                    : "\(job.displayName)\n\n\(reason)"
                SoundEffects.play(.error)
            }

            if job.state == .completed {
                DecryptActivityManager.shared.finish(
                    key: IslandTaskKey.decrypt(job.id),
                    detail: job.outputSizeText ?? ""
                )
            } else {
                DecryptActivityManager.shared.fail(
                    key: IslandTaskKey.decrypt(job.id),
                    reason: job.message ?? "",
                    cancelled: job.state == .cancelled
                )
            }

            pump()
        }
    }

    private func beginBackgroundAssertion() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "decrypt-inbox") { [weak self] in
            Task { @MainActor in self?.endBackgroundAssertion() }
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func sortJobs() {
        jobs.sort { $0.createdAt > $1.createdAt }
    }

    private func existingOutput(for source: URL) -> URL? {
        let stem = source.deletingPathExtension().lastPathComponent
        for suffix in ["-decrypted.ipa", "-PARTIAL.ipa"] {
            let candidate = outputURL.appendingPathComponent(stem + suffix)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func uniqueDestination(for name: String) -> URL {
        var candidate = inboxURL.appendingPathComponent(name)
        var index = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = inboxURL.appendingPathComponent("\(base)-\(index).\(ext)")
            index += 1
        }
        return candidate
    }
}
