import Foundation

enum DownloadConnectionSettings {
    static let key = "download_max_connections"
    static let minimum = 1
    static let maximum = 64
    static let fallback = 8
    static let presets = [1, 2, 4, 8, 16, 32, 64]
    static let minSegmentSize: Int64 = 2 * 1024 * 1024
    static let dynamicSplitMinimum: Int64 = 8 * 1024 * 1024

    static var defaultValue: Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored == 0 ? fallback : clamp(stored)
    }

    static func clamp(_ value: Int) -> Int {
        min(maximum, max(minimum, value))
    }

    static func effectiveLimit(_ limit: Int, totalBytes: Int64) -> Int {
        let capped = clamp(limit)
        guard totalBytes > 0 else { return capped }
        let possible = Int((totalBytes + minSegmentSize - 1) / minSegmentSize)
        return max(minimum, min(capped, possible))
    }
}

final class SegmentedIPADownloader: NSObject, @unchecked Sendable {
    static let shared = SegmentedIPADownloader()

    static let minSegmentSize: Int64 = DownloadConnectionSettings.minSegmentSize
    static let maxSegmentRetries = 2
    static var stallTimeout: TimeInterval = 45
    static private let stallCheckInterval: TimeInterval = 5

    typealias ProgressHandler = @Sendable (Int64, Int64, Int) -> Void
    typealias FinishHandler = @Sendable (Result<(tempFileURL: URL, totalBytes: Int64), DownloadError>) -> Void

    enum Outcome {
        case success(tempFileURL: URL, totalBytes: Int64)
        case failure(DownloadError)
    }

    private struct Segment {
        let index: Int
        var start: Int64
        var end: Int64
        var received: Int64 = 0
        var retries: Int = 0
        var finished: Bool = false
        var superseded: Bool = false
        var pendingFailure: Error?
        var activeTask: URLSessionDataTask?
        var fileHandle: FileHandle?
    }

    private struct ResumeSegment: Codable {
        var start: Int64
        var end: Int64
        var received: Int64
    }

    private struct ResumeState: Codable {
        var version: Int
        var url: String
        var totalSize: Int64
        var segments: [ResumeSegment]
    }

    private enum FinishCleanup {
        case keepAll
        case deleteResumeOnly
    }

    private struct State {
        var url: URL
        var tempFileURL: URL
        var totalSize: Int64
        var rangeSupported: Bool
        var allowFullResponse: Bool
        var maxConnections: Int
        var session: URLSession?
        var segments: [Segment]
        let handler: DownloadHandler
        var userCancelled = false
        var paused = false
        var finished = false
        var lastDataAt = Date()
        var lastResumeWriteAt = Date.distantPast
        var stallTimer: DispatchSourceTimer?
        var lastProgressAt: Date?
        var onProgress: ProgressHandler
        var onFinish: FinishHandler
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private var foregroundObserver: NSObjectProtocol?
    private let foregroundQueue = OperationQueue()

