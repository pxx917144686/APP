import Foundation
import UIKit
#if canImport(Alamofire)
import Alamofire
#endif

@MainActor
final class BackgroundDownloadManager: ObservableObject, @unchecked Sendable {
    static let shared = BackgroundDownloadManager()

    @Published var downloadProgress: [String: Double] = [:]

    #if canImport(Alamofire)
    @Published var activeDownloads: [String: Alamofire.DownloadRequest] = [:]
    #else
    @Published var activeDownloads: Set<String> = []
    #endif

    private init() {}

    #if canImport(Alamofire)

    private lazy var backgroundSession: Alamofire.Session = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.app.backgrounddownload"
        )
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
            "HTTPProxy": "",
            "HTTPSProxy": "",
            "SOCKSProxy": ""
        ]
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.shouldUseExtendedBackgroundIdleMode = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7200
        configuration.waitsForConnectivity = true
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.tlsMaximumSupportedProtocolVersion = .TLSv13
        configuration.networkServiceType = .default

        let session = Alamofire.Session(
            configuration: configuration,
            rootQueue: DispatchQueue(label: "com.app.backgrounddownload.root"),
            serializationQueue: DispatchQueue(label: "com.app.backgrounddownload.serialization")
        )

        return session
    }()

    func startDownload(
        url: URL,
        destinationURL: URL,
        downloadId: String,
        headers: Alamofire.HTTPHeaders? = nil,
        progressHandler: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {

        let destination: Alamofire.DownloadRequest.Destination = { _, _ in
            (destinationURL, [.removePreviousFile, .createIntermediateDirectories])
        }

        let request = backgroundSession.download(
            url,
            method: .get,
            headers: headers,
            to: destination
        )
        .downloadProgress { progress in
            DispatchQueue.main.async {
                self.downloadProgress[downloadId] = progress.fractionCompleted
                progressHandler(progress.fractionCompleted)
            }
        }
        .response { response in
            switch response.result {
            case .success(let fileURL):
                if let fileURL = fileURL {

                    DispatchQueue.main.async {
                        self.activeDownloads.removeValue(forKey: downloadId)
                        self.downloadProgress.removeValue(forKey: downloadId)
                    }
                    completion(.success(fileURL))
                } else {

                    completion(.failure(NSError(domain: "BackgroundDownload", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载文件URL为空"])))
                }
            case .failure(let error):

                DispatchQueue.main.async {
                    self.activeDownloads.removeValue(forKey: downloadId)
                    self.downloadProgress.removeValue(forKey: downloadId)
                }
                completion(.failure(error))
            }
        }

        activeDownloads[downloadId] = request
        downloadProgress[downloadId] = 0
    }

    func cancelDownload(downloadId: String) {
        activeDownloads[downloadId]?.cancel()
        activeDownloads.removeValue(forKey: downloadId)
        downloadProgress.removeValue(forKey: downloadId)

    }

    func pauseDownload(downloadId: String) {
        activeDownloads[downloadId]?.suspend()

    }

    func resumeDownload(downloadId: String) {
        activeDownloads[downloadId]?.resume()

    }

    #else

    func startDownload(
        url: URL,
        destinationURL: URL,
        downloadId: String,
        headers: [String: String]? = nil,
        progressHandler: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {

        let config = URLSessionConfiguration.background(withIdentifier: "com.app.backgrounddownload")
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
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        config.waitsForConnectivity = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        config.networkServiceType = .default

        let session = URLSession(
            configuration: config,
            delegate: LegacyBackgroundDownloadDelegate.shared,
            delegateQueue: nil
        )

        var request = URLRequest(url: url)
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let task = session.downloadTask(with: request)
        task.resume()

        LegacyBackgroundDownloadDelegate.shared.registerTask(
            task,
            downloadId: downloadId,
            destinationURL: destinationURL,
            progressHandler: progressHandler,
            completion: completion
        )

        DispatchQueue.main.async {
            self.downloadProgress[downloadId] = 0
            self.activeDownloads.insert(downloadId)
        }
    }

    func cancelDownload(downloadId: String) {
        LegacyBackgroundDownloadDelegate.shared.cancelDownload(downloadId: downloadId)
        activeDownloads.remove(downloadId)
        downloadProgress.removeValue(forKey: downloadId)
    }

    #endif
}

#if !canImport(Alamofire)
final class LegacyBackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    static let shared = LegacyBackgroundDownloadDelegate()

    private var tasks: [Int: String] = [:]
    private var destinations: [String: URL] = [:]
    private var progressHandlers: [String: (Double) -> Void] = [:]
    private var completionHandlers: [String: (Result<URL, Error>) -> Void] = [:]
    private let lock = NSLock()

    private override init() {
        super.init()
    }

    func registerTask(
        _ task: URLSessionDownloadTask,
        downloadId: String,
        destinationURL: URL,
        progressHandler: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }

        tasks[task.taskIdentifier] = downloadId
        destinations[downloadId] = destinationURL
        progressHandlers[downloadId] = progressHandler
        completionHandlers[downloadId] = completion
    }

    func cancelDownload(downloadId: String) {
        lock.lock()
        let taskId = tasks.first(where: { $0.value == downloadId })?.key
        lock.unlock()

        if let taskId = taskId {
            URLSession.shared.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == taskId })?.cancel()
            }
        }

        lock.lock()
        if let taskId = taskId {
            tasks.removeValue(forKey: taskId)
        }
        destinations.removeValue(forKey: downloadId)
        progressHandlers.removeValue(forKey: downloadId)
        completionHandlers.removeValue(forKey: downloadId)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        let downloadId = tasks[downloadTask.taskIdentifier]
        let destination = destinations[downloadId ?? ""]
        let completion = completionHandlers[downloadId ?? ""]
        lock.unlock()

        guard let downloadId = downloadId,
              let destination = destination,
              let completion = completion else {
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)

            completion(.success(destination))
        } catch {

            completion(.failure(error))
        }

        cleanup(downloadId: downloadId, taskId: downloadTask.taskIdentifier)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let downloadId = tasks[downloadTask.taskIdentifier]
        let progressHandler = progressHandlers[downloadId ?? ""]
        lock.unlock()

        guard let downloadId = downloadId,
              let progressHandler = progressHandler else {
            return
        }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            BackgroundDownloadManager.shared.downloadProgress[downloadId] = progress
        }
        progressHandler(progress)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            lock.lock()
            let downloadId = tasks[task.taskIdentifier]
            let completion = completionHandlers[downloadId ?? ""]
            lock.unlock()

            if let downloadId = downloadId, let completion = completion {

                completion(.failure(error))
                cleanup(downloadId: downloadId, taskId: task.taskIdentifier)
            }
        }
    }

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

    private func cleanup(downloadId: String, taskId: Int) {
        lock.lock()
        tasks.removeValue(forKey: taskId)
        destinations.removeValue(forKey: downloadId)
        progressHandlers.removeValue(forKey: downloadId)
        completionHandlers.removeValue(forKey: downloadId)
        lock.unlock()

        DispatchQueue.main.async {
            BackgroundDownloadManager.shared.activeDownloads.remove(downloadId)
            BackgroundDownloadManager.shared.downloadProgress.removeValue(forKey: downloadId)
        }
    }
}
#endif
