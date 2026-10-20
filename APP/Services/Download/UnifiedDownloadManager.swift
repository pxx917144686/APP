import Foundation
import SwiftUI
import Combine

@MainActor
class UnifiedDownloadManager: ObservableObject, @unchecked Sendable {
    static let shared = UnifiedDownloadManager()

    @Published var downloadRequests: [DownloadRequest] = []
    @Published var completedRequests: Set<UUID> = []
    @Published var activeDownloads: Set<UUID> = []
    @Published var waitingDownloads: Set<UUID> = []

    var sortedDownloadRequests: [DownloadRequest] {
        downloadRequests.sorted { req1, req2 in
            let priority1 = downloadPriority(for: req1)
            let priority2 = downloadPriority(for: req2)
            if priority1 != priority2 {
                return priority1 > priority2
            }
            return req1.createdAt > req2.createdAt
        }
    }

    private func downloadPriority(for request: DownloadRequest) -> Int {
        switch request.runtime.status {
        case .downloading:
            return 4
        case .waiting:
            return 3
        case .paused:
            return 2
        case .failed:
            return 1
        case .cancelled:
            return 1
        case .completed:
            return 0
        }
    }

    var maxConcurrentDownloads: Int = 3

    private let downloadManager = AppStoreDownloadManager.shared
    private let purchaseManager = PurchaseManager.shared

    private var downloadQueue: [DownloadRequest] = []
    private var reservedDestinationPaths: Set<String> = []
    private var requestDestinationPaths: [UUID: String] = [:]

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private var downloadsDirectory: URL {
        let fm = FileManager.default
        let docs = documentsDirectory
        let downloads = docs.appendingPathComponent("Downloads", isDirectory: true)
        if !fm.fileExists(atPath: downloads.path) {
            try? fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        }
        return downloads
    }

    private func uniqueDestinationURL(bundleId: String, version: String) -> URL {
        let baseName = "\(bundleId)_\(version)"
        let baseURL = downloadsDirectory.appendingPathComponent(baseName).appendingPathExtension("ipa")

        return baseURL
    }

    private func relativePath(for fullPath: String) -> String {
        let docsPath = documentsDirectory.path
        if fullPath.hasPrefix(docsPath) {
            return String(fullPath.dropFirst(docsPath.count + 1))
        }
        return (fullPath as NSString).lastPathComponent
    }

    private func fullPath(for relativePath: String) -> String {
        documentsDirectory.appendingPathComponent(relativePath).path
    }

    private init() {

        configureSessionMonitoring()
    }