    override init() {
        super.init()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("UIApplicationWillEnterForegroundNotification"),
            object: nil,
            queue: foregroundQueue
        ) { [weak self] _ in
            self?.resetStallBaseline()
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    private func resetStallBaseline() {
        locked {
            for key in Array(states.keys) {
                states[key]?.lastDataAt = Date()
            }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func start(
        downloadId: String,
        url: URL,
        tempFileURL: URL,
        maxConnections: Int = DownloadConnectionSettings.defaultValue,
        allowsSystemProxy: Bool = false,
        onProgress: @escaping ProgressHandler,
        onFinish: @escaping FinishHandler
    ) async {
        if locked({
            if let existing = states[downloadId], !existing.finished {
                states[downloadId]?.onProgress = onProgress
                states[downloadId]?.onFinish = onFinish
                return true
            }
            return false
        }) {
            return
        }

        let connectionLimit = DownloadConnectionSettings.clamp(maxConnections)
        let handler = DownloadHandler(downloadId: downloadId, owner: self)
        let placeholder = State(
            url: url,
            tempFileURL: tempFileURL,
            totalSize: 0,
            rangeSupported: false,
            allowFullResponse: true,
            maxConnections: connectionLimit,
            session: nil,
            segments: [],
            handler: handler,
            onProgress: onProgress,
            onFinish: onFinish
        )
        locked { states[downloadId] = placeholder }

        let probeResponse = await HeaderProbe().probe(
            url: url,
            headers: [
                "Accept-Encoding": "identity",
                "Accept": "*/*",
                "Range": "bytes=0-0"
            ],
            allowsSystemProxy: allowsSystemProxy
        )

        var totalSize: Int64 = 0
        var rangeSupported = false
        if let http = probeResponse {
            if http.statusCode == 206, let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let parsed = Self.parseTotalSize(from: contentRange), parsed > 0 {
                rangeSupported = true
                totalSize = parsed
            } else if http.statusCode == 200, http.expectedContentLength > 0 {
                rangeSupported = false
                totalSize = Int64(http.expectedContentLength)
            }
        }

        var resumeSegments: [ResumeSegment]? = nil
        if rangeSupported {
            resumeSegments = Self.loadResumeState(tempFileURL: tempFileURL, url: url, probeTotalSize: totalSize)
        }
        let isResume = resumeSegments != nil

        var cancelledDuringProbe = false
        var setupFailed = false
        var segments: [Segment] = []

        locked {
            guard var state = states[downloadId], !state.finished else {
                cancelledDuringProbe = true
                return
            }
            if state.userCancelled {
                cancelledDuringProbe = true
                state.finished = true
                states.removeValue(forKey: downloadId)
                return
            }
            guard let prepared = Self.prepareSegments(
                tempFileURL: tempFileURL,
                totalSize: totalSize,
                rangeSupported: rangeSupported,
                resumeSegments: resumeSegments,
                maxConnections: connectionLimit
            ) else {
                setupFailed = true
                state.finished = true
                states.removeValue(forKey: downloadId)
                return
            }
            let session = URLSession(
                configuration: Self.makeSessionConfiguration(maxConnections: connectionLimit,
                                                              allowsSystemProxy: allowsSystemProxy),
                delegate: handler,
                delegateQueue: nil
            )
            segments = prepared
            state.segments = prepared
            state.session = session
            state.totalSize = totalSize
            state.rangeSupported = rangeSupported
            state.allowFullResponse = !rangeSupported
            states[downloadId] = state
        }

        if cancelledDuringProbe {
            onFinish(.failure(.unknownError("download_cancelled".localized)))
            return
        }
        if setupFailed {
            onFinish(.failure(.fileSystemError("dl_err_file_system".localized)))
            return
        }

        if segments.allSatisfy({ $0.finished }) {
            NSLog("[SegmentedDownloader] \(downloadId) resume: all segments complete, finalize directly")
            emitFinish(downloadId: downloadId, outcome: Self.finalOutcome(tempFileURL: tempFileURL, totalSize: totalSize, segments: segments), cleanup: .deleteResumeOnly)
            return
        }

        var deferredByPause = false
        locked {
            if let state = states[downloadId], !state.finished, !state.userCancelled, state.paused {
                deferredByPause = true
            }
        }
        if deferredByPause {
            NSLog("[SegmentedDownloader] \(downloadId) paused during probe, defer segment launch")
            return
        }

        for index in segments.indices where !segments[index].finished {
            launchSegment(downloadId: downloadId, index: index)
        }
        startStallWatchdog(downloadId: downloadId)
        if isResume {
            let resumedBytes = segments.reduce(0) { $0 + $1.received }
            onProgress(resumedBytes, totalSize, segments.filter { !$0.finished }.count)
        }
        NSLog("[SegmentedDownloader] \(downloadId) start, size=\(totalSize), range=\(rangeSupported), segments=\(segments.count), resume=\(isResume), resumedBytes=\(segments.reduce(0) { $0 + $1.received })")
    }

    func discard(downloadId: String) {
        let tasks: [URLSessionTask]? = locked {
            guard var state = states[downloadId] else { return nil }
            state.userCancelled = true
            state.finished = true
            state.stallTimer?.cancel()
            state.stallTimer = nil
            let tasks = state.segments.compactMap { $0.activeTask }
            for index in state.segments.indices {
                try? state.segments[index].fileHandle?.close()
                state.segments[index].fileHandle = nil
                state.segments[index].activeTask = nil
            }
            state.session?.invalidateAndCancel()
            state.session = nil
            states.removeValue(forKey: downloadId)
            return tasks
        }
        tasks?.forEach { $0.cancel() }
    }

    func pause(downloadId: String) {
        let tasks: [URLSessionTask]? = locked {
            guard var state = states[downloadId], !state.finished, !state.paused else { return nil }
            state.paused = true
            state.stallTimer?.cancel()
            state.stallTimer = nil
            let tasks = state.segments.compactMap { $0.activeTask }
            states[downloadId] = state
            return tasks
        }
        tasks?.forEach { $0.suspend() }
    }

    func isPaused(downloadId: String) -> Bool {
        locked { states[downloadId]?.paused == true }
    }

    func resume(downloadId: String) {
        var launchIndices: [Int] = []
        var resumedBytes: Int64 = 0
        var totalSize: Int64 = 0
        var onProgress: ProgressHandler?
        let tasks: [URLSessionTask]? = locked {
            guard var state = states[downloadId], !state.finished, state.paused else { return nil }
            state.paused = false
            let tasks = state.segments.compactMap { $0.activeTask }
            if tasks.isEmpty, !state.segments.isEmpty,
               state.segments.contains(where: { !$0.finished }) {
                for index in state.segments.indices where !state.segments[index].finished {
                    launchIndices.append(index)
                }
            }
            resumedBytes = state.segments.reduce(0) { $0 + $1.received }
            totalSize = state.totalSize
            onProgress = state.onProgress
            state.lastDataAt = Date()
            states[downloadId] = state
            return tasks
        }
        tasks?.forEach { $0.resume() }
        for index in launchIndices {
            launchSegment(downloadId: downloadId, index: index)
        }
        startStallWatchdog(downloadId: downloadId)
        if !launchIndices.isEmpty, let onProgress {
            onProgress(resumedBytes, totalSize, launchIndices.count)
        }
    }

    func cancel(downloadId: String) {
        var immediateFinish = false
        let tasks: [URLSessionTask]? = locked {
            guard var state = states[downloadId], !state.finished else { return nil }
            state.userCancelled = true
            let tasks = state.segments.compactMap { $0.activeTask }
            if tasks.isEmpty, !state.segments.isEmpty {
                state.finished = true
                for index in state.segments.indices {
                    try? state.segments[index].fileHandle?.close()
                    state.segments[index].fileHandle = nil
                    state.segments[index].activeTask = nil
                }
                state.session?.invalidateAndCancel()
                state.session = nil
                immediateFinish = true
            }
            states[downloadId] = state
            return tasks
        }
        tasks?.forEach { $0.cancel() }
        if immediateFinish {
            emitFinish(downloadId: downloadId, outcome: .failure(.unknownError("download_cancelled".localized)), cleanup: .keepAll)
        }
    }

    private func launchSegment(downloadId: String, index: Int) {
        let captured: (url: URL, start: Int64, end: Int64, rangeSupported: Bool, session: URLSession?)? = locked {
            guard let state = states[downloadId], !state.finished, index < state.segments.count else { return nil }
            let segment = state.segments[index]
            let resumeStart = segment.start + segment.received
            return (state.url, resumeStart, segment.end, state.rangeSupported, state.session)
        }
        guard let captured, let session = captured.session else { return }

        let request = Self.makeRequest(
            url: captured.url,
            start: captured.start,
            end: captured.end,
            rangeSupported: captured.rangeSupported
        )
        let task = session.dataTask(with: request)
        task.taskDescription = "\(downloadId)#\(index)"

        var shouldLaunch = false
        locked {
            if var state = states[downloadId], index < state.segments.count,
               !state.finished, !state.userCancelled, !state.paused {
                state.segments[index].activeTask = task
                states[downloadId] = state
                shouldLaunch = true
            }
        }
        if shouldLaunch {
            task.resume()
        } else {
            task.cancel()
        }
    }

    fileprivate func handleSegmentResponse(
        downloadId: String,
        index: Int,
        response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }

        var disposition: URLSession.ResponseDisposition = .cancel
        var failure: Error?
        var expectedStart: Int64 = 0
        let hasState: Bool = locked {
            guard var state = states[downloadId], !state.finished, index < state.segments.count else { return false }
            let okStatus = (200...299).contains(http.statusCode)
            let acceptable = okStatus && (state.allowFullResponse || http.statusCode == 206)
            if acceptable {
                disposition = .allow
                expectedStart = state.segments[index].start + state.segments[index].received
                if !state.allowFullResponse, let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                   let actualStart = Self.parseRangeStart(from: contentRange), actualStart != expectedStart {
                    disposition = .cancel
                    failure = NSError(
                        domain: "DownloadManager",
                        code: -6,
                        userInfo: [NSLocalizedDescriptionKey: "dl_err_failed_retry".localized + " (Content-Range \(actualStart) != \(expectedStart))"]
                    )
                }
            } else {
                failure = NSError(
                    domain: "DownloadManager",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "dl_err_failed_retry".localized + " (HTTP \(http.statusCode))"]
                )
            }
            if let failure {
                state.segments[index].pendingFailure = failure
                states[downloadId] = state
            }
            return true
        }

        completionHandler(disposition)
        if hasState, let failure {
            processSegmentFailure(downloadId: downloadId, index: index, error: failure)
        }
    }

    fileprivate func handleSegmentData(downloadId: String, index: Int, data: Data) {
        var shouldReport = false
        var totalReceived: Int64 = 0
        var totalSize: Int64 = 0
        var activeConnections = 0
        var onProgress: ProgressHandler?

        locked {
            guard var state = states[downloadId], !state.finished, index < state.segments.count else { return }
            if let fileHandle = state.segments[index].fileHandle {
                do {
                    try fileHandle.write(contentsOf: data)
                    state.segments[index].received += Int64(data.count)
                } catch {
                    state.segments[index].pendingFailure = NSError(
                        domain: "DownloadManager",
                        code: -7,
                        userInfo: [NSLocalizedDescriptionKey: "dl_err_file_system".localized]
                    )
                    states[downloadId] = state
                    state.segments[index].activeTask?.cancel()
                    return
                }
            }
            totalReceived = state.segments.reduce(0) { $0 + $1.received }
            totalSize = state.totalSize

            let now = Date()
            state.lastDataAt = now
            let last = state.lastProgressAt ?? .distantPast
            let done = totalSize > 0 && totalReceived >= totalSize
            if now.timeIntervalSince(last) >= 0.1 || done {
                state.lastProgressAt = now
                shouldReport = true
                activeConnections = state.segments.filter { !$0.finished && $0.activeTask != nil }.count
                if state.rangeSupported, now.timeIntervalSince(state.lastResumeWriteAt) >= 1.0 {
                    state.lastResumeWriteAt = now
                    Self.writeResumeState(tempFileURL: state.tempFileURL, url: state.url, totalSize: state.totalSize, segments: state.segments)
                }
            }
            onProgress = state.onProgress
            states[downloadId] = state
        }

        if shouldReport, let onProgress {
            onProgress(totalReceived, totalSize, activeConnections)
        }
    }

    fileprivate func handleSegmentCompletion(downloadId: String, index: Int, error: Error?) {
        var action: SegmentAction = .none
        var needsSplit = false
        var relaunchAfterSupersede = false

        locked {
            guard var state = states[downloadId], !state.finished, index < state.segments.count else { return }

            if state.userCancelled {
                action = .finish(.failure(.unknownError("download_cancelled".localized)), cleanup: .keepAll)
                cleanupState(&state, cancelledRemainder: true)
                states[downloadId] = state
                return
            }

            if state.segments[index].superseded {
                state.segments[index].superseded = false
                state.segments[index].activeTask = nil
                states[downloadId] = state
                relaunchAfterSupersede = true
                return
            }

            let nsError = error as NSError?
            if error != nil, nsError?.code == NSURLErrorCancelled {
                state.segments[index].activeTask = nil
                if let pending = state.segments[index].pendingFailure {
                    state.segments[index].pendingFailure = nil
                    states[downloadId] = state
                    action = .retry(index: index, error: pending)
                } else {
                    states[downloadId] = state
                    action = .retry(index: index, error: error!)
                }
                return
            }

            if let error {
                state.segments[index].activeTask = nil
                states[downloadId] = state
                action = .retry(index: index, error: error)
                return
            }

            let segment = state.segments[index]
            let segmentLength = segment.end < 0 ? segment.received : segment.end - segment.start + 1
            if segment.received == segmentLength {
                state.segments[index].finished = true
                state.segments[index].activeTask = nil
                try? state.segments[index].fileHandle?.close()
                state.segments[index].fileHandle = nil

                if state.segments.allSatisfy({ $0.finished }) {
                    action = .finish(
                        Self.finalOutcome(tempFileURL: state.tempFileURL, totalSize: state.totalSize, segments: state.segments),
                        cleanup: .deleteResumeOnly
                    )
                    cleanupState(&state, cancelledRemainder: false)
                    states[downloadId] = state
                } else {
                    states[downloadId] = state
                    needsSplit = true
                }
            } else {
                states[downloadId] = state
                action = .retry(
                    index: index,
                    error: NSError(
                        domain: "DownloadManager",
                        code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "dl_err_failed_retry".localized + " (short read \(segment.received)/\(segmentLength))"]
                    )
                )
            }
        }

        switch action {
        case .none:
            if relaunchAfterSupersede {
                launchSegment(downloadId: downloadId, index: index)
            }
            if needsSplit {
                for splitIndex in splitLargestSegment(downloadId: downloadId) {
                    launchSegment(downloadId: downloadId, index: splitIndex)
                }
            }
        case .retry(let index, let error):
            processSegmentFailure(downloadId: downloadId, index: index, error: error)
        case .finish(let outcome, let cleanup):
            emitFinish(downloadId: downloadId, outcome: outcome, cleanup: cleanup)
        }
    }

