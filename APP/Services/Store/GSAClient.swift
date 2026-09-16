import Foundation
import Crypto
import BigNum
import CommonCrypto

struct GSAAuthTokens {
    let adsid: String
    let idmsToken: String
    let extraPlist: [String: Any]
    let dsPersonId: String
    let countryCode: String?
    let storeFront: String?

    private func pickCI(_ d: [String: Any], _ keys: [String]) -> Any? {
        let lowerMap = Dictionary(uniqueKeysWithValues: d.keys.map { ($0.lowercased(), $0) })
        for k in keys {
            if let real = lowerMap[k.lowercased()], let v = d[real], "\(String(describing: v))" != "" {
                return d[real]
            }
        }
        return nil
    }
    private func deepFindStr(_ keys: [String]) -> String? {
        let lowerKeys = keys.map { $0.lowercased() }
        var stack: [Any] = [extraPlist]
        var visited = Set<ObjectIdentifier>()
        while !stack.isEmpty {
            let cur = stack.removeLast()
            if let d = cur as? [String: Any] {
                let id = ObjectIdentifier(d as NSDictionary)
                if visited.contains(id) { continue }
                visited.insert(id)
                let lowerMap = Dictionary(uniqueKeysWithValues: d.keys.map { ($0.lowercased(), $0) })
                for lk in lowerKeys {
                    if lowerKeys.contains(lk), let real = lowerMap[lk], let v = d[real] {
                        if let s = toStr(v), !s.isEmpty { return s }
                    }
                }
                for v in d.values { stack.append(v) }
            } else if let arr = cur as? [Any] {
                for v in arr { stack.append(v) }
            }
        }
        return nil
    }
    private func toStr(_ v: Any?) -> String? {
        guard let v else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let d = v as? Data { return String(data: d, encoding: .utf8) }
        return nil
    }
    var gsIdmsToken: String {
        let keys = ["GsIdmsToken","idmsToken","idmsAuthToken","idms_token","gs_idms_token","com.apple.gs.idms.auth","idmsAuth","idms_auth_token"]
        if let v = toStr(pickCI(extraPlist, keys)) { return v }
        let tKeys = ["t","tokens","tokensDict","authResults","auth","authServiceResponse"]
        for tk in tKeys {
            if let t = pickCI(extraPlist, [tk]) as? [String: Any] {
                if let v = toStr(pickCI(t, keys)) { return v }
            }
        }
        if let deep = deepFindStr(keys), !deep.isEmpty { return deep }
        return idmsToken
    }
    var pet: String? {
        let petKeys = ["com.apple.gs.idms.pet","idmsPet","pet","PET","com_apple_gs_idms_pet","petToken","idms_pet"]
        let valKeys = ["token","Token","value","stringValue"]
        let tKeys = ["t","tokens","tokensDict","authResults","auth","authServiceResponse"]
        for tk in tKeys {
            if let t = pickCI(extraPlist, [tk]) as? [String: Any] {
                if let inner = pickCI(t, petKeys) as? [String: Any], let v = toStr(pickCI(inner, valKeys)) { return v }
                if let s = toStr(pickCI(t, petKeys)), !s.isEmpty { return s }
            }
        }
        if let s = toStr(pickCI(extraPlist, petKeys)), !s.isEmpty { return s }
        if let deep = deepFindStr(petKeys), !deep.isEmpty { return deep }
        return nil
    }
    var identityToken: String? {
        let raw = "\(adsid):\(gsIdmsToken)"
        guard let d = raw.data(using: .utf8) else { return nil }
        return d.base64EncodedString()
    }
}

struct GSAInitResponse {
    let c: String
    let s: Data
    let B: Data
    let iterations: Int
    let proto: String
}

enum GSAClientError: Error {
    case invalidURL
    case requestFailed(Int, String)
    case invalidPlist
    case protoMissing(String)
    case srpProofMismatch
    case srpKeyUnavailable
    case spdDecodeFailed
    case trustedDeviceNotifyFailed
    case lockedAccount(String)
    case invalidCredentials(String)
    case invalidSecurityCode(String)
    case tooManyRequests
    case serverError(Int, String)
    case twoFactorRequired(GSAAuthTokens)
}

private enum NG2048 {
    static let N_HEX = "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73"
    static let G_UINT = 2
}