    private func configureSessionMonitoring() {

        Task { @MainActor in
            restoreDownloadTasks()
            restoreBackgroundDownloadHandlers()
            syncDownloadStatus()
        }

        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.saveDownloadTasks()
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.restoreBackgroundDownloadHandlers()
                self.syncDownloadStatus()
                self.saveDownloadTasks()
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.saveDownloadTasks()
            }
        }
    }

    private func restoreSingleDownloadHandler(for request: DownloadRequest) {
        let downloadId = request.id.uuidString

        downloadManager.attachHandlers(
            for: downloadId,
            progressHandler: { downloadProgress in
                Task { @MainActor in
                    request.runtime.updateProgress(
                        completed: downloadProgress.bytesDownloaded,
                        total: downloadProgress.totalBytes
                    )
                    request.runtime.speed = downloadProgress.formattedSpeed

                    switch downloadProgress.status {
                    case .waiting:
                        request.runtime.status = DownloadStatus.waiting
                    case .downloading:
                        request.runtime.status = DownloadStatus.downloading
                    case .paused:
                        request.runtime.status = DownloadStatus.paused
                    case .completed:
                        request.runtime.status = DownloadStatus.completed
                    case .failed:
                        request.runtime.status = DownloadStatus.failed
                    case .cancelled:
                        request.runtime.status = DownloadStatus.cancelled
                    }

                    request.objectWillChange.send()
                    request.runtime.objectWillChange.send()
                }
            },
            completion: { result in
                Task { @MainActor in
                    guard request.runtime.status != .completed,
                          request.runtime.status != .failed else {
                        return
                    }

                    switch result {
                    case .success(let downloadResult):
                        request.runtime.updateProgress(
                            completed: downloadResult.fileSize,
                            total: downloadResult.fileSize
                        )
                        request.runtime.status = DownloadStatus.completed
                        request.localFilePath = downloadResult.fileURL.path
                        self.completedRequests.insert(request.id)
                        self.saveDownloadTasks()

                    case .failure(let error):
                        request.runtime.error = error.localizedDescription
                        request.runtime.status = DownloadStatus.failed
                    }

                    self.activeDownloads.remove(request.id)
                    self.processNextInQueue()
                }
            }
        )
    }

    private func restoreBackgroundDownloadHandlers() {
        downloadManager.restoreBackgroundTasks(
            progressHandler: { [weak self] downloadId, downloadProgress in
                Task { @MainActor in
                    guard let self = self else { return }
                    let uuid = UUID(uuidString: downloadId)
                    guard let request = self.downloadRequests.first(where: { $0.id.uuidString == downloadId || $0.id == uuid }) else {
                        return
                    }

                    request.runtime.updateProgress(
                        completed: downloadProgress.bytesDownloaded,
                        total: downloadProgress.totalBytes
                    )
                    request.runtime.speed = downloadProgress.formattedSpeed
                    request.runtime.status = .downloading

                    if !self.activeDownloads.contains(request.id) {
                        self.activeDownloads.insert(request.id)
                    }

                    request.objectWillChange.send()
                    request.runtime.objectWillChange.send()
                }
            },
            completion: { [weak self] downloadId, result in
                Task { @MainActor in
                    guard let self = self else { return }
                    let uuid = UUID(uuidString: downloadId)
                    guard let request = self.downloadRequests.first(where: { $0.id.uuidString == downloadId || $0.id == uuid }) else {
                        return
                    }

                    guard request.runtime.status != .completed,
                          request.runtime.status != .failed else {
                        return
                    }

                    switch result {
                    case .success(let downloadResult):
                        request.runtime.updateProgress(
                            completed: downloadResult.fileSize,
                            total: downloadResult.fileSize
                        )
                        request.runtime.status = .completed
                        request.localFilePath = downloadResult.fileURL.path
                        self.completedRequests.insert(request.id)

                    case .failure(let error):
                        request.runtime.error = error.localizedDescription
                        request.runtime.status = .failed
                    }

                    self.activeDownloads.remove(request.id)
                    self.processNextInQueue()
                    self.saveDownloadTasks()
                }
            }
        )
    }

    func addDownload(
        bundleIdentifier: String,
        name: String,
        version: String,
        identifier: Int,
        iconURL: String? = nil,
        versionId: String? = nil,
        price: Double? = nil,
        currency: String? = nil
    ) -> UUID {

        if let existing = downloadRequests.first(where: {
            $0.bundleIdentifier == bundleIdentifier && $0.version == version
        }) {
            return existing.id
        }

        let package = DownloadArchive(
            bundleIdentifier: bundleIdentifier,
            name: name,
            version: version,
            identifier: identifier,
            iconURL: iconURL,
            price: price,
            currency: currency
        )

        let request = DownloadRequest(
            bundleIdentifier: bundleIdentifier,
            version: version,
            name: name,
            package: package,
            versionId: versionId
        )

        downloadRequests.append(request)
        return request.id
    }

    func deleteDownload(request: DownloadRequest) {
        if let index = downloadRequests.firstIndex(where: { $0.id == request.id }) {
            downloadRequests.remove(at: index)
        }
        if let queueIndex = downloadQueue.firstIndex(where: { $0.id == request.id }) {
            downloadQueue.remove(at: queueIndex)
        }
        if let destPath = requestDestinationPaths[request.id] {
            reservedDestinationPaths.remove(destPath)
            requestDestinationPaths.removeValue(forKey: request.id)
        }
        if let localPath = request.localFilePath {
            reservedDestinationPaths.remove(localPath)
        }
        activeDownloads.remove(request.id)
        completedRequests.remove(request.id)
        waitingDownloads.remove(request.id)
    }

    func startDownload(for request: DownloadRequest) {
        guard request.runtime.status != .completed else {
            return
        }

        guard !activeDownloads.contains(request.id),
              !waitingDownloads.contains(request.id) else {
            return
        }

        if activeDownloads.count >= maxConcurrentDownloads {
            request.runtime.status = DownloadStatus.waiting
            waitingDownloads.insert(request.id)
            downloadQueue.append(request)
            return
        }

        activeDownloads.insert(request.id)
        request.runtime.status = DownloadStatus.downloading
        request.runtime.error = nil

        request.runtime.progress = Progress(totalUnitCount: 0)
        request.runtime.progress.completedUnitCount = 0

        Task {
            let downloadId = request.id.uuidString
            let hasBackgroundTask = await self.downloadManager.hasBackgroundTask(for: downloadId)
            if hasBackgroundTask || self.downloadManager.hasActiveDownload(for: downloadId) {
                await MainActor.run {
                    self.restoreSingleDownloadHandler(for: request)
                }
                return
            }
            guard let account = AppStore.this.selectedAccount else {
                await MainActor.run {
                    request.runtime.error = "请先添加Apple ID账户"
                    request.runtime.status = DownloadStatus.failed
                    self.activeDownloads.remove(request.id)
                }
                self.processNextInQueue()
                return
            }

            AuthenticationManager.shared.setCookies(account.cookies)

            let storeAccount = Account(
                name: account.email,
                email: account.email,
                firstName: account.firstName,
                lastName: account.lastName,
                passwordToken: account.storeResponse.passwordToken,
                directoryServicesIdentifier: account.storeResponse.directoryServicesIdentifier,
                dsPersonId: account.storeResponse.directoryServicesIdentifier,
                cookies: account.cookies,
                countryCode: account.countryCode,
                pod: account.pod,
                storeResponse: account.storeResponse,
                deviceGUID: account.deviceGUID,
                hsc: account.hsc,
                adsid: account.adsid,
                idmsToken: account.idmsToken
            )

            let isValid = await AuthenticationManager.shared.validateAccount(storeAccount)
            if !isValid {
                await MainActor.run {
                    request.runtime.error = "Apple ID会话已过期，请重新登录"
                    request.runtime.status = DownloadStatus.failed
                    self.activeDownloads.remove(request.id)
                }
                self.processNextInQueue()
                return
            }

            let regionValidation = (account.countryCode == storeAccount.countryCode)

            if !regionValidation {
                await MainActor.run {
                    request.runtime.error = "地区设置不匹配，请检查账户地区设置"
                    request.runtime.status = DownloadStatus.failed
                    self.activeDownloads.remove(request.id)
                }
                self.processNextInQueue()
                return
            }

            let purchaseResult = await purchaseManager.purchaseAppIfNeeded(
                appIdentifier: String(request.package.identifier),
                account: storeAccount,
                countryCode: account.countryCode,
                isFree: request.package.isFree
            )

            switch purchaseResult {
            case .success:
                let effectiveVersionId: String?
                if let v = request.versionId, !v.isEmpty {
                    effectiveVersionId = v
                } else {
                    do {
                        let dlResp = try await StoreRequest.shared.download(
                            appIdentifier: String(request.package.identifier),
                            account: storeAccount,
                            appVersion: nil
                        )
                        if let firstSong = dlResp.songList.first {
                            let latestId = firstSong.metadata.softwareVersionExternalIdentifier
                            if !latestId.isEmpty {
                                effectiveVersionId = latestId
                            } else {
                                effectiveVersionId = nil
                            }
                        } else {
                            effectiveVersionId = nil
                        }
                    } catch {
                        effectiveVersionId = nil
                    }
                }

                if effectiveVersionId != request.versionId {
                    request.versionId = effectiveVersionId
                }

                proceedWithDownload(
                    for: request,
                    storeAccount: storeAccount
                )
            case .failure(let error):
                await MainActor.run {
                    request.runtime.error = error.localizedDescription
                    request.runtime.status = DownloadStatus.failed
                    self.activeDownloads.remove(request.id)
                }
                self.processNextInQueue()
            }
        }
    }

    private func proceedWithDownload(
        for request: DownloadRequest,
        storeAccount: Account
    ) {
        let bundleId = request.package.bundleIdentifier
        let version = request.version
        let destinationURL = uniqueDestinationURL(bundleId: bundleId, version: version)

        reservedDestinationPaths.insert(destinationURL.path)
        requestDestinationPaths[request.id] = destinationURL.path

        downloadManager.downloadApp(
            appIdentifier: String(request.package.identifier),
            account: storeAccount,
            destinationURL: destinationURL,
            appVersion: request.versionId,
            downloadId: request.id.uuidString,
            progressHandler: { downloadProgress in
                Task { @MainActor in

                    request.runtime.updateProgress(
                        completed: downloadProgress.bytesDownloaded,
                        total: downloadProgress.totalBytes
                    )
                    request.runtime.speed = downloadProgress.formattedSpeed

                    switch downloadProgress.status {
                    case .waiting:
                        request.runtime.status = DownloadStatus.waiting
                    case .downloading:
                        request.runtime.status = DownloadStatus.downloading
                    case .paused:
                        request.runtime.status = DownloadStatus.paused
                    case .completed:
                        request.runtime.status = DownloadStatus.completed
                    case .failed:
                        request.runtime.status = DownloadStatus.failed
                    case .cancelled:
                        request.runtime.status = DownloadStatus.cancelled
                    }

                    let progressPercent = Int(downloadProgress.progress * 100)
                    if progressPercent % 1 == 0 && progressPercent > 0 {
                    }

                    request.objectWillChange.send()
                    request.runtime.objectWillChange.send()
                }
            },
            completion: { result in
                Task { @MainActor in
                    guard request.runtime.status != .completed,
                          request.runtime.status != .failed else {
                        return
                    }

                    switch result {
                    case .success(let downloadResult):

                        request.runtime.updateProgress(
                            completed: downloadResult.fileSize,
                            total: downloadResult.fileSize
                        )
                        request.runtime.status = DownloadStatus.completed

                        request.localFilePath = downloadResult.fileURL.path
                        self.completedRequests.insert(request.id)
                        self.reservedDestinationPaths.remove(downloadResult.fileURL.path)
                        self.requestDestinationPaths.removeValue(forKey: request.id)

                        self.saveDownloadTasks()

                    case .failure(let error):
                        self.reservedDestinationPaths.remove(destinationURL.path)
                        self.requestDestinationPaths.removeValue(forKey: request.id)
                        request.runtime.error = error.localizedDescription
                        request.runtime.status = DownloadStatus.failed
                    }

                    self.activeDownloads.remove(request.id)
                    self.processNextInQueue()
                }
            }
        )
    }

    private func processNextInQueue() {
        guard !downloadQueue.isEmpty else { return }
        guard activeDownloads.count < maxConcurrentDownloads else { return }

        let nextRequest = downloadQueue.removeFirst()
        waitingDownloads.remove(nextRequest.id)

        startDownload(for: nextRequest)
    }

    func moveToFront(requestId: UUID) {
        guard let index = downloadQueue.firstIndex(where: { $0.id == requestId }) else { return }
        let request = downloadQueue.remove(at: index)
        downloadQueue.insert(request, at: 0)
    }

    func cancelDownload(request: DownloadRequest) {
        if let index = downloadQueue.firstIndex(where: { $0.id == request.id }) {
            downloadQueue.remove(at: index)
        }
        waitingDownloads.remove(request.id)

        if activeDownloads.contains(request.id) {
            downloadManager.cancelDownload(downloadId: request.id.uuidString)
            activeDownloads.remove(request.id)
            processNextInQueue()
        } else {

            downloadManager.cancelDownload(downloadId: request.id.uuidString)
        }

        request.runtime.status = DownloadStatus.cancelled
        request.runtime.error = nil
        saveDownloadTasks()
    }

    func pauseDownload(request: DownloadRequest) {
        if waitingDownloads.contains(request.id) {
            if let index = downloadQueue.firstIndex(where: { $0.id == request.id }) {
                downloadQueue.remove(at: index)
            }
            waitingDownloads.remove(request.id)
            request.runtime.status = DownloadStatus.paused
            saveDownloadTasks()
            return
        }

        if activeDownloads.contains(request.id) {
            downloadManager.pauseDownload(downloadId: request.id.uuidString)
            request.runtime.status = DownloadStatus.paused
            activeDownloads.remove(request.id)
            processNextInQueue()
            saveDownloadTasks()
        }
    }

    func resumeDownload(request: DownloadRequest) {
        guard request.runtime.status == DownloadStatus.paused ||
              request.runtime.status == DownloadStatus.failed else { return }

        request.runtime.error = nil
        startDownload(for: request)
    }

    var queuePosition: (Int, Int) {
        let waiting = downloadQueue.count
        let active = activeDownloads.count
        return (active, waiting)
    }
}