    private func splitLargestSegment(downloadId: String) -> [Int] {
        var launchIndices: [Int] = []
        locked {
            guard var state = states[downloadId], !state.finished,
                  !state.userCancelled, !state.paused, state.rangeSupported else { return }
            let unfinishedCount = state.segments.filter { !$0.finished }.count
            guard unfinishedCount > 0, unfinishedCount < state.maxConnections else { return }

            var targetIndex: Int?
            var largestRemaining: Int64 = 0
            for index in state.segments.indices where !state.segments[index].finished {
                let segment = state.segments[index]
                let remaining = segment.end - (segment.start + segment.received) + 1
                if remaining > largestRemaining {
                    largestRemaining = remaining
                    targetIndex = index
                }
            }
            guard let target = targetIndex, largestRemaining >= DownloadConnectionSettings.dynamicSplitMinimum,
                  largestRemaining >= 2 else { return }

            let segment = state.segments[target]
            let cursor = segment.start + segment.received
            let splitPoint = cursor + largestRemaining / 2
            guard splitPoint > cursor, splitPoint <= segment.end else { return }

            guard let handle = try? FileHandle(forWritingTo: state.tempFileURL) else { return }
            handle.seek(toFileOffset: UInt64(splitPoint))

            var newSegment = Segment(index: state.segments.count, start: splitPoint, end: segment.end)
            newSegment.fileHandle = handle
            state.segments[target].end = splitPoint - 1
            state.segments[target].superseded = true
            let activeTask = state.segments[target].activeTask
            state.segments[target].activeTask = nil
            state.segments.append(newSegment)
            states[downloadId] = state

            let hadActiveTask = activeTask != nil
            activeTask?.cancel()
            launchIndices = [newSegment.index]
            if !hadActiveTask {
                launchIndices.append(target)
            }
            NSLog("[SegmentedDownloader] \(downloadId) dynamic split segment \(target) at \(splitPoint), now \(state.segments.count) segments")
        }
        return launchIndices
    }

