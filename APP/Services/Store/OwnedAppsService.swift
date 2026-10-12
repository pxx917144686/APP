import Foundation

struct OwnedAppInfo {
    let id: Int64
    let bundleId: String
    let name: String
    let version: String
    let purchaseDate: Date?
    let mediaKind: UInt64
    let supportedProducts: UInt64
}

final class OwnedAppsService {
    static let shared = OwnedAppsService()

    private let baseURL = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"
    private let mediaKindIOS: UInt64 = 131072
    private let mediaKindArcade: UInt64 = 262144
    private let mediaKindMac: UInt64 = 67108864

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func fetchOwnedApps(account: Account) async throws -> [OwnedAppInfo] {
        let storefront = account.storeResponse.storeFront.isEmpty ? "143441-1,29" : account.storeResponse.storeFront
        return try await fetchOwnedAppsForStorefront(account: account, storefront: storefront)
    }

    private func fetchOwnedAppsForStorefront(account: Account, storefront: String) async throws -> [OwnedAppInfo] {
        let guid = GUIDCache.shared.get(for: account)
        let query = "('com.apple.itunes.extended\\-media\\-kind:\(mediaKindIOS)')"

        let loginData = try await postRaw(path: "/login", storefront: storefront, account: account, guid: guid, body: Data(), contentType: nil, signature: nil)
        try checkDAAPStatus(loginData, label: "login")
        guard let sessionId = try dmapFirstUint(loginData, "mlid"), sessionId <= UInt64(UInt32.max) else {
            throw StoreError.authenticationFailedWithDetails("已购接口 login 未返回有效会话 ID")
        }

        let signer = try await WasmSAPSigner.openSession(guid: guid)
        defer { Task { await signer.close() } }

        let updateBody = Data("session-id=\(sessionId)&revision-number=(null)&query=\(query)".utf8)
        let updateSignature = try await signer.sign(updateBody)
        let updateData = try await postRaw(path: "/update", storefront: storefront, account: account, guid: guid, body: updateBody, contentType: "application/x-www-form-urlencoded", signature: updateSignature)
        try checkDAAPStatus(updateData, label: "update")
        guard let revision = try dmapFirstUint(updateData, "musr"), revision <= UInt64(UInt32.max) else {
            throw StoreError.authenticationFailedWithDetails("已购接口 update 未返回有效版本号")
        }

        let itemsBody = Self.itemsBody(sessionId: sessionId, revision: revision, query: query)
        let itemsSignature = try await signer.sign(itemsBody)
        let itemsData = try await postRaw(
            path: "/databases/\(revision)/items",
            storefront: storefront,
            account: account,
            guid: guid,
            body: itemsBody,
            contentType: "application/x-dmap-tagged",
            signature: itemsSignature
        )
        try checkDAAPStatus(itemsData, label: "items")
        return try parseOwnedApps(itemsData)
    }

