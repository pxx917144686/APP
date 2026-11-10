import Foundation

struct OwnedApp: Codable, Identifiable {
    var id: String
    var bundleID: String
    var name: String
    var version: String
    var purchaseDate: Date?
    var iconURL: URL?
}

enum DMAP {
    struct Tag { let name: String; let payload: Data }
    private static let containers: Set<String> = ["adbs", "adsr", "aply", "avdb", "mbcl", "mccr", "mcty", "mdcl", "mlcl", "mlit", "mlog", "msrv", "mupd"]

    static func tag(_ name: String, _ payload: Data = Data()) -> Data {
        precondition(name.utf8.count == 4 && name.utf8.allSatisfy { (32...126).contains($0) })
        precondition(payload.count <= Int(UInt32.max))
        var data = Data(name.utf8)
        var count = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
    static func uint32(_ name: String, _ value: UInt32) -> Data {
        var number = value.bigEndian
        return withUnsafeBytes(of: &number) { tag(name, Data($0)) }
    }
    static func string(_ name: String, _ value: String) -> Data { tag(name, Data(value.utf8)) }
    static func integer(_ data: Data) throws -> UInt64 {
        guard [1, 4, 8].contains(data.count) else { throw ToolError.message("dmap_err_integer_length".localized) }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    static func walk(_ data: Data, depth: Int = 0, visitor: (Tag) throws -> Void) throws {
        guard depth <= 16 else { throw ToolError.message("dmap_err_nesting".localized) }
        var offset = data.startIndex
        let end = data.endIndex
        while offset < end {
            guard end - offset >= 8 else { throw ToolError.message("dmap_err_tag_truncated".localized) }
            let nameBytes = data[offset..<(offset + 4)]
            guard nameBytes.allSatisfy({ (32...126).contains($0) }),
                  let name = String(bytes: nameBytes, encoding: .ascii) else { throw ToolError.message("dmap_err_tag_name".localized) }
            let length = data[(offset + 4)..<(offset + 8)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let start = offset + 8
            guard UInt64(length) <= UInt64(end - start) else { throw ToolError.message("dmap_err_payload_truncated".localized) }
            let stop = start + Int(length)
            let payload = data[start..<stop]
            try visitor(Tag(name: name, payload: payload))
            if containers.contains(name) { try walk(payload, depth: depth + 1, visitor: visitor) }
            offset = stop
        }
    }
    private struct Found: Error { let value: UInt32 }
    static func firstInteger(_ data: Data, name: String) throws -> UInt32? {
        do {
            try walk(data) { tag in
                guard tag.name == name else { return }
                let number = try integer(tag.payload)
                guard number <= UInt32.max else { throw ToolError.message("dmap_err_value_overflow".localized) }
                throw Found(value: UInt32(number))
            }
        } catch let found as Found { return found.value }
        return nil
    }
    static func validate(_ data: Data) throws {
        guard let status = try firstInteger(data, name: "mstt") else {
            throw ToolError.message("dmap_err_sync_failed".localized)
        }
        if status != 200 {
            throw ToolError.message("dmap_err_sync_failed_status".localized(status))
        }
    }
    static func ownedApps(_ data: Data) throws -> [OwnedApp] {
        var apps: [OwnedApp] = []; var seen = Set<String>()
        try walk(data) { item in
            guard item.name == "mlit" else { return }
            var app = OwnedApp(id: "", bundleID: "", name: "", version: "")
            try walk(item.payload) { field in
                let text = String(data: field.payload, encoding: .utf8) ?? ""
                switch field.name {
                case "aeSI": app.id = String(try integer(field.payload))
                case "aeBI": app.bundleID = text
                case "aeLN": app.name = text
                case "minm": if app.name.isEmpty { app.name = text }
                case "aePd": app.version = text
                case "asdp": app.purchaseDate = Date(timeIntervalSince1970: Double(try integer(field.payload)))
                default: break
                }
            }
            if !app.id.isEmpty, seen.insert(app.id).inserted { apps.append(app) }
        }
        return apps.sorted { ($0.purchaseDate ?? .distantPast) > ($1.purchaseDate ?? .distantPast) }
    }
}

@MainActor
enum PurchaseHistoryService {
    static func ownedApps(account: Account) async throws -> [OwnedApp] {
        let guid = GUIDCache.shared.get()
        let base = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"
        let query = "('com.apple.itunes.extended\\-media\\-kind:131072')"
        let headers = purchaseHeaders(account, guid: guid)

        let (login, _) = try await HTTPClient.shared.request(
            URL(string: base + "/login")!, method: "POST", headers: headers, appleRedirects: true)
        try DMAP.validate(login)
        guard let session = try DMAP.firstInteger(login, name: "mlid") else {
            throw ToolError.message("dmap_err_sync_failed".localized)
        }

        let updateBody = Data("session-id=\(session)&revision-number=(null)&query=\(query)".utf8)
        var updateHeaders = headers
        updateHeaders["X-Apple-ActionSignature"] = try await SAPSigner.shared.sign(updateBody, guid: guid, useCache: true)
        let (update, _) = try await HTTPClient.shared.request(
            URL(string: base + "/update")!, method: "POST", body: updateBody, headers: updateHeaders, appleRedirects: true)
        try DMAP.validate(update)
        guard let revision = try DMAP.firstInteger(update, name: "musr") else {
            throw ToolError.message("dmap_err_sync_failed".localized)
        }

        let payload = DMAP.uint32("mstc", UInt32(Date().timeIntervalSince1970)) + DMAP.uint32("mlid", session) +
            DMAP.tag("mikd", Data([2])) + DMAP.uint32("musr", revision) + DMAP.uint32("mder", 0) +
            DMAP.string("mque", query) + DMAP.tag("aetl")
        let body = DMAP.tag("adsr", payload)
        var itemHeaders = purchaseHeaders(account, guid: guid)
        itemHeaders["Content-Type"] = "application/x-dmap-tagged"
        itemHeaders["X-Apple-ActionSignature"] = try await SAPSigner.shared.sign(body, guid: guid, useCache: true)

        let (items, _) = try await HTTPClient.shared.request(
            URL(string: base + "/databases/\(revision)/items")!, method: "POST", body: body,
            headers: itemHeaders, appleRedirects: true)
        return try await Task.detached(priority: .userInitiated) {
            try DMAP.validate(items)
            return try DMAP.ownedApps(items)
        }.value
    }

    private static func purchaseHeaders(_ account: Account, guid: String) -> [String: String] {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let iso = ISO8601DateFormatter()
        var headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Dsid": account.dsPersonId, "iCloud-DSID": account.dsPersonId,
            "Accept": "*/*", "Accept-Language": "en-us", "Client-Cloud-DAAP-Request-Reason": "5",
            "Client-Cloud-Purchase-Daap-Version": "1.1/Configurator-2.0", "Client-DAAP-Version": "3.12",
            "Date": date.string(from: now), "X-Apple-I-Client-Time": iso.string(from: now),
            "X-Apple-I-Locale": "en_US", "X-Apple-I-TimeZone": "Local",
            "X-Apple-TZ": String(TimeZone.current.secondsFromGMT(for: now) / 60), "X-Guid": guid
        ]
        if !account.passwordToken.isEmpty { headers["X-Token"] = account.passwordToken }
        let storeFront = account.storeResponse.storeFront
        if !storeFront.isEmpty { headers["X-Apple-Store-Front"] = storeFront }
        let cookie = AuthCookieCache.shared.get(dsid: account.dsPersonId).first
            ?? UserDefaults.standard.string(forKey: "ipadn_cookie_\(account.dsPersonId)")
        if let cookie, !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }
}