struct PySRPUser {
    let username: String
    let N: BigNum
    let g: BigNum
    let sizeN: Int
    let a: BigNum
    let A: BigNum
    var K: [UInt8] = []
    var S: BigNum? = nil
    var M: [UInt8]? = nil
    var u: BigNum? = nil
    var x: BigNum? = nil
    var v: BigNum? = nil
    var B: BigNum? = nil
    var aBytesSeed: [UInt8] = []

    init(username: String, aBytesSeed: [UInt8]? = nil) {
        self.username = username
        guard let n = BigNum(hex: NG2048.N_HEX) else {
            fatalError("N hex invalid")
        }
        self.N = n
        self.g = BigNum(NG2048.G_UINT)
        let nBytes = self.N.bytes
        self.sizeN = nBytes.count
        let seed: [UInt8]
        if let aBytesSeed = aBytesSeed {
            seed = aBytesSeed
        } else {
            var bytes = [UInt8](repeating: 0, count: 32 + self.sizeN)
            for i in 0..<bytes.count {
                bytes[i] = UInt8.random(in: 0...255)
            }
            seed = bytes
        }
        self.aBytesSeed = seed
        self.a = BigNum(bytes: seed)
        self.A = self.g.power(self.a, modulus: self.N)
    }

    func startAuthentication() -> [UInt8] {
        padToN(self.A.bytes)
    }

    private func padToN(_ bytes: [UInt8]) -> [UInt8] {
        let diff = sizeN - bytes.count
        return diff > 0 ? [UInt8](repeating: 0, count: diff) + bytes : bytes
    }

    private func H(_ bytes: [UInt8]) -> [UInt8] {
        [UInt8](SHA256.hash(data: bytes))
    }

    private func H_padded(_ bytes: [UInt8]) -> [UInt8] {
        if bytes.count > 0, bytes.count < sizeN {
            return H([UInt8](repeating: 0, count: sizeN - bytes.count) + bytes)
        }
        return H(bytes)
    }

    mutating func processChallenge(salt: [UInt8], serverB_bytes: [UInt8], derivedPassword: [UInt8]) -> [UInt8]? {
        let B_bn = BigNum(bytes: serverB_bytes)
        self.B = B_bn
        guard B_bn % N != BigNum(0) else { return nil }
        let A_bytes = padToN(self.A.bytes)
        let B_bytes = padToN(serverB_bytes)
        let u_bn = BigNum(bytes: H(A_bytes + B_bytes))
        self.u = u_bn
        let inner = H([UInt8]("".utf8) + [0x3A] + derivedPassword)
        let x_bn = BigNum(bytes: H(salt + inner))
        self.x = x_bn
        let v = g.power(x_bn, modulus: N)
        self.v = v
        let k_bn = BigNum(bytes: H(N.bytes + padToN(g.bytes)))
        let kv = k_bn.mul(v, modulus: N)
        let base = B_bn.sub(kv, modulus: N)
        let exponent = a + u_bn * x_bn
        let S_bn = base.power(exponent, modulus: N)
        self.S = S_bn
        self.K = H(padToN(S_bn.bytes))
        let m1 = computeM1(salt: salt, A: self.A.bytes, B: serverB_bytes)
        self.M = m1
        return m1
    }

    func computeM1(salt: [UInt8], A: [UInt8], B: [UInt8]) -> [UInt8] {
        let hN = H(N.bytes)
        let gPadded = padToN(g.bytes)
        let hg = H(gPadded)
        var hNg = [UInt8](repeating: 0, count: hN.count)
        for i in 0..<hN.count {
            hNg[i] = hN[i] ^ hg[i]
        }
        let hU = H([UInt8](username.utf8))
        return H(hNg + hU + salt + A + B + K)
    }

    func computeM2(A: [UInt8], M: [UInt8]) -> [UInt8] {
        H(A + M + K)
    }
}

