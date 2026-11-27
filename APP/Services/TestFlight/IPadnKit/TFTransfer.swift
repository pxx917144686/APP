import Foundation

/// Control surface forwarded to the segmented download engine while it owns
/// the transfer; a handle with attached controls routes pause/resume/cancel
/// to the engine instead of the legacy URLSessionDownloadTask.
public struct TFEngineControls: @unchecked Sendable {
    public let pause: () -> Void
    public let resume: () -> Void
    public let cancel: () -> Void

    public init(pause: @escaping () -> Void,
                resume: @escaping () -> Void,
                cancel: @escaping () -> Void) {
        self.pause = pause
        self.resume = resume
        self.cancel = cancel
    }
}

public final class TFTransferHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var paused = false
    private var pauseContinuation: CheckedContinuation<Void, Error>?
    private var pausedResumeData: Data?
    private var engine: TFEngineControls?

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused && !cancelled
    }

    public func pause() {
        lock.lock()
        guard !cancelled, !paused else {
            lock.unlock()
            return
        }
        paused = true
        let task = self.task
        let engine = self.engine
        lock.unlock()
        engine?.pause()
        task?.cancel(byProducingResumeData: { [weak self] data in
            guard let self, let data, !data.isEmpty else { return }
            self.storePausedResumeData(data)
        })
    }

    public func resume() {
        lock.lock()
        guard !cancelled, paused else {
            lock.unlock()
            return
        }
        paused = false
        let continuation = pauseContinuation
        pauseContinuation = nil
        let engine = self.engine
        lock.unlock()
        engine?.resume()
        continuation?.resume()
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        paused = false
        pausedResumeData = nil
        let task = self.task
        let continuation = pauseContinuation
        pauseContinuation = nil
        let engine = self.engine
        lock.unlock()
        engine?.cancel()
        task?.cancel()
        continuation?.resume(throwing: TFError.cancelled)
    }

    func attachEngine(_ controls: TFEngineControls) {
        lock.lock()
        engine = controls
        let alreadyPaused = paused && !cancelled
        lock.unlock()
        if alreadyPaused {
            controls.pause()
        }
    }

    func detachEngine() {
        lock.lock()
        engine = nil
        lock.unlock()
    }

    func attach(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        let paused = self.paused
        lock.unlock()
        if cancelled {
            task.cancel()
        } else if paused {
            task.cancel(byProducingResumeData: { [weak self] data in
                guard let self, let data, !data.isEmpty else { return }
                self.storePausedResumeData(data)
            })
        }
    }

    func storePausedResumeData(_ data: Data) {
        lock.lock()
        if !cancelled {
            pausedResumeData = data
        }
        lock.unlock()
    }

    func takePausedResumeData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let data = pausedResumeData
        pausedResumeData = nil
        return data
    }

    public func waitWhilePaused() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: TFError.cancelled)
                    return
                }
                if !paused {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                if let previous = pauseContinuation {
                    previous.resume(throwing: TFError.cancelled)
                }
                pauseContinuation = continuation
                lock.unlock()
            }
        } onCancel: {
            self.cancel()
        }
    }
}

private struct TFTransferPausedError: Error {
    let resumeData: Data?
}

private struct TFBackgroundFallbackError: Error {}

/// Records pause/cancel intents that may arrive before the segmented engine
/// has registered its state for a download id.
final class SegmentedIntentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _paused = false
    private var _cancelled = false

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }

    var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }
}

