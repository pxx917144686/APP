import Foundation
import UIKit
import ZsignSwift

enum SigningPhase: String, Sendable {
    case idle
    case preparing
    case unpacking
    case signing
    case packing
    case completed

    var stepIndex: Int {
        switch self {
        case .idle, .preparing: return 0
        case .unpacking: return 1
        case .signing: return 2
        case .packing: return 3
        case .completed: return 4
        }
    }

    var title: String {
        switch self {
        case .idle, .preparing: return "sign_phase_prepare".localized
        case .unpacking: return "sign_phase_unpack".localized
        case .signing: return "sign_phase_sign".localized
        case .packing: return "sign_phase_pack".localized
        case .completed: return "sign_phase_done".localized
        }
    }
}

enum SigningOutcome: Equatable {
    case idle
    case running
    case completed
    case failed
    case cancelled
}

struct SigningUpdate: Sendable {
    let phase: SigningPhase?
    let progress: Double?
    let text: String?
    let level: DecryptLogLevel

    init(phase: SigningPhase? = nil, progress: Double? = nil, text: String? = nil, level: DecryptLogLevel = .info) {
        self.phase = phase
        self.progress = progress
        self.text = text
        self.level = level
    }
}

struct SigningInjection: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let name: String
    let isFramework: Bool
    var targets: Set<String>
    var weak: Bool

    init(id: UUID = UUID(), url: URL, name: String, isFramework: Bool, targets: Set<String> = ["."], weak: Bool = true) {
        self.id = id
        self.url = url
        self.name = name
        self.isFramework = isFramework
        self.targets = targets
        self.weak = weak
    }
}

struct SigningTargetCredentials: Sendable {
    let targetID: String
    let bundlePath: String
    let originalBundleIdentifier: String
    let bundleIdentifier: String
    let certificate: SigningCertificate
    let certificateURL: URL
    let password: String
    let profile: SigningProfile
    let profileURL: URL
    let entitlementsPlist: Data?
}

struct SigningIPTask: Sendable {
    let ipa: SigningIPAInfo
    let certificate: SigningCertificate
    let certificateURL: URL
    let profile: SigningProfile
    let profileURL: URL
    let password: String
    let bundleIdentifier: String
    let displayName: String
    let version: String
    let removeProvision: Bool
    let entitlementsPlist: Data?
    let injections: [SigningInjection]
    let removeWatchApp: Bool
    let removeTargetPaths: [String]
    let targetCredentials: [SigningTargetCredentials]
    let outputDirectory: URL
}

enum SigningEngineError: LocalizedError {
    case missingInput(String)
    case unpackFailed(String)
    case noPayload
    case signFailed(String)
    case packFailed(String)
    case injectionFailed(String)
    case outputMissing
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingInput(let detail): return "sign_err_missing_input".localized(detail)
        case .unpackFailed(let detail): return "sign_err_unpack".localized(detail)
        case .noPayload: return "sign_err_no_payload".localized
        case .signFailed(let detail): return "sign_err_sign".localized(detail)
        case .packFailed(let detail): return "sign_err_pack".localized(detail)
        case .injectionFailed(let detail): return "sign_err_inject".localized(detail)
        case .outputMissing: return "sign_err_output".localized
        case .cancelled: return "dc_err_cancelled".localized
        }
    }
}

private final class ZsignErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ value: Error?) {
        lock.lock()
        error = value
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

final class SigningCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func throwIfCancelled() throws {
        if isCancelled { throw SigningEngineError.cancelled }
    }
}

enum SigningEngine {
    private static let engineMutex = NSLock()

