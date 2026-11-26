import Foundation

final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let targetURL: URL
    private let onProgress: @Sendable (Double) -> Void
    private let onFinish: @Sendable (Result<URL, Error>) -> Void

    init(
        targetURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void,
        onFinish: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        self.targetURL = targetURL
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(0.999, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: targetURL)
            try FileManager.default.moveItem(at: location, to: targetURL)
            onFinish(.success(targetURL))
        } catch {
            onFinish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        onFinish(.failure(error))
    }
}

@MainActor
final class UpdateDownloader: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var delegate: UpdateDownloadDelegate?

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    func start(url: URL, version: String) {
        cancel()

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("APP_\(version).ipa")

        let delegate = UpdateDownloadDelegate(
            targetURL: target,
            onProgress: { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(fraction)
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let fileURL):
                        self.phase = .finished(fileURL)
                    case .failure(let error):
                        self.phase = .failed(error.localizedDescription)
                    }
                    self.session?.finishTasksAndInvalidate()
                    self.session = nil
                    self.task = nil
                }
            }
        )
        self.delegate = delegate

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        configuration.allowsCellularAccess = true

        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session

        let task = session.downloadTask(with: url)
        self.task = task
        phase = .downloading(0)
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
        if case .downloading = phase {
            phase = .idle
        }
    }
}