    private enum SegmentAction {
        case none
        case retry(index: Int, error: Error)
        case finish(Outcome, cleanup: FinishCleanup)
    }

    private func processSegmentFailure(downloadId: String, index: Int, error: Error) {
        var action: SegmentAction = .none

        locked {
            guard var state = states[downloadId], !state.finished, index < state.segments.count else { return }
            state.segments[index].retries += 1
            NSLog("[SegmentedDownloader] \(downloadId) segment \(index) failed (\(error.localizedDescription)), retry \(state.segments[index].retries)/\(Self.maxSegmentRetries)")

            if state.segments[index].retries > Self.maxSegmentRetries {
                action = .finish(.failure(Self.mapNetworkError(error)), cleanup: .keepAll)
                cleanupState(&state, cancelledRemainder: true)
                states[downloadId] = state
            } else {
                states[downloadId] = state
                action = .retry(index: index, error: error)
            }
        }

        switch action {
        case .none:
            break
        case .retry:
            launchSegment(downloadId: downloadId, index: index)
        case .finish(let outcome, let cleanup):
            emitFinish(downloadId: downloadId, outcome: outcome, cleanup: cleanup)
        }
    }

    private func emitFinish(downloadId: String, outcome: Outcome, cleanup: FinishCleanup) {
        let captured: (onProgress: ProgressHandler, onFinish: FinishHandler, received: Int64, total: Int64, tempFileURL: URL)? = locked {
            guard let state = states[downloadId] else { return nil }
            states.removeValue(forKey: downloadId)
            let received = state.segments.reduce(0) { $0 + $1.received }
            return (state.onProgress, state.onFinish, received, state.totalSize, state.tempFileURL)
        }
        guard let captured else { return }

        let ownsFiles = locked { states[downloadId] == nil }
        if ownsFiles {
            switch cleanup {
            case .keepAll:
                break
            case .deleteResumeOnly:
                try? FileManager.default.removeItem(at: Self.resumeFilePath(for: captured.tempFileURL))
            }
        }

        let result: Result<(tempFileURL: URL, totalBytes: Int64), DownloadError>
        switch outcome {
        case .success(let tempFileURL, let totalBytes):
            result = .success((tempFileURL, totalBytes))
        case .failure(let error):
            result = .failure(error)
        }

        let progress = captured.onProgress
        let finish = captured.onFinish
        DispatchQueue.global(qos: .userInitiated).async {
            progress(captured.received, captured.total, 0)
            finish(result)
        }
    }