    static func sign(
        _ task: SigningIPTask,
        onUpdate: @escaping @Sendable (SigningUpdate) -> Void
    ) async throws -> URL {
        let cancelFlag = SigningCancelFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try signSync(task, cancelFlag: cancelFlag, onUpdate: onUpdate)
            }.value
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    private static func signSync(
        _ task: SigningIPTask,
        cancelFlag: SigningCancelFlag,
        onUpdate: @escaping @Sendable (SigningUpdate) -> Void
    ) throws -> URL {
        engineMutex.lock()
        defer { engineMutex.unlock() }
        let fileManager = FileManager.default
        for url in [task.ipa.url, task.certificateURL, task.profileURL] where !fileManager.fileExists(atPath: url.path) {
            throw SigningEngineError.missingInput(url.lastPathComponent)
        }
        try? fileManager.createDirectory(at: task.outputDirectory, withIntermediateDirectories: true)

        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("Signing-\(UUID().uuidString)", isDirectory: true)
        let workRoot = tempRoot.appendingPathComponent("work", isDirectory: true)
        let outputTemp = tempRoot.appendingPathComponent("signed.ipa")
        try fileManager.createDirectory(at: workRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        onUpdate(SigningUpdate(phase: .preparing, progress: 0.04, text: "prepare  \(task.ipa.fileName)", level: .phase))
        onUpdate(SigningUpdate(progress: 0.08, text: "workdir  \(workRoot.lastPathComponent)", level: .detail))

        try cancelFlag.throwIfCancelled()
        onUpdate(SigningUpdate(phase: .unpacking, progress: 0.14, text: "unpack  \(task.ipa.sizeText)", level: .phase))
        try unpack(task.ipa.url, to: workRoot)
        onUpdate(SigningUpdate(progress: 0.28, text: "unpacked  Payload + metadata", level: .success))

        let payload = workRoot.appendingPathComponent("Payload", isDirectory: true)
        let contents = (try? fileManager.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw SigningEngineError.noPayload
        }
        onUpdate(SigningUpdate(progress: 0.32, text: "bundle  \(appURL.lastPathComponent)", level: .info))

        if !task.removeTargetPaths.isEmpty {
            for path in task.removeTargetPaths where !path.isEmpty {
                let target = appURL.appendingPathComponent(path).standardizedFileURL
                guard target.path.hasPrefix(appURL.standardizedFileURL.path + "/") else { continue }
                if FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.removeItem(at: target)
                    onUpdate(SigningUpdate(progress: 0.33, text: "remove uncovered target  \(path)", level: .warning))
                }
            }
        }
        if task.removeWatchApp {
            removeWatchAppBundle(from: appURL, onUpdate: onUpdate)
        }

        let targetCredentials = Self.normalizedTargetCredentials(task.targetCredentials)
        if !task.removeProvision {
            embedNestedProvisioningProfiles(in: appURL, credentials: targetCredentials, task: task, onUpdate: onUpdate)
        }

        var entitlementsPath = ""
        if let entitlementsPlist = task.entitlementsPlist {
            let entitlementsURL = tempRoot.appendingPathComponent("entitlements.plist")
            try entitlementsPlist.write(to: entitlementsURL, options: .atomic)
            entitlementsPath = entitlementsURL.path
            onUpdate(SigningUpdate(progress: 0.34, text: "entitlements  custom selection", level: .info))
        }

        if !task.injections.isEmpty {
            try applyInjections(task.injections, to: appURL, removeTargetPaths: task.removeTargetPaths, onUpdate: onUpdate)
        }

        Zsign.setSkipSignPaths(targetCredentials.map(\.bundlePath))
        defer { Zsign.setSkipSignPaths([]) }

        for credentials in targetCredentials {
            let targetURL = appURL.appendingPathComponent(credentials.bundlePath, isDirectory: true)
            guard fileManager.fileExists(atPath: targetURL.path) else { continue }
            var targetEntitlementsPath = ""
            if let data = credentials.entitlementsPlist {
                let safeName = credentials.bundlePath.replacingOccurrences(of: "/", with: "_")
                let entitlementsURL = tempRoot.appendingPathComponent("entitlements-\(safeName).plist")
                try data.write(to: entitlementsURL, options: .atomic)
                targetEntitlementsPath = entitlementsURL.path
            }
            if credentials.bundleIdentifier != credentials.originalBundleIdentifier
                || task.bundleIdentifier != task.ipa.bundleIdentifier {
                try rewriteTargetReferences(
                    at: targetURL,
                    credentials: credentials,
                    allCredentials: targetCredentials,
                    oldMainID: task.ipa.bundleIdentifier,
                    newMainID: task.bundleIdentifier,
                    onUpdate: onUpdate
                )
            }
            onUpdate(SigningUpdate(progress: 0.38, text: "target sign  \(credentials.bundlePath)  \(credentials.profile.displayName)", level: .info))
            try signTargetBundle(
                targetURL,
                profileURL: credentials.profileURL,
                certificateURL: credentials.certificateURL,
                password: credentials.password,
                entitlementsPath: targetEntitlementsPath,
                targetLabel: credentials.bundlePath,
                customIdentifier: credentials.bundleIdentifier == credentials.originalBundleIdentifier ? "" : credentials.bundleIdentifier,
                removeProvision: task.removeProvision
            )
            onUpdate(SigningUpdate(progress: 0.40, text: "target signed  \(credentials.bundlePath)", level: .success))
        }

        try cancelFlag.throwIfCancelled()
        onUpdate(SigningUpdate(phase: .signing, progress: 0.42, text: "sign  Zsign + \(task.certificate.commonName)", level: .phase))
        try runZsign(task: task, cancelFlag: cancelFlag, appPath: appURL.path, entitlementsPath: entitlementsPath, onUpdate: onUpdate)
        try cancelFlag.throwIfCancelled()
        onUpdate(SigningUpdate(progress: 0.74, text: "signed  \(task.bundleIdentifier)", level: .success))

        onUpdate(SigningUpdate(phase: .packing, progress: 0.82, text: "pack  IPA", level: .phase))
        try pack(workRoot, to: outputTemp)
        guard fileManager.fileExists(atPath: outputTemp.path) else {
            throw SigningEngineError.outputMissing
        }

        let stem = task.ipa.url.deletingPathExtension().lastPathComponent
        var outputURL = task.outputDirectory.appendingPathComponent("\(stem)-signed.ipa")
        if fileManager.fileExists(atPath: outputURL.path) {
            outputURL = task.outputDirectory.appendingPathComponent("\(stem)-signed-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).ipa")
        }
        try? fileManager.removeItem(at: outputURL)
        try fileManager.moveItem(at: outputTemp, to: outputURL)
        let size = (try? fileManager.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0

        onUpdate(SigningUpdate(phase: .completed, progress: 1.0, text: "output  \(outputURL.lastPathComponent)  \(formatBytes(size))", level: .success))
        return outputURL
    }

    private static func removeWatchAppBundle(
        from appURL: URL,
        onUpdate: @escaping @Sendable (SigningUpdate) -> Void
    ) {
        let watchURL = appURL.appendingPathComponent("Watch", isDirectory: true)
        guard FileManager.default.fileExists(atPath: watchURL.path) else {
            onUpdate(SigningUpdate(progress: 0.33, text: "watch  not present", level: .info))
            return
        }
        try? FileManager.default.removeItem(at: watchURL)
        onUpdate(SigningUpdate(progress: 0.33, text: "watch  removed", level: .success))
    }

    private static func embedNestedProvisioningProfiles(
        in appURL: URL,
        credentials: [SigningTargetCredentials],
        task: SigningIPTask,
        onUpdate: @escaping @Sendable (SigningUpdate) -> Void
    ) {
        let fileManager = FileManager.default
        let root = appURL.standardizedFileURL
        let rootPrefix = root.path + "/"
        var embedded = 0

        for credentials in credentials {
            let target = appURL.appendingPathComponent(credentials.bundlePath).standardizedFileURL
            guard target.path.hasPrefix(rootPrefix),
                  target.pathExtension.lowercased() == "appex",
                  fileManager.fileExists(atPath: target.path) else { continue }
            write(profile: credentials.profileURL, into: target, fileManager: fileManager)
            embedded += 1
            onUpdate(SigningUpdate(progress: 0.335, text: "profile  \(credentials.bundlePath) / \(credentials.profile.displayName)", level: .info))
        }

        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard url.pathExtension.lowercased() == "appex" else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPrefix.count))
            if credentials.contains(where: { $0.bundlePath == relative }) {
                continue
            }
            guard !task.removeTargetPaths.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) else { continue }
            if let containing = credentials.last(where: { relative.hasPrefix($0.bundlePath + "/") }) {
                write(profile: containing.profileURL, into: url, fileManager: fileManager)
                embedded += 1
                onUpdate(SigningUpdate(progress: 0.335, text: "profile  \(relative) / \(containing.profile.displayName)", level: .info))
                continue
            }
            write(profile: task.profileURL, into: url, fileManager: fileManager)
            embedded += 1
            onUpdate(SigningUpdate(progress: 0.335, text: "profile  \(relative) / main", level: .info))
        }

        if embedded > 0 {
            onUpdate(SigningUpdate(progress: 0.336, text: "embedded.mobileprovision  \(embedded) appex", level: .success))
        }
    }

    private static func normalizedTargetCredentials(_ credentials: [SigningTargetCredentials]) -> [SigningTargetCredentials] {
        let sorted = credentials.sorted {
            $0.bundlePath.components(separatedBy: "/").count
                < $1.bundlePath.components(separatedBy: "/").count
        }
        var result: [SigningTargetCredentials] = []
        for credential in sorted {
            if !result.contains(where: { credential.bundlePath.hasPrefix($0.bundlePath + "/") }) {
                result.append(credential)
            }
        }
        return result
    }

    private static func write(profile profileURL: URL, into bundleURL: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: profileURL.path) else { return }
        let destination = bundleURL.appendingPathComponent("embedded.mobileprovision")
        try? fileManager.removeItem(at: destination)
        try? fileManager.copyItem(at: profileURL, to: destination)
    }

    private static func applyInjections(
        _ injections: [SigningInjection],
        to appURL: URL,
        removeTargetPaths: [String],
        onUpdate: @escaping @Sendable (SigningUpdate) -> Void
    ) throws {
        let fileManager = FileManager.default

        for injection in injections {
            let targetIDs = injection.targets.isEmpty ? ["."] : injection.targets.sorted()
            for targetID in targetIDs {
                let targetBundle = targetID == "." ? appURL : appURL.appendingPathComponent(targetID, isDirectory: true)
                guard fileManager.fileExists(atPath: targetBundle.path) else {
                    let explicitlyRemoved = removeTargetPaths.contains { $0 == targetID || targetID.hasPrefix($0 + "/") }
                    if explicitlyRemoved {
                        onUpdate(SigningUpdate(progress: 0.36, text: "inject skip  \(injection.name) · \(targetID) (target removed)", level: .warning))
                        continue
                    }
                    throw SigningEngineError.injectionFailed("\(injection.name) · \(targetID)")
                }

                let infoURL = targetBundle.appendingPathComponent("Info.plist")
                guard let infoData = try? Data(contentsOf: infoURL),
                      let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
                      let executableName = info["CFBundleExecutable"] as? String,
                      !executableName.isEmpty else {
                    throw SigningEngineError.injectionFailed("\(injection.name) · CFBundleExecutable")
                }
                let executable = targetBundle.appendingPathComponent(executableName)

                let frameworks = targetBundle.appendingPathComponent("Frameworks", isDirectory: true)
                try? fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)

                let destinationName = injection.url.lastPathComponent
                let destination = frameworks.appendingPathComponent(destinationName)
                try? fileManager.removeItem(at: destination)
                do {
                    try fileManager.copyItem(at: injection.url, to: destination)
                } catch {
                    throw SigningEngineError.injectionFailed("\(injection.name) · \(targetID)")
                }

                let loadPath: String
                if injection.isFramework {
                    let frameworkInfoURL = destination.appendingPathComponent("Info.plist")
                    let frameworkInfo = (try? Data(contentsOf: frameworkInfoURL)).flatMap {
                        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
                    }
                    let binaryName = (frameworkInfo?["CFBundleExecutable"] as? String)
                        ?? destination.deletingPathExtension().lastPathComponent
                    loadPath = "@executable_path/Frameworks/\(destinationName)/\(binaryName)"
                } else {
                    loadPath = "@executable_path/Frameworks/\(destinationName)"
                }

                let injected = Zsign.injectDyLib(appExecutable: executable.path, with: loadPath, weak: injection.weak)
                guard injected else {
                    throw SigningEngineError.injectionFailed("\(injection.name) · \(targetID)")
                }
                let targetLabel = targetID == "." ? "main" : targetID
                onUpdate(SigningUpdate(progress: 0.36, text: "inject  \(targetLabel)  \(loadPath)", level: .success))
            }
        }
    }

    private static func signTargetBundle(
        _ targetURL: URL,
        profileURL: URL,
        certificateURL: URL,
        password: String,
        entitlementsPath: String,
        targetLabel: String,
        customIdentifier: String = "",
        removeProvision: Bool = false
    ) throws {
        let box = ZsignErrorBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Zsign.sign(
                appPath: targetURL.path,
                provisionPath: profileURL.path,
                p12Path: certificateURL.path,
                p12Password: password,
                entitlementsPath: entitlementsPath,
                customIdentifier: customIdentifier,
                customName: "",
                customVersion: "",
                adhoc: false,
                removeProvision: !removeProvision,
                completion: { _, error in
                    box.set(error)
                }
            )
            if !ok {
                box.set(box.get() ?? SigningEngineError.signFailed("Zsign returned false"))
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.get() {
            throw SigningEngineError.signFailed("\(targetLabel): \(error.localizedDescription)")
        }
    }


    private static func rewriteTargetReferences(
        at targetURL: URL,
        credentials: SigningTargetCredentials,
        allCredentials: [SigningTargetCredentials],
        oldMainID: String,
        newMainID: String,
        onUpdate: @escaping @Sendable (SigningUpdate) -> Void
    ) throws {
        let infoURL = targetURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              var plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return
        }

        var replacements: [String: String] = [:]
        if !oldMainID.isEmpty, !newMainID.isEmpty {
            replacements[oldMainID] = newMainID
        }
        for credential in allCredentials where !credential.originalBundleIdentifier.isEmpty {
            replacements[credential.originalBundleIdentifier] = credential.bundleIdentifier
        }

        func mapped(_ value: String) -> String {
            if let direct = replacements[value] {
                return direct
            }
            if !oldMainID.isEmpty,
               !newMainID.isEmpty,
               value.hasPrefix(oldMainID + ".") {
                return newMainID + String(value.dropFirst(oldMainID.count))
            }
            return value
        }

        var changed = false

        if let companion = plist["WKCompanionAppBundleIdentifier"] as? String {
            let updated = mapped(companion)
            if updated != companion {
                plist["WKCompanionAppBundleIdentifier"] = updated
                changed = true
                onUpdate(SigningUpdate(progress: 0.37, text: "bundle id  \(companion) -> \(updated)", level: .detail))
            }
        }

        if var extensionDict = plist["NSExtension"] as? [String: Any],
           var attributes = extensionDict["NSExtensionAttributes"] as? [String: Any],
           let appBundleID = attributes["WKAppBundleIdentifier"] as? String {
            let updated = mapped(appBundleID)
            if updated != appBundleID {
                attributes["WKAppBundleIdentifier"] = updated
                extensionDict["NSExtensionAttributes"] = attributes
                plist["NSExtension"] = extensionDict
                changed = true
                onUpdate(SigningUpdate(progress: 0.37, text: "bundle id  \(appBundleID) -> \(updated)", level: .detail))
            }
        }

        guard changed else { return }
        let updatedData = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try updatedData.write(to: infoURL, options: .atomic)
    }

    private static func runZsign(
        task: SigningIPTask,
        cancelFlag: SigningCancelFlag,
        appPath: String,
        entitlementsPath: String,
        onUpdate: @escaping @Sendable (SigningUpdate) -> Void
    ) throws {
        try cancelFlag.throwIfCancelled()
        let box = ZsignErrorBox()
        let semaphore = DispatchSemaphore(value: 0)
        let zsignEmbedsProfile = !task.removeProvision
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Zsign.sign(
                appPath: appPath,
                provisionPath: task.profileURL.path,
                p12Path: task.certificateURL.path,
                p12Password: task.password,
                entitlementsPath: entitlementsPath,
                customIdentifier: task.bundleIdentifier,
                customName: task.displayName,
                customVersion: task.version,
                adhoc: false,
                removeProvision: zsignEmbedsProfile,
                completion: { _, error in
                    box.set(error)
                }
            )
            if !ok {
                box.set(box.get() ?? SigningEngineError.signFailed("Zsign returned false"))
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.get() {
            throw SigningEngineError.signFailed(error.localizedDescription)
        }
        onUpdate(SigningUpdate(progress: 0.70, text: "zsign  completed", level: .detail))
    }

    private static func unpack(_ source: URL, to destination: URL) throws {
        var errorBuffer = [CChar](repeating: 0, count: 1024)
        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                fp_zip_unpack(sourcePath, destinationPath, &errorBuffer, Int32(errorBuffer.count))
            }
        }
        guard status == 0 else {
            throw SigningEngineError.unpackFailed(String(cString: errorBuffer))
        }
    }

    private static func pack(_ source: URL, to destination: URL) throws {
        var errorBuffer = [CChar](repeating: 0, count: 1024)
        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                fp_zip_pack(sourcePath, destinationPath, &errorBuffer, Int32(errorBuffer.count))
            }
        }
        guard status == 0 else {
            throw SigningEngineError.packFailed(String(cString: errorBuffer))
        }
    }

    private static func formatBytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: value)
    }
}

