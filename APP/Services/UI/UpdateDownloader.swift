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
        case preparing
        case downloading(Double)
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isIncremental = false
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var downloadedBytes: Int64 = 0

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var delegate: UpdateDownloadDelegate?
    private var incrementalTask: Task<Void, Never>?

    var isDownloading: Bool {
        switch phase {
        case .preparing, .downloading: return true
        default: return false
        }
    }

    var progressFraction: Double {
        if case .downloading(let value) = phase { return value }
        return 0
    }

    func start(url: URL, version: String) {
        cancel()

        let directory = updatesDirectory()
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
                    self.delegate = nil
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
        isIncremental = false
        totalBytes = 0
        downloadedBytes = 0
        phase = .downloading(0)
        task.resume()
    }

    func startIncremental(
        newURL: URL,
        newSize: Int64,
        version: String,
        baseURL: URL
    ) {
        cancel()

        let target = updatesDirectory().appendingPathComponent("APP_\(version).ipa")
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.allowsCellularAccess = true
        let session = URLSession(configuration: configuration)
        self.session = session

        isIncremental = true
        totalBytes = newSize
        downloadedBytes = 0
        phase = .preparing

        incrementalTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let plan = try await IncrementalIPAUpdater.makePlan(
                    baseURL: baseURL,
                    newURL: newURL,
                    newSize: newSize,
                    session: session
                )
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    self.totalBytes = plan.downloadBytes
                    self.downloadedBytes = 0
                    self.phase = .downloading(0)
                }
                try await IncrementalIPAUpdater.apply(
                    plan: plan,
                    baseURL: baseURL,
                    newURL: newURL,
                    targetURL: target,
                    session: session
                ) { fraction in
                    Task { @MainActor in
                        guard let self, self.isIncremental else { return }
                        guard case .downloading = self.phase else { return }
                        self.phase = .downloading(fraction)
                        self.downloadedBytes = Int64(Double(plan.downloadBytes) * fraction)
                    }
                }
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    self.phase = .finished(target)
                    self.incrementalTask = nil
                    self.session?.finishTasksAndInvalidate()
                    self.session = nil
                }
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    self.incrementalTask = nil
                    self.session?.invalidateAndCancel()
                    self.session = nil
                    self.isIncremental = false
                    self.totalBytes = 0
                    self.downloadedBytes = 0
                    self.start(url: newURL, version: version)
                }
            }
        }
    }

    func cancel() {
        incrementalTask?.cancel()
        incrementalTask = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
        isIncremental = false
        totalBytes = 0
        downloadedBytes = 0
        switch phase {
        case .preparing, .downloading:
            phase = .idle
        default:
            break
        }
    }

    private func updatesDirectory() -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
