import Foundation

public enum TFInvariants {

    public static let expectedUserAgent =
        "MacAppStore/3.0 TestFlight/4.4.0 (Macintosh; OS X 15.6; 24G84) AppleWebKit/8614.3.7.1.5 AMS/1 (dt:1)"
    public static let expectedClientInfo =
        "<MacBookPro18,3> <macOS;15.6;24G84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    public static let expectedPlatform = "iphone"
    public static let expectedAppName = "akd"

    public static func check(userAgent: String = TFConstants.effectiveUserAgent,
                             clientInfo: String = TFConstants.authClientInfo,
                             platform: String = TFConstants.storePlatform,
                             appName: String = TFConstants.clientAppName,
                             log: (@Sendable (String) -> Void)? = nil) throws {
        let pairs: [(String, String, String)] = [
            ("User-Agent", expectedUserAgent, userAgent),
            ("X-MMe-Client-Info", expectedClientInfo, clientInfo),
            ("平台", expectedPlatform, platform),
            ("X-Apple-Client-App-Name", expectedAppName, appName),
        ]
        for (name, expected, actual) in pairs where expected != actual {
            throw TFError.invariant(name, expected: expected, actual: actual)
        }
        log?("invariants: 4 项通过（UA / Client-Info / 平台 iphone / akd）")
    }
}
