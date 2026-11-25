import Foundation
import CryptoKit

struct SwiftTestFlightSession: Sendable {
    let accountID: String
    let sessionID: String
    let dsid: String
    let udid: String
    let deviceModel: String
    let storeFront: String
    let amdM: String
    let amd: String
    let userAgent: String

    static let digestSalt = "LWzxL71nAUJTbK9X54DDQU5KC6oTcBFuibEJXIZglPRkhCSmh68PREebiNDZXctOKXpIcOfbnndI2FjMveKfRYOLPfYFRTgua1vg"

    static func create(context: Data, transport: TestFlightHTTPTransport) async throws -> SwiftTestFlightSession {
        guard let object = try JSONSerialization.jsonObject(with: context) as? [String: Any],
              let dsid = object["dsid"] as? String,
              let udid = object["udid"] as? String,
              let cookies = object["storeCookies"] as? [String: String],
              let headers = object["headers"] as? [String: String],
              !dsid.isEmpty, !udid.isEmpty, !cookies.isEmpty else {
            throw TestFlightHTTPError.invalidAccount
        }
        let deviceModel = headers["X-Apple-Device-Model"] ?? "iPhone12,1"
        let storeFront = headers["X-Apple-Store-Front"] ?? "143441-1,29"
        let amdM = headers["X-Apple-AMD-M"] ?? ""
        let userAgent = headers["User-Agent"] ?? "TestFlight/4.4.0 (Macintosh; macOS 27.2)"
        let amd = headers["X-Apple-AMD"] ?? ""
        guard !amdM.isEmpty else { throw TestFlightHTTPError.missingProof }

        var requestHeaders = headers
        requestHeaders["Accept"] = "application/json"
        requestHeaders["Content-Type"] = "application/json"
        requestHeaders["Accept-Language"] = "en-US"

        let body: [String: Any] = [
            "deviceModel": deviceModel,
            "deviceName": "TestFlight",
            "dsId": Int64(dsid) ?? 0,
            "deviceVendorId": UUID().uuidString,
            "storeFrontIdentifier": storeFront.components(separatedBy: ",").first ?? storeFront,
            "storeCookies": cookies
        ]
        var request = URLRequest(url: URL(string: "https://testflight.apple.com/v1/session/authenticate")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (key, value) in requestHeaders { request.setValue(value, forHTTPHeaderField: key) }

        let response = try await transport.execute(request)
        guard (200..<300).contains(response.status) else {
            throw TestFlightSessionError.http(response.status)
        }
        var payload = try JSONSerialization.jsonObject(with: response.body)
        if let dict = payload as? [String: Any], let data = dict["data"] { payload = data }
        guard let dict = payload as? [String: Any],
              let accountID = dict["accountId"] as? String, !accountID.isEmpty,
              let sessionID = dict["sessionId"] as? String, !sessionID.isEmpty else {
            throw TestFlightSessionError.invalidSession
        }
        return SwiftTestFlightSession(
            accountID: accountID,
            sessionID: sessionID,
            dsid: dsid,
            udid: udid,
            deviceModel: deviceModel,
            storeFront: storeFront,
            amdM: amdM,
            amd: amd,
            userAgent: userAgent
        )
    }

    func catalog(transport: TestFlightHTTPTransport) async throws -> Data {
        let requestID = UUID().uuidString
        let digest = Insecure.SHA1.hash(data: Data((sessionID + requestID + dsid + Self.digestSalt).utf8))
            .map { String(format: "%02x", $0) }.joined()
        var headers: [String: String] = [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Accept-Language": "en-US",
            "X-Apple-AMD": amd,
            "X-Apple-AMD-M": amdM,
            "X-Apple-Store-Front": storeFront,
            "X-Apple-Device-Model": deviceModel,
            "X-Apple-TA-Device": deviceModel,
            "User-Agent": userAgent,
            "X-Session-Id": sessionID,
            "X-Request-Id": requestID,
            "X-Session-Digest": digest
        ]
        headers["X-Session-Id"] = sessionID
        let escaped = accountID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? accountID
        let url = URL(string: "https://testflight.apple.com/v4/accounts/\(escaped)/apps?allDetailsCount=10000")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let response = try await transport.execute(request)
        guard (200..<300).contains(response.status) else {
            throw TestFlightSessionError.http(response.status)
        }
        return response.body
    }
}

enum TestFlightSessionError: LocalizedError {
    case http(Int)
    case invalidSession

    var errorDescription: String? {
        switch self {
        case .http(let status): return "TestFlight HTTP \(status)"
        case .invalidSession: return "TestFlight returned no session"
        }
    }
}
