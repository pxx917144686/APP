import Foundation

/// Values that only exist on the wire, captured while AppleAuth is running.
///
/// `X-Apple-AMD-M` is a *request* header the store login sends, and
/// `x-set-apple-store-front` is a *response* header; neither survives into the store
/// session object, so the TestFlight context has to be assembled from what we saw.
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

    /// Raw `Set-Cookie` pairs seen on the store auth response.
    ///
    /// `HTTPCookieStorage` drops some of them (TrPod / X-Token / isPpuOptOut never show
    /// up in the shared jar), and the service validates the whole set, so the wire bytes
    /// are kept verbatim instead.
    public static var cookies: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return _cookies }
        set { lock.lock(); _cookies = newValue; lock.unlock() }
    }

    /// Used when the response header never arrived; the value a JP account sees.
    public static let defaultStoreFront = "143441-1,29"

    public static func reset() {
        lock.lock()
        _amdm = nil
        _storeFront = nil
        _cookies = [:]
        lock.unlock()
    }
}