final class GSAClient {
    static let shared = GSAClient()
    let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        cfg.tlsMaximumSupportedProtocolVersion = .TLSv13
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.httpShouldUsePipelining = true
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
            "HTTPProxy": "",
            "HTTPSProxy": "",
            "SOCKSProxy": ""
        ]
        cfg.urlCredentialStorage = nil
        #if canImport(UIKit) || targetEnvironment(macCatalyst)
        if #available(iOS 15.0, macCatalyst 15.0, *) {
            cfg.multipathServiceType = .none
        }
        #endif
        session = URLSession(configuration: cfg)
    }

    struct GSAuthResult {
        let tokens: GSAAuthTokens?
        let passwordToken: String?
        let dsPersonId: String?
        let accountInfo: [String: Any]
        let raw: [String: Any]
    }

    func grandSlamAuthenticate(
        email: String,
        password: String,
        aniData: AnisetteData,
        securityCode: String? = nil,
        preM1Handler: ((GSAInitResponse, PySRPUser) -> Void)? = nil
    ) async throws -> GSAuthResult {
        var user = PySRPUser(username: email)
        let publicA = user.startAuthentication()

        let initResp = try await grandSlamInit(email: email, publicA: publicA, aniData: aniData)

        let derivedPassword = try encryptPassword(
            password: password,
            salt: [UInt8](initResp.s),
            iterations: initResp.iterations,
            proto: initResp.proto
        )

        guard let M1 = user.processChallenge(
            salt: [UInt8](initResp.s),
            serverB_bytes: [UInt8](initResp.B),
            derivedPassword: derivedPassword
        ) else {
            throw GSAClientError.srpKeyUnavailable
        }
        preM1Handler?(initResp, user)

        let completeResult = try await grandSlamComplete(
            email: email,
            initC: initResp.c,
            srpM1: M1,
            aniData: aniData,
            securityCode: securityCode
        )

        if let m2Data = completeResult.raw["M2"] as? Data {
            let expected = user.computeM2(A: self_padToN(user.A.bytes, sizeN: user.sizeN), M: M1)
            if [UInt8](m2Data) != expected {
            }
        }

        let ec = completeResult.raw["ec"] as? Int
        let statusBox = completeResult.raw["Status"] as? [String: Any]
        let au = (statusBox?["au"] as? String) ?? (completeResult.raw["au"] as? String)
        let hsc = (statusBox?["hsc"] as? Int) ?? (completeResult.raw["hsc"] as? Int) ?? 0
        let hasSPD = (completeResult.raw["spd"] as? Data) != nil
        let hasM2 = completeResult.raw["M2"] != nil
        let twoFactorTriggered = (hsc == 409 || au == "trustedDeviceSecondaryAuth" || ec == -21669)

        if hasSPD, hasM2 {
            do {
                let spdBytes = completeResult.raw["spd"] as! Data
                let spdPlain = try decryptSPD(K: Data(user.K), spd: spdBytes)
                if let parsed = try? parsePlistAuto(spdPlain) {
                    if let tokens = extractTokens(parsed) {
                        let extractedPT = (tokens.extraPlist["__extracted_password_token"] as? String) ?? ""
                        let rawPT = completeResult.passwordToken ?? ""
                        func isTrueiTunesPasswordToken(_ s: String) -> Bool {
                            isTrueCommerceKitPasswordToken(unwrapSharedChannelsTokenIfNeeded(s))
                        }
                        var finalPT: String? = nil
                        for cand in [rawPT, extractedPT] where isTrueiTunesPasswordToken(cand) {
                            if finalPT == nil || cand.count > finalPT!.count { finalPT = cand }
                        }
                        let finalDSID = completeResult.dsPersonId ?? tokens.dsPersonId
                        if twoFactorTriggered {
                            throw GSAClientError.twoFactorRequired(tokens)
                        }
                        return GSAuthResult(
                            tokens: tokens,
                            passwordToken: finalPT,
                            dsPersonId: finalDSID.isEmpty ? nil : finalDSID,
                            accountInfo: completeResult.accountInfo,
                            raw: completeResult.raw
                        )
                    }
                }
            } catch let e as GSAClientError {
                throw e
            } catch {
            }
        }

        if twoFactorTriggered {
            throw GSAClientError.twoFactorRequired(GSAAuthTokens(adsid: "", idmsToken: "", extraPlist: [:], dsPersonId: "", countryCode: nil, storeFront: nil))
        }

        if let ec, ec != 0 {
            if ec == -20209 || ec == -20205 || ec == -20201 {
                throw GSAClientError.lockedAccount("ec=\(ec)")
            }
            if ec == -21669 {
                throw GSAClientError.twoFactorRequired(GSAAuthTokens(adsid: "", idmsToken: "", extraPlist: [:], dsPersonId: "", countryCode: nil, storeFront: nil))
            }
            let em = completeResult.raw["em"] as? String ?? ""
            throw GSAClientError.serverError(ec, em)
        }

        return GSAuthResult(
            tokens: nil,
            passwordToken: completeResult.passwordToken,
            dsPersonId: completeResult.dsPersonId,
            accountInfo: completeResult.accountInfo,
            raw: completeResult.raw
        )
    }

    private func self_padToN(_ bytes: [UInt8], sizeN: Int) -> [UInt8] {
        let diff = sizeN - bytes.count
        return diff > 0 ? [UInt8](repeating: 0, count: diff) + bytes : bytes
    }

    func grandSlamInit(email: String, publicA: [UInt8], aniData: AnisetteData, urlSession: URLSession? = nil) async throws -> GSAInitResponse {
        let body: [String: Any] = [
            "A2k": Data(publicA),
            "ps": ["s2k", "s2k_fo"],
            "u": email,
            "o": "init"
        ]
        let (status, dict, data) = try await requestGsService(body: body, aniData: aniData, urlSession: urlSession)
        guard (200..<300).contains(status) else {
            let hint = String(data: data.prefix(400), encoding: .utf8) ?? String(describing: dict)
            throw GSAClientError.requestFailed(status, hint)
        }
        let ec = dict["ec"] as? Int ?? 0
        if ec == -20209 || ec == -20205 || ec == -20201 {
            throw GSAClientError.lockedAccount("ec=\(ec)")
        }
        guard let c = dict["c"] as? String else {
            let status = dict["Status"] as? [String: Any] ?? [:]
            let hint = """
                init missing c. HTTP 200. dict.top.keys=\(dict.keys.sorted())
                Status.keys=\(status.keys.sorted())  Status.hsc=\(status["hsc"] ?? "nil")  Status.au=\(status["au"] ?? "nil")
                dict.ec=\(dict["ec"] ?? "nil")  dict.au=\(dict["au"] ?? "nil")
                rawPrefix=\(String(data: data.prefix(900), encoding: .utf8) ?? "(not UTF-8)")
                """
            throw GSAClientError.requestFailed(200, hint)
        }
        guard let s = dict["s"] as? Data else {
            let hint = "keys=\(dict.keys.sorted()) raw=\(String(data: data.prefix(400), encoding: .utf8) ?? "")"
            throw GSAClientError.requestFailed(status, "init missing s: \(hint)")
        }
        guard let B = dict["B"] as? Data else {
            throw GSAClientError.requestFailed(status, "init missing B: keys=\(dict.keys.sorted())")
        }
        let iterations = (dict["i"] as? Int) ?? (dict["i"] as? NSNumber)?.intValue ?? 0
        guard let proto = dict["sp"] as? String else {
            throw GSAClientError.requestFailed(status, "init missing sp: keys=\(dict.keys.sorted())")
        }
        return GSAInitResponse(c: c, s: s, B: B, iterations: iterations, proto: proto)
    }

    struct CompleteResult {
        let passwordToken: String?
        let dsPersonId: String?
        let accountInfo: [String: Any]
        let raw: [String: Any]
    }

    func grandSlamComplete(
        email: String,
        initC: String,
        srpM1: [UInt8],
        aniData: AnisetteData,
        securityCode: String? = nil,
        urlSession: URLSession? = nil
    ) async throws -> CompleteResult {
        var body: [String: Any] = [
            "c": initC,
            "M1": Data(srpM1),
            "u": email,
            "o": "complete"
        ]
        if let sc = securityCode, !sc.isEmpty {
            body["securityCode"] = sc
            body["scnt"] = "trusteddevice"
        }
        let (status, dict, _) = try await requestGsService(body: body, aniData: aniData, urlSession: urlSession)
        guard (200..<400).contains(status) else {
            throw GSAClientError.serverError(status, String(describing: dict))
        }
        let statusBox = dict["Status"] as? [String: Any]
        let accountInfo = (dict["accountInfo"] as? [String: Any]) ?? (statusBox?["accountInfo"] as? [String: Any]) ?? [:]
        let passwordToken = dict["passwordToken"] as? String
            ?? (statusBox?["passwordToken"] as? String)
            ?? (dict["pt"] as? String)
            ?? (accountInfo["passwordToken"] as? String)
        let dsPersonId: String? = ({
            let v = dict["dsPersonId"] ?? statusBox?["dsPersonId"] ?? dict["DsPrsId"] ?? statusBox?["DsPrsId"] ?? dict["DsPrsID"] ?? statusBox?["DsPrsID"] ?? dict["dsID"] ?? statusBox?["dsID"] ?? dict["AdsID"] ?? statusBox?["AdsID"] ?? accountInfo["directoryServicesIdentifier"] ?? accountInfo["dsPersonId"] ?? accountInfo["DsPrsId"]
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            if let d = v as? Data { return String(data: d, encoding: .utf8) }
            return nil
        })()
        return CompleteResult(
            passwordToken: passwordToken,
            dsPersonId: dsPersonId,
            accountInfo: accountInfo,
            raw: dict
        )
    }

    func requestTrustedDeviceNotification(
        adsid: String,
        idmsToken: String,
        aniHeaders: [String: String],
        clientInfo: String,
        urlSession: URLSession? = nil
    ) async throws {
        let payload = "\(adsid):\(idmsToken)"
        guard let payloadData = payload.data(using: .utf8) else { throw GSAClientError.trustedDeviceNotifyFailed }
        let token = payloadData.base64EncodedString()
        let client = urlSession ?? session
        let urls: [String] = [
            "https://gsa.apple.com/auth/verify/trusteddevice",
            "https://idmsa.apple.com/appleauth/auth/verify/trusteddevice",
            "https://gsa.apple.com.cn/auth/verify/trusteddevice"
        ]
        var lastError: Error?
        for urlStr in urls {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "GET"
            req.setValue(GSA_UA, forHTTPHeaderField: "User-Agent")
            req.setValue(clientInfo, forHTTPHeaderField: "X-MMe-Client-Info")
            req.setValue("en-us", forHTTPHeaderField: "Accept-Language")
            req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            req.setValue("text/x-xml-plist, application/json, */*", forHTTPHeaderField: "Accept")
            req.setValue(token, forHTTPHeaderField: "X-Apple-Identity-Token")
            for (k, v) in aniHeaders {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.httpShouldHandleCookies = true
            do {
                let (data, resp) = try await client.data(for: req)
                guard let http = resp as? HTTPURLResponse else { continue }
                if (200..<300).contains(http.statusCode) {
                    return
                }
                if (400..<500).contains(http.statusCode), urlStr != urls.last {
                    let s = String(data: data.prefix(400), encoding: .utf8) ?? ""
                    lastError = GSAClientError.requestFailed(http.statusCode, "\(urlStr) body=\(s.prefix(200))")
                    continue
                }
                lastError = GSAClientError.requestFailed(http.statusCode, urlStr)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? GSAClientError.trustedDeviceNotifyFailed
    }

    func requestGsService(
        body: [String: Any],
        aniData: AnisetteData,
        urlSession: URLSession? = nil
    ) async throws -> (Int, [String: Any], Data) {
        guard let url = URL(string: "https://gsa.apple.com/grandslam/GsService2") else {
            throw GSAClientError.invalidURL
        }
        let client = urlSession ?? session
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(GSA_UA, forHTTPHeaderField: "User-Agent")
        req.setValue(clientInfoString, forHTTPHeaderField: "X-MMe-Client-Info")
        var request = body
        request["cpd"] = aniData.cpdDictionary()
        let wrapper: [String: Any] = [
            "Header": ["Version": "1.0.1"],
            "Request": request
        ]
        let plistBody = try PropertyListSerialization.data(fromPropertyList: wrapper, format: .xml, options: 0)
        req.httpBody = plistBody
        let (data, resp) = try await client.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GSAClientError.invalidPlist
        }
        let parsed: [String: Any]
        if !data.isEmpty {
            if let p = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                if let resp = p["Response"] as? [String: Any] {
                    parsed = resp
                } else {
                    parsed = p
                }
            } else if let j = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                parsed = j
            } else {
                parsed = [:]
            }
        } else {
            parsed = [:]
        }
        return (http.statusCode, parsed, data)
    }
}

