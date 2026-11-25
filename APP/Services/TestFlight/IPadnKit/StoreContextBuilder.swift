import Foundation

public enum StoreContextBuilder {

    public static func allowedNames(dsid: String) -> [String] {
        [
            "X-Dsid", "hsaccnt", "itspod",
            "mt-tkn-" + dsid, "mz_at0-" + dsid, "mz_at_mau-" + dsid, "mz_at_ssl-" + dsid,
            "pldfltcid", "tv-pldfltcid", "wosid-lite",
        ]
    }

    public static func numericDsid(_ dsid: String) throws -> Int {
        guard let value = Int(dsid), value > 0 else {
            throw TFError.invariant("dsId", expected: "正整数", actual: dsid)
        }
        return value
    }

    public static func assertSigned(_ cookies: [String: String], dsid: String) throws {
        let key = "mz_at_ssl-" + dsid
        guard let value = cookies[key], !value.isEmpty else {
            throw TFError.invariant(key, expected: "非空 cookie", actual: "缺失")
        }
    }

    public static func whitelist(_ cookies: [String: String], dsid: String,
                                 log: @escaping @Sendable (String) -> Void) throws -> [String: String] {
        let allowed = allowedNames(dsid: dsid)
        var kept: [String: String] = [:]
        for name in allowed {
            if let value = cookies[name], !value.isEmpty { kept[name] = value }
        }
        let dropped = cookies.count - kept.count
        let missing = allowed.filter { kept[$0] == nil }
        if dropped > 0 {
            log("cookies: 丢弃 " + String(dropped) + " 个白名单外的项")
        }
        guard missing.isEmpty else {
            throw TFError.invariant("cookie 白名单", expected: allowed.joined(separator: ","),
                                    actual: "缺少 " + missing.joined(separator: ","))
        }
        return kept
    }

    public static func contextFromCookies(dsid: String,
                                          macHeaders: [String: String],
                                          log: @escaping @Sendable (String) -> Void) throws -> TFContext {
        TFLogin.purgeForeignCookies(dsid: dsid, log: log)

        var raw: [String: String] = [:]
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.contains("apple.com") {
            let isOurs = cookie.name == "X-Dsid"
                ? cookie.value == dsid
                : TFLogin.cookieBelongs(cookie.name, dsid: dsid)
            if isOurs, !cookie.value.isEmpty { raw[cookie.name] = cookie.value }
        }
        for (name, value) in TFStoreCapture.cookies where !value.isEmpty {
            let isOurs = name == "X-Dsid" ? value == dsid : TFLogin.cookieBelongs(name, dsid: dsid)
            if isOurs { raw[name] = value }
        }
        raw["X-Dsid"] = dsid

        let cookies = try whitelist(raw, dsid: dsid, log: log)
        try assertSigned(cookies, dsid: dsid)
        log("sign-in: dsid …" + String(dsid.suffix(4)) + " cookies " + String(cookies.count)
            + " [" + cookies.keys.sorted().joined(separator: ",") + "]")

        var headers = macHeaders
        headers["User-Agent"] = TFConstants.effectiveUserAgent
        headers["X-Apple-Store-Front"] = TFStoreCapture.storeFront ?? TFStoreCapture.defaultStoreFront
        headers["X-Apple-Device-Model"] = TFConstants.macModel
        headers["X-Apple-TA-Device"] = TFConstants.macModel
        headers["X-Apple-TestFlight-iOS"] = "0"
        headers["X-Apple-Rosetta-Available"] = "0"
        guard let amdm = TFStoreCapture.amdm, !amdm.isEmpty else {
            throw TFError.invariant("X-Apple-AMD-M", expected: "登录响应里捕获", actual: "缺失")
        }
        headers["X-Apple-AMD-M"] = amdm

        let hardware20 = TFIdentity.hardware20()
        let vendorID = hardware20.prefix(16).map { String(format: "%02X", $0) }.joined()
        let fullFront = headers["X-Apple-Store-Front"] ?? TFStoreCapture.defaultStoreFront
        let shortFront = fullFront.split(separator: ",").first.map(String.init) ?? fullFront
        let udid = hardware20.map { String(format: "%02x", $0) }.joined()
        _ = try identityTag(dsid: dsid, udid: udid)

        var identity: [String: String] = [:]
        identity["User-Agent"] = TFConstants.effectiveUserAgent
        identity["X-Apple-Device-Model"] = TFConstants.macModel
        identity["X-Apple-TA-Device"] = TFConstants.macModel
        identity["X-Apple-TestFlight-iOS"] = "0"
        identity["X-Apple-Rosetta-Available"] = "0"
        identity["X-Apple-Store-Front"] = fullFront
        identity["X-Apple-AMD-M"] = amdm

        let payload: [String: Any] = [
            "deviceModel": TFConstants.macModel,
            "deviceName": "iPadn",
            "dsId": try numericDsid(dsid),
            "deviceVendorId": vendorID,
            "storeFrontIdentifier": shortFront,
            "storeCookies": cookies,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let dsidMasked = "…" + String(dsid.suffix(4))
        log("sign-in: body dsId=" + dsidMasked + " vendor=‹redacted›"
            + " front=" + shortFront + " name=iPadn cookies=" + String(cookies.count))
        log("sign-in: identity " + dsidMasked + ":‹udid› · headers " + String(identity.count) + " ["
            + identity.keys.sorted().joined(separator: ",") + "]")
        return TFContext(body: data, hardware20: hardware20,
                         storefront: fullFront, headers: identity, dsid: dsid,
                         storeCookies: cookies)
    }

    public static func identityTag(dsid: String, udid: String) throws -> String {
        guard udid.count == 40, udid.allSatisfy(\.isHexDigit) else {
            throw TFError.invariant("udid", expected: "40 位 hex", actual: String(udid.count) + " 位")
        }
        _ = try numericDsid(dsid)
        return dsid + ":" + udid
    }
}
