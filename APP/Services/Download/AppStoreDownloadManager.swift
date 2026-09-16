import Foundation
import CryptoKit
import SwiftUI
import UIKit

extension AppStoreDownloadManager {
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {

        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            if let completionHandler = appDelegate.backgroundSessionCompletionHandler {

                DispatchQueue.main.async {
                    completionHandler()
                    appDelegate.backgroundSessionCompletionHandler = nil
                }
            }
        }
    }
}

struct DownloadStoreItem: Codable {
    let url: String
    let md5: String
    let sinfs: [DownloadSinfInfo]
    let metadata: DownloadAppMetadata
}

struct DownloadAppMetadata: Codable {
    let bundleId: String
    let bundleDisplayName: String
    let bundleShortVersionString: String
    let softwareVersionExternalIdentifier: String
    let softwareVersionExternalIdentifiers: [Int]?
}

struct DownloadSinfInfo: Codable {
    let id: Int
    let sinf: String
}

@MainActor
class IPAProcessor: @unchecked Sendable {
    static let shared = IPAProcessor()

    private init() {}

    func processIPA(
        at ipaPath: URL,
        withSinfs sinfs: [Any],
        completion: @escaping (Result<URL, Error>) -> Void
    ) {

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let startTime = Date()
                let processedIPA = try self.processIPAFast(at: ipaPath, withSinfs: sinfs)
                _ = Date().timeIntervalSince(startTime)
                DispatchQueue.main.async {
                    completion(.success(processedIPA))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    nonisolated private func processIPAFast(at ipaPath: URL, withSinfs sinfs: [Any]) throws -> URL {

        let ipaData = try Data(contentsOf: ipaPath)

        guard let eocd = FastZipArchive.findEndOfCentralDirectory(in: ipaData) else {
            throw NSError(domain: "IPAProcessing", code: 10, userInfo: [NSLocalizedDescriptionKey: "无效的IPA文件，未找到中央目录"])
        }

        let entries = try FastZipArchive.readCentralDirectory(from: ipaData, eocd: eocd)

        let appFolderName = findAppFolderName(in: entries)
        guard let appName = appFolderName else {
            throw NSError(domain: "IPAProcessing", code: 11, userInfo: [NSLocalizedDescriptionKey: "未找到Payload中的.app文件夹"])
        }

        let sinfFiles = generateSinfFiles(sinfs: sinfs, appName: appName)
        let metadataPlist = generateiTunesMetadataPlist(
            appName: appName,
            entries: entries,
            ipaData: ipaData
        )

        var filesToAdd: [(path: String, data: Data)] = []

        for (index, sinfData) in sinfFiles.enumerated() {
            let sinfPath = "Payload/\(appName).app/SC_Info/\(appName).sinf"
            if index == 0 {
                filesToAdd.append((sinfPath, sinfData))
            } else {
                let altPath = "Payload/\(appName).app/SC_Info/\(appName)_\(index).sinf"
                filesToAdd.append((altPath, sinfData))
            }
        }

        filesToAdd.append(("iTunesMetadata.plist", metadataPlist))

        let success = FastZipArchive.shared.addFiles(
            toZipAtPath: ipaPath.path,
            files: filesToAdd
        )

        guard success else {
            throw NSError(domain: "IPAProcessing", code: 12, userInfo: [NSLocalizedDescriptionKey: "增量添加文件失败"])
        }

        return ipaPath
    }

    nonisolated private func findAppFolderName(in entries: [FastZipArchive.CentralDirectoryEntry]) -> String? {
        for entry in entries {
            let path = entry.filename
            if path.hasPrefix("Payload/") && path.hasSuffix(".app/") {
                let name = path
                    .replacingOccurrences(of: "Payload/", with: "")
                    .replacingOccurrences(of: ".app/", with: "")
                return name
            }
        }
        for entry in entries {
            let path = entry.filename
            if path.hasPrefix("Payload/") && path.contains(".app/") {
                if let range = path.range(of: "Payload/"),
                   let endRange = path.range(of: ".app/") {
                    let name = String(path[range.upperBound..<endRange.lowerBound])
                    return name
                }
            }
        }
        return nil
    }

    nonisolated private func generateSinfFiles(sinfs: [Any], appName: String) -> [Data] {
        var result: [Data] = []

        if sinfs.isEmpty {
            let defaultSinf = createDefaultSinfData(for: appName)
            result.append(defaultSinf)
            return result
        }

        for sinf in sinfs {
            if let sinfInfo = sinf as? DownloadSinfInfo {
                if let data = Data(base64Encoded: sinfInfo.sinf) {
                    result.append(data)
                }
            } else if let sinfDict = sinf as? [String: Any],
                      let sinfString = sinfDict["sinf"] as? String,
                      let data = Data(base64Encoded: sinfString) {
                result.append(data)
            }
        }

        if result.isEmpty {
            let defaultSinf = createDefaultSinfData(for: appName)
            result.append(defaultSinf)
        }

        return result
    }

    nonisolated private func generateiTunesMetadataPlist(
        appName: String,
        entries: [FastZipArchive.CentralDirectoryEntry],
        ipaData: Data
    ) -> Data {
        var bundleId = "com.unknown.app"
        var displayName = appName
        var version = "1.0"

        let infoPlistPath = "Payload/\(appName).app/Info.plist"

        for entry in entries {
            if entry.filename == infoPlistPath {
                do {
                    let plistData = try FastZipArchive.extractSingleEntry(
                        from: ipaData,
                        entry: entry
                    )
                    if let plist = try PropertyListSerialization.propertyList(
                        from: plistData,
                        options: [],
                        format: nil
                    ) as? [String: Any] {
                        bundleId = plist["CFBundleIdentifier"] as? String ?? bundleId
                        displayName = plist["CFBundleDisplayName"] as? String ??
                                     plist["CFBundleName"] as? String ?? displayName
                        version = plist["CFBundleVersion"] as? String ?? version
                    }
                } catch {
                }
                break
            }
        }

        let metadataDict: [String: Any] = [
            "appleId": bundleId,
            "artistId": 0,
            "artistName": "Unknown Developer",
            "bundleId": bundleId,
            "bundleVersion": version,
            "copyright": "Copyright",
            "drmVersionNumber": 0,
            "fileExtension": "ipa",
            "fileName": "\(appName).app",
            "genre": "Productivity",
            "genreId": 6007,
            "itemId": 0,
            "itemName": displayName,
            "kind": "software",
            "playlistName": "iOS Apps",
            "price": 0.0,
            "priceDisplay": "Free",
            "rating": "4+",
            "releaseDate": "2025-01-01T00:00:00Z",
            "s": 143441,
            "softwareIcon57x57URL": "",
            "softwareIconNeedsShine": false,
            "softwareSupportedDeviceIds": [1, 2],
            "softwareVersionBundleId": bundleId,
            "softwareVersionExternalIdentifier": 0,
            "softwareVersionExternalIdentifiers": [],
            "subgenres": [],
            "vendorId": 0,
            "versionRestrictions": 0
        ]

        if let plistData = try? PropertyListSerialization.data(
            fromPropertyList: metadataDict,
            format: .xml,
            options: 0
        ) {
            return plistData
        }

        return Data()
    }

    nonisolated private func createDefaultSinfData(for appName: String) -> Data {
        var sinfData = Data()

        let header = "SINF".data(using: .utf8) ?? Data()
        sinfData.append(header)

        let version: UInt32 = 1
        var versionBytes = version
        sinfData.append(Data(bytes: &versionBytes, count: MemoryLayout<UInt32>.size))

        if let appNameData = appName.data(using: .utf8) {
            let nameLength: UInt32 = UInt32(appNameData.count)
            var nameLengthBytes = nameLength
            sinfData.append(Data(bytes: &nameLengthBytes, count: MemoryLayout<UInt32>.size))
            sinfData.append(appNameData)
        }

        let timestamp: UInt64 = UInt64(Date().timeIntervalSince1970)
        var timestampBytes = timestamp
        sinfData.append(Data(bytes: &timestampBytes, count: MemoryLayout<UInt64>.size))

        let checksum = sinfData.reduce(0) { $0 ^ $1 }
        var checksumBytes = checksum
        sinfData.append(Data(bytes: &checksumBytes, count: MemoryLayout<UInt8>.size))

        return sinfData
    }
}

class AppStoreDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = AppStoreDownloadManager()
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var directDownloadTasks: [String: URLSessionDataTask] = [:]
    private var directDownloadData: [String: Data] = [:]
    private var directDownloadExpectedSize: [String: Int64] = [:]
    private var directDownloadFileHandles: [String: FileHandle] = [:]
    private var directDownloadTempFiles: [String: URL] = [:]
    private var directDownloadBytesWritten: [String: Int64] = [:]
    private var progressHandlers: [String: (DownloadProgress) -> Void] = [:]
    private var completionHandlers: [String: (Result<DownloadResult, DownloadError>) -> Void] = [:]
    private var downloadStartTimes: [String: Date] = [:]
    private var lastProgressUpdate: [String: (bytes: Int64, time: Date)] = [:]
    private var lastUIUpdate: [String: Date] = [:]
    private var downloadDestinations: [String: URL] = [:]
    private var downloadStoreItems: [String: DownloadStoreItem] = [:]
    private var pendingCompletionHandlers: [String: (Result<DownloadResult, DownloadError>) -> Void] = [:]
    private var startingDownloads: Set<String> = []
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.app.appstoredownload.session"
        )
        config.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
            "HTTPProxy": "",
            "HTTPSProxy": "",
            "SOCKSProxy": ""
        ]
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.shouldUseExtendedBackgroundIdleMode = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        config.networkServiceType = .default
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private lazy var foregroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
            "HTTPProxy": "",
            "HTTPSProxy": "",
            "SOCKSProxy": ""
        ]
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        config.networkServiceType = .default
        return URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    }()
    private var activeSessionType: [String: String] = [:]
    private var resumeDataStore: [String: Data] = [:]
    private var isRetryingDownload: Set<String> = []
    private var completedDownloads: Set<String> = []
    private var persistedContexts: [String: DownloadContext] = [:]

    private struct DownloadContext: Codable {
        let downloadId: String
        let destinationPath: String
        let storeItem: DownloadStoreItem
        let bytesDownloaded: Int64
        let totalBytes: Int64
        let resumeDataPath: String?
    }

    private override init() {
        super.init()
        loadPersistedContexts()
    }

    private func loadPersistedContexts() {
        guard let data = UserDefaults.standard.data(forKey: "DownloadContexts") else { return }
        do {
            persistedContexts = try JSONDecoder().decode([String: DownloadContext].self, from: data)
        } catch {
        }
    }

    private func savePersistedContexts() {
        do {
            let data = try JSONEncoder().encode(persistedContexts)
            UserDefaults.standard.set(data, forKey: "DownloadContexts")
        } catch {
        }
    }

    private func persistContext(for downloadId: String, bytesDownloaded: Int64 = 0, totalBytes: Int64 = 0) {
        guard let destination = downloadDestinations[downloadId],
              let storeItem = downloadStoreItems[downloadId] else { return }

        var resumeDataPath: String? = nil
        if let resumeData = resumeDataStore[downloadId] {
            resumeDataPath = saveResumeData(resumeData, for: downloadId)
        }

        let context = DownloadContext(
            downloadId: downloadId,
            destinationPath: destination.path,
            storeItem: storeItem,
            bytesDownloaded: bytesDownloaded,
            totalBytes: totalBytes,
            resumeDataPath: resumeDataPath
        )
        persistedContexts[downloadId] = context
        savePersistedContexts()
    }

    private func resumeDataPath(for downloadId: String) -> URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let resumeDir = documentsDir.appendingPathComponent("ResumeData", isDirectory: true)
        try? FileManager.default.createDirectory(at: resumeDir, withIntermediateDirectories: true)
        return resumeDir.appendingPathComponent("\(downloadId).resume")
    }

    private func saveResumeData(_ data: Data, for downloadId: String) -> String {
        let path = resumeDataPath(for: downloadId)
        do {
            try data.write(to: path)
            return path.path
        } catch {
            return path.path
        }
    }

    private func loadResumeData(for downloadId: String) -> Data? {
        let path = resumeDataPath(for: downloadId)
        guard let data = try? Data(contentsOf: path) else {
            return nil
        }
        return data
    }

    private func deleteResumeData(for downloadId: String) {
        let path = resumeDataPath(for: downloadId)
        try? FileManager.default.removeItem(at: path)
    }

    private func checkPartialFile(for downloadId: String) -> Int64? {
        guard let destinationURL = downloadDestinations[downloadId] else { return nil }
        let tempPath = destinationURL.path + ".download"
        guard FileManager.default.fileExists(atPath: tempPath) else { return nil }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: tempPath)
            return attrs[.size] as? Int64
        } catch {
            return nil
        }
    }

    private func verifyDownloadedFile(downloadId: String, fileURL: URL, expectedMD5: String) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }

        let isValid = verifyFileIntegrity(fileURL: fileURL, expectedMD5: expectedMD5)
        if isValid {
        } else {
        }
        return isValid
    }

    private func removePersistedContext(for downloadId: String) {
        persistedContexts.removeValue(forKey: downloadId)
        deleteResumeData(for: downloadId)
        savePersistedContexts()
    }

    func restoreBackgroundTasks(
        progressHandler: @escaping @Sendable (String, DownloadProgress) -> Void,
        completion: @escaping @Sendable (String, Result<DownloadResult, DownloadError>) -> Void
    ) {
        Task { @MainActor in
            let bgTasks = await urlSession.allTasks
            var restoredCount = 0

            for task in bgTasks {
                guard let downloadTask = task as? URLSessionDownloadTask,
                      let downloadId = downloadTask.taskDescription,
                      !downloadId.isEmpty else { continue }

                guard let context = persistedContexts[downloadId] else {
                    continue
                }

                downloadTasks[downloadId] = downloadTask
                downloadDestinations[downloadId] = URL(fileURLWithPath: context.destinationPath)
                downloadStoreItems[downloadId] = context.storeItem
                downloadStartTimes[downloadId] = Date()

                progressHandlers[downloadId] = { progress in
                    progressHandler(downloadId, progress)
                }
                completionHandlers[downloadId] = { result in
                    completion(downloadId, result)
                }

                restoredCount += 1
            }

            let fgTasks = await foregroundSession.allTasks
            for task in fgTasks {
                guard let dataTask = task as? URLSessionDataTask,
                      let downloadId = dataTask.taskDescription,
                      !downloadId.isEmpty else { continue }

                guard directDownloadTasks[downloadId] == nil else {
                    continue
                }

                guard let context = persistedContexts[downloadId] else {
                    continue
                }

                directDownloadTasks[downloadId] = dataTask
                downloadDestinations[downloadId] = URL(fileURLWithPath: context.destinationPath)
                downloadStoreItems[downloadId] = context.storeItem
                downloadStartTimes[downloadId] = Date()

                progressHandlers[downloadId] = { progress in
                    progressHandler(downloadId, progress)
                }
                completionHandlers[downloadId] = { result in
                    completion(downloadId, result)
                }

                restoredCount += 1
            }

            if restoredCount > 0 {

            }
        }
    }

    @MainActor
    func downloadApp(
        appIdentifier: String,
        account: Account,
        destinationURL: URL,
        appVersion: String? = nil,
        downloadId: String? = nil,
        progressHandler: @escaping @Sendable (DownloadProgress) -> Void,
        completion: @escaping @Sendable (Result<DownloadResult, DownloadError>) -> Void
    ) {
        let downloadId = downloadId ?? UUID().uuidString

        if hasActiveDownload(for: downloadId) || startingDownloads.contains(downloadId) {

            attachHandlers(for: downloadId, progressHandler: progressHandler, completion: completion)
            return
        }

        startingDownloads.insert(downloadId)

        Task { @MainActor in
            defer {
                startingDownloads.remove(downloadId)
            }
            do {

                let dsPersonId = account.dsPersonId
                let passwordToken = account.passwordToken
                let storeFront = account.storeResponse.storeFront

                let plistResponse = try await downloadFromStoreAPI(
                    appIdentifier: appIdentifier,
                    directoryServicesIdentifier: dsPersonId,
                    appVersion: appVersion,
                    passwordToken: passwordToken,
                    storeFront: storeFront
                )

                var downloadStoreItem: DownloadStoreItem?

                if let songList = plistResponse["songList"] as? [[String: Any]], !songList.isEmpty {
                    let firstSongItem = songList[0]

                    downloadStoreItem = convertToDownloadStoreItem(from: firstSongItem)
                } else {

                    let failureType = plistResponse["failureType"] as? String ?? ""
                    let customerMessage = plistResponse["customerMessage"] as? String ?? ""
                    if !failureType.isEmpty {
                        let dm = self.mapStoreError(failureType, customerMessage: customerMessage.isEmpty ? nil : customerMessage)
                        DispatchQueue.main.async {
                            completion(.failure(dm))
                        }
                        return
                    }

                    let error: DownloadError = .licenseError("应用未购买，请先前往App Store购买")
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                    return
                }

                guard let storeItem = downloadStoreItem else {
                    let error: DownloadError = .unknownError("无法创建下载项")
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                    return
                }

                await startFileDownload(
                    downloadId: downloadId,
                    storeItem: storeItem,
                    destinationURL: destinationURL,
                    progressHandler: progressHandler,
                    completion: completion
                )
            } catch StoreError.codeRequired {
                DispatchQueue.main.async {
                    completion(.failure(.authenticationError("iTunes 会话已失效且需要双重认证验证码，请重新登录该 Apple ID 完成验证后重试")))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.networkError(error)))
                }
            }
        }
    }

    private func convertToDownloadStoreItem(from storeItem: Any) -> DownloadStoreItem {

        if let dict = storeItem as? [String: Any] {

            let url = dict["URL"] as? String ?? ""
            let md5 = dict["md5"] as? String ?? ""

            var bundleId = "unknown"
            var bundleDisplayName = "Unknown App"
            var bundleShortVersionString = "1.0"
            var softwareVersionExternalIdentifier = "0"
            var softwareVersionExternalIdentifiers: [Int] = []

            if let metadata = dict["metadata"] as? [String: Any] {
                bundleId = metadata["softwareVersionBundleId"] as? String ?? "unknown"
                bundleDisplayName = metadata["bundleDisplayName"] as? String ?? "Unknown App"
                bundleShortVersionString = metadata["bundleShortVersionString"] as? String ?? "1.0"
                if let extId = metadata["softwareVersionExternalIdentifier"] as? Int {
                    softwareVersionExternalIdentifier = String(extId)
                }
                softwareVersionExternalIdentifiers = metadata["softwareVersionExternalIdentifiers"] as? [Int] ?? []

            }

            var sinfs: [DownloadSinfInfo] = []
            if let sinfsArray = dict["sinfs"] as? [[String: Any]] {

                for (index, sinfDict) in sinfsArray.enumerated() {

                    let sinfId = sinfDict["id"] as? Int ?? index

                    if let sinfData = sinfDict["sinf"] {

                        var finalSinfData: String = ""

                        if let stringData = sinfData as? String {
                            finalSinfData = stringData

                        } else if let dataData = sinfData as? Data {
                            finalSinfData = dataData.base64EncodedString()

                        } else {

                            finalSinfData = "\(sinfData)"

                        }

                        if !finalSinfData.isEmpty && finalSinfData.count > 10 {
                            let sinfInfo = DownloadSinfInfo(
                                id: sinfId,
                                sinf: finalSinfData
                            )
                            sinfs.append(sinfInfo)
                        } else {
                        }
                    } else {
                    }
                }
            } else {
            }

            guard !url.isEmpty && !md5.isEmpty else {
                return createDefaultDownloadStoreItem()
            }

            let downloadMetadata = DownloadAppMetadata(
                bundleId: bundleId,
                bundleDisplayName: bundleDisplayName,
                bundleShortVersionString: bundleShortVersionString,
                softwareVersionExternalIdentifier: softwareVersionExternalIdentifier,
                softwareVersionExternalIdentifiers: softwareVersionExternalIdentifiers
            )

            return DownloadStoreItem(
                url: url,
                md5: md5,
                sinfs: sinfs,
                metadata: downloadMetadata
            )
        } else {
            return createDefaultDownloadStoreItem()
        }
    }

    private func createDefaultDownloadStoreItem() -> DownloadStoreItem {
        return DownloadStoreItem(
            url: "",
            md5: "",
            sinfs: [],
            metadata: DownloadAppMetadata(
                bundleId: "unknown",
                bundleDisplayName: "Unknown App",
                bundleShortVersionString: "1.0",
                softwareVersionExternalIdentifier: "0",
                softwareVersionExternalIdentifiers: []
            )
        )
    }

    @MainActor
    private func startFileDownload(
        downloadId: String,
        storeItem: DownloadStoreItem,
        destinationURL: URL,
        progressHandler: @escaping @Sendable (DownloadProgress) -> Void,
        completion: @escaping @Sendable (Result<DownloadResult, DownloadError>) -> Void
    ) async {
        guard let downloadURL = URL(string: storeItem.url) else {
            DispatchQueue.main.async {
                completion(.failure(.unknownError("无效的下载URL: \(storeItem.url)")))
            }
            return
        }

        let isTrollStore = EnvironmentDetector.shared.isTrollStore
        let isJailbroken = EnvironmentDetector.shared.isJailbroken
        let useDirectDownload = isTrollStore || isJailbroken

        if useDirectDownload {
            activeSessionType[downloadId] = "direct"
            await startDirectDownload(
                downloadId: downloadId,
                storeItem: storeItem,
                destinationURL: destinationURL,
                progressHandler: progressHandler,
                completion: completion
            )
            return
        }

        activeSessionType[downloadId] = "background"

        let session = urlSession

        var request = URLRequest(url: downloadURL)

        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let downloadTask: URLSessionDownloadTask

        if let resumeData = resumeDataStore[downloadId] {
            downloadTask = session.downloadTask(withResumeData: resumeData)
            resumeDataStore.removeValue(forKey: downloadId)
        } else if let savedResumeData = loadResumeData(for: downloadId) {
            downloadTask = session.downloadTask(withResumeData: savedResumeData)
        } else {
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            downloadTask = session.downloadTask(with: request)
        }

        downloadTask.taskDescription = downloadId

        downloadStartTimes[downloadId] = Date()
        downloadTasks[downloadId] = downloadTask
        progressHandlers[downloadId] = progressHandler

        downloadDestinations[downloadId] = destinationURL
        downloadStoreItems[downloadId] = storeItem
        completionHandlers[downloadId] = completion

        persistContext(for: downloadId)

        downloadTask.resume()
    }

    @MainActor
    private func startDirectDownload(
        downloadId: String,
        storeItem: DownloadStoreItem,
        destinationURL: URL,
        progressHandler: @escaping @Sendable (DownloadProgress) -> Void,
        completion: @escaping @Sendable (Result<DownloadResult, DownloadError>) -> Void
    ) async {
        guard let downloadURL = URL(string: storeItem.url) else {
            completion(.failure(.unknownError("无效的下载URL")))
            return
        }

        if directDownloadTasks[downloadId] != nil {

            progressHandlers[downloadId] = progressHandler
            completionHandlers[downloadId] = completion
            return
        }

        let existingTasks = await foregroundSession.allTasks
        if let existingTask = existingTasks.first(where: { $0.taskDescription == downloadId }) as? URLSessionDataTask {

            directDownloadTasks[downloadId] = existingTask
            downloadDestinations[downloadId] = destinationURL
            downloadStoreItems[downloadId] = storeItem
            progressHandlers[downloadId] = progressHandler
            completionHandlers[downloadId] = completion
            return
        }

        downloadDestinations[downloadId] = destinationURL
        downloadStoreItems[downloadId] = storeItem
        completionHandlers[downloadId] = completion
        progressHandlers[downloadId] = progressHandler
        downloadStartTimes[downloadId] = Date()
        directDownloadData[downloadId] = Data()
        directDownloadBytesWritten[downloadId] = 0

        let tempDir = NSTemporaryDirectory()
        let tempFileURL = URL(fileURLWithPath: tempDir).appendingPathComponent("\(downloadId).tmp")
        directDownloadTempFiles[downloadId] = tempFileURL

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: tempFileURL.path) {
            try? fileManager.removeItem(at: tempFileURL)
        }
        fileManager.createFile(atPath: tempFileURL.path, contents: nil)

        if let fileHandle = try? FileHandle(forWritingTo: tempFileURL) {
            directDownloadFileHandles[downloadId] = fileHandle
        }

        var request = URLRequest(url: downloadURL)
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let dataTask = foregroundSession.dataTask(with: request)
        dataTask.taskDescription = downloadId
        directDownloadTasks[downloadId] = dataTask

        dataTask.resume()
    }

    @MainActor
    private func retryWithForegroundDownload(
        downloadId: String,
        storeItem: DownloadStoreItem,
        destinationURL: URL
    ) {

        downloadDestinations[downloadId] = destinationURL
        downloadStoreItems[downloadId] = storeItem
        downloadStartTimes[downloadId] = Date()
        directDownloadBytesWritten[downloadId] = 0
        activeSessionType[downloadId] = "foreground_retry"

        let tempDir = NSTemporaryDirectory()
        let tempFileURL = URL(fileURLWithPath: tempDir).appendingPathComponent("\(downloadId).tmp")
        directDownloadTempFiles[downloadId] = tempFileURL

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: tempFileURL.path) {
            try? fileManager.removeItem(at: tempFileURL)
        }
        fileManager.createFile(atPath: tempFileURL.path, contents: nil)

        if let fileHandle = try? FileHandle(forWritingTo: tempFileURL) {
            directDownloadFileHandles[downloadId] = fileHandle
        }

        guard let downloadURL = URL(string: storeItem.url) else {
            safeComplete(downloadId: downloadId, result: .failure(.unknownError("无效的下载URL")))
            return
        }

        var request = URLRequest(url: downloadURL)
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let dataTask = foregroundSession.dataTask(with: request)
        dataTask.taskDescription = downloadId
        directDownloadTasks[downloadId] = dataTask

        dataTask.resume()
    }

    private func verifyFileIntegrity(fileURL: URL, expectedMD5: String) -> Bool {
        guard let fileData = try? Data(contentsOf: fileURL) else {
            return false
        }
        let digest = Insecure.MD5.hash(data: fileData)
        let calculatedMD5 = digest.map { String(format: "%02hhx", $0) }.joined()
        return calculatedMD5.lowercased() == expectedMD5.lowercased()
    }

    func pauseDownload(downloadId: String) {
        if let task = downloadTasks[downloadId] {
            task.suspend()
        }
        if let task = directDownloadTasks[downloadId] {
            task.suspend()
        }
    }

    func resumeDownload(downloadId: String) {
        if let task = downloadTasks[downloadId] {
            task.resume()

        } else if let task = directDownloadTasks[downloadId] {
            task.resume()

        } else {

        }
    }

    func cancelDownload(downloadId: String) {
        if let task = downloadTasks[downloadId] {
            task.cancel()
            downloadTasks.removeValue(forKey: downloadId)
        }
        if let task = directDownloadTasks[downloadId] {
            task.cancel()
            directDownloadTasks.removeValue(forKey: downloadId)
        }
        startingDownloads.remove(downloadId)
    }

    var activeDownloadIds: Set<String> {
        get async {
            let tasks = await urlSession.allTasks
            let ids = tasks.compactMap { task -> String? in
                guard let desc = task.taskDescription, !desc.isEmpty else { return nil }
                return desc
            }
            var result = Set(ids)
            result.formUnion(downloadTasks.keys)
            result.formUnion(directDownloadTasks.keys)
            return result
        }
    }

    func hasActiveDownload(for downloadId: String) -> Bool {
        if startingDownloads.contains(downloadId) {
            return true
        }
        if downloadTasks[downloadId] != nil {
            return true
        }
        if directDownloadTasks[downloadId] != nil {
            return true
        }
        return false
    }

    func hasBackgroundTask(for downloadId: String) async -> Bool {
        let backgroundTasks = await urlSession.allTasks
        let hasBg = backgroundTasks.contains { task in
            task.taskDescription == downloadId
        }
        if hasBg {
            return true
        }
        let directTasks = await foregroundSession.allTasks
        let hasDirect = directTasks.contains { task in
            task.taskDescription == downloadId
        }
        return hasDirect
    }

    func attachHandlers(
        for downloadId: String,
        progressHandler: @escaping @Sendable (DownloadProgress) -> Void,
        completion: @escaping @Sendable (Result<DownloadResult, DownloadError>) -> Void
    ) {
        progressHandlers[downloadId] = progressHandler
        completionHandlers[downloadId] = completion
    }

    private func safeComplete(downloadId: String, result: Result<DownloadResult, DownloadError>) {
        guard !completedDownloads.contains(downloadId) else {
            return
        }
        completedDownloads.insert(downloadId)

        DispatchQueue.main.async { [weak self] in
            self?.completionHandlers[downloadId]?(result)
            self?.cleanupDownload(downloadId: downloadId)
        }
    }

    private func cleanupDownload(downloadId: String) {
        downloadTasks.removeValue(forKey: downloadId)
        progressHandlers.removeValue(forKey: downloadId)
        completionHandlers.removeValue(forKey: downloadId)
        downloadStartTimes.removeValue(forKey: downloadId)
        lastProgressUpdate.removeValue(forKey: downloadId)
        lastUIUpdate.removeValue(forKey: downloadId)
        downloadDestinations.removeValue(forKey: downloadId)
        downloadStoreItems.removeValue(forKey: downloadId)
        directDownloadTasks.removeValue(forKey: downloadId)
        directDownloadData.removeValue(forKey: downloadId)
        directDownloadExpectedSize.removeValue(forKey: downloadId)
        directDownloadBytesWritten.removeValue(forKey: downloadId)

        if let fileHandle = directDownloadFileHandles[downloadId] {
            try? fileHandle.close()
        }
        directDownloadFileHandles.removeValue(forKey: downloadId)

        if let tempFileURL = directDownloadTempFiles[downloadId] {
            try? FileManager.default.removeItem(at: tempFileURL)
        }
        directDownloadTempFiles.removeValue(forKey: downloadId)

        isRetryingDownload.remove(downloadId)
        removePersistedContext(for: downloadId)

    }

    private func downloadFromStoreAPI(
        appIdentifier: String,
        directoryServicesIdentifier: String,
        appVersion: String?,
        passwordToken: String,
        storeFront: String
    ) async throws -> [String: Any] {

        let guid = await StoreRequest.shared.currentGUID()
        let url = URL(string: "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=\(guid)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")

        request.setValue("Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6", forHTTPHeaderField: "User-Agent")
        request.setValue(directoryServicesIdentifier, forHTTPHeaderField: "X-Dsid")
        request.setValue(directoryServicesIdentifier, forHTTPHeaderField: "iCloud-DSID")

        if !passwordToken.isEmpty {
            request.setValue(passwordToken, forHTTPHeaderField: "X-Token")
        }
        if !storeFront.isEmpty {

            let normalizedStoreFront = storeFront.split(separator: "-").first.map(String.init) ?? storeFront
            request.setValue(normalizedStoreFront, forHTTPHeaderField: "X-Apple-Store-Front")
        }

        var body: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": appIdentifier
        ]

        if let appVersion = appVersion {
            body["externalVersionId"] = appVersion
        }

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: body,
            format: .xml,
            options: 0
        )
        request.httpBody = plistData

        let storeConfig = URLSessionConfiguration.default
        storeConfig.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
            "HTTPProxy": "",
            "HTTPSProxy": "",
            "SOCKSProxy": ""
        ]
        storeConfig.timeoutIntervalForRequest = 30
        storeConfig.tlsMinimumSupportedProtocolVersion = .TLSv12
        storeConfig.tlsMaximumSupportedProtocolVersion = .TLSv13
        let storeSession = URLSession(configuration: storeConfig, delegate: SRPURLSessionDelegate.shared, delegateQueue: nil)
        let (data, response) = try await storeSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.networkError(NSError(domain: "StoreAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的HTTP响应"]))
        }

        if httpResponse.statusCode != 200 {
            var parsedFailure = ""
            var parsedCustomer = ""
            do {
                if let p = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                    parsedFailure = p["failureType"] as? String ?? ""
                    parsedCustomer = p["customerMessage"] as? String ?? ""
                }
            } catch {
            }
            let errorMessage = !parsedCustomer.isEmpty ? parsedCustomer : (String(data: data, encoding: .utf8) ?? "未知错误")
            throw DownloadError.networkError(NSError(domain: "StoreAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(errorMessage.isEmpty ? parsedFailure : errorMessage)"]))
        }

        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] ?? [:]

        if let songList = plist["songList"] as? [[String: Any]], !songList.isEmpty {

            let firstSong = songList[0]

            if let sinfs = firstSong["sinfs"] as? [[String: Any]], !sinfs.isEmpty {
                for (_, sinf) in sinfs.enumerated() {
                    if let _ = sinf["sinf"] as? String {
                    } else {
                    }
                }
            } else {
                if let _ = firstSong["sinfs"] {
                }
            }

            if let _ = firstSong["metadata"] as? [String: Any] {
            }
        } else {
        }

        return plist
    }

    private func generateGUID() -> String {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).uppercased()
    }

    private func mapStoreError(_ failureType: String, customerMessage: String?) -> DownloadError {
        switch failureType {
        case "INVALID_ITEM":
            return .appNotFound(customerMessage ?? "应用未找到")
        case "INVALID_LICENSE":
            return .licenseError(customerMessage ?? "许可证无效")
        case "INVALID_CREDENTIALS":
            return .authenticationError(customerMessage ?? "认证失败")
        default:
            return .unknownError(customerMessage ?? "未知错误")
        }
    }
}

