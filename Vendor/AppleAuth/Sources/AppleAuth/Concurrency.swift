import Foundation

internal enum NativeCallbackContext {
    @TaskLocal static var deviceID: UUID?
}

internal final class ResultCell<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func finish(_ value: Result<Value, Error>) {
        lock.lock()
        let first = result == nil
        if first { result = value }
        lock.unlock()
        if first { ready.signal() }
    }

    func wait() throws -> Value {
        ready.wait()
        lock.lock()
        let value = result!
        lock.unlock()
        return try value.get()
    }
}

internal final class NativeOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    private var task: Task<Void, Never>?
    private var cancelWait: (@Sendable () -> Void)?

    func checkCancellation() throws {
        lock.lock()
        let value = canceled
        lock.unlock()
        if value { throw CancellationError() }
    }

    func install(_ task: Task<Void, Never>, cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        self.task = task
        cancelWait = cancel
        let value = canceled
        lock.unlock()
        if value { task.cancel(); cancel() }
    }

    func clear() {
        lock.lock(); task = nil; cancelWait = nil; lock.unlock()
    }

    func cancel() {
        lock.lock()
        canceled = true
        let task = task
        let notify = cancelWait
        lock.unlock()
        notify?()
        task?.cancel()
    }

    func blocking<Value: Sendable>(_ body: @escaping @Sendable () async throws -> Value) throws -> Value {
        try checkCancellation()
        let cell = ResultCell<Value>()
        let task = Task.detached {
            do { cell.finish(.success(try await body())) }
            catch { cell.finish(.failure(error)) }
        }
        install(task, cancel: { cell.finish(.failure(CancellationError())) })
        defer { clear() }
        return try cell.wait()
    }
}