struct DownloadArchive {
    let bundleIdentifier: String
    let name: String
    let version: String
    let identifier: Int
    let iconURL: String?
    let description: String?
    let price: Double?
    let currency: String?

    var isFree: Bool { (price ?? 0.0) == 0.0 }

    init(bundleIdentifier: String, name: String, version: String, identifier: Int = 0, iconURL: String? = nil, description: String? = nil, price: Double? = nil, currency: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.identifier = identifier
        self.iconURL = iconURL
        self.description = description
        self.price = price
        self.currency = currency
    }
}

class DownloadRuntime: ObservableObject {
    @Published var status: DownloadStatus = DownloadStatus.waiting
    @Published var progress: Progress = Progress(totalUnitCount: 0)
    @Published var speed: String = ""
    @Published var error: String?
    @Published var progressValue: Double = 0.0

    init() {

        progress.completedUnitCount = 0
    }

    @MainActor
    func updateProgress(completed: Int64, total: Int64) {

        progress = Progress(totalUnitCount: total)
        progress.completedUnitCount = completed
        progressValue = total > 0 ? Double(completed) / Double(total) : 0.0

        objectWillChange.send()
    }
}

enum DownloadStatus: String, Codable {
    case waiting
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

class DownloadRequest: Identifiable, ObservableObject, Equatable, @unchecked Sendable {
    let id: UUID
    let bundleIdentifier: String
    let version: String
    let name: String
    var createdAt: Date
    let package: DownloadArchive
    var versionId: String?
    @Published var localFilePath: String?