let GSA_CLIENT_INFO = "<MacBookPro18,3> <Mac OS X;13.4.1;22F8> <com.apple.AOSKit/282 (com.apple.dt.Xcode/3594.4.19)>"
let GSA_UA = "akd/1.0 CFNetwork/1408.0.4 Darwin/22.5.0"
let clientInfoString = GSA_CLIENT_INFO

func encryptPassword(password: String, salt: [UInt8], iterations: Int, proto: String) throws -> [UInt8] {
    let pwData = password.data(using: .utf8)!
    let sha = SHA256.hash(data: pwData)
    var pass: [UInt8]
    if proto == "s2k_fo" {
        let hex = sha.map { String(format: "%02x", $0) }.joined()
        pass = [UInt8](hex.utf8)
    } else {
        pass = [UInt8](sha)
    }
    return try pbkdf2SHA256(password: pass, salt: salt, iterations: iterations, keyLength: 32)
}

private func pbkdf2SHA256(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int) throws -> [UInt8] {
    var derivedBytes = [UInt8](repeating: 0, count: keyLength)
    let status = CCKeyDerivationPBKDF(
        CCPBKDFAlgorithm(kCCPBKDF2),
        password, password.count,
        salt, salt.count,
        CCPBKDFAlgorithm(kCCPRFHmacAlgSHA256),
        UInt32(iterations),
        &derivedBytes, derivedBytes.count
    )
    guard status == 0 else { throw NSError(domain: "PBKDF2", code: Int(status)) }
    return derivedBytes
}