extension AppStoreDownloadManager {
    private func downloadId(for task: URLSessionTask) -> String? {
        if let taskDesc = task.taskDescription, !taskDesc.isEmpty {
            return taskDesc
        }
        return downloadTasks.first(where: { $0.value == task })?.key
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {

        guard let downloadId = downloadId(for: downloadTask),
              let destinationURL = downloadDestinations[downloadId],
              let storeItem = downloadStoreItems[downloadId] else {
            return
        }

        var actualLocation = location
        if !FileManager.default.fileExists(atPath: location.path) {

            let tempDownloadPath = destinationURL.path + ".download"
            if FileManager.default.fileExists(atPath: tempDownloadPath) {
                actualLocation = URL(fileURLWithPath: tempDownloadPath)
            } else if let foundURL = findDownloadedFile(
                downloadId: downloadId,
                location: location,
                destinationURL: destinationURL,
                expectedSize: downloadTask.countOfBytesReceived
            ) {
                actualLocation = foundURL
            } else if let lastResortURL = lastResortFileSearch(
                expectedSize: downloadTask.countOfBytesReceived,
                downloadId: downloadId
            ) {
                actualLocation = lastResortURL
            }
        }

        guard FileManager.default.fileExists(atPath: actualLocation.path) else {
            Task { @MainActor in
                self.isRetryingDownload.insert(downloadId)
                self.retryWithForegroundDownload(
                    downloadId: downloadId,
                    storeItem: storeItem,
                    destinationURL: destinationURL
                )
            }
            return
        }

        do {

            let targetDirectory = destinationURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: targetDirectory.path) {
                try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true, attributes: nil)
            }

            if actualLocation.path != destinationURL.path {
                let tempTargetURL = destinationURL.appendingPathExtension("tmp")
                if FileManager.default.fileExists(atPath: tempTargetURL.path) {
                    try FileManager.default.removeItem(at: tempTargetURL)
                }
                try FileManager.default.moveItem(at: actualLocation, to: tempTargetURL)

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    let _ = try? FileManager.default.replaceItemAt(
                        destinationURL,
                        withItemAt: tempTargetURL,
                        backupItemName: nil,
                        options: []
                    )
                } else {
                    try FileManager.default.moveItem(at: tempTargetURL, to: destinationURL)
                }
            }

