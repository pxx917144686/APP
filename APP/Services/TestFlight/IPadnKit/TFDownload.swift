import Foundation
import AppleAuth

public enum TFDownload {

    public struct Report: Sendable {
        public var bundle: String
        public var declaredSize: Int?
        public var transportBytes: Int
        public var appleZipBytes: Int
        public var outputBytes: Int
        public var baseMembers: Int
        public var finalMembers: Int
        public var encryptedImages: Int
        public var clearImages: Int
        public var sinfPaths: [String]
        public var sinfSizes: [Int]
        public var output: URL
    }

    public static func envelope(dsid: String, headers: [String: String],
                                storeCookies: [String: String], udid: String) throws -> Data {
        let payload: [String: Any] = [
            "dsid": dsid,
            "headers": headers,
            "storeCookies": storeCookies,
            "udid": udid,
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private static func safeSegment(_ raw: String, fallback: String? = nil) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? (fallback ?? "") : trimmed
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0"),
              value != ".",
              value != ".." else {
            throw TFError.malformed("无效的目录名：\(raw)")
        }
        return value
    }

    public static func directoryURL(bundle: String) -> URL? {
        guard let safe = try? safeSegment(bundle),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent("TestFlight", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
    }

    public static func directory(bundle: String) throws -> URL {
        let safe = try safeSegment(bundle)
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("TestFlight", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public static func buildDirectory(bundle: String, buildID: String) throws -> URL {
        let safeBuild = try safeSegment(buildID, fallback: "unknown")
        let root = try directory(bundle: bundle)
            .appendingPathComponent(safeBuild, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func writeProductMeta(directory: URL, bundle: String, buildID: String,
                                 versionLabel: String?, bytes: Int, platform: String? = nil) {
        var payload: [String: Any] = [
            "bundleId": bundle,
            "buildId": buildID.isEmpty ? "unknown" : buildID,
            "version": versionLabel ?? "",
            "bytes": bytes,
            "downloadedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let platform, !platform.isEmpty {
            payload["platform"] = platform
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("product.json"), options: .atomic)
    }

    public static func run(bundle: String, context: Data, hardware20: Data,
                           identity: [String: String] = [:], metadata: Data? = nil,
                           expect: (members: Int, encrypted: Int)? = nil,
                           buildID: String = "",
                           versionLabel: String? = nil,
                           platform: String? = nil,
                           handle: TFTransferHandle = TFTransferHandle(),
                           maxConnections: Int? = nil,
                           progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in },
                           onActiveConnections: (@Sendable (Int) -> Void)? = nil,
                           stage: (@Sendable (String) -> Void)? = nil,
                           onForegroundFallback: (@Sendable () -> Void)? = nil,
                           refresh: (@Sendable () async -> Data?)? = nil,
                           log: @escaping @Sendable (String) -> Void) async throws -> Report {
        let root = try buildDirectory(bundle: bundle, buildID: buildID)
        let work = root.appendingPathComponent(".work", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let metadataData: Data
        if let metadata {
            metadataData = metadata
            log("install: using supplied metadata " + String(metadata.count) + " B")
        } else {
            let client = try await TestFlightClient.fromStoreCookies(context, transport: transport(log: log),
                                                                     options: options(headers: identity))
            log("install: client headers " + String(identity.count) + " ["
                + identity.keys.sorted().joined(separator: ",") + "]")
            log("install: request for " + bundle)
            metadataData = try await client.installMetadata(bundle: bundle)
            log("install: metadata " + String(metadataData.count) + " B")
        }

        if let sanitized = sanitizedDisplayMetadata(from: metadataData) {
            try? sanitized.write(to: root.appendingPathComponent("metadata.json"), options: .atomic)
        }
        let text = String(decoding: metadataData, as: UTF8.self)
        log("install: metadata has "
            + (text.contains("dpInfo") ? "dpInfo" : "NO dpInfo")
            + ", " + (text.contains("packages") ? "packages" : "no packages")
            + ", " + (text.contains("https://") ? "url" : "no url"))
        var urlString: String?
        var dpInfo: Data?
        var declaredSize: Int?
        walkMetadata(metadataData, url: &urlString, dpInfo: &dpInfo, size: &declaredSize, log: log)
        guard let urlString, let url = URL(string: urlString) else {
            throw TFError.malformed("install: 元数据里没有 url")
        }
        log("install: url host=" + (url.host ?? "-") + " dpInfo="
            + (dpInfo.map { String($0.count) + " B" } ?? "null")
            + " size=" + (declaredSize.map(String.init) ?? "-"))

        if handle.isPaused {
            try await handle.waitWhilePaused()
            if handle.isCancelled { throw TFError.cancelled }
            stage?("downloading")
        }
        let transportURL = work.appendingPathComponent(bundle + "-transport.bin")
        let scratchURL = root.appendingPathComponent(bundle + "-partial.bin")
        let connections = max(1, maxConnections ?? DownloadConnectionSettings.defaultValue)
        let allowsSystemProxy = !(TFNet.mode == .direct || (TFNet.mode == .auto && TFNet.didBypassProxy))
        let currentURL = url
        let transfer = try await TFTransfer.downloadSegmented(url: currentURL, to: transportURL,
                                                              scratchURL: scratchURL,
                                                              handle: handle,
                                                              maxConnections: connections,
                                                              allowsSystemProxy: allowsSystemProxy,
                                                              progress: progress,
                                                              onActiveConnections: onActiveConnections,
                                                              onResume: { stage?("downloading") },
                                                              refresh: {
            guard let refresh else { return nil }
            guard let renewed = await refresh() else { return nil }
            var next: String?
            var info: Data?
            var size: Int?
            walkMetadata(renewed, url: &next, dpInfo: &info, size: &size, log: nil)
            return next.flatMap(URL.init(string:))
        }, log: log)
        let transportBytes = transfer.bytes
        _ = currentURL

        if handle.isCancelled {
            try? FileManager.default.removeItem(at: work)
            throw TFError.cancelled
        }
        stage?("verifying")

        let appleZipBytes: Int
        let base: URL
        var baseMembers = 0
        var encryptedImages = 0
        var clearImages = 0
        if let dpInfo, dpInfo.count == 88 {
            let appleZip = work.appendingPathComponent(bundle + "-applezip.ipa")
            _ = try StoreSupport.unwrapTestFlight(source: transportURL, destination: appleZip,
                                                  hardware20: hardware20, dpInfo88: dpInfo)
            appleZipBytes = fileSize(appleZip)
            let first = try firstBytes(of: appleZip, count: 4)
            let isZip = first == Data([0x50, 0x4B, 0x03, 0x04])
            log("transport: applezip " + String(appleZipBytes) + " B, head "
                + first.map { String(format: "%02X", $0) }.joined() + (isZip ? " (PK ok)" : " (PK MISSING)"))
            guard isZip else { throw TFError.malformed("applezip 首块不是 PK\\x03\\x04") }
            let normalized = work.appendingPathComponent(bundle + "-base.ipa")
            let info = try StoreSupport.normalizeIPA(source: appleZip, destination: normalized,
                                                     expectedBundle: bundle)
            base = normalized
            log("applezip: base IPA " + String(fileSize(base)) + " B, members "
                + String(info.members) + ", encrypted " + String(info.encryptedImages)
                + ", clear " + String(info.clearImages))
            baseMembers = Int(info.members)
            encryptedImages = Int(info.encryptedImages)
            clearImages = Int(info.clearImages)
        } else {
            let first = try firstBytes(of: transportURL, count: 4)
            let isZip = first == Data([0x50, 0x4B, 0x03, 0x04])
            log("transport: no dpInfo, CDN file head "
                + first.map { String(format: "%02X", $0) }.joined() + (isZip ? " (PK ok)" : " (PK MISSING)"))
            guard isZip else { throw TFError.malformed("无 dpInfo 且 CDN 文件不是 zip") }
            let copy = work.appendingPathComponent(bundle + "-base.ipa")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: transportURL, to: copy)
            appleZipBytes = 0
            base = copy
            baseMembers = TFSINF.memberCount(ipa: base)
            log("plain: base IPA " + String(fileSize(base)) + " B, members " + String(baseMembers))
            guard baseMembers > 0 else { throw TFError.malformed("CDN zip 打不开") }
            if encryptedImages == 0 {
                var skipped: [String] = []
                encryptedImages = TFSINF.encryptedMachOCount(ipa: base, skipped: &skipped)
                log("plain: encrypted Mach-O " + String(encryptedImages)
                    + " [" + skipped.joined(separator: ",") + "]")
            }
        }

        let shippedSinf = TFSINF.members(ipa: base).filter {
            $0.contains("/SC_Info/") && $0.hasSuffix(".sinf")
        }
        var sinf = TFSINF.Report()
        if !shippedSinf.isEmpty {
            log("sinf: kept as shipped (" + String(shippedSinf.count) + " member(s))")
        } else if encryptedImages > 0 {
            sinf = try TFSINF.install(metadata: metadataData, ipa: base)
            guard !sinf.paths.isEmpty else {
                throw TFError.malformed("SINF: 加密包在 install metadata 中没有可用 sinf，产物无法安装")
            }
            log("sinf: " + String(sinf.paths.count) + " member(s) (added " + String(sinf.addedCount) + ") "
                + sinf.paths.joined(separator: ",") + " sizes "
                + sinf.sizes.map(String.init).joined(separator: ","))
        } else {
            log("sinf: skipped (unencrypted build without SC_Info)")
        }
        let addedSinfCount = sinf.addedCount
        let finalMembers = TFSINF.memberCount(ipa: base)
        log("sinf: after install members " + String(finalMembers)
            + " (base " + String(baseMembers) + " + " + String(addedSinfCount) + ")")
        guard finalMembers == baseMembers + addedSinfCount else {
            throw TFError.malformed("成员数不符：" + String(finalMembers) + " != "
                                    + String(baseMembers) + " + " + String(addedSinfCount))
        }

        if handle.isCancelled {
            try? FileManager.default.removeItem(at: work)
            throw TFError.cancelled
        }

        let output = root.appendingPathComponent(bundle + ".ipa")
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: base, to: output)
        do {
            try validate(output: output, bundle: bundle, transportBytes: transportBytes,
                         declaredSize: declaredSize, baseMembers: baseMembers,
                         addedSinfCount: addedSinfCount,
                         normalizedEncryptedImages: encryptedImages,
                         expect: expect, metadata: metadataData, log: log)
        } catch {
            try? FileManager.default.removeItem(at: output)
            log("validate: 产物已删除，原因：" + error.localizedDescription)
            throw error
        }
        try? FileManager.default.removeItem(at: work)
        if let plist = iTunesMetadataPlist(metadata: metadataData, bundle: bundle, version: versionLabel),
           FastZipArchive.shared.addFiles(toZipAtPath: output.path,
                                          files: [(path: "iTunesMetadata.plist", data: plist)]) {
            log("metadata: iTunesMetadata.plist " + String(plist.count) + " B")
        }
        let outputBytes = fileSize(output)
        writeProductMeta(directory: root, bundle: bundle, buildID: buildID,
                         versionLabel: versionLabel, bytes: outputBytes, platform: platform)
        log("done: " + output.lastPathComponent + " " + String(outputBytes) + " B, members "
            + String(finalMembers) + " (encrypted IPA, kept out of the decrypt pipeline)")

        return Report(bundle: bundle, declaredSize: declaredSize, transportBytes: transportBytes,
                      appleZipBytes: appleZipBytes, outputBytes: outputBytes,
                      baseMembers: baseMembers, finalMembers: finalMembers,
                      encryptedImages: encryptedImages, clearImages: clearImages,
                      sinfPaths: sinf.paths, sinfSizes: sinf.sizes, output: output)
    }

    static func iTunesMetadataPlist(metadata: Data, bundle: String, version: String?) -> Data? {
        var title = bundle
        var short = version ?? ""
        if let root = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any] {
            let payload = (root["data"] as? [String: Any]) ?? root
            if let framework = payload["framework"] as? [String: Any] {
                if let name = framework["displayName"] as? String, !name.isEmpty {
                    title = name
                } else if let name = framework["name"] as? String, !name.isEmpty {
                    title = name
                }
                if short.isEmpty {
                    short = (framework["shortVersion"] as? String)
                        ?? (framework["cfBundleShortVersion"] as? String)
                        ?? ""
                }
            }
        }
        let dictionary: [String: Any] = [
            "appleId": bundle,
            "artistId": 0,
            "artistName": title,
            "bundleId": bundle,
            "bundleVersion": short,
            "copyright": "Copyright © 2025",
            "drmVersionNumber": 0,
            "fileExtension": "ipa",
            "fileName": title + ".ipa",
            "genre": "Productivity",
            "genreId": 6007,
            "itemId": 0,
            "itemName": title,
            "kind": "software",
            "playlistName": "iOS Apps",
            "price": 0.0,
            "priceDisplay": "Free",
            "rating": "4+",
            "releaseDate": "2025-01-01T00:00:00Z",
            "s": 143441,
            "softwareIcon57x57URL": "",
            "softwareIconNeedsShine": false,
            "softwareSupportedDeviceIds": [1, 2],
            "softwareVersionBundleId": bundle,
            "softwareVersionExternalIdentifier": 0,
            "softwareVersionExternalIdentifiers": [],
            "subgenres": [],
            "vendorId": 0,
            "versionRestrictions": 0,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    static func validate(output: URL, bundle: String, transportBytes: Int, declaredSize: Int?,
                         baseMembers: Int, addedSinfCount: Int,
                         normalizedEncryptedImages: Int = 0,
                         expect: (members: Int, encrypted: Int)?,
                         metadata: Data, log: @escaping @Sendable (String) -> Void) throws {
        if let declaredSize, declaredSize > 0, transportBytes != declaredSize {
            log("validate: 下载 " + String(transportBytes) + " B != packageSizeBytes " + String(declaredSize))
            throw TFError.malformed("下载长度与 install 元数据不一致")
        }
        guard let found = TFSINF.bundleID(ipa: output) else {
            throw TFError.malformed("validate: 读不到 CFBundleIdentifier")
        }
        guard found.caseInsensitiveCompare(bundle) == .orderedSame else {
            log("validate: bundle " + found + " != " + bundle)
            throw TFError.malformed("产物 bundle 与请求不一致")
        }
        let members = TFSINF.memberCount(ipa: output)
        guard members == baseMembers + addedSinfCount else {
            dumpPackages(metadata: metadata, log: log)
            throw TFError.malformed("成员数 " + String(members) + " != base " + String(baseMembers)
                                    + " + sinf " + String(addedSinfCount))
        }
        if let expect, members != expect.members {
            dumpPackages(metadata: metadata, log: log)
            log("validate: 成员数 " + String(members) + " != --tf-expect " + String(expect.members))
            throw TFError.malformed("产物成员数与 --tf-expect 不符")
        }
        var skipped: [String] = []
        let scannedEncrypted = TFSINF.encryptedMachOCount(ipa: output, skipped: &skipped)
        let encryptedNames = skipped.filter { $0.hasPrefix("enc:") }.map { String($0.dropFirst(4)) }
        let oversizedSkipped = skipped.filter { !$0.hasPrefix("enc:") }
        let encrypted = (scannedEncrypted == 0 && !oversizedSkipped.isEmpty && normalizedEncryptedImages > 0)
            ? normalizedEncryptedImages
            : max(scannedEncrypted, normalizedEncryptedImages)
        log("validate: bundle ok, members " + String(members) + " (base " + String(baseMembers)
            + " + sinf " + String(addedSinfCount) + "), encrypted Mach-O " + String(encrypted)
            + " (scanned " + String(scannedEncrypted) + ", normalized " + String(normalizedEncryptedImages)
            + ") [" + encryptedNames.joined(separator: ",") + "]")
        if !oversizedSkipped.isEmpty {
            log("validate: 跳过大文件 " + oversizedSkipped.joined(separator: ","))
        }
        if let expect, encrypted != expect.encrypted {
            dumpPackages(metadata: metadata, log: log)
            log("validate: 加密 Mach-O " + String(encrypted) + " != --tf-expect " + String(expect.encrypted))
            throw TFError.malformed("加密镜像数与 --tf-expect 不符")
        }
        guard encrypted > 0 else { throw TFError.malformed("产物里没有加密 Mach-O") }
        let hasSinf = TFSINF.members(ipa: output).contains {
            $0.contains("/SC_Info/") && $0.hasSuffix(".sinf")
        }
        guard hasSinf else {
            throw TFError.malformed("产物有加密 Mach-O 但没有 SC_Info/*.sinf，无法安装")
        }
    }

    static func sanitizedDisplayMetadata(from data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (root["data"] as? [String: Any]) ?? root
        guard let framework = payload["framework"] as? [String: Any] else { return nil }
        let allowedKeys: Set<String> = [
            "displayName", "testNotes", "developerName",
            "shortVersion", "cfBundleShortVersion",
            "bundleVersion", "cfBundleVersion",
            "bundleId", "bundleID", "name",
        ]
        var safeFramework: [String: Any] = [:]
        for (key, value) in framework where allowedKeys.contains(key) {
            safeFramework[key] = value
        }
        guard !safeFramework.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["data": ["framework": safeFramework]],
                                           options: [.sortedKeys])
    }

    static func dumpPackages(metadata: Data, log: @escaping @Sendable (String) -> Void) {
        guard let root = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any] else { return }
        let payload = (root["data"] as? [String: Any]) ?? root
        guard let packages = payload["packages"] as? [String: Any] else {
            log("packages: 元数据里没有 packages")
            return
        }
        log("packages keys [" + packages.keys.sorted().joined(separator: ",") + "]")
        for (variant, value) in packages.sorted(by: { $0.key < $1.key }) {
            guard let dictionary = value as? [String: Any] else {
                log("  " + variant + " = <" + String(describing: type(of: value)) + ">")
                continue
            }
            for (key, item) in dictionary.sorted(by: { $0.key < $1.key }) {
                let lower = key.lowercased()
                if lower.contains("dpinfo") || lower.contains("sinf") || lower.contains("token") || lower.contains("key") {
                    let count = (item as? String)?.count ?? 0
                    log("  " + variant + "." + key + " = ‹redacted \(count) chars›")
                } else if let text = item as? String {
                    if let parsed = URL(string: text), parsed.scheme?.hasPrefix("http") == true {
                        log("  " + variant + "." + key + " = " + (parsed.host ?? "-") + parsed.path)
                    } else {
                        log("  " + variant + "." + key + " = " + (text.count > 80 ? String(text.prefix(80)) + "…" : text))
                    }
                } else {
                    log("  " + variant + "." + key + " = " + String(describing: item))
                }
            }
        }
    }

    static func options(headers: [String: String]) -> TestFlightOptions {
        var merged = headers
        merged["User-Agent"] = TFConstants.storeUserAgent
        merged["X-Apple-TestFlight-iOS"] = "0"
        merged["X-Apple-Rosetta-Available"] = "0"
        merged["X-Apple-Device-Model"] = TFConstants.macModel
        merged["X-Apple-TA-Device"] = TFConstants.macModel
        return TestFlightOptions(headers: merged, deviceModel: TFConstants.macModel, deviceName: "iPadn")
    }

    static func transport(log: @escaping @Sendable (String) -> Void) -> HTTPTransport {
        { request in
            var request = request
            request.timeoutInterval = 60
            let (data, http) = try await TFNet.data(for: request, cookieStorage: .shared, acceptCookies: true)
            let status = http.statusCode
            let host = request.url?.host ?? "?"
            let path = request.url?.path ?? "/"
            log("  request " + (request.httpMethod ?? "GET") + " " + host + path
                + " -> " + String(status) + ", " + String(data.count) + " B")
            if request.httpMethod == "POST", let body = request.httpBody,
               let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                log("    body " + String(body.count) + " B keys "
                    + object.keys.sorted().joined(separator: ","))
            }
            if status >= 400, !data.isEmpty {
                let text = String(decoding: data.prefix(200), as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: " ")
                log("    body: " + text)
            }
            let headers = http.allHeaderFields.compactMap { key, value -> HTTPHeader? in
                guard let key = key as? String else { return nil }
                return HTTPHeader(key, String(describing: value))
            }
            return HTTPResponse(status: status, body: data, headers: headers)
        }
    }

    static func walkMetadata(_ data: Data, url: inout String?, dpInfo: inout Data?, size: inout Int?,
                             log: (@Sendable (String) -> Void)? = nil) {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return }

        func decodeDPInfo(_ value: Any?, trail: String) -> Data? {
            guard let text = value as? String else { return nil }
            let decoded = Data(base64Encoded: text)
            log?("  dpInfo at " + trail + ": string " + String(text.count)
                 + ", base64 -> " + String(decoded?.count ?? -1))
            guard let decoded, decoded.count == 88 else { return nil }
            return decoded
        }

        func decodePackageSize(_ dictionary: [String: Any], allowGenericSize: Bool) -> Int? {
            let keys = allowGenericSize ? ["packageSizeBytes", "packageSize", "size"] : ["packageSizeBytes", "packageSize"]
            for key in keys {
                if let number = dictionary[key] as? NSNumber, number.intValue > 0 {
                    return number.intValue
                }
            }
            return nil
        }

        if let rootDict = root as? [String: Any] {
            let payload = (rootDict["data"] as? [String: Any]) ?? rootDict
            let payloadTrail = (rootDict["data"] as? [String: Any]) != nil ? "/data" : ""
            if let packages = payload["packages"] as? [String: Any] {
                let orderedKeys = ["full"] + packages.keys.filter { $0 != "full" }.sorted()
                for variant in orderedKeys {
                    guard let pkg = packages[variant] as? [String: Any],
                          let candidateURL = pkg["url"] as? String,
                          candidateURL.hasPrefix("https://") else { continue }
                    let baseTrail = payloadTrail + "/packages/" + variant
                    url = candidateURL
                    log?("  url at " + baseTrail + "/url")
                    if let decoded = decodeDPInfo(pkg["dpInfo"], trail: baseTrail + "/dpInfo") {
                        dpInfo = decoded
                    } else if let sibling = decodeDPInfo(payload["dpInfo"], trail: payloadTrail + "/dpInfo") {
                        dpInfo = sibling
                    }
                    if let pkgSize = decodePackageSize(pkg, allowGenericSize: true) {
                        size = pkgSize
                    }
                    return
                }
            }
        }

        func walk(_ node: Any, _ trail: String) {
            if let dictionary = node as? [String: Any] {
                let hasURLHere: Bool = {
                    guard let text = dictionary["url"] as? String else { return false }
                    return text.hasPrefix("https://")
                }()
                if hasURLHere, url == nil, let text = dictionary["url"] as? String {
                    url = text
                    log?("  url at " + trail + "/url")
                    if dpInfo == nil, let decoded = decodeDPInfo(dictionary["dpInfo"], trail: trail + "/dpInfo") {
                        dpInfo = decoded
                    }
                    if size == nil, let pkgSize = decodePackageSize(dictionary, allowGenericSize: true) {
                        size = pkgSize
                    }
                }
                for key in dictionary.keys.sorted() {
                    guard let value = dictionary[key] else { continue }
                    let here = trail + "/" + key
                    if key == "dpInfo", dpInfo == nil, let decoded = decodeDPInfo(value, trail: here) {
                        dpInfo = decoded
                    } else if ["packageSizeBytes", "packageSize"].contains(key),
                              let number = value as? NSNumber, number.intValue > 0, size == nil {
                        size = number.intValue
                    }
                    walk(value, here)
                }
            } else if let array = node as? [Any] {
                for (index, value) in array.enumerated() { walk(value, trail + "[" + String(index) + "]") }
            }
        }
        walk(root, "")
    }

    static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    static func firstBytes(of url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }
}