func decryptSPD(K: Data, spd: Data) throws -> Data {
    let key = hmacSHA256(key: K, data: Array("extra data key:".utf8))
    let ivFull = hmacSHA256(key: K, data: Array("extra data iv:".utf8))
    let iv = ivFull.prefix(16)
    guard key.count == 32, iv.count == 16 else {
        throw GSAClientError.spdDecodeFailed
    }
    let padded = try aes256CBCDecrypt(key: key, iv: Data(iv), ciphertext: spd)
    return try pkcs7Unpad(padded)
}

private func hmacSHA256(key: Data, data: [UInt8]) -> Data {
    let k = SymmetricKey(data: key)
    let mac = HMAC<SHA256>.authenticationCode(for: Data(data), using: k)
    return Data(mac)
}

private func aes256CBCDecrypt(key: Data, iv: Data, ciphertext: Data) throws -> Data {
    guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
        throw GSAClientError.spdDecodeFailed
    }
    var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
    var numBytes: Int = 0
    let status = CCCrypt(
        CCOperation(kCCDecrypt),
        CCAlgorithm(kCCAlgorithmAES),
        CCOptions(0),
        Array(key), key.count,
        Array(iv),
        Array(ciphertext), ciphertext.count,
        &out, out.count,
        &numBytes
    )
    guard status == 0 else {
        throw GSAClientError.spdDecodeFailed
    }
    return Data(out[0..<numBytes])
}

