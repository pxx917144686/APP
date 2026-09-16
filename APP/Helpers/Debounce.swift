import Foundation
import Combine

@MainActor
final class Debounce: ObservableObject {
    private let delay: TimeInterval
    private var task: Task<Void, Never>?

    init(delay: TimeInterval = 0.1) {
        self.delay = delay
    }

    func execute(_ action: @escaping () -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func invalidate() {
        cancel()
    }
}

@MainActor
final class Throttle: ObservableObject {
    private let interval: TimeInterval
    private var lastExecution: Date = .distantPast
    private var pendingAction: (() -> Void)?
    private var isScheduled = false

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    func execute(_ action: @escaping () -> Void) {
        let now = Date()
        let timeSinceLastExecution = now.timeIntervalSince(lastExecution)

        if timeSinceLastExecution >= interval {
            lastExecution = now
            action()
        } else {
            pendingAction = action
            if !isScheduled {
                isScheduled = true
                let remaining = interval - timeSinceLastExecution
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self.lastExecution = Date()
                    self.isScheduled = false
                    self.pendingAction?()
                    self.pendingAction = nil
                }
            }
        }
    }

    func cancel() {
        pendingAction = nil
        isScheduled = false
    }

    func invalidate() {
        cancel()
    }
}