@MainActor
final class SigningSession: ObservableObject {
    @Published private(set) var phase: SigningPhase = .idle
    @Published private(set) var outcome: SigningOutcome = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var lines: [DecryptLogLine] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isRunning = false
    @Published var isExpanded = true
    @Published private(set) var outputURL: URL?
    @Published private(set) var errorMessage: String?

    private let tasks = TaskBag()
    private let signingTaskKey = "signing"
    private var ticker: Timer?
    private var startedAt: Date?
    private var cancelled = false
    private var islandKey: String?
    private var islandTitle = ""
    private var islandPercent = -1
    private var islandPhase = ""

    var isActive: Bool {
        phase != .idle || !lines.isEmpty
    }

    func start(_ taskRequest: SigningIPTask) {
        SoundEffects.play(.press)
        reset()
        isRunning = true
        isExpanded = true
        outcome = .running
        phase = .preparing
        startedAt = Date()
        startTicker()
        append("input  \(taskRequest.ipa.fileName)  \(taskRequest.ipa.sizeText)", level: .phase)
        append("cert  \(taskRequest.certificate.commonName)  \(taskRequest.certificate.teamID)", level: .info)
        append("profile  \(taskRequest.profile.displayName)  \(taskRequest.profile.applicationIdentifier)", level: .info)
        append("bundle  \(taskRequest.bundleIdentifier)", level: .detail)

        let key = IslandTaskKey.sign(UUID())
        islandKey = key
        islandTitle = taskRequest.displayName.isEmpty ? taskRequest.ipa.displayName : taskRequest.displayName
        SigningCancelCenter.shared.register(key) { [weak self] in
            self?.cancel()
        }
        reportIsland(progress: 0.04, phase: SigningPhase.preparing.title, detail: taskRequest.certificate.commonName)

        tasks.replace(key: signingTaskKey) { [weak self] token in
            guard let self else { return }
            do {
                let output = try await SigningEngine.sign(taskRequest) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.tasks.isCurrent(token, for: self.signingTaskKey) else { return }
                        self.apply(update)
                    }
                }
                guard self.tasks.isCurrent(token, for: self.signingTaskKey) else { return }
                self.finish(output: output, error: nil)
            } catch {
                guard self.tasks.isCurrent(token, for: self.signingTaskKey) else { return }
                self.finish(output: nil, error: error)
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        cancelled = true
        tasks.cancel(key: signingTaskKey)
        append("cancelling…", level: .warning)
    }