final class TFBackgroundSessionHub: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = TFBackgroundSessionHub()

    private let lock = NSLock()
    private var attempts: [String: TFTransferAttempt] = [:]
    private var _preferForeground = false
    private var _backgroundUnavailable = false
    private var backgroundCompletion: (@Sendable () -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: TFTransfer.backgroundSessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 3
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    var preferForeground: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _preferForeground }
        set { lock.lock(); _preferForeground = newValue; lock.unlock() }
    }

    var shouldUseForeground: Bool {
        lock.lock(); defer { lock.unlock() }
        return _preferForeground || _backgroundUnavailable
    }

    func markBackgroundUnavailable() {
        lock.lock()
        _backgroundUnavailable = true
        lock.unlock()
    }

    func setBackgroundCompletion(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let previous = backgroundCompletion
        backgroundCompletion = {
            previous?()
            handler()
        }
        let idle = attempts.isEmpty
        lock.unlock()
        _ = session
        if idle {
        }
    }

    func register(taskID: String, attempt: TFTransferAttempt) -> URLSession {
        lock.lock()
        attempts[taskID] = attempt
        lock.unlock()
        return session
    }

    func unregister(taskID: String) {
        lock.lock()
        attempts.removeValue(forKey: taskID)
        lock.unlock()
    }

    private func attempt(for task: URLSessionTask) -> TFTransferAttempt? {
        guard let key = task.taskDescription else { return nil }
        lock.lock(); defer { lock.unlock() }
        return attempts[key]
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        attempt(for: downloadTask)?.handleDidWriteData(
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let target = attempt(for: downloadTask) else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        target.handleDidFinishDownloading(downloadTask: downloadTask, location: location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = task.taskDescription
        let target: TFTransferAttempt? = {
            guard let key else { return nil }
            lock.lock(); defer { lock.unlock() }
            return attempts.removeValue(forKey: key)
        }()
        target?.handleDidComplete(error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = backgroundCompletion
        backgroundCompletion = nil
        lock.unlock()
        guard let completion else { return }
        DispatchQueue.main.async {
            completion()
        }
    }
}

public enum TFTransfer {

    public static var backgroundSessionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "app.local.iPadn") + ".background.tf.downloads"
    }

    public static var preferForegroundSession: Bool {
        get { TFBackgroundSessionHub.shared.preferForeground }
        set { TFBackgroundSessionHub.shared.preferForeground = newValue }
    }

    public static func handleBackgroundEvents(completionHandler: @escaping @Sendable () -> Void) {
        TFBackgroundSessionHub.shared.setBackgroundCompletion(completionHandler)
    }

    public struct Outcome {
        public var bytes: Int
        public var attempts: [String]
    }

    static func isResumeDataCompatible(_ data: Data?, usingBackground: Bool) -> Bool {
        guard let data, !data.isEmpty else { return false }
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let bgID = plist["NSURLSessionResumeInfoBackgroundIdentifier"] as? String, !bgID.isEmpty {
            return usingBackground
        }
        return !usingBackground ? true : true
    }

    static func isBackgroundFileError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain,
           ns.code == NSURLErrorCannotCreateFile || ns.code == NSURLErrorCannotWriteToFile {
            return true
        }
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain,
           ns.code == Int(EACCES) || ns.code == Int(EPERM) {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return isBackgroundFileError(underlying)
        }
        return false
    }

    public static func download(url: URL, to destination: URL,
                                handle: TFTransferHandle,
                                progress: @escaping @Sendable (Int64, Int64) -> Void,
                                onResume: (@Sendable () -> Void)? = nil,
                                onForegroundFallback: (@Sendable () -> Void)? = nil,
                                refresh: () async throws -> URL?,
                                log: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        var attempts: [String] = []
        var resumeData: Data?
        var current = url
        var failureCount = 0

        while failureCount < 3 {
            if handle.isCancelled { throw TFError.cancelled }
            if handle.isPaused {
                try await handle.waitWhilePaused()
                if handle.isCancelled { throw TFError.cancelled }
                onResume?()
            }
            let useBackground = !TFBackgroundSessionHub.shared.shouldUseForeground && TFNet.mode != .direct
            if !useBackground {
                onForegroundFallback?()
            }
            let effectiveResume = isResumeDataCompatible(resumeData, usingBackground: useBackground) ? resumeData : nil
            let attemptIndex = failureCount + 1
            do {
                let attempt = TFTransferAttempt(handle: handle, progress: progress, useBackground: useBackground)
                let (temporary, response) = try await attempt.run(url: current, resume: effectiveResume)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                defer { try? FileManager.default.removeItem(at: temporary) }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? -1
                attempts.append("#\(attemptIndex) ok " + String(bytes) + " B (HTTP " + String(status)
                                + (effectiveResume == nil ? ", fresh" : ", resumed")
                                + (useBackground ? ", bg" : ", fg") + ")")
                log("cdn: " + attempts.joined(separator: "; "))
                return Outcome(bytes: bytes, attempts: attempts)
            } catch is TFBackgroundFallbackError {
                if handle.isCancelled { throw TFError.cancelled }
                TFBackgroundSessionHub.shared.markBackgroundUnavailable()
                resumeData = nil
                onForegroundFallback?()
                log("cdn: background session unavailable, falling back to foreground session")
                continue
            } catch let paused as TFTransferPausedError {
                if handle.isCancelled { throw TFError.cancelled }
                let captured = paused.resumeData ?? handle.takePausedResumeData()
                if let captured, !captured.isEmpty {
                    resumeData = captured
                }
                log("cdn: paused (" + (resumeData == nil ? "no resume data" : "resume data \(resumeData!.count) B") + ")")
                try await handle.waitWhilePaused()
                if handle.isCancelled { throw TFError.cancelled }
                if let late = handle.takePausedResumeData(), !late.isEmpty {
                    resumeData = late
                }
                onResume?()
                continue
            } catch {
                if handle.isCancelled { throw TFError.cancelled }
                if case TFError.cancelled = error { throw TFError.cancelled }
                if useBackground && isBackgroundFileError(error) {
                    TFBackgroundSessionHub.shared.markBackgroundUnavailable()
                    resumeData = nil
                    onForegroundFallback?()
                    log("cdn: background file error (\((error as NSError).code)), retrying in foreground")
                    continue
                }
                failureCount += 1
                let failure = error as NSError
                resumeData = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                attempts.append("#\(failureCount) failed " + String(failure.code)
                                + (resumeData == nil ? ", no resume data" : ", resume data ok"))
                log("cdn: attempt " + String(failureCount) + " failed (" + String(failure.code) + ")"
                    + (resumeData == nil ? "" : ", have resume data"))
                if failureCount >= 3 { break }

                var renewed: URL?
                do { renewed = try await refresh() } catch { renewed = nil }
                if let renewed, renewed != current {
                    log("cdn: install refreshed, URL changed (accessKey rotated)")
                    current = renewed
                    resumeData = nil
                }
            }
        }
        throw TFError.networkLost
    }

    /// Multi-connection transfer through the shared segmented engine
    /// (`SegmentedIPADownloader`). Bytes stream into `scratchURL` (persistent,
    /// keeps `.segresume` across process restarts and URL access-key rotation)
    /// and move to `destination` on success. Pause/resume/cancel are routed
    /// through the handle to the engine.
    static func downloadSegmented(url: URL, to destination: URL,
                                  scratchURL: URL,
                                  handle: TFTransferHandle,
                                  maxConnections: Int,
                                  allowsSystemProxy: Bool,
                                  progress: @escaping @Sendable (Int64, Int64) -> Void,
                                  onActiveConnections: (@Sendable (Int) -> Void)? = nil,
                                  onResume: (@Sendable () -> Void)? = nil,
                                  refresh: () async throws -> URL?,
                                  log: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        var attempts: [String] = []
        var current = url
        var failureCount = 0

        func cleanupScratch() {
            try? FileManager.default.removeItem(at: scratchURL)
            // Mirrors SegmentedIPADownloader.resumeFilePath(_:).
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: scratchURL.path + ".segresume"))
        }

        while failureCount < 3 {
            if handle.isCancelled { throw TFError.cancelled }
            if handle.isPaused {
                try await handle.waitWhilePaused()
                if handle.isCancelled { throw TFError.cancelled }
                onResume?()
            }

            let attemptURL = current
            let downloadId = UUID().uuidString
            let attemptIndex = failureCount + 1
            log("cdn: segmented attempt #\(String(attemptIndex)) conns=\(String(maxConnections))")
            let engine = SegmentedIPADownloader.shared

            // pause/cancel arriving before the engine registers its state are
            // no-ops engine-side; record the intent and re-apply after start.
            let gate = SegmentedIntentGate()
            var finished = false
            let finishLock = NSLock()
            let result: Result<(tempFileURL: URL, totalBytes: Int64), DownloadError> = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Result<(tempFileURL: URL, totalBytes: Int64), DownloadError>, Never>) in
                    handle.attachEngine(TFEngineControls(
                        pause: {
                            gate.paused = true
                            engine.pause(downloadId: downloadId)
                        },
                        resume: {
                            gate.paused = false
                            engine.resume(downloadId: downloadId)
                        },
                        cancel: {
                            gate.cancelled = true
                            engine.cancel(downloadId: downloadId)
                        }
                    ))
                    let finishOnce: @Sendable (Result<(tempFileURL: URL, totalBytes: Int64), DownloadError>) -> Void = { outcome in
                        finishLock.lock()
                        let first = !finished
                        finished = true
                        finishLock.unlock()
                        guard first else { return }
                        handle.detachEngine()
                        continuation.resume(returning: outcome)
                    }
                    Task.detached {
                        await engine.start(
                            downloadId: downloadId,
                            url: attemptURL,
                            tempFileURL: scratchURL,
                            maxConnections: maxConnections,
                            allowsSystemProxy: allowsSystemProxy,
                            onProgress: { bytes, total, connections in
                                progress(bytes, total)
                                onActiveConnections?(connections)
                            },
                            onFinish: finishOnce
                        )
                        if gate.cancelled {
                            engine.cancel(downloadId: downloadId)
                        } else if gate.paused {
                            engine.pause(downloadId: downloadId)
                        }
                    }
                }
            } onCancel: {
                gate.cancelled = true
                engine.cancel(downloadId: downloadId)
            }

            switch result {
            case .success:
                if handle.isCancelled {
                    cleanupScratch()
                    throw TFError.cancelled
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: scratchURL, to: destination)
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? -1
                    attempts.append("#\(String(attemptIndex)) ok \(String(bytes)) B (segmented)")
                    log("cdn: " + attempts.joined(separator: "; "))
                    return Outcome(bytes: bytes, attempts: attempts)
                } catch {
                    attempts.append("#\(String(attemptIndex)) failed (move \((error as NSError).code))")
                    log("cdn: " + attempts.joined(separator: "; "))
                    failureCount += 1
                }
            case .failure(let error):
                if handle.isCancelled {
                    cleanupScratch()
                    throw TFError.cancelled
                }
                failureCount += 1
                attempts.append("#\(String(failureCount)) failed (\(error.localizedDescription))")
                log("cdn: attempt \(String(failureCount)) failed (\(error.localizedDescription))")
                if failureCount < 3 {
                    // Rotate the access key before the next attempt; .segresume
                    // survives because resume validation compares host+path only.
                    do {
                        if let renewed = try await refresh(), renewed != current {
                            log("cdn: install refreshed, URL changed (accessKey rotated)")
                            current = renewed
                        }
                    } catch {
                        log("cdn: refresh failed (\(String((error as NSError).code)))")
                    }
                }
            }
        }
        throw TFError.networkLost
    }
}

