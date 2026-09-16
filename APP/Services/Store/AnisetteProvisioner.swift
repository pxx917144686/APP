import Foundation

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { self.value = v }
}

struct AnisetteData {
    let machineID: String
    let oneTimePassword: String
    let localUserID: String
    let routingInfo: String
    let deviceID: String
    let serialNumber: String
    let clientTime: String
    let locale: String
    let timezone: String
    let deviceUDID: String

    func cpdDictionary() -> [String: Any] {
        return [
            "bootstrap": true,
            "icscrec": true,
            "pbe": false,
            "prkgen": true,
            "svct": "iCloud",
            "X-Apple-I-MD": machineID,
            "X-Apple-I-MD-M": oneTimePassword,
            "X-Apple-I-MD-LU": localUserID,
            "X-Apple-I-MD-RINFO": routingInfo,
            "X-Apple-I-Client-Time": clientTime,
            "X-Apple-I-TimeZone": timezone,
            "X-Apple-Locale": locale,
            "X-Mme-Device-Id": deviceUDID,
            "X-Apple-I-SRL-NO": serialNumber
        ]
    }

    func aniHeaders() -> [String: String] {
        return [
            "X-Apple-I-MD": machineID,
            "X-Apple-I-MD-M": oneTimePassword,
            "X-Apple-I-MD-LU": localUserID,
            "X-Apple-I-MD-RINFO": routingInfo,
            "X-Apple-I-Client-Time": clientTime,
            "X-Apple-I-TimeZone": timezone,
            "X-Apple-Locale": locale,
            "X-Mme-Device-Id": deviceUDID,
            "X-Apple-I-SRL-NO": serialNumber
        ]
    }
}

final class AnisetteProvisioner {
    static let shared = AnisetteProvisioner()

    private struct Server: Equatable, Hashable {
        let name: String
        let base: String
        var rootURL: String { base.hasSuffix("/") ? base : base + "/" }
        var wsURL: String {
            let https = base.replacingOccurrences(of: "http://", with: "ws://").replacingOccurrences(of: "https://", with: "wss://")
            return (https.hasSuffix("/") ? https : https + "/") + "v3/provisioning_session"
        }
        var getHeadersURL: String { rootURL + "v3/get_headers" }
    }

    private let defaultServers: [Server] = [
        Server(name: "ani.sidestore.io",         base: "https://ani.sidestore.io"),
        Server(name: "ani3server.fly.dev",        base: "https://ani3server.fly.dev"),
        Server(name: "anisette.crystall1ne.dev",  base: "https://anisette.crystall1ne.dev"),
        Server(name: "Macley",                    base: "http://5.249.163.88:6969"),
        Server(name: "ani.sidestore.app",         base: "https://ani.sidestore.app"),
        Server(name: "ani.sidestore.zip",         base: "https://ani.sidestore.zip"),
        Server(name: "nyc1.provisioning.nickel.dev", base: "https://nyc1.provisioning.nickel.dev"),
        Server(name: "ani.846969.xyz",            base: "https://ani.846969.xyz"),
        Server(name: "ani.npeg.us",               base: "https://ani.npeg.us"),
        Server(name: "ani.xu30.top",              base: "https://ani.xu30.top"),
        Server(name: "ani.neoarz.com",            base: "https://ani.neoarz.com"),
        Server(name: "ani.owoellen.rocks",        base: "https://ani.owoellen.rocks"),
        Server(name: "ani.jaydenha.uk",           base: "https://ani.jaydenha.uk"),
        Server(name: "anisette.wedotstud.io",     base: "https://anisette.wedotstud.io"),
        Server(name: "Marcus-render",             base: "https://anisette-v3-server-p72s.onrender.com")
    ]