    private var cancellables: Set<AnyCancellable> = []
    @Published var runtime: DownloadRuntime { didSet { bindRuntime() } }

    var iconURL: String? {
        return package.iconURL
    }

    var identifier: Int {
        return package.identifier
    }

    init(id: UUID = UUID(), bundleIdentifier: String, version: String, name: String, package: DownloadArchive, versionId: String? = nil) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.name = name
        self.createdAt = Date()
        self.package = package
        self.versionId = versionId
        self.runtime = DownloadRuntime()

        bindRuntime()
    }

    private func bindRuntime() {
        cancellables.removeAll()
        runtime.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var hint: String {
        if let error = runtime.error {
            return error
        }
        return switch runtime.status {
        case DownloadStatus.waiting:
            "等待中..."
        case DownloadStatus.downloading:
            [
                String(Int(runtime.progressValue * 100)) + "%",
                runtime.speed.isEmpty ? "" : runtime.speed,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        case DownloadStatus.paused:
            "已暂停"
        case DownloadStatus.completed:
            "已完成"
        case DownloadStatus.failed:
            "下载失败"
        case DownloadStatus.cancelled:
            "已取消"
        }
    }

    static func == (lhs: DownloadRequest, rhs: DownloadRequest) -> Bool {
        return lhs.id == rhs.id
    }
}

extension UnifiedDownloadManager {

    func saveDownloadTasks() {

        let saveData = DownloadTasksSaveData(
            downloadRequests: downloadRequests.map { request in
                DownloadRequestSaveData(
                    id: request.id,
                    bundleIdentifier: request.bundleIdentifier,
                    version: request.version,
                    name: request.name,
                    package: request.package,
                    versionId: request.versionId,
                    runtime: DownloadRuntimeSaveData(
                        status: request.runtime.status,
                        progressValue: request.runtime.progressValue,
                        error: request.runtime.error,
                        speed: request.runtime.speed,
                        localFilePath: request.localFilePath.map { relativePath(for: $0) }
                    ),
                    createdAt: request.createdAt
                )
            },
            completedRequests: Array(completedRequests),
            activeDownloads: Array(activeDownloads),
            waitingDownloads: Array(waitingDownloads),
            queueOrder: downloadQueue.map { $0.id }
        )

        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(saveData) else { return }
            UserDefaults.standard.set(data, forKey: "DownloadTasks")
        }
    }

    func restoreDownloadTasks() {

        guard let data = UserDefaults.standard.data(forKey: "DownloadTasks") else {
            return
        }

        let saveData: DownloadTasksSaveData
        do {
            saveData = try JSONDecoder().decode(DownloadTasksSaveData.self, from: data)
        } catch {
            return
        }

        let documentsPath = documentsDirectory.path
        let downloadsPath = downloadsDirectory.path
        let descriptors: [(id: UUID, bundleId: String, version: String, relativePath: String?)] = saveData.downloadRequests.map {
            ($0.id, $0.bundleIdentifier, $0.version, $0.runtime.localFilePath)
        }

        DispatchQueue.global(qos: .utility).async {
            let resolved = Self.resolveLocalFiles(for: descriptors, documentsPath: documentsPath, downloadsPath: downloadsPath)
            Task { @MainActor in
                self.finishRestore(saveData: saveData, resolvedPaths: resolved)
            }
        }
    }

    private static func resolveLocalFiles(
        for descriptors: [(id: UUID, bundleId: String, version: String, relativePath: String?)],
        documentsPath: String,
        downloadsPath: String
    ) -> [UUID: String?] {
        var result: [UUID: String?] = [:]
        let fileManager = FileManager.default
        let libraryDir = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first
        let cachesDir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
        let appSupportDir = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first

        let searchDirectories: [URL] = [
            URL(fileURLWithPath: downloadsPath),
            URL(fileURLWithPath: documentsPath),
            libraryDir.map { URL(fileURLWithPath: $0) },
            cachesDir.map { URL(fileURLWithPath: $0) },
            appSupportDir.map { URL(fileURLWithPath: $0).appendingPathComponent("Downloads") },
            appSupportDir.map { URL(fileURLWithPath: $0) }
        ].compactMap { $0 }

        for desc in descriptors {
            guard let relativePath = desc.relativePath else {
                result[desc.id] = nil
                continue
            }

            let fullPath = (documentsPath as NSString).appendingPathComponent(relativePath)
            var resolvedPath: String? = nil

            if fileManager.fileExists(atPath: fullPath) {
                resolvedPath = fullPath
            } else {
                let fileName = (relativePath as NSString).lastPathComponent
                let standardFileName = "\(desc.bundleId)_\(desc.version).ipa"
                let searchFileNames = [fileName, standardFileName]

                for dir in searchDirectories {
                    for fname in searchFileNames {
                        let candidate = dir.appendingPathComponent(fname).path
                        if fileManager.fileExists(atPath: candidate) {
                            resolvedPath = candidate
                            break
                        }
                    }
                    if resolvedPath != nil { break }
                }

                if resolvedPath == nil {
                    for dir in searchDirectories {
                        guard let enumerator = fileManager.enumerator(
                            at: dir,
                            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                            options: [.skipsHiddenFiles, .skipsPackageDescendants]
                        ) else { continue }

                        for case let url as URL in enumerator {
                            guard url.pathExtension.lowercased() == "ipa" else { continue }
                            let matchByName = searchFileNames.contains(url.lastPathComponent)
                            let matchById = url.lastPathComponent.contains(desc.bundleId) && url.lastPathComponent.contains(desc.version)
                            if matchByName || matchById {
                                resolvedPath = url.path
                                break
                            }
                        }
                        if resolvedPath != nil { break }
                    }
                }
            }

            result[desc.id] = resolvedPath
        }

        return result
    }

    private func finishRestore(saveData: DownloadTasksSaveData, resolvedPaths: [UUID: String?]) {
        var restoredRequests: [DownloadRequest] = []
        var seenKeys = Set<String>()

        for saveRequest in saveData.downloadRequests {
            let key = "\(saveRequest.bundleIdentifier)|\(saveRequest.version)"
            if seenKeys.contains(key) {
                continue
            }
            seenKeys.insert(key)

            let request = DownloadRequest(
                id: saveRequest.id,
                bundleIdentifier: saveRequest.bundleIdentifier,
                version: saveRequest.version,
                name: saveRequest.name,
                package: saveRequest.package,
                versionId: saveRequest.versionId
            )

            request.runtime.status = saveRequest.runtime.status
            request.runtime.progressValue = saveRequest.runtime.progressValue
            request.runtime.error = saveRequest.runtime.error
            request.runtime.speed = saveRequest.runtime.speed
            request.createdAt = saveRequest.createdAt

            if let resolved = resolvedPaths[saveRequest.id], let path = resolved {
                request.localFilePath = path
            } else {
                request.localFilePath = nil
                if request.runtime.status == .completed {
                    request.runtime.status = .cancelled
                    request.runtime.error = "本地文件已丢失，请重新下载"
                }
            }

            restoredRequests.append(request)
        }

        downloadRequests = restoredRequests

        completedRequests = Set(saveData.completedRequests)
        let savedActive = Set(saveData.activeDownloads)
        let savedWaiting = Set(saveData.waitingDownloads ?? [])

        var newActive: Set<UUID> = []
        var newWaiting: Set<UUID> = []

        for request in downloadRequests {
            if completedRequests.contains(request.id) {
                if request.localFilePath != nil {
                    request.runtime.status = .completed
                } else {
                    completedRequests.remove(request.id)
                    request.runtime.status = .cancelled
                    request.runtime.error = "本地文件已丢失，请重新下载"
                }
            } else if savedActive.contains(request.id) {
                request.runtime.status = .downloading
                newActive.insert(request.id)
            } else if savedWaiting.contains(request.id) {
                request.runtime.status = .waiting
                newWaiting.insert(request.id)
            }
        }

        activeDownloads = newActive
        waitingDownloads = newWaiting

        if let queueOrder = saveData.queueOrder {
            downloadQueue = queueOrder.compactMap { requestId in
                downloadRequests.first(where: { $0.id == requestId && newWaiting.contains(requestId) })
            }
        } else {
            downloadQueue = downloadRequests.filter { newWaiting.contains($0.id) }
        }

        syncDownloadStatus()
    }

    func syncDownloadStatus() {

        Task { @MainActor in
            let activeIds = await downloadManager.activeDownloadIds

            for request in downloadRequests {
                let hasActiveTask = activeIds.contains(request.id.uuidString)

                if request.runtime.status == .downloading && !hasActiveTask {
                    request.runtime.status = .paused
                    activeDownloads.remove(request.id)
                } else if request.runtime.status == .paused && hasActiveTask {
                    request.runtime.status = .downloading
                    activeDownloads.insert(request.id)
                }
            }

            let validActive = activeDownloads.filter { id in
                downloadRequests.contains(where: { $0.id == id })
            }
            activeDownloads = validActive

            let refreshed = downloadRequests
            downloadRequests = refreshed

        }
    }

    func pauseAllDownloads() {

        for request in downloadRequests {
            if request.runtime.status == DownloadStatus.downloading {
                request.runtime.status = DownloadStatus.paused
                activeDownloads.remove(request.id)
            }
            if request.runtime.status == DownloadStatus.waiting {
                request.runtime.status = DownloadStatus.paused
                waitingDownloads.remove(request.id)
            }
        }

        downloadQueue.removeAll()

        saveDownloadTasks()
    }

    func resumeAllDownloads() {

        let pausedRequests = downloadRequests.filter {
            $0.runtime.status == DownloadStatus.paused
        }

        for request in pausedRequests {
            startDownload(for: request)
        }

        saveDownloadTasks()
    }
}

private struct DownloadTasksSaveData: Codable {
    let downloadRequests: [DownloadRequestSaveData]
    let completedRequests: [UUID]
    let activeDownloads: [UUID]
    let waitingDownloads: [UUID]?
    let queueOrder: [UUID]?
}

private struct DownloadRequestSaveData: Codable {
    let id: UUID
    let bundleIdentifier: String
    let version: String
    let name: String
    let packageIdentifier: Int
    let packageIconURL: String?
    let packagePrice: Double?
    let packageCurrency: String?
    let versionId: String?
    let runtime: DownloadRuntimeSaveData
    var createdAt: Date

    init(id: UUID, bundleIdentifier: String, version: String, name: String, package: DownloadArchive, versionId: String?, runtime: DownloadRuntimeSaveData, createdAt: Date) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.name = name
        self.packageIdentifier = package.identifier
        self.packageIconURL = package.iconURL
        self.packagePrice = package.price
        self.packageCurrency = package.currency
        self.versionId = versionId
        self.runtime = runtime
        self.createdAt = createdAt
    }

    var package: DownloadArchive {
        return DownloadArchive(
            bundleIdentifier: bundleIdentifier,
            name: name,
            version: version,
            identifier: packageIdentifier,
            iconURL: packageIconURL,
            price: packagePrice,
            currency: packageCurrency
        )
    }
}

private struct DownloadRuntimeSaveData: Codable {
    let status: DownloadStatus
    let progressValue: Double
    let error: String?
    let speed: String
    let localFilePath: String?
}
