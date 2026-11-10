import Foundation

final class AccountPodCache {
    static let shared = AccountPodCache()
    private var map: [String: String] = [:]
    private let lock = NSLock()
    func set(dsid: String, pod: String) {
        guard !pod.isEmpty else { return }
        lock.lock(); map[dsid] = pod; lock.unlock()
    }
    func get(dsid: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return map[dsid] ?? ""
    }
    func clear(dsid: String) {
        lock.lock(); map.removeValue(forKey: dsid); lock.unlock()
    }
}
