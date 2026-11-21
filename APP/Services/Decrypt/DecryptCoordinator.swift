import Foundation

final class DecryptCancelToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

@MainActor
final class DecryptCoordinator: ObservableObject {
    static let shared = DecryptCoordinator()

    @Published private(set) var activeRequestID: UUID?
    private(set) var cancelToken = DecryptCancelToken()

    var isBusy: Bool { activeRequestID != nil }

    func begin(requestID: UUID) -> DecryptCancelToken {
        if activeRequestID == requestID { return cancelToken }
        cancelToken = DecryptCancelToken()
        activeRequestID = requestID
        return cancelToken
    }

    func finish(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
    }

    func cancel() {
        cancelToken.cancel()
    }
}
