import Foundation

final class AccountPodCache {
    static let shared = AccountPodCache()
    private var map: [String: String] = [:]
    private let lock = NSLock()
    private static let defaultsKey = "store_account_pod_cache"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            map = saved
        }
    }

    func set(dsid: String, pod: String) {
        guard !pod.isEmpty else { return }
        lock.lock(); map[dsid] = pod; lock.unlock()
        persist()
    }
    func get(dsid: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return map[dsid] ?? ""
    }
    func clear(dsid: String) {
        lock.lock(); map.removeValue(forKey: dsid); lock.unlock()
        persist()
    }
    private func persist() {
        lock.lock(); let snapshot = map; lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