private func pkcs7Unpad(_ data: Data) throws -> Data {
    guard !data.isEmpty else { throw GSAClientError.spdDecodeFailed }
    let last = data[data.count - 1]
    guard last > 0, last <= 16 else { throw GSAClientError.spdDecodeFailed }
    guard data.count >= Int(last) else { throw GSAClientError.spdDecodeFailed }
    for i in (data.count - Int(last))..<data.count {
        if data[i] != last { throw GSAClientError.spdDecodeFailed }
    }
    return data.dropLast(Int(last))
}

func parsePlistAuto(_ data: Data) throws -> [String: Any] {
    if let pl = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
        return pl
    }
    let header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n".data(using: .utf8)!
    var combined = header
    var scan = data
    while !scan.isEmpty && (scan[0] == 0x00 || scan[0] == 0x20 || scan[0] == 0x0a || scan[0] == 0x0d) {
        scan.removeFirst()
    }
    combined.append(scan)
    if let pl = try? PropertyListSerialization.propertyList(from: combined, options: [], format: nil) as? [String: Any] {
        return pl
    }
    throw GSAClientError.spdDecodeFailed
}

private func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b64 = String(parts[1])
    let pad = (4 - (b64.count % 4)) % 4
    if pad > 0 { b64.append(contentsOf: repeatElement("=", count: pad)) }
    b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    guard let data = Data(base64Encoded: b64),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json
}

private func unwrapSharedChannelsTokenIfNeeded(_ candidate: String) -> String {
    guard candidate.hasPrefix("eyJ"), candidate.contains(".") else { return candidate }
    guard let payload = decodeJWTPayload(candidate) else { return candidate }
    let id = (payload["id"] as? String) ?? ""
    if id == "com.apple.gs.sharedchannels.auth", let inner = payload["token"] as? String, !inner.isEmpty {
        return inner
    }
    return candidate
}