    private func apply(_ update: SigningUpdate) {
        if let phase = update.phase { self.phase = phase }
        if let progress = update.progress {
            self.progress = max(self.progress, min(1, progress))
        }
        if let text = update.text {
            append(text, level: update.level)
        }
        reportIsland(progress: progress, phase: phase.title, detail: update.text ?? "")
    }

    private func reportIsland(progress: Double, phase: String, detail: String) {
        guard let key = islandKey else { return }
        let percent = Int((min(max(progress, 0), 1) * 100).rounded())
        guard percent != islandPercent || phase != islandPhase else { return }
        islandPercent = percent
        islandPhase = phase
        IslandActivityManager.shared.start(
            key: key,
            kind: IslandTaskKind.sign,
            title: islandTitle,
            phase: phase,
            detail: String(detail.prefix(80)),
            progress: min(max(progress, 0), 1)
        )
    }

    private func finish(output: URL?, error: Error?) {
        isRunning = false
        ticker?.invalidate()
        ticker = nil
        if let startedAt {
            elapsed = Date().timeIntervalSince(startedAt)
        }
        let key = islandKey
        if let output, !cancelled {
            SoundEffects.play(.success)
            phase = .completed
            progress = 1
            outcome = .completed
            outputURL = output
            append("done  \(output.lastPathComponent)", level: .success)
            if let key {
                IslandActivityManager.shared.finish(key: key, detail: output.lastPathComponent)
            }
        } else {
            let message = error?.localizedDescription ?? "sign_err_unknown".localized
            errorMessage = message
            if cancelled {
                outcome = .cancelled
            } else if let engineError = error as? SigningEngineError, case .cancelled = engineError {
                outcome = .cancelled
            } else {
                outcome = .failed
            }
            SoundEffects.play(cancelled ? .fall : .error)
            append("failed  \(message)", level: .failure)
            if let key {
                IslandActivityManager.shared.fail(
                    key: key,
                    reason: message,
                    cancelled: outcome == .cancelled
                )
            }
        }
        SigningCancelCenter.shared.unregister(key)
        islandKey = nil
    }

