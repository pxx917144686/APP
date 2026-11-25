import Foundation

public enum TFStoreCapture {
    private static let lock = NSLock()
    private static var _amdm: String?
    private static var _storeFront: String?
    private static var _cookies: [String: String] = [:]

    public static var amdm: String? {
        get { lock.lock(); defer { lock.unlock() }; return _amdm }
        set { lock.lock(); _amdm = newValue; lock.unlock() }
    }

    public static var storeFront: String? {
        get { lock.lock(); defer { lock.unlock() }; return _storeFront }
        set { lock.lock(); _storeFront = newValue; lock.unlock() }
    }

    public static var cookies: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return _cookies }
        set { lock.lock(); _cookies = newValue; lock.unlock() }
    }

    public static let defaultStoreFront = "143441-1,29"

    public static func reset() {
        lock.lock()
        _amdm = nil
        _storeFront = nil
        _cookies = [:]
        lock.unlock()
    }
}