            if !storeItem.md5.isEmpty {
                let isValid = verifyDownloadedFile(
                    downloadId: downloadId,
                    fileURL: destinationURL,
                    expectedMD5: storeItem.md5
                )
                if !isValid {
                }
            }

            let result = DownloadResult(
                downloadId: downloadId,
                fileURL: destinationURL,
                fileSize: downloadTask.countOfBytesReceived,
                metadata: DownloadAppMetadata(
                    bundleId: storeItem.metadata.bundleId,
                    bundleDisplayName: storeItem.metadata.bundleDisplayName,
                    bundleShortVersionString: storeItem.metadata.bundleShortVersionString,
                    softwareVersionExternalIdentifier: storeItem.metadata.softwareVersionExternalIdentifier,
                    softwareVersionExternalIdentifiers: storeItem.metadata.softwareVersionExternalIdentifiers
                ),
                sinfs: storeItem.sinfs,
                expectedMD5: storeItem.md5
            )

            Task { @MainActor in
                IPAProcessor.shared.processIPA(at: destinationURL, withSinfs: storeItem.sinfs) { processingResult in
                switch processingResult {
                case .success(let processedIPA):

                    Task {
                        do {

                            guard let metadata = result.metadata else {
                                self.safeComplete(downloadId: downloadId, result: .success(result))
                                return
                            }

                            let finalIPA = try await self.generateiTunesMetadata(
                                for: processedIPA.path,
                                bundleId: metadata.bundleId,
                                displayName: metadata.bundleDisplayName,
                                version: metadata.bundleShortVersionString,
                                externalVersionId: Int(metadata.softwareVersionExternalIdentifier) ?? 0,
                                externalVersionIds: metadata.softwareVersionExternalIdentifiers
                            )

                            let finalResult = DownloadResult(
                                downloadId: result.downloadId,
                                fileURL: URL(fileURLWithPath: finalIPA),
                                fileSize: result.fileSize,
                                metadata: result.metadata,
                                sinfs: result.sinfs,
                                expectedMD5: result.expectedMD5
                            )

                            self.safeComplete(downloadId: downloadId, result: .success(finalResult))
                        } catch {
                            self.safeComplete(downloadId: downloadId, result: .success(result))
                        }
                    }
                case .failure(_):

                    self.safeComplete(downloadId: downloadId, result: .success(result))
                }
            }
            }
        } catch {
            safeComplete(downloadId: downloadId, result: .failure(.fileSystemError("文件移动失败: \(error.localizedDescription)")))
        }
    }
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {

        guard let downloadId = downloadId(for: downloadTask),
              let progressHandler = progressHandlers[downloadId],
              let startTime = downloadStartTimes[downloadId] else {
            return
        }
        let currentTime = Date()

        var speed: Double = 0.0
        var remainingTime: TimeInterval = 0.0
        if let lastUpdate = lastProgressUpdate[downloadId] {
            let timeDiff = currentTime.timeIntervalSince(lastUpdate.time)
            if timeDiff > 0 {
                let bytesDiff = totalBytesWritten - lastUpdate.bytes
                speed = Double(bytesDiff) / timeDiff
            }
        } else {

            let totalTime = currentTime.timeIntervalSince(startTime)
            if totalTime > 0 {
                speed = Double(totalBytesWritten) / totalTime
            }
        }

        if speed > 0 && totalBytesExpectedToWrite > totalBytesWritten {
            let remainingBytes = totalBytesExpectedToWrite - totalBytesWritten
            remainingTime = Double(remainingBytes) / speed
        }
        let progressValue = totalBytesExpectedToWrite > 0 ?
            Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0.0
        let progress = DownloadProgress(
            downloadId: downloadId,
            bytesDownloaded: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite,
            progress: progressValue,
            speed: speed,
            remainingTime: remainingTime,
            status: DownloadStatus.downloading
        )

        let lastUIUpdateTime = lastUIUpdate[downloadId] ?? Date.distantPast
        let shouldUpdate = currentTime.timeIntervalSince(lastUIUpdateTime) >= 0.1 || progressValue >= 1.0

        lastProgressUpdate[downloadId] = (bytes: totalBytesWritten, time: currentTime)
        if shouldUpdate {
            lastUIUpdate[downloadId] = currentTime

            if persistedContexts[downloadId] != nil {
                persistContext(
                    for: downloadId,
                    bytesDownloaded: totalBytesWritten,
                    totalBytes: totalBytesExpectedToWrite
                )
            }

            DispatchQueue.main.async {
                progressHandler(progress)
            }
        }
    }

    private func findDownloadedFile(
        downloadId: String,
        location: URL,
        destinationURL: URL,
        expectedSize: Int64
    ) -> URL? {
        let fileManager = FileManager.default
        let tempDir = NSTemporaryDirectory()
        let cachesDir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? ""
        let libraryDir = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first ?? ""
        let docsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""

        var searchPaths: [String] = []

        let standardPaths = [
            tempDir + location.lastPathComponent,
            tempDir + "\(downloadId).tmp",
            tempDir + "\(downloadId).download",
            cachesDir + "/\(location.lastPathComponent)",
            cachesDir + "/\(downloadId).tmp",
            cachesDir + "/\(downloadId).download",
            cachesDir + "/com.apple.nsurlsessiond/Downloads/\(location.lastPathComponent)",
            cachesDir + "/com.apple.nsurlsessiond/Downloads/\(downloadId)",
            cachesDir + "/com.apple.CFNetworkDownload_\(downloadId).tmp",
            libraryDir + "/Caches/\(location.lastPathComponent)",
            libraryDir + "/Caches/\(downloadId).tmp",
            libraryDir + "/Caches/com.apple.nsurlsessiond/Downloads/\(location.lastPathComponent)",
            libraryDir + "/Caches/com.apple.CFNetworkDownload_\(downloadId).tmp",
            destinationURL.path + ".download",
            destinationURL.deletingLastPathComponent().path + "/\(location.lastPathComponent)",
            destinationURL.deletingLastPathComponent().path + "/\(downloadId).tmp",
            docsDir + "/\(location.lastPathComponent)",
            docsDir + "/\(downloadId).tmp",
            docsDir + "/Downloads/\(location.lastPathComponent)"
        ]
        searchPaths.append(contentsOf: standardPaths)

        let isTrollStore = EnvironmentDetector.shared.isTrollStore
        let isJailbroken = EnvironmentDetector.shared.isJailbroken

        if isTrollStore || isJailbroken {
            let bundleId = Bundle.main.bundleIdentifier ?? ""
            let trollStorePaths = [
                "/var/mobile/Library/Caches/\(location.lastPathComponent)",
                "/var/mobile/Library/Caches/com.apple.nsurlsessiond/Downloads/\(location.lastPathComponent)",
                "/private/var/mobile/Library/Caches/\(location.lastPathComponent)",
                "/private/var/mobile/Library/Caches/com.apple.nsurlsessiond/Downloads/\(location.lastPathComponent)",
                "/var/mobile/Containers/Data/Application/\(bundleId)/tmp/\(location.lastPathComponent)",
                "/var/mobile/Containers/Data/Application/\(bundleId)/Library/Caches/\(location.lastPathComponent)",
                "/var/tmp/\(location.lastPathComponent)",
                "/private/var/tmp/\(location.lastPathComponent)",
                "/tmp/\(location.lastPathComponent)",
                "/var/mobile/tmp/\(location.lastPathComponent)",
                "/private/var/mobile/tmp/\(location.lastPathComponent)"
            ]
            searchPaths.append(contentsOf: trollStorePaths)
        }

        for path in searchPaths {
            if fileManager.fileExists(atPath: path) {
                do {
                    let attrs = try fileManager.attributesOfItem(atPath: path)
                    let fileSize = attrs[.size] as? Int64 ?? 0
                    if expectedSize > 0 {
                        let sizeDiff = abs(fileSize - expectedSize)
                        let sizeRatio = Double(sizeDiff) / Double(expectedSize)
                        if sizeRatio < 0.05 {
                            return URL(fileURLWithPath: path)
                        } else {
                        }
                    } else {
                        return URL(fileURLWithPath: path)
                    }
                } catch {
                    if fileManager.fileExists(atPath: path) {
                        return URL(fileURLWithPath: path)
                    }
                }
            }
        }

        if let deepSearchResult = deepSearchForFile(
            in: cachesDir,
            expectedSize: expectedSize,
            downloadId: downloadId,
            locationLastPath: location.lastPathComponent
        ) {
            return deepSearchResult
        }

        if isTrollStore || isJailbroken {
            let systemCacheDirs = [
                "/var/mobile/Library/Caches",
                "/private/var/mobile/Library/Caches"
            ]
            for dir in systemCacheDirs {
                if let result = deepSearchForFile(
                    in: dir,
                    expectedSize: expectedSize,
                    downloadId: downloadId,
                    locationLastPath: location.lastPathComponent
                ) {
                    return result
                }
            }
        }

        return nil
    }

    private func deepSearchForFile(
        in directory: String,
        expectedSize: Int64,
        downloadId: String,
        locationLastPath: String
    ) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: directory) else {
            return nil
        }

        var candidates: [(path: String, size: Int64)] = []
        let maxCandidates = 50
        var checkedCount = 0
        let maxCheck = 500

        while let filePath = enumerator.nextObject() as? String, checkedCount < maxCheck {
            checkedCount += 1
            let fullPath = (directory as NSString).appendingPathComponent(filePath)
            let fileName = (fullPath as NSString).lastPathComponent

            let isPossibleMatch = fileName.contains(locationLastPath)
                || fileName.contains(downloadId)
                || fileName.hasSuffix(".ipa")
                || fileName.hasSuffix(".tmp")
                || fileName.hasSuffix(".download")

            if isPossibleMatch {
                do {
                    let attrs = try fileManager.attributesOfItem(atPath: fullPath)
                    let fileSize = attrs[.size] as? Int64 ?? 0

                    if expectedSize > 0 {
                        let sizeDiff = abs(fileSize - expectedSize)
                        let sizeRatio = Double(sizeDiff) / Double(expectedSize)
                        if sizeRatio < 0.05 {
                            return URL(fileURLWithPath: fullPath)
                        } else if sizeRatio < 0.3 {
                            candidates.append((fullPath, fileSize))
                        }
                    } else {
                        candidates.append((fullPath, fileSize))
                    }
                } catch {
                    continue
                }
            }

            if candidates.count >= maxCandidates {
                break
            }
        }

        if !candidates.isEmpty {
            let bestMatch = candidates.min { abs($0.size - expectedSize) < abs($1.size - expectedSize) }
            if let best = bestMatch {
                return URL(fileURLWithPath: best.path)
            }
        }

        return nil
    }

    private func lastResortFileSearch(expectedSize: Int64, downloadId: String) -> URL? {
        let fileManager = FileManager.default
        let tempDir = NSTemporaryDirectory()
        let cachesDir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? ""
        let libraryDir = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first ?? ""
        let docsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""

        var searchDirs = [tempDir, cachesDir, libraryDir + "/Caches", docsDir]

        let isTrollStore = EnvironmentDetector.shared.isTrollStore
        let isJailbroken = EnvironmentDetector.shared.isJailbroken
        if isTrollStore || isJailbroken {
            searchDirs.append(contentsOf: [
                "/var/tmp",
                "/private/var/tmp",
                "/tmp",
                "/var/mobile/Library/Caches",
                "/private/var/mobile/Library/Caches"
            ])
        }

        var candidates: [(path: String, size: Int64, modDate: Date)] = []

        for dir in searchDirs {
            guard let enumerator = fileManager.enumerator(atPath: dir) else { continue }
            var checked = 0
            while let filePath = enumerator.nextObject() as? String, checked < 1000 {
                checked += 1
                let fullPath = (dir as NSString).appendingPathComponent(filePath)
                let fileName = (fullPath as NSString).lastPathComponent

                let isPossible = fileName.hasSuffix(".ipa")
                    || fileName.hasSuffix(".tmp")
                    || fileName.hasSuffix(".download")
                    || fileName.contains("CFNetwork")
                    || fileName.contains("nsurlsession")
                    || fileName.contains(downloadId)

                guard isPossible else { continue }

                do {
                    let attrs = try fileManager.attributesOfItem(atPath: fullPath)
                    let fileSize = attrs[.size] as? Int64 ?? 0
                    let modDate = attrs[.modificationDate] as? Date ?? Date.distantPast

                    if expectedSize > 0 {
                        let sizeDiff = abs(fileSize - expectedSize)
                        let sizeRatio = Double(sizeDiff) / Double(expectedSize)
                        if sizeRatio < 0.5 {
                            candidates.append((fullPath, fileSize, modDate))
                        }
                    } else if fileSize > 1024 * 1024 {
                        candidates.append((fullPath, fileSize, modDate))
                    }
                } catch {
                    continue
                }
            }
        }

        if !candidates.isEmpty {
            candidates.sort { $0.modDate > $1.modDate }
            if expectedSize > 0 {
                candidates.sort { abs($0.size - expectedSize) < abs($1.size - expectedSize) }
            }
            if let best = candidates.first {
                return URL(fileURLWithPath: best.path)
            }
        }

        return nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let downloadId = dataTask.taskDescription, !downloadId.isEmpty else {
            completionHandler(.allow)
            return
        }
        let expectedSize = response.expectedContentLength
        directDownloadExpectedSize[downloadId] = expectedSize
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let downloadId = dataTask.taskDescription, !downloadId.isEmpty else { return }

        if let fileHandle = directDownloadFileHandles[downloadId] {
            do {
                if #available(iOS 13.0, *) {
                    try fileHandle.seekToEnd()
                } else {
                    fileHandle.seekToEndOfFile()
                }
                fileHandle.write(data)
                directDownloadBytesWritten[downloadId] = (directDownloadBytesWritten[downloadId] ?? 0) + Int64(data.count)
            } catch {

            }
        }

        let totalBytesWritten = directDownloadBytesWritten[downloadId] ?? 0
        let totalBytesExpected = directDownloadExpectedSize[downloadId] ?? 0
        let progress = totalBytesExpected > 0 ? Double(totalBytesWritten) / Double(totalBytesExpected) : 0

        guard let progressHandler = progressHandlers[downloadId],
              let startTime = downloadStartTimes[downloadId] else {
            return
        }

        let currentTime = Date()
        var speed: Double = 0.0
        if let lastUpdate = lastProgressUpdate[downloadId] {
            let timeDiff = currentTime.timeIntervalSince(lastUpdate.time)
            if timeDiff > 0 {
                let bytesDiff = totalBytesWritten - lastUpdate.bytes
                speed = Double(bytesDiff) / timeDiff
            }
        } else {
            let totalTime = currentTime.timeIntervalSince(startTime)
            if totalTime > 0 {
                speed = Double(totalBytesWritten) / totalTime
            }
        }

        lastProgressUpdate[downloadId] = (totalBytesWritten, currentTime)

        var remainingTime: TimeInterval = 0
        if speed > 0 && totalBytesExpected > 0 {
            remainingTime = Double(totalBytesExpected - totalBytesWritten) / speed
        }

        let downloadProgress = DownloadProgress(
            downloadId: downloadId,
            bytesDownloaded: totalBytesWritten,
            totalBytes: totalBytesExpected,
            progress: progress,
            speed: speed,
            remainingTime: remainingTime,
            status: .downloading
        )

        DispatchQueue.main.async {
            progressHandler(downloadProgress)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let dataTask = task as? URLSessionDataTask, let tid = dataTask.taskDescription, !tid.isEmpty {
            handleDirectDownloadCompletion(downloadId: tid, error: error)
            return
        }

        guard let downloadTask = task as? URLSessionDownloadTask,
              let downloadId = downloadId(for: downloadTask),
              let _ = downloadDestinations[downloadId],
              let _ = downloadStoreItems[downloadId] else {
            return
        }

        if isRetryingDownload.contains(downloadId) {
            return
        }

        if completedDownloads.contains(downloadId) {
            return
        }

        if let error = error {

            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                resumeDataStore[downloadId] = resumeData
            }

            if let nsError = error as NSError? {

                if nsError.domain == NSURLErrorDomain {

                    switch nsError.code {
                    case NSURLErrorNotConnectedToInternet:
                        safeComplete(downloadId: downloadId, result: .failure(.networkError(NSError(domain: "DownloadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "设备未连接到互联网，请检查网络连接后重试"]))))
                    case NSURLErrorTimedOut:
                        safeComplete(downloadId: downloadId, result: .failure(.networkError(NSError(domain: "DownloadManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "下载超时，请检查网络连接后重试"]))))
                    case NSURLErrorCancelled:
                        safeComplete(downloadId: downloadId, result: .failure(.unknownError("下载已取消")))
                    default:
                        safeComplete(downloadId: downloadId, result: .failure(.networkError(NSError(domain: "DownloadManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "下载失败，请稍后重试"]))))
                    }
                } else if nsError.domain == "NSCocoaErrorDomain" {

                    safeComplete(downloadId: downloadId, result: .failure(.fileSystemError("文件操作失败，请确保有足够的存储空间")))
                } else {

                    safeComplete(downloadId: downloadId, result: .failure(.unknownError("下载过程中发生未知错误")))
                }
            } else {

                safeComplete(downloadId: downloadId, result: .failure(.unknownError("下载失败: \(error.localizedDescription)")))
            }
        }
    }

    private func handleDirectDownloadCompletion(downloadId: String, error: Error?) {
        guard let destinationURL = downloadDestinations[downloadId],
              let storeItem = downloadStoreItems[downloadId] else {
            return
        }

        if let fileHandle = directDownloadFileHandles[downloadId] {
            do {
                if #available(iOS 13.0, *) {
                    try fileHandle.close()
                } else {
                    fileHandle.closeFile()
                }
            } catch {}
            directDownloadFileHandles.removeValue(forKey: downloadId)
        }

        if let error = error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet:
                    safeComplete(downloadId: downloadId, result: .failure(.networkError(NSError(domain: "DownloadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "设备未连接到互联网，请检查网络连接后重试"]))))
                case NSURLErrorTimedOut:
                    safeComplete(downloadId: downloadId, result: .failure(.networkError(NSError(domain: "DownloadManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "下载超时，请检查网络连接后重试"]))))
                case NSURLErrorCancelled:
                    safeComplete(downloadId: downloadId, result: .failure(.unknownError("下载已取消")))
                default:
                    safeComplete(downloadId: downloadId, result: .failure(.networkError(NSError(domain: "DownloadManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "下载失败，请稍后重试"]))))
                }
            } else {
                safeComplete(downloadId: downloadId, result: .failure(.unknownError("下载失败: \(error.localizedDescription)")))
            }
            return
        }

        var downloadedFileSize: Int64 = 0

        if let tempFileURL = directDownloadTempFiles[downloadId],
           FileManager.default.fileExists(atPath: tempFileURL.path),
           let fileSize = try? FileManager.default.attributesOfItem(atPath: tempFileURL.path)[.size] as? NSNumber,
           fileSize.int64Value > 0 {
            downloadedFileSize = fileSize.int64Value

        }

        guard let tempFileURL = directDownloadTempFiles[downloadId],
              FileManager.default.fileExists(atPath: tempFileURL.path),
              downloadedFileSize > 0 else {
            safeComplete(downloadId: downloadId, result: .failure(.fileSystemError("下载数据为空或临时文件不存在")))
            return
        }

        do {
            let targetDirectory = destinationURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: targetDirectory.path) {
                try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true, attributes: nil)
            }

            let tempTargetURL = destinationURL.appendingPathExtension("tmp")

            if FileManager.default.fileExists(atPath: tempTargetURL.path) {
                try FileManager.default.removeItem(at: tempTargetURL)
            }

            try FileManager.default.moveItem(at: tempFileURL, to: tempTargetURL)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let _ = try? FileManager.default.replaceItemAt(
                    destinationURL,
                    withItemAt: tempTargetURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: tempTargetURL, to: destinationURL)
            }

            let result = DownloadResult(
                downloadId: downloadId,
                fileURL: destinationURL,
                fileSize: downloadedFileSize,
                metadata: DownloadAppMetadata(
                    bundleId: storeItem.metadata.bundleId,
                    bundleDisplayName: storeItem.metadata.bundleDisplayName,
                    bundleShortVersionString: storeItem.metadata.bundleShortVersionString,
                    softwareVersionExternalIdentifier: storeItem.metadata.softwareVersionExternalIdentifier,
                    softwareVersionExternalIdentifiers: storeItem.metadata.softwareVersionExternalIdentifiers
                ),
                sinfs: storeItem.sinfs,
                expectedMD5: storeItem.md5
            )

            Task { @MainActor in
                IPAProcessor.shared.processIPA(at: destinationURL, withSinfs: storeItem.sinfs) { processingResult in
                    switch processingResult {
                    case .success(let processedIPA):

                        Task {
                            do {
                                guard let metadata = result.metadata else {
                                    self.safeComplete(downloadId: downloadId, result: .success(result))
                                    return
                                }

                                let finalIPA = try await self.generateiTunesMetadata(
                                    for: processedIPA.path,
                                    bundleId: metadata.bundleId,
                                    displayName: metadata.bundleDisplayName,
                                    version: metadata.bundleShortVersionString,
                                    externalVersionId: Int(metadata.softwareVersionExternalIdentifier) ?? 0,
                                    externalVersionIds: metadata.softwareVersionExternalIdentifiers
                                )

                                let finalResult = DownloadResult(
                                    downloadId: result.downloadId,
                                    fileURL: URL(fileURLWithPath: finalIPA),
                                    fileSize: result.fileSize,
                                    metadata: result.metadata,
                                    sinfs: result.sinfs,
                                    expectedMD5: result.expectedMD5
                                )

                                self.safeComplete(downloadId: downloadId, result: .success(finalResult))
                            } catch {
                                self.safeComplete(downloadId: downloadId, result: .success(result))
                            }
                        }
                    case .failure(_):
                        self.safeComplete(downloadId: downloadId, result: .success(result))
                    }
                }
            }
        } catch {
            safeComplete(downloadId: downloadId, result: .failure(.fileSystemError("文件写入失败: \(error.localizedDescription)")))
        }
    }
}

struct DownloadProgress {
    let downloadId: String
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let progress: Double
    let speed: Double
    let remainingTime: TimeInterval
    let status: DownloadStatus
    var formattedProgress: String {
        return String(format: "%.1f%%", progress * 100)
    }
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: bytesDownloaded)) / \(formatter.string(fromByteCount: totalBytes))"
    }
    var formattedSpeed: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(speed)))/s"
    }
    var formattedRemainingTime: String {
        if remainingTime <= 0 {
            return "--:--"
        }
        let hours = Int(remainingTime) / 3600
        let minutes = (Int(remainingTime) % 3600) / 60
        let seconds = Int(remainingTime) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

struct DownloadResult {
    let downloadId: String
    let fileURL: URL
    let fileSize: Int64
    var metadata: DownloadAppMetadata?
    var sinfs: [DownloadSinfInfo]?
    var expectedMD5: String?
    var isIntegrityValid: Bool {
        guard let expectedMD5 = expectedMD5,
              let fileData = try? Data(contentsOf: fileURL) else {
            return false
        }
        let digest = Insecure.MD5.hash(data: fileData)
        let calculatedMD5 = digest.map { String(format: "%02hhx", $0) }.joined()
        return calculatedMD5.lowercased() == expectedMD5.lowercased()
    }
}

enum DownloadError: LocalizedError {
    case invalidURL(String)
    case appNotFound(String)
    case licenseError(String)
    case authenticationError(String)
    case downloadNotFound(String)
    case fileSystemError(String)
    case integrityCheckFailed(String)
    case licenseCheckFailed(String)
    case networkError(Error)
    case unknownError(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL(let message):
            return "无效的URL: \(message)"
        case .appNotFound(let message):
            return "应用未找到: \(message)"
        case .licenseError(let message):
            return "许可证错误: \(message)"
        case .authenticationError(let message):
            return "认证错误: \(message)"
        case .downloadNotFound(let message):
            return "下载未找到: \(message)"
        case .fileSystemError(let message):
            return "文件系统错误: \(message)"
        case .integrityCheckFailed(let message):
            return "完整性检查失败: \(message)"
        case .licenseCheckFailed(let message):
            return "许可证检查失败: \(message)"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .unknownError(let message):
            return "未知错误: \(message)"
        }
    }
}

struct UnifiedDownloadRequest: Identifiable, Codable {
    let id: String
    let bundleIdentifier: String
    let name: String
    let version: String
    let identifier: String
    let iconURL: String?
    let versionId: String?
    var status: DownloadStatus
    var progress: Double
    let createdAt: Date
    var completedAt: Date?
    var filePath: String?
    var errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, bundleIdentifier, name, version, identifier, iconURL, versionId, status, progress
        case createdAt, completedAt, filePath, errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        identifier = try container.decode(String.self, forKey: .identifier)
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        versionId = try container.decodeIfPresent(String.self, forKey: .versionId)
        status = try container.decode(DownloadStatus.self, forKey: .status)
        progress = try container.decode(Double.self, forKey: .progress)

        let createdAtString = try container.decode(String.self, forKey: .createdAt)
        createdAt = ISO8601DateFormatter().date(from: createdAtString) ?? Date()

        if let completedAtString = try container.decodeIfPresent(String.self, forKey: .completedAt) {
            completedAt = ISO8601DateFormatter().date(from: completedAtString)
        }

        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(identifier, forKey: .identifier)
        try container.encodeIfPresent(iconURL, forKey: .iconURL)
        try container.encodeIfPresent(versionId, forKey: .versionId)
        try container.encode(status, forKey: .status)
        try container.encode(progress, forKey: .progress)

        let dateFormatter = ISO8601DateFormatter()
        try container.encode(dateFormatter.string(from: createdAt), forKey: .createdAt)

        if let completedAt = completedAt {
            try container.encode(dateFormatter.string(from: completedAt), forKey: .completedAt)
        }

        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }
}

extension AppStoreDownloadManager {

    private func generateiTunesMetadata(
        for ipaPath: String,
        bundleId: String,
        displayName: String,
        version: String,
        externalVersionId: Int,
        externalVersionIds: [Int]?
    ) async throws -> String {

        let metadataDict: [String: Any] = [
            "appleId": bundleId,
            "artistId": 0,
            "artistName": displayName,
            "bundleId": bundleId,
            "bundleVersion": version,
            "copyright": "Copyright © 2025",
            "drmVersionNumber": 0,
            "fileExtension": "ipa",
            "fileName": "\(displayName).ipa",
            "genre": "Productivity",
            "genreId": 6007,
            "itemId": 0,
            "itemName": displayName,
            "kind": "software",
            "playlistName": "iOS Apps",
            "price": 0.0,
            "priceDisplay": "Free",
            "rating": "4+",
            "releaseDate": "2025-01-01T00:00:00Z",
            "s": 143441,
            "softwareIcon57x57URL": "",
            "softwareIconNeedsShine": false,
            "softwareSupportedDeviceIds": [1, 2],
            "softwareVersionBundleId": bundleId,
            "softwareVersionExternalIdentifier": externalVersionId,
            "softwareVersionExternalIdentifiers": externalVersionIds ?? [],
            "subgenres": [],
            "vendorId": 0,
            "versionRestrictions": 0
        ]

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: metadataDict,
            format: .xml,
            options: 0
        )

        let success = FastZipArchive.shared.addFiles(
            toZipAtPath: ipaPath,
            files: [("iTunesMetadata.plist", plistData)]
        )

        guard success else {
            throw NSError(domain: "iTunesMetadataProcessing", code: 1, userInfo: [NSLocalizedDescriptionKey: "FastZipArchive添加iTunesMetadata.plist失败"])
        }

        return ipaPath
    }
}