    private func append(_ text: String, level: DecryptLogLevel) {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        lines.append(DecryptLogLine(text: trimmed, level: level, time: Date()))
        if lines.count > 800 {
            lines.removeFirst(lines.count - 800)
        }
    }

    private func reset() {
        tasks.cancel(key: signingTaskKey)
        ticker?.invalidate()
        ticker = nil
        SigningCancelCenter.shared.unregister(islandKey)
        islandKey = nil
        islandTitle = ""
        islandPercent = -1
        islandPhase = ""
        phase = .idle
        outcome = .idle
        progress = 0
        lines.removeAll()
        elapsed = 0
        isRunning = false
        outputURL = nil
        errorMessage = nil
        cancelled = false
        startedAt = nil
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    deinit {
        ticker?.invalidate()
    }
}

struct SigningIPAInfo: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let fileSize: Int64
    let bundleIdentifier: String
    let version: String
    let build: String
    let displayName: String
    let name: String
    let isEncrypted: Bool
    let requiredEntitlementKeys: Set<String>
    let hasOriginalProfile: Bool

    var fileName: String { url.lastPathComponent }

    var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: fileSize)
    }

    private static func mainExecutableIsEncrypted(
        data: Data,
        entries: [FastZipArchive.CentralDirectoryEntry],
        appInfoEntry: FastZipArchive.CentralDirectoryEntry,
        executableName: String?
    ) -> Bool {
        guard let executableName, !executableName.isEmpty else { return false }
        let prefix = String(appInfoEntry.filename.dropLast("Info.plist".count))
        let executablePath = prefix + executableName
        guard let entry = entries.first(where: { $0.filename == executablePath }),
              let executableData = try? FastZipArchive.extractSingleEntry(from: data, entry: entry) else {
            return false
        }
        return machOIsEncrypted(executableData)
    }

    private static func machOIsEncrypted(_ data: Data) -> Bool {
        guard data.count >= 32 else { return false }
        func readUInt32(_ offset: Int) -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { return 0 }
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }
        let magic = readUInt32(0)
        let is64 = magic == 0xfeedfacf
        let is32 = magic == 0xfeedface
        guard is64 || is32 else { return false }
        let headerSize = is64 ? 32 : 28
        let commandCount = readUInt32(16)
        var offset = headerSize
        for _ in 0..<commandCount {
            guard offset + 8 <= data.count else { break }
            let command = readUInt32(offset)
            let commandSize = readUInt32(offset + 4)
            guard commandSize >= 8, offset + Int(commandSize) <= data.count else { break }
            if command == 0x21 || command == 0x2c, offset + 20 <= data.count {
                if readUInt32(offset + 16) != 0 { return true }
            }
            offset += Int(commandSize)
        }
        return false
    }

    static func read(url: URL) throws -> SigningIPAInfo {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard let eocd = FastZipArchive.findEndOfCentralDirectory(in: data),
              let entries = try? FastZipArchive.readCentralDirectory(from: data, eocd: eocd),
              let infoEntry = entries.first(where: {
                  let parts = $0.filename.split(separator: "/").map(String.init)
                  return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
              }),
              let infoData = try? FastZipArchive.extractSingleEntry(from: data, entry: infoEntry),
              let plist = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let bundleIdentifier = plist["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            throw SigningEngineError.missingInput(url.lastPathComponent)
        }
        let version = (plist["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (plist["CFBundleVersion"] as? String) ?? ""
        let displayName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? bundleIdentifier
        let name = (plist["CFBundleName"] as? String) ?? displayName
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let encrypted = mainExecutableIsEncrypted(
            data: data,
            entries: entries,
            appInfoEntry: infoEntry,
            executableName: plist["CFBundleExecutable"] as? String
        )
        let appPrefix = String(infoEntry.filename.dropLast("Info.plist".count))
        let originalProfilePath = appPrefix + "embedded.mobileprovision"
        var requiredEntitlementKeys: Set<String> = []
        var hasOriginalProfile = false
        if let profileEntry = entries.first(where: { $0.filename == originalProfilePath }),
           let profileData = try? FastZipArchive.extractSingleEntry(from: data, entry: profileEntry),
           let metadata = try? SigningParser.profile(data: profileData) {
            requiredEntitlementKeys = Set(metadata.entitlementKeys)
            hasOriginalProfile = true
        }
        return SigningIPAInfo(
            url: url,
            fileSize: size,
            bundleIdentifier: bundleIdentifier,
            version: version,
            build: build,
            displayName: displayName,
            name: name,
            isEncrypted: encrypted,
            requiredEntitlementKeys: requiredEntitlementKeys,
            hasOriginalProfile: hasOriginalProfile
        )
    }
}

enum SigningInstallerError: LocalizedError {
    case serverUnavailable
    case manifestUnavailable
    case openFailed

    var errorDescription: String? {
        switch self {
        case .serverUnavailable: return "sign_install_server_unavailable".localized
        case .manifestUnavailable: return "sign_install_manifest_unavailable".localized
        case .openFailed: return "sign_install_open_failed".localized
        }
    }
}

enum SigningInstallPhase: Equatable {
    case idle
    case preparing
    case connecting
    case transferring(Double)
    case awaitingSystem
    case delivered
    case failed(String)
}

@MainActor
enum SigningInstaller {
    static func install(
        ipaURL: URL,
        onPhase: (@MainActor (SigningInstallPhase) -> Void)? = nil
    ) async throws {
        let info = try SigningIPAInfo.read(url: ipaURL)
        do {
            try await SigningOTAInstaller.install(ipaURL: ipaURL, info: info, onPhase: onPhase)
        } catch {
            print("[SignInstall] Falling back to local HTTPS install: \(error.localizedDescription)")
            try await installViaLocalHTTPS(ipaURL: ipaURL, onPhase: onPhase)
        }
    }

    static func installViaLocalHTTPS(
        ipaURL: URL,
        onPhase: (@MainActor (SigningInstallPhase) -> Void)? = nil
    ) async throws {
        onPhase?(.preparing)
        let info = try SigningIPAInfo.read(url: ipaURL)
        let requestID = UUID()
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "signing.install") {
            DispatchQueue.main.async {
                guard backgroundTask != .invalid else { return }
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        InstallKeepAlive.shared.start()
        let port = HTTPServerManager.shared.allocatePort()
        let host = currentLocalIPv4() ?? "127.0.0.1"
        let appInfo = AppInfo(
            name: info.displayName.isEmpty ? info.name : info.displayName,
            version: info.version,
            bundleIdentifier: info.bundleIdentifier,
            path: ipaURL.path,
            localPath: ipaURL.path
        )
        HTTPServerManager.shared.startServer(
            for: requestID,
            port: port,
            host: host,
            ipaPath: ipaURL.path,
            appInfo: appInfo
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 15
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)

        let healthURLString = "https://\(installServerHost):\(port)/health"
        var healthy = false
        for _ in 1...20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let url = URL(string: healthURLString) else { break }
            if let (_, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                healthy = true
                break
            }
        }
        guard healthy else {
            HTTPServerManager.shared.stopServer(for: requestID)
            InstallKeepAlive.shared.stop()
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            onPhase?(.failed(SigningInstallerError.serverUnavailable.localizedDescription))
            throw SigningInstallerError.serverUnavailable
        }
        onPhase?(.connecting)

        let manifestString = "https://\(installServerHost):\(port)/plist/\(info.bundleIdentifier)"
        guard let manifestURL = URL(string: manifestString),
              let (data, response) = try? await session.data(from: manifestURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              String(data: data, encoding: .utf8)?.contains("<plist") == true else {
            HTTPServerManager.shared.stopServer(for: requestID)
            InstallKeepAlive.shared.stop()
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            throw SigningInstallerError.manifestUnavailable
        }

        let itmsString = "itms-services://?action=download-manifest&url=" + queryEncodedForInstall(manifestString)
        guard let itmsURL = URL(string: itmsString), UIApplication.shared.canOpenURL(itmsURL) else {
            HTTPServerManager.shared.stopServer(for: requestID)
            InstallKeepAlive.shared.stop()
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            throw SigningInstallerError.openFailed
        }

        let opened = await withCheckedContinuation { continuation in
            UIApplication.shared.open(itmsURL, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
        guard opened else {
            HTTPServerManager.shared.stopServer(for: requestID)
            InstallKeepAlive.shared.stop()
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            onPhase?(.failed(SigningInstallerError.openFailed.localizedDescription))
            throw SigningInstallerError.openFailed
        }
        onPhase?(.awaitingSystem)

        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 600) {
            Task { @MainActor in
                HTTPServerManager.shared.stopServer(for: requestID)
                InstallKeepAlive.shared.stop()
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            }
        }
    }
}

private func queryEncodedForInstall(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}