func extractTokens(_ spd: [String: Any]) -> GSAAuthTokens? {
    func pickCI(_ d: [String: Any], _ keys: [String]) -> Any? {
        let lowerMap = Dictionary(uniqueKeysWithValues: d.keys.map { ($0.lowercased(), $0) })
        for k in keys {
            if let real = lowerMap[k.lowercased()], let v = d[real], "\(String(describing: v))" != "" {
                return d[real]
            }
        }
        return nil
    }
    func toStr(_ v: Any?) -> String? {
        guard let v else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let d = v as? Data { return String(data: d, encoding: .utf8) }
        return nil
    }
    let adsid = toStr(pickCI(spd, ["AdsID","adsid","AltDsID","AltDsId"]))
    let dsid = toStr(pickCI(spd, ["DsPrsId","DsPrsID","dsPrsId","DsId","dsID","dsid","DsPersonId","dsPersonId","DsPersonID","dsPersonID","AdsID","adsid"])) ?? ""
    let cc: String? = toStr(pickCI(spd, ["countryCode","CountryCode","country","Country","region","Region"]))
    let sf: String? = toStr(pickCI(spd, ["Storefront","storeFront","storefront","sf","SF","frontEndStorefront","feSF"]))
    func isTrueiTunesPasswordToken(_ raw: String) -> Bool {
        isTrueCommerceKitPasswordToken(unwrapSharedChannelsTokenIfNeeded(raw))
    }
    let pwdKeys = ["passwordToken","password_token","password","pt","token","Token","idmsPassword","idms_password","itunesPassword","itunes_password","mzPassword"]
    var pwdTok: String?
    var best = ""
    func considerCandidate(_ raw: String) {
        guard !raw.isEmpty else { return }
        let unwrapped = unwrapSharedChannelsTokenIfNeeded(raw)
        let quality = isTrueCommerceKitPasswordToken(unwrapped)
        if quality && unwrapped.count > best.count {
            best = unwrapped
        }
    }
    if let raw = toStr(pickCI(spd, pwdKeys)) { considerCandidate(raw) }
    var idms = toStr(pickCI(spd, ["GsIdmsToken","idmsToken","idms_token","idmsAuthToken","idmsPet","pet","com.apple.gs.idms.pet","com.apple.gs.idms.auth"]))
    var idmsT: [String: Any]? = pickCI(spd, ["t","tokens","tokensDict"]) as? [String: Any]
    if idmsT == nil {
        if let auth = pickCI(spd, ["auth","authServiceResponse","authResults"]) as? [String: Any] {
            idmsT = pickCI(auth, ["t","tokens","tokensDict"]) as? [String: Any]
        }
    }
    if let t = idmsT {
        if let raw = toStr(pickCI(t, pwdKeys)) { considerCandidate(raw) }
        if idms == nil {
            idms = toStr(pickCI(t, ["com.apple.gs.idms.pet","com.apple.gs.idms.auth","com.apple.gs.idms","idms","pet","idmsToken","idms_auth_token","gsIdmsToken"]))
            if idms == nil {
                for (k, v) in t where k.lowercased().contains("idms") {
                    if let d = v as? [String: Any] {
                        idms = toStr(d["value"]) ?? toStr(d["token"]) ?? String(describing: d)
                        break
                    } else if let s = toStr(v) {
                        idms = s
                        break
                    }
                }
            }
        }
        for (_, v) in t {
            if let d = v as? [String: Any],
               let raw = toStr(pickCI(d, ["passwordToken","password","token","value"])) {
                considerCandidate(raw)
            }
        }
    }
    do {
        var visited = Set<ObjectIdentifier>()
        var stack: [Any] = [spd]
        while !stack.isEmpty {
            let cur = stack.removeLast()
            if let d = cur as? [String: Any] {
                let id = ObjectIdentifier(d as NSDictionary)
                if visited.contains(id) { continue }
                visited.insert(id)
                for (k, v) in d {
                    let kl = k.lowercased()
                    if kl.contains("password") || kl.contains("token") || kl == "pt" {
                        if let raw = toStr(v) { considerCandidate(raw) }
                    }
                }
                for v in d.values { stack.append(v) }
            } else if let arr = cur as? [Any] {
                for v in arr { stack.append(v) }
            }
        }
    }
    if !best.isEmpty { pwdTok = best }
    guard let adsid, let idms else { return nil }
    var outExtra = spd
    if let p = pwdTok, !p.isEmpty {
        outExtra["__extracted_password_token"] = p
    }
    return GSAAuthTokens(
        adsid: adsid,
        idmsToken: idms,
        extraPlist: outExtra,
        dsPersonId: dsid.isEmpty ? adsid : dsid,
        countryCode: cc,
        storeFront: sf
    )
}