    private func postRaw(path: String, storefront: String, account: Account, guid: String, body: Data, contentType: String?, signature: Data?) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw StoreError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let now = Date()
        let utc = now.utcRFC1123()
        let offsetSeconds = TimeZone.current.secondsFromGMT(for: now)

        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        request.setValue("5", forHTTPHeaderField: "Client-Cloud-DAAP-Request-Reason")
        request.setValue("1.1/Configurator-2.0", forHTTPHeaderField: "Client-Cloud-Purchase-Daap-Version")
        request.setValue("3.12", forHTTPHeaderField: "Client-DAAP-Version")
        request.setValue(utc, forHTTPHeaderField: "Date")
        request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(now.iso8601UTC(), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue("en_US", forHTTPHeaderField: "X-Apple-I-Locale")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Apple-I-TimeZone")
        request.setValue(storefront, forHTTPHeaderField: "X-Apple-Store-Front")
        request.setValue(String(offsetSeconds / 60), forHTTPHeaderField: "X-Apple-TZ")
        request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "X-Dsid")
        request.setValue(guid, forHTTPHeaderField: "X-Guid")
        request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let signature {
            request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "x-apple-actionsignature")
        }
        let cookieLines = UserDefaults.standard.stringArray(forKey: "sap_real_cookies_v1_\(account.directoryServicesIdentifier)")
            ?? AuthCookieCache.shared.get(dsid: account.directoryServicesIdentifier)
        let cookieHeader = cookieLines
            .compactMap { $0.components(separatedBy: ";").first }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.httpShouldHandleCookies = false
        } else {
            request.httpShouldHandleCookies = true
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StoreError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let hex = data.prefix(80).map { String(format: "%02x", $0) }.joined()
            downloadDebugLog("ownedApps \(path) HTTP \(http.statusCode) hex=\(hex)")
            throw StoreError.authenticationFailedWithDetails("已购接口 HTTP \(http.statusCode)（\(path)）")
        }
        return data
    }

    private func checkDAAPStatus(_ data: Data, label: String) throws {
        let status = try? dmapFirstUint(data, "mstt")
        if let status, status == 401 || status == 403 {
            throw StoreError.authenticationFailedWithDetails("已购接口会话失效（\(label) DAAP status \(status)）")
        }
    }

    private func parseOwnedApps(_ data: Data) throws -> [OwnedAppInfo] {
        var apps: [OwnedAppInfo] = []
        try walkDMAP(data, depth: 0) { tag, payload in
            guard tag == "mlit" else { return }
            var id: Int64 = 0
            var bundleId = ""
            var name = ""
            var version = ""
            var purchaseDate: Date?
            var mediaKind: UInt64 = 0
            var supportedProducts: UInt64 = 0
            try walkDMAP(payload, depth: 0) { itemTag, itemPayload in
                switch itemTag {
                case "aeSI":
                    id = Self.dmapInt64(itemPayload)
                case "aeBI":
                    bundleId = String(decoding: itemPayload, as: UTF8.self)
                case "aeLN", "minm":
                    if name.isEmpty {
                        name = String(decoding: itemPayload, as: UTF8.self)
                    }
                case "aePd":
                    version = String(decoding: itemPayload, as: UTF8.self)
                case "asdp":
                    if itemPayload.count == 4 {
                        purchaseDate = Date(timeIntervalSince1970: Double(Self.beUint32(itemPayload, 0)))
                    }
                case "aeMk", "aeSS":
                    let value = Self.dmapUint(itemPayload)
                    if itemTag == "aeMk" {
                        mediaKind = value
                    } else {
                        supportedProducts = value
                    }
                default:
                    break
                }
            }
            if id != 0 {
                apps.append(OwnedAppInfo(
                    id: id,
                    bundleId: bundleId,
                    name: name,
                    version: version,
                    purchaseDate: purchaseDate,
                    mediaKind: mediaKind,
                    supportedProducts: supportedProducts
                ))
            }
        }
        return apps
    }

    static func itemsBody(sessionId: UInt64, revision: UInt64, query: String) -> Data {
        var payload = Data()
        payload.append(dmapUint32("mstc", UInt32(Date().timeIntervalSince1970)))
        payload.append(dmapUint32("mlid", UInt32(truncatingIfNeeded: sessionId)))
        payload.append(dmapUint8("mikd", 2))
        payload.append(dmapUint32("musr", UInt32(truncatingIfNeeded: revision)))
        payload.append(dmapUint32("mder", 0))
        payload.append(dmapString("mque", query))
        payload.append(dmapContainer("aetl", Data()))
        return dmapContainer("adsr", payload)
    }

    private static func dmapContainer(_ name: String, _ payload: Data) -> Data {
        var out = Data(name.utf8.prefix(4))
        appendUint32(&out, UInt32(payload.count))
        out.append(payload)
        return out
    }

    private static func dmapUint32(_ name: String, _ value: UInt32) -> Data {
        var out = Data(name.utf8.prefix(4))
        appendUint32(&out, 4)
        appendUint32(&out, value)
        return out
    }

    private static func dmapUint8(_ name: String, _ value: UInt8) -> Data {
        var out = Data(name.utf8.prefix(4))
        appendUint32(&out, 1)
        out.append(value)
        return out
    }

    private static func dmapString(_ name: String, _ value: String) -> Data {
        let payload = Data(value.utf8)
        var out = Data(name.utf8.prefix(4))
        appendUint32(&out, UInt32(payload.count))
        out.append(payload)
        return out
    }

    private static func appendUint32(_ data: inout Data, _ value: UInt32) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func beUint32(_ data: Data, _ offset: Int) -> UInt32 {
        let bytes = [UInt8](data)
        guard bytes.count >= offset + 4 else { return 0 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func dmapInt64(_ payload: Data) -> Int64 {
        let bytes = [UInt8](payload)
        if bytes.count == 4 {
            return Int64(beUint32(payload, 0))
        }
        if bytes.count == 8 {
            var value: UInt64 = 0
            for b in bytes { value = value << 8 | UInt64(b) }
            return Int64(bitPattern: value)
        }
        return 0
    }

    private static func dmapUint(_ payload: Data) -> UInt64 {
        let bytes = [UInt8](payload)
        var value: UInt64 = 0
        for b in bytes { value = value << 8 | UInt64(b) }
        return value
    }

    private func dmapFirstUint(_ data: Data, _ target: String) throws -> UInt64? {
        var found: UInt64?
        try walkDMAP(data, depth: 0) { tag, payload in
            guard found == nil, tag == target else { return }
            if payload.count == 4 {
                found = UInt64(Self.beUint32(payload, 0))
            } else if payload.count == 8 {
                let bytes = [UInt8](payload)
                var value: UInt64 = 0
                for b in bytes { value = value << 8 | UInt64(b) }
                found = value
            }
        }
        return found
    }

    private func walkDMAP(_ data: Data, depth: Int, visit: (String, Data) throws -> Void) throws {
        if depth > 16 { return }
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else { break }
            guard let tag = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) else { break }
            let length = Int(Self.beUint32(Data(bytes[offset + 4..<offset + 8]), 0))
            guard length >= 0, offset + 8 + length <= bytes.count else { break }
            let payload = Data(bytes[(offset + 8)..<(offset + 8 + length)])
            try visit(tag, payload)
            if Self.isContainer(tag) {
                try walkDMAP(payload, depth: depth + 1, visit: visit)
            }
            offset += 8 + length
        }
    }

    private static func isContainer(_ tag: String) -> Bool {
        ["adbs", "adsr", "aply", "avdb", "mbcl", "mccr", "mcty", "mdcl", "mlcl", "mlit", "mlog", "msrv", "mupd"].contains(tag)
    }
}

private extension Date {
    func utcRFC1123() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        return formatter.string(from: self)
    }

    func iso8601UTC() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        return formatter.string(from: self)
    }
}