final class TFTransferAttempt: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let handle: TFTransferHandle
    private let progress: @Sendable (Int64, Int64) -> Void
    private let useBackground: Bool
    private let taskID = UUID().uuidString
    private var continuation: CheckedContinuation<(URL, URLResponse?), Error>?
    private var foregroundSession: URLSession?
    private var saved: URL?
    private var response: URLResponse?
    private var failure: Error?
    private var finished = false
    private var lastEmit: CFAbsoluteTime = 0

    init(handle: TFTransferHandle, progress: @escaping @Sendable (Int64, Int64) -> Void, useBackground: Bool = false) {
        self.handle = handle
        self.progress = progress
        self.useBackground = useBackground
    }

    deinit {
        if useBackground {
            TFBackgroundSessionHub.shared.unregister(taskID: taskID)
        } else {
            foregroundSession?.invalidateAndCancel()
        }
    }

    func run(url: URL, resume: Data?) async throws -> (URL, URLResponse?) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.timeoutInterval = 300
            let session: URLSession
            if useBackground {
                session = TFBackgroundSessionHub.shared.register(taskID: taskID, attempt: self)
            } else {
                let fg = URLSession(configuration: TFNet.configuration(), delegate: self, delegateQueue: nil)
                self.foregroundSession = fg
                session = fg
            }
            let task: URLSessionDownloadTask
            if let resume, !resume.isEmpty {
                task = session.downloadTask(withResumeData: resume)
            } else {
                task = session.downloadTask(with: request)
            }
            if useBackground {
                task.taskDescription = taskID
            }
            handle.attach(task)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        handleDidWriteData(totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        handleDidFinishDownloading(downloadTask: downloadTask, location: location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        handleDidComplete(error: error)
    }

    func handleDidWriteData(totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEmit >= 0.25 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastEmit = now
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func handleDidFinishDownloading(downloadTask: URLSessionDownloadTask, location: URL) {
        response = downloadTask.response
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            saved = nil
            failure = TFError.http(status: http.statusCode,
                                   path: downloadTask.currentRequest?.url?.path ?? "/cdn",
                                   body: "")
            return
        }
        let copy = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".part")
        do {
            try? FileManager.default.removeItem(at: copy)
            do {
                try FileManager.default.moveItem(at: location, to: copy)
            } catch {
                try FileManager.default.copyItem(at: location, to: copy)
                try? FileManager.default.removeItem(at: location)
            }
            saved = copy
        } catch {
            try? FileManager.default.removeItem(at: copy)
            saved = nil
            failure = (useBackground && TFTransfer.isBackgroundFileError(error))
                ? TFBackgroundFallbackError()
                : error
        }
    }

    func handleDidComplete(error: Error?) {
        if let error {
            if let saved {
                try? FileManager.default.removeItem(at: saved)
                self.saved = nil
            }
            if handle.isPaused && !handle.isCancelled {
                let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                finish(.failure(TFTransferPausedError(resumeData: data)))
            } else if (error as NSError).code == NSURLErrorCancelled || handle.isCancelled {
                finish(.failure(TFError.cancelled))
            } else if useBackground && TFTransfer.isBackgroundFileError(error) {
                finish(.failure(TFBackgroundFallbackError()))
            } else {
                finish(.failure(error))
            }
            return
        }
        guard let saved else {
            finish(.failure(failure ?? TFError.networkLost))
            return
        }
        finish(.success((saved, response)))
    }

    private func finish(_ result: Result<(URL, URLResponse?), Error>) {
        guard !finished else { return }
        finished = true
        if useBackground {
            TFBackgroundSessionHub.shared.unregister(taskID: taskID)
        } else {
            foregroundSession?.invalidateAndCancel()
        }
        switch result {
        case let .success(value): continuation?.resume(returning: value)
        case let .failure(error): continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}