    private let session: URLSession
    private var cachedData: AnisetteData?
    private var failedServers = Set<String>()
    private var loadedServers: [Server]?
    private let deviceUDID = UUID().uuidString.uppercased()
    private let userID = UUID().uuidString.uppercased()

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 45
        cfg.httpShouldSetCookies = false
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        cfg.tlsMaximumSupportedProtocolVersion = .TLSv13
        cfg.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
            "HTTPProxy": "",
            "HTTPSProxy": "",
            "SOCKSProxy": ""
        ]
        session = URLSession(configuration: cfg)
    }

    private func activeServers() async -> [Server] {
        if let s = loadedServers { return s }
        let dynamic: [Server]? = try? await fetchDynamicServers()
        var list = dynamic ?? defaultServers
        var seen = Set<String>()
        list = list.filter { seen.insert($0.name).inserted }
        loadedServers = list
        return list
    }

    private func fetchDynamicServers() async throws -> [Server] {
        guard let url = URL(string: "https://raw.githubusercontent.com/SideStore/anisette-servers/refs/heads/main/servers.json") else {
            return []
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.setValue("application/vnd.github.v3.raw", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else { return [] }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = j["servers"] as? [[String: Any]] else { return [] }
        var out: [Server] = []
        for item in list {
            guard let name = item["name"] as? String, var addr = item["address"] as? String else { continue }
            if addr.hasSuffix("/") { addr.removeLast() }
            out.append(Server(name: name, base: addr))
        }
        return out
    }

    func getAnisette() async throws -> AnisetteData {
        if let cached = cachedData { return cached }
        failedServers.removeAll()
        let servers = await activeServers()
        var lastError: Error?

        for s in servers {
            do {
                let r = try await provisionRootGet(server: s)
                cachedData = r
                return r
            } catch {
                failedServers.insert(s.name)
                lastError = error
            }
        }

        for s in servers {
            if failedServers.contains(s.name + "#ws") { continue }
            do {
                let r = try await provisionWSOnce(server: s)
                cachedData = r
                return r
            } catch {
                failedServers.insert(s.name + "#ws")
                lastError = error
            }
        }

        if let fb = try? await provisionFromDiskCache() {
            cachedData = fb
            return fb
        }
        for s in servers {
            if let d = try? await provisionHTTPDirect(server: s) {
                cachedData = d
                return d
            }
        }
        throw StoreError.networkError(lastError ?? NSError(domain: "Anisette", code: -1))
    }

    private func provisionRootGet(server: Server) async throws -> AnisetteData {
        guard let url = URL(string: server.rootURL) else {
            throw StoreError.networkError(NSError(domain: "AnisetteRoot", code: -1))
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 7)
        req.httpMethod = "GET"
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("akd/1.0 CFNetwork/1408.0.4 Darwin/22.5.0", forHTTPHeaderField: "User-Agent")
        req.setValue(GSA_CLIENT_INFO, forHTTPHeaderField: "X-MMe-Client-Info")
        let (data, resp) = try await session.data(for: req)
        guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw StoreError.networkError(NSError(domain: "AnisetteRoot", code: -status))
        }
        var out: [String: String] = [:]
        for (k, v) in h.allHeaderFields {
            let key = "\(k)"
            if key.hasPrefix("X-Apple-I-MD") || key == "X-Apple-I-Client-Time" || key == "X-Apple-I-TimeZone" || key == "X-Apple-Locale" {
                out[key] = "\(v)"
            }
        }
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in j {
                if out[k] == nil { out[k] = "\(v)" }
            }
        }
        guard let md = out["X-Apple-I-MD"], !md.isEmpty,
              let md_m = out["X-Apple-I-MD-M"], !md_m.isEmpty else {
            throw StoreError.networkError(NSError(domain: "AnisetteRoot", code: -2))
        }
        return try buildAnisetteData(headers: out, rinfo: out["X-Apple-I-MD-RINFO"])
    }

    private func provisionWSOnce(server: Server) async throws -> AnisetteData {
        guard let wsURL = URL(string: server.wsURL) else {
            throw StoreError.networkError(NSError(domain: "AnisetteWS", code: -2))
        }
        let identifier = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let adiPbBox: Box<String?> = Box(nil)
        let rinfoBox: Box<String?> = Box(nil)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = session.webSocketTask(with: wsURL)
            let resumed = NSLock()
            var resumedFlag = false
            func resumeOnce(_ result: Result<Void, Error>) {
                resumed.lock()
                if resumedFlag {
                    resumed.unlock()
                    return
                }
                resumedFlag = true
                resumed.unlock()
                switch result {
                case .success: cont.resume()
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            let timeoutWork = DispatchWorkItem {
                task.cancel(with: .goingAway, reason: nil)
                resumeOnce(.failure(StoreError.networkError(NSError(domain: "AnisetteWS", code: -3))))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 22, execute: timeoutWork)
            Task {
                do {
                    task.resume()
                    let spim = try await startProvisioning()
                    var done = false
                    while !done {
                        let msg = try await receiveMessage(task: task)
                        guard let json = msg as? [String: Any] else { continue }
                        let result = json["result"] as? String
                        switch result {
                        case "GiveIdentifier":
                            try await sendMessage(task: task, data: ["identifier": identifier])
                        case "GiveStartProvisioningData":
                            try await sendMessage(task: task, data: ["spim": spim])
                        case "GiveEndProvisioningData":
                            if let cpim = json["cpim"] as? String {
                                let (ptm, tk, ri) = try await endProvisioning(cpim: cpim)
                                rinfoBox.value = ri
                                try await sendMessage(task: task, data: ["ptm": ptm, "tk": tk])
                            }
                        case "ProvisioningSuccess":
                            adiPbBox.value = json["adi_pb"] as? String
                            done = true
                        case "Timeout":
                            timeoutWork.cancel()
                            task.cancel()
                            resumeOnce(.failure(StoreError.networkError(NSError(domain: "AnisetteWS", code: -5))))
                            return
                        case "EndProvisioningError", "StartProvisioningError", "ProvisioningError":
                            timeoutWork.cancel()
                            task.cancel()
                            resumeOnce(.failure(StoreError.networkError(NSError(domain: "AnisetteWS", code: -6))))
                            return
                        default:
                            break
                        }
                    }
                    timeoutWork.cancel()
                    task.cancel()
                    if adiPbBox.value != nil {
                        resumeOnce(.success(()))
                    } else {
                        resumeOnce(.failure(StoreError.networkError(NSError(domain: "AnisetteWS", code: -7))))
                    }
                } catch {
                    timeoutWork.cancel()
                    task.cancel()
                    resumeOnce(.failure(error))
                }
            }
        }
        guard let adiPb = adiPbBox.value else {
            throw StoreError.networkError(NSError(domain: "AnisetteWS", code: -8))
        }
        let headers = try await fetchHeaders(headersURL: server.getHeadersURL, adiPb: adiPb, identifier: identifier)
        return try buildAnisetteData(headers: headers, rinfo: rinfoBox.value)
    }

    private func provisionFromDiskCache() async throws -> AnisetteData? {
        let fm = FileManager.default
        let possiblePaths = [
            NSTemporaryDirectory().appending("cached_anisette.json")
        ]
        for path in possiblePaths {
            guard fm.fileExists(atPath: path),
                  let data = fm.contents(atPath: path),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { continue }
            guard let md = j["X-Apple-I-MD"], !md.isEmpty,
                  let md_m = j["X-Apple-I-MD-M"], !md_m.isEmpty else { continue }
            return try buildAnisetteData(headers: j, rinfo: j["X-Apple-I-MD-RINFO"])
        }
        return nil
    }

    private func provisionHTTPDirect(server: Server) async throws -> AnisetteData? {
        guard let url = URL(string: server.getHeadersURL) else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.httpMethod = "GET"
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(GSA_UA, forHTTPHeaderField: "User-Agent")
        req.setValue(GSA_CLIENT_INFO, forHTTPHeaderField: "X-MMe-Client-Info")
        let (data, resp) = try await session.data(for: req)
        var out: [String: String] = [:]
        if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            for (k, v) in http.allHeaderFields {
                let key = "\(k)"
                if key.hasPrefix("X-Apple-I-MD") { out[key] = "\(v)" }
            }
        }
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for k in ["X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-LU", "X-Apple-I-MD-RINFO", "X-Apple-I-Client-Time"] {
                if let v = j[k], out[k] == nil { out[k] = "\(v)" }
            }
        }
        guard let md = out["X-Apple-I-MD"], !md.isEmpty,
              let md_m = out["X-Apple-I-MD-M"], !md_m.isEmpty else {
            return nil
        }
        return try buildAnisetteData(headers: out, rinfo: nil)
    }

    private func buildAnisetteData(headers: [String: String], rinfo: String?) throws -> AnisetteData {
        let nowISO = iso8601Now()
        let loc = Locale.current.identifier
        let tz = TimeZone.current.identifier
        let userIdB64 = Data(userID.utf8).base64EncodedString()
        let data = AnisetteData(
            machineID: headers["X-Apple-I-MD"] ?? "",
            oneTimePassword: headers["X-Apple-I-MD-M"] ?? "",
            localUserID: headers["X-Apple-I-MD-LU"] ?? userIdB64,
            routingInfo: rinfo ?? headers["X-Apple-I-MD-RINFO"] ?? "17106176",
            deviceID: deviceUDID,
            serialNumber: "0",
            clientTime: headers["X-Apple-I-Client-Time"] ?? nowISO,
            locale: loc,
            timezone: tz,
            deviceUDID: deviceUDID
        )
        if data.machineID.isEmpty || data.oneTimePassword.isEmpty {
            throw StoreError.networkError(NSError(domain: "Anisette", code: -9))
        }
        return data
    }

    private func receiveMessage(task: URLSessionWebSocketTask) async throws -> Any? {
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { cont in
                    task.receive { result in
                        switch result {
                        case .success(let message):
                            switch message {
                            case .data(let d):
                                if let json = try? JSONSerialization.jsonObject(with: d) {
                                    cont.resume(returning: json)
                                } else {
                                    cont.resume(returning: nil)
                                }
                            case .string(let s):
                                if let d = s.data(using: .utf8),
                                   let json = try? JSONSerialization.jsonObject(with: d) {
                                    cont.resume(returning: json)
                                } else {
                                    cont.resume(returning: nil)
                                }
                            @unknown default:
                                cont.resume(returning: nil)
                            }
                        case .failure(let error):
                            cont.resume(throwing: error)
                        }
                    }
                }
            },
            onCancel: {
                task.cancel()
            }
        )
    }

    private func sendMessage(task: URLSessionWebSocketTask, data: [String: Any]) async throws {
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.send(.data(jsonData)) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    private func startProvisioning() async throws -> String {
        let bagURL = "https://gsa.apple.com/grandslam/GsService2/lookup"
        var req = URLRequest(url: URL(string: bagURL)!, timeoutInterval: 15)
        req.setValue(GSA_CLIENT_INFO, forHTTPHeaderField: "X-MMe-Client-Info")
        req.setValue("Xcode", forHTTPHeaderField: "User-Agent")
        let (bagData, _) = try await session.data(for: req)
        guard let bag = try? PropertyListSerialization.propertyList(from: bagData, options: [], format: nil) as? [String: Any],
              let urls = bag["urls"] as? [String: Any],
              let startURL = urls["midStartProvisioning"] as? String else {
            throw StoreError.networkError(NSError(domain: "Anisette", code: -10))
        }
        let body = try PropertyListSerialization.data(fromPropertyList: ["Header": [:], "Request": [:]], format: .xml, options: 0)
        var req2 = URLRequest(url: URL(string: startURL)!, timeoutInterval: 15)
        req2.httpMethod = "POST"
        req2.httpBody = body
        req2.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req2.setValue(GSA_UA, forHTTPHeaderField: "User-Agent")
        req2.setValue(GSA_CLIENT_INFO, forHTTPHeaderField: "X-MMe-Client-Info")
        req2.setValue("*/*", forHTTPHeaderField: "Accept")
        req2.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req2.setValue(deviceUDID, forHTTPHeaderField: "X-Mme-Device-Id")
        req2.setValue("0", forHTTPHeaderField: "X-Apple-I-MD-LU")
        req2.setValue("-10000", forHTTPHeaderField: "X-Apple-Baa-E")
        req2.setValue("2", forHTTPHeaderField: "X-Apple-Baa-Avail")
        req2.setValue(iso8601Now(), forHTTPHeaderField: "X-Apple-I-Client-Time")
        req2.setValue("akd", forHTTPHeaderField: "X-Apple-Client-App-Name")
        req2.setValue("-7066", forHTTPHeaderField: "X-Apple-Host-Baa-E")
        req2.setValue("AKAuthenticationError:-7066|com.apple.devicecheck.error.baa:-10000", forHTTPHeaderField: "X-Apple-Baa-UE")
        let (respData, _) = try await session.data(for: req2)
        guard let pl = try? PropertyListSerialization.propertyList(from: respData, options: [], format: nil) as? [String: Any],
              let resp = pl["Response"] as? [String: Any],
              let spim = resp["spim"] as? String else {
            throw StoreError.networkError(NSError(domain: "Anisette", code: -11))
        }
        return spim
    }

    private func endProvisioning(cpim: String) async throws -> (ptm: String, tk: String, rinfo: String) {
        let bagURL = "https://gsa.apple.com/grandslam/GsService2/lookup"
        var req = URLRequest(url: URL(string: bagURL)!, timeoutInterval: 15)
        req.setValue(GSA_CLIENT_INFO, forHTTPHeaderField: "X-MMe-Client-Info")
        req.setValue("Xcode", forHTTPHeaderField: "User-Agent")
        let (bagData, _) = try await session.data(for: req)
        guard let bag = try? PropertyListSerialization.propertyList(from: bagData, options: [], format: nil) as? [String: Any],
              let urls = bag["urls"] as? [String: Any],
              let endURL = urls["midFinishProvisioning"] as? String else {
            throw StoreError.networkError(NSError(domain: "Anisette", code: -12))
        }
        let body = try PropertyListSerialization.data(fromPropertyList: ["Header": [:], "Request": ["cpim": cpim]], format: .xml, options: 0)
        var req2 = URLRequest(url: URL(string: endURL)!, timeoutInterval: 15)
        req2.httpMethod = "POST"
        req2.httpBody = body
        req2.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req2.setValue(GSA_UA, forHTTPHeaderField: "User-Agent")
        req2.setValue(GSA_CLIENT_INFO, forHTTPHeaderField: "X-MMe-Client-Info")
        req2.setValue("*/*", forHTTPHeaderField: "Accept")
        req2.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req2.setValue(deviceUDID, forHTTPHeaderField: "X-Mme-Device-Id")
        req2.setValue(iso8601Now(), forHTTPHeaderField: "X-Apple-I-Client-Time")
        let (respData, _) = try await session.data(for: req2)
        guard let pl = try? PropertyListSerialization.propertyList(from: respData, options: [], format: nil) as? [String: Any],
              let resp = pl["Response"] as? [String: Any],
              let ptm = resp["ptm"] as? String,
              let tk = resp["tk"] as? String else {
            throw StoreError.networkError(NSError(domain: "Anisette", code: -13))
        }
        let rinfo = (resp["X-Apple-I-MD-RINFO"] as? String) ?? "17106176"
        return (ptm, tk, rinfo)
    }

    private func fetchHeaders(headersURL: String, adiPb: String, identifier: String) async throws -> [String: String] {
        var req = URLRequest(url: URL(string: headersURL)!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = try JSONSerialization.data(withJSONObject: ["adi_pb": adiPb, "identifier": identifier])
        req.httpBody = payload
        let (respData, resp) = try await session.data(for: req)
        var out: [String: String] = [:]
        if let http = resp as? HTTPURLResponse {
            for (k, v) in http.allHeaderFields {
                let key = "\(k)"
                if key.hasPrefix("X-Apple-I-MD") {
                    out[key] = "\(v)"
                }
            }
        }
        if let j = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] {
            for k in ["X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-LU", "X-Apple-I-MD-RINFO", "X-Apple-I-Client-Time"] {
                if let v = j[k] {
                    if out[k] == nil { out[k] = "\(v)" }
                }
            }
        }
        return out
    }

    private func iso8601Now() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date())
    }

    func reset() {
        cachedData = nil
        failedServers.removeAll()
    }
}
