import Foundation

@MainActor
final class TaskBag {
    private struct Entry {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var entries: [String: Entry] = [:]

    @discardableResult
    func replace(key: String, operation: @escaping @MainActor (UUID) async -> Void) -> UUID {
        cancel(key: key)
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await operation(token)
            self?.complete(key: key, token: token)
        }
        entries[key] = Entry(token: token, task: task)
        return token
    }

    func token(for key: String) -> UUID? {
        entries[key]?.token
    }

    func isCurrent(_ token: UUID, for key: String) -> Bool {
        entries[key]?.token == token
    }

    func cancel(key: String) {
        entries[key]?.task.cancel()
    }

    func cancelAll() {
        for entry in entries.values {
            entry.task.cancel()
        }
    }

    private func complete(key: String, token: UUID) {
        guard entries[key]?.token == token else { return }
        entries.removeValue(forKey: key)
    }

    deinit {
        for entry in entries.values {
            entry.task.cancel()
        }
    }
}