    private func startStallWatchdog(downloadId: String) {
        locked {
            guard var state = states[downloadId], !state.finished else { return }
            state.lastDataAt = Date()
            if state.stallTimer != nil {
                states[downloadId] = state
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + Self.stallCheckInterval,
                           repeating: Self.stallCheckInterval)
            timer.setEventHandler { [weak self] in
                self?.checkStall(downloadId: downloadId)
            }
            state.stallTimer = timer
            states[downloadId] = state
            timer.resume()
        }
    }

    private func checkStall(downloadId: String) {
        var outcome: Outcome?
        locked {
            guard var state = states[downloadId], !state.finished, !state.userCancelled, !state.paused else { return }
            guard Date().timeIntervalSince(state.lastDataAt) > Self.stallTimeout else { return }
            NSLog("[SegmentedDownloader] \(downloadId) stall detected (> \(Self.stallTimeout)s without data), failing with resume points kept")
            outcome = .failure(Self.mapNetworkError(NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "dl_err_timeout".localized]
            )))
            cleanupState(&state, cancelledRemainder: true)
            states[downloadId] = state
        }
        if let outcome {
            emitFinish(downloadId: downloadId, outcome: outcome, cleanup: .keepAll)
        }
    }

    private func cleanupState(_ state: inout State, cancelledRemainder: Bool) {
        state.finished = true
        state.stallTimer?.cancel()
        state.stallTimer = nil
        for index in state.segments.indices {
            if cancelledRemainder, !state.segments[index].finished {
                state.segments[index].activeTask?.cancel()
            }
            try? state.segments[index].fileHandle?.close()
            state.segments[index].fileHandle = nil
            state.segments[index].activeTask = nil
        }
        if cancelledRemainder {
            state.session?.invalidateAndCancel()
        } else {
            state.session?.finishTasksAndInvalidate()
        }
        state.session = nil
    }

    private static func makeSessionConfiguration(maxConnections: Int, allowsSystemProxy: Bool) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        if !allowsSystemProxy {
            config.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0,
                "SOCKSEnable": 0,
                "HTTPProxy": "",
                "HTTPSProxy": "",
                "SOCKSProxy": ""
            ]
        }
        config.httpMaximumConnectionsPerHost = max(1, maxConnections)
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        config.networkServiceType = .default
        config.httpCookieStorage = HTTPCookieStorage.shared
        return config
    }

    private static func makeRequest(url: URL, start: Int64, end: Int64, rangeSupported: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if rangeSupported {
            let endValue = end < 0 ? "" : String(end)
            request.setValue("bytes=\(start)-\(endValue)", forHTTPHeaderField: "Range")
        }
        return request
    }

    private static func prepareSegments(tempFileURL: URL, totalSize: Int64, rangeSupported: Bool,
                                        resumeSegments: [ResumeSegment]?, maxConnections: Int) -> [Segment]? {
        let fileManager = FileManager.default
        let isResume = rangeSupported && totalSize > 0 && resumeSegments != nil
        if !isResume {
            try? fileManager.removeItem(at: tempFileURL)
            try? fileManager.removeItem(at: resumeFilePath(for: tempFileURL))
            guard fileManager.createFile(atPath: tempFileURL.path, contents: nil, attributes: nil),
                  let root = try? FileHandle(forWritingTo: tempFileURL) else {
                return nil
            }
            if totalSize > 0 {
                try? root.truncate(atOffset: UInt64(totalSize))
            }
            try? root.close()
        }

        var segments: [Segment] = []
        if rangeSupported, totalSize > 0, let resumeSegments {
            for (index, resume) in resumeSegments.enumerated() {
                var segment = Segment(index: index, start: resume.start, end: resume.end)
                segment.received = resume.received
                let length = resume.end - resume.start + 1
                if segment.received == length {
                    segment.finished = true
                }
                guard let handle = try? FileHandle(forWritingTo: tempFileURL) else { return nil }
                if segment.finished {
                    try? handle.close()
                } else {
                    handle.seek(toFileOffset: UInt64(segment.start + segment.received))
                    segment.fileHandle = handle
                }
                segments.append(segment)
            }
        } else if rangeSupported, totalSize > 0 {
            let connectionCount = max(1, min(maxConnections, Int((totalSize + minSegmentSize - 1) / minSegmentSize)))
            let base = totalSize / Int64(connectionCount)
            let remainder = totalSize % Int64(connectionCount)
            var offset: Int64 = 0
            for index in 0..<connectionCount {
                let length = base + (Int64(index) < remainder ? 1 : 0)
                let start = offset
                let end = offset + length - 1
                offset = end + 1
                var segment = Segment(index: index, start: start, end: end)
                guard let handle = try? FileHandle(forWritingTo: tempFileURL) else { return nil }
                handle.seek(toFileOffset: UInt64(start))
                segment.fileHandle = handle
                segments.append(segment)
            }
        } else {
            var segment = Segment(index: 0, start: 0, end: totalSize > 0 ? totalSize - 1 : -1)
            guard let handle = try? FileHandle(forWritingTo: tempFileURL) else { return nil }
            if totalSize > 0 {
                handle.seek(toFileOffset: 0)
            } else {
                handle.seekToEndOfFile()
            }
            segment.fileHandle = handle
            segments.append(segment)
        }
        return segments
    }

    private static func finalOutcome(tempFileURL: URL, totalSize: Int64, segments: [Segment]) -> Outcome {
        if totalSize > 0 {
            let attributes = try? FileManager.default.attributesOfItem(atPath: tempFileURL.path)
            let actual = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            if actual != totalSize {
                return .failure(.networkError(NSError(
                    domain: "DownloadManager",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "dl_err_size_mismatch".localized(actual, totalSize)]
                )))
            }
            return .success(tempFileURL: tempFileURL, totalBytes: totalSize)
        }
        let received = segments.reduce(0) { $0 + $1.received }
        guard received > 0 else {
            return .failure(.fileSystemError("dl_err_empty_data".localized))
        }
        return .success(tempFileURL: tempFileURL, totalBytes: received)
    }

    private static func resumeFilePath(for tempFileURL: URL) -> URL {
        URL(fileURLWithPath: tempFileURL.path + ".segresume")
    }

    private static func loadResumeState(tempFileURL: URL, url: URL, probeTotalSize: Int64) -> [ResumeSegment]? {
        guard probeTotalSize > 0 else { return nil }
        guard let data = try? Data(contentsOf: resumeFilePath(for: tempFileURL)),
              let state = try? JSONDecoder().decode(ResumeState.self, from: data) else {
            return nil
        }
        // Compare host+path only: CDNs rotate access tokens in the query string
        // (e.g. TestFlight accessKey), which must not invalidate resume points.
        guard state.version == 1,
              let savedURL = URL(string: state.url),
              savedURL.host == url.host, savedURL.path == url.path,
              state.totalSize == probeTotalSize,
              !state.segments.isEmpty else {
            return nil
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: tempFileURL.path),
              (attributes[.size] as? NSNumber)?.int64Value == state.totalSize else {
            return nil
        }
        for segment in state.segments {
            let length = segment.end - segment.start + 1
            guard segment.start >= 0, segment.end >= segment.start,
                  segment.received >= 0, segment.received <= length else {
                return nil
            }
        }
        let totalReceived = state.segments.reduce(0) { $0 + $1.received }
        guard totalReceived <= state.totalSize else { return nil }
        return state.segments
    }

    private static func writeResumeState(tempFileURL: URL, url: URL, totalSize: Int64, segments: [Segment]) {
        guard totalSize > 0 else { return }
        let state = ResumeState(
            version: 1,
            url: url.absoluteString,
            totalSize: totalSize,
            segments: segments.map { ResumeSegment(start: $0.start, end: $0.end, received: $0.received) }
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: resumeFilePath(for: tempFileURL), options: .atomic)
    }

    private static func mapNetworkError(_ error: Error) -> DownloadError {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return .networkError(error)
        }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet:
            return .networkError(NSError(domain: "DownloadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "dl_err_offline".localized]))
        case NSURLErrorTimedOut:
            return .networkError(NSError(domain: "DownloadManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "dl_err_timeout".localized]))
        case NSURLErrorCancelled:
            return .unknownError("download_cancelled".localized)
        default:
            return .networkError(NSError(domain: "DownloadManager", code: nsError.code, userInfo: [NSLocalizedDescriptionKey: "dl_err_failed_retry".localized + " (NSURLError \(nsError.code))"]))
        }
    }

    private static func parseTotalSize(from contentRange: String) -> Int64? {
        guard let slashIndex = contentRange.lastIndex(of: "/") else { return nil }
        let totalPart = contentRange[contentRange.index(after: slashIndex)...].trimmingCharacters(in: .whitespaces)
        guard totalPart != "*" else { return nil }
        return Int64(totalPart)
    }

    private static func parseRangeStart(from contentRange: String) -> Int64? {
        guard let dashIndex = contentRange.firstIndex(of: "-") else { return nil }
        let prefix = contentRange[contentRange.startIndex..<dashIndex]
        guard let spaceIndex = prefix.lastIndex(of: " ") else { return nil }
        return Int64(prefix[prefix.index(after: spaceIndex)...].trimmingCharacters(in: .whitespaces))
    }
}

private final class DownloadHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let downloadId: String
    private weak var owner: SegmentedIPADownloader?

    init(downloadId: String, owner: SegmentedIPADownloader) {
        self.downloadId = downloadId
        self.owner = owner
        super.init()
    }

    private func segmentIndex(for task: URLSessionTask) -> Int? {
        guard let description = task.taskDescription else { return nil }
        guard let hashIndex = description.lastIndex(of: "#") else { return nil }
        return Int(description[description.index(after: hashIndex)...])
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let owner, let index = segmentIndex(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        owner.handleSegmentResponse(downloadId: downloadId, index: index, response: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let owner, let index = segmentIndex(for: dataTask) else { return }
        owner.handleSegmentData(downloadId: downloadId, index: index, data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let owner, let index = segmentIndex(for: task) else { return }
        owner.handleSegmentCompletion(downloadId: downloadId, index: index, error: error)
    }
}

private final class HeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse?, Never>?

    func probe(url: URL, headers: [String: String], allowsSystemProxy: Bool = false) async -> HTTPURLResponse? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        if !allowsSystemProxy {
            config.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0,
                "SOCKSEnable": 0
            ]
        }
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        return await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        NSLog("[SegmentedDownloader] probe response status=\((response as? HTTPURLResponse)?.statusCode ?? -1) cl=\(response.expectedContentLength)")
        continuation?.resume(returning: response as? HTTPURLResponse)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        NSLog("[SegmentedDownloader] probe completed with error=\(String(describing: error))")
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: nil)
    }
}
