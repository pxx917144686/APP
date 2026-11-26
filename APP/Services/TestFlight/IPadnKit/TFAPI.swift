import CryptoKit
import Foundation
import AppleAuth

public enum TFAPI {

    public static func authenticate(context: TFContext,
                                    log: @escaping @Sendable (String) -> Void) async throws -> TFSession {
        let path = "/v1/session/authenticate"
        var request = URLRequest(url: URL(string: TFConstants.host + path)!)
        request.httpMethod = "POST"
        request.httpBody = context.body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(TFConstants.agent, forHTTPHeaderField: "User-Agent")
        request.setValue("0", forHTTPHeaderField: "X-Apple-TestFlight-iOS")
        for (name, value) in context.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let amdm = context.headers["X-Apple-AMD-M"] ?? "-"
        let masked = amdm.count > 8 ? String(amdm.prefix(8)) + "…(" + String(amdm.count) + ")" : amdm
        log("authenticate: headers " + String(context.headers.count) + " ["
            + context.headers.keys.sorted().joined(separator: ",") + "]")
        log("authenticate: ua=[" + (context.headers["User-Agent"] ?? "-") + "]")
        log("authenticate: amdm=" + masked
            + " front=" + (context.headers["X-Apple-Store-Front"] ?? "-")
            + " tf-ios=" + (context.headers["X-Apple-TestFlight-iOS"] ?? "-")
            + " rosetta=" + (context.headers["X-Apple-Rosetta-Available"] ?? "-"))
        log("authenticate: posting \(context.body.count) B · \(context.summary)")

        let (data, response) = try await send(request)
        try ensure(response, data: data, path: path)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TFError.malformed("authenticate: 不是 JSON 对象")
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        guard let sessionID = firstString(in: payload, keys: ["sessionId", "sessionID", "session_id"]),
              !sessionID.isEmpty else {
            throw TFError.malformed("authenticate: 没有 sessionId（键：\(payload.keys.sorted().joined(separator: ","))）")
        }
        let dsid = firstString(in: payload, keys: ["dsid", "dsId", "DSID"]) ?? context.dsid
        let account = firstString(in: payload, keys: ["accountId", "accountID", "account_id"]) ?? ""
        log("authenticate: response keys [" + payload.keys.sorted().joined(separator: ",") + "]")
        log("authenticate: account " + (account.isEmpty ? "-" : String(account.prefix(8)) + "…")
            + " dsid " + String(dsid.count) + " digits")
        log("authenticate: ok, sessionId \(sessionID.count) chars")
        return TFSession(id: sessionID, dsid: dsid, account: account, baseHeaders: context.headers)
    }

    public static func catalog(session: TFSession,
                               log: @escaping @Sendable (String) -> Void) async throws -> [TFBetaApp] {
        let account = session.account.isEmpty ? session.dsid : session.account
        let path = "/v4/accounts/\(account)/apps?allDetailsCount=10000"
        let data = try await signedGET(path: path, session: session, log: log)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TFError.malformed("apps: response is not a JSON object")
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        let raw = (payload["apps"] as? [[String: Any]]) ?? (root["apps"] as? [[String: Any]]) ?? []
        let apps = raw.compactMap { item -> TFBetaApp? in
            guard let appID = firstString(in: item, keys: ["appId", "adamId", "id"]), !appID.isEmpty else { return nil }
            let name = firstString(in: item, keys: ["name", "appName", "bundleName"]) ?? appID
            let bundle = firstString(in: item, keys: ["bundleId", "bundleID"]) ?? ""
            let developer = firstString(in: item, keys: ["developerName", "providerName"]).map(TFAppDetail.cleanDeveloperName)
            let versions = (item["versions"] as? [[String: Any]]) ?? (item["builds"] as? [[String: Any]]) ?? []
            let latest = versions.compactMap { firstString(in: $0, keys: ["version", "shortVersion", "versionString"]) }.first
            log("  app " + name + " | id " + appID + " | bundle " + bundle
                + " | builds " + String(versions.count) + " | keys "
                + item.keys.sorted().joined(separator: ","))
            return TFBetaApp(id: appID, name: name, bundleID: bundle,
                             latestVersion: latest, buildCount: versions.count,
                             developerName: developer)
        }
        log("apps: \(apps.count) app(s), raw \(raw.count)")
        return apps
    }

    public static func iconTemplate(appID: String, session: TFSession,
                                    log: @escaping @Sendable (String) -> Void) async -> String? {
        await iconAsset(appID: appID, session: session, log: log)?.urlTemplate
    }

    public static func iconAsset(appID: String, session: TFSession,
                                 log: @escaping @Sendable (String) -> Void) async -> TFIconAsset? {
        await appDetailV3(appID: appID, session: session, log: log)?.iconAsset
    }

    public static func appDetailV3(appID: String, session: TFSession,
                                   log: @escaping @Sendable (String) -> Void) async -> TFAppDetail? {
        await appDetailV3(appID: appID, fallbackName: nil, fallbackDeveloper: nil,
                          isPhone: true, session: session, log: log)
    }

    public static func appDetailV3(appID: String,
                                   fallbackName: String?,
                                   fallbackDeveloper: String?,
                                   isPhone: Bool = true,
                                   session: TFSession,
                                   log: @escaping @Sendable (String) -> Void) async -> TFAppDetail? {
        let account = session.account.isEmpty ? session.dsid : session.account
        let primaryPath = "/v3/accounts/\(account)/apps/\(appID)?allDetailsCount=10000"
        do {
            let data = try await signedGET(path: primaryPath, session: session, log: log)
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let payload = (root["data"] as? [String: Any]) ?? (root["platforms"] != nil ? root : nil) {
                return parseDetailPayload(
                    payload,
                    appID: appID,
                    fallbackName: fallbackName,
                    fallbackDeveloper: fallbackDeveloper,
                    isPhone: isPhone
                )
            }
            return nil
        } catch let TFError.http(status, _, body) where status == 404 || status == 410 {
            log("detail \(appID): v3 HTTP \(status) \(body.prefix(120)) -> 归入以前测试过")
            let publicIcon = await TFIcon.publicArtworkAsset(appID: appID, log: log)
            return TFAppDetail(
                appID: appID,
                name: fallbackName ?? appID,
                bundleID: "",
                developerName: TFAppDetail.cleanDeveloperName(fallbackDeveloper ?? ""),
                buildID: "",
                shortVersion: "",
                buildVersion: "",
                expirationISO: nil,
                releaseDateISO: nil,
                whatsNew: nil,
                description: nil,
                fileSizeBytes: nil,
                fileSizeUncompressedBytes: nil,
                compatibilityStatement: nil,
                supportEmail: nil,
                shareURL: nil,
                privacyPolicyURL: nil,
                supportedDevices: nil,
                termsOfService: nil,
                availability: .previouslyTested,
                incompatiblePlatforms: nil,
                iconAsset: publicIcon
            )
        } catch {
            log("detail \(appID): \(shortText(error))")
            return nil
        }
    }

    public static func allAppDetailsV3(for catalogApps: [TFBetaApp],
                                       isPhone: Bool = true,
                                       session: TFSession,
                                       log: @escaping @Sendable (String) -> Void) async -> [String: TFAppDetail] {
        guard !catalogApps.isEmpty else { return [:] }
        let byID = Dictionary(uniqueKeysWithValues: catalogApps.map { ($0.id, $0) })
        let account = session.account.isEmpty ? session.dsid : session.account
        let path = "/v3/accounts/\(account)/apps?allDetailsCount=10000"
        var results: [String: TFAppDetail] = [:]
        do {
            let data = try await signedGET(path: path, session: session, log: log)
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            let items: [[String: Any]]
            if let direct = root["data"] as? [[String: Any]] {
                items = direct
            } else if let container = root["data"] as? [String: Any],
                      let nested = container["apps"] as? [[String: Any]] {
                items = nested
            } else {
                items = (root["apps"] as? [[String: Any]]) ?? []
            }
            for item in items {
                guard let id = firstString(in: item, keys: ["appAdamId", "appId", "adamId", "id"]),
                      !id.isEmpty else { continue }
                let catalogApp = byID[id]
                let detail = parseDetailPayload(
                    item,
                    appID: id,
                    fallbackName: catalogApp?.name,
                    fallbackDeveloper: catalogApp?.developerName,
                    isPhone: isPhone
                )
                results[id] = detail
            }
            for app in catalogApps where results[app.id] == nil {
                let publicIcon = await TFIcon.publicArtworkAsset(appID: app.id, log: log)
                results[app.id] = TFAppDetail(
                    appID: app.id,
                    name: app.name,
                    bundleID: app.bundleID,
                    developerName: TFAppDetail.cleanDeveloperName(app.developerName ?? ""),
                    buildID: "",
                    shortVersion: "",
                    buildVersion: "",
                    expirationISO: nil,
                    releaseDateISO: nil,
                    whatsNew: nil,
                    description: nil,
                    fileSizeBytes: nil,
                    fileSizeUncompressedBytes: nil,
                    compatibilityStatement: nil,
                    supportEmail: nil,
                    shareURL: nil,
                    privacyPolicyURL: nil,
                    supportedDevices: nil,
                    termsOfService: nil,
                    availability: .previouslyTested,
                    incompatiblePlatforms: nil,
                    iconAsset: publicIcon
                )
            }
            log("v3 bulk details: \(items.count) active/archived, \(catalogApps.count - items.count) retired")
        } catch {
            log("v3 bulk details failed (\(shortText(error))), falling back to per-app fetch")
        }
        return results
    }

    public static func localizedValue(from raw: Any?,
                                      preferredLanguages: [String] = Locale.preferredLanguages) -> String? {
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let dict = raw as? [String: Any], !dict.isEmpty else { return nil }
        var normalized: [String: String] = [:]
        for (k, v) in dict {
            guard let text = v as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            normalized[k.lowercased().replacingOccurrences(of: "_", with: "-")] = trimmed
        }
        guard !normalized.isEmpty else { return nil }

        for pref in preferredLanguages {
            let clean = pref.lowercased().replacingOccurrences(of: "_", with: "-")
            if let exact = normalized[clean] { return exact }
            let parts = clean.split(separator: "-").map(String.init)
            if parts.count >= 2 {
                let two = parts[0] + "-" + parts[1]
                if let hit = normalized[two] { return hit }
            }
            if parts.first == "zh" {
                let isHant = parts.contains("hant") || parts.contains("tw") || parts.contains("hk") || parts.contains("mo")
                let zhCandidates = isHant ? ["zh-hant", "zh-tw", "zh-hk", "zh-hans", "zh-cn", "zh"]
                                          : ["zh-hans", "zh-cn", "zh-sg", "zh"]
                for key in zhCandidates {
                    if let hit = normalized[key] { return hit }
                }
            }
            if let lang = parts.first {
                if let hit = normalized[lang] { return hit }
                if let prefixHit = normalized.first(where: { $0.key.hasPrefix(lang + "-") })?.value {
                    return prefixHit
                }
            }
        }
        return normalized["en-us"] ?? normalized["en"] ?? normalized.values.first
    }

    public struct LocalizedInstallMeta: Sendable {
        public var displayName: String?
        public var testNotes: String?
        public var developerName: String?
        public var shortVersion: String?
        public var buildVersion: String?
        public var bundleID: String?
    }

    public static func extractLocalizedMetadata(from data: Data) -> LocalizedInstallMeta? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (root["data"] as? [String: Any]) ?? root
        guard let framework = payload["framework"] as? [String: Any] else { return nil }
        let name = localizedValue(from: framework["displayName"])
        let notes = localizedValue(from: framework["testNotes"])
        let dev = (framework["developerName"] as? String).map(TFAppDetail.cleanDeveloperName)
        let short = firstString(in: framework, keys: ["shortVersion", "cfBundleShortVersion"])
        let build = firstString(in: framework, keys: ["bundleVersion", "cfBundleVersion"])
        let bundle = firstString(in: framework, keys: ["bundleId", "bundleID"])
        if name == nil && notes == nil && short == nil && build == nil && bundle == nil { return nil }
        return LocalizedInstallMeta(
            displayName: name,
            testNotes: notes,
            developerName: dev?.isEmpty == true ? nil : dev,
            shortVersion: short,
            buildVersion: build,
            bundleID: bundle
        )
    }

    public static func cachedInstallMetadata(bundle: String) -> LocalizedInstallMeta? {
        let trimmed = bundle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        var candidates: [URL] = []
        if let newestDir = TFProducts.newest(bundle: trimmed)?.directory {
            candidates.append(newestDir.appendingPathComponent("metadata.json"))
        }
        candidates.append(docs.appendingPathComponent("TestFlight/\(trimmed)/metadata.json"))
        candidates.append(docs.appendingPathComponent("TestFlight/debug/metadata-\(trimmed).json"))
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let meta = extractLocalizedMetadata(from: data) {
                return meta
            }
        }
        return nil
    }

    private static func parseDetailPayload(_ payload: [String: Any],
                                           appID: String,
                                           fallbackName: String?,
                                           fallbackDeveloper: String?,
                                           isPhone: Bool) -> TFAppDetail {
        let platforms = (payload["platforms"] as? [[String: Any]]) ?? []
        let previouslyTestedFlag = (payload["previouslyTested"] as? Bool) ?? false

        func isActiveBuild(_ build: [String: Any]) -> Bool {
            if let expired = build["expired"] as? Bool, expired { return false }
            if let removed = build["removed"] as? Bool, removed { return false }
            if let removed = build["buildRemoved"] as? Bool, removed { return false }
            if let removalType = build["buildRemovalType"] as? String, !removalType.isEmpty { return false }
            if let expStr = firstString(in: build, keys: ["expiration", "expirationDate"]),
               let expDate = TFAppDetail.parseISO8601(expStr), expDate <= Date() {
                return false
            }
            let size = (build["fileSize"] as? NSNumber)?.int64Value ?? -1
            let uncomp = (build["fileSizeUncompressed"] as? NSNumber)?.int64Value ?? -1
            let compat = (firstString(in: build, keys: ["compatibilityMessage", "compatibilityStatement"]) ?? "").lowercased()
            if size == 0 && uncomp <= 0 && (compat.contains("移除") || compat.contains("removed") || compat.contains("expired") || compat.contains("过期")) {
                return false
            }
            return true
        }

        func isIPadOnlyBuild(_ build: [String: Any]) -> Bool {
            guard isPhone, let families = build["deviceFamilyInfo"] as? [[String: Any]], !families.isEmpty else {
                return false
            }
            let names = families.compactMap { ($0["name"] as? String)?.lowercased() }
            guard !names.isEmpty else { return false }
            let supportsPhone = names.contains { $0 == "ios" || $0.contains("iphone") || $0.contains("ipod") }
            let supportsPad = names.contains { $0.contains("ipad") }
            return !supportsPhone && supportsPad
        }

        func platformDisplayName(_ raw: String) -> String {
            switch raw.lowercased() {
            case "osx", "macos": return "macOS"
            case "appletvos", "tvos": return "Apple TV"
            case "xros", "visionos": return "visionOS"
            case "watchos": return "Apple Watch"
            default: return raw.uppercased()
            }
        }

        var activeIOSBuild: [String: Any]?
        var otherActiveBuilds: [(platform: String, build: [String: Any])] = []
        var activePlatformBuilds: [TFPlatformBuild] = []
        var iosFallbackBuild: [String: Any]?
        var anyFallbackBuild: [String: Any]?

        func makePlatformBuild(rawPlatform: String, build: [String: Any], ipadOnly: Bool, watchOnly: Bool) -> TFPlatformBuild? {
            let bID = firstString(in: build, keys: ["id"]) ?? ""
            guard !bID.isEmpty else { return nil }
            let bFramework = (build["framework"] as? [String: Any]) ?? (payload["framework"] as? [String: Any])
            let bNotes = localizedValue(from: bFramework?["testNotes"])
                ?? (build["whatsNew"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let bSize = (build["fileSize"] as? NSNumber)?.int64Value
            let bUncomp = (build["fileSizeUncompressed"] as? NSNumber)?.int64Value
            return TFPlatformBuild(
                platform: rawPlatform,
                buildID: bID,
                shortVersion: firstString(in: build, keys: ["cfBundleShortVersion", "shortVersion"]) ?? "",
                buildVersion: firstString(in: build, keys: ["cfBundleVersion", "version"]) ?? "",
                expirationISO: firstString(in: build, keys: ["expiration", "expirationDate"]),
                releaseDateISO: firstString(in: build, keys: ["releaseDate", "lastModified"]),
                fileSizeBytes: bSize ?? bUncomp,
                fileSizeUncompressedBytes: bUncomp,
                compatibilityStatement: firstString(in: build, keys: ["compatibilityMessage", "compatibilityStatement"]),
                whatsNew: bNotes?.isEmpty == true ? nil : bNotes,
                isIPadOnly: ipadOnly,
                isWatchOnly: watchOnly
            )
        }

        func platformSortRank(_ b: TFPlatformBuild) -> Int {
            switch b.platform.lowercased() {
            case "ios": return b.isWatchOnly ? 5 : (b.isIPadOnly ? 1 : 0)
            case "appletvos", "tvos": return 2
            case "xros", "visionos": return 3
            case "osx", "macos": return 4
            default: return 6
            }
        }

        for platform in platforms {
            let pname = (platform["name"] as? String)?.lowercased() ?? ""
            guard let build = platform["build"] as? [String: Any] else { continue }
            if pname == "ios" && iosFallbackBuild == nil { iosFallbackBuild = build }
            if anyFallbackBuild == nil { anyFallbackBuild = build }
            guard isActiveBuild(build) else { continue }
            let watchOnly = (build["watchOnly"] as? Bool) ?? false
            let ipadOnly = pname == "ios" && isIPadOnlyBuild(build)
            if !previouslyTestedFlag,
               let entry = makePlatformBuild(rawPlatform: pname, build: build, ipadOnly: ipadOnly, watchOnly: watchOnly) {
                activePlatformBuilds.append(entry)
            }
            if pname == "ios" && !watchOnly && !ipadOnly {
                activeIOSBuild = build
            } else if pname == "ios" && watchOnly {
                otherActiveBuilds.append(("Apple Watch", build))
            } else if ipadOnly {
                otherActiveBuilds.append(("iPad", build))
            } else {
                otherActiveBuilds.append((platformDisplayName(pname), build))
            }
        }
        activePlatformBuilds.sort { lhs, rhs in
            let lRank = platformSortRank(lhs)
            let rRank = platformSortRank(rhs)
            if lRank != rRank { return lRank < rRank }
            return (Int64(lhs.buildID) ?? 0) > (Int64(rhs.buildID) ?? 0)
        }

        let availability: TFAppAvailability
        let incompatiblePlatforms: [String]?
        let chosenBuild: [String: Any]?

        if let iosBuild = activeIOSBuild, !previouslyTestedFlag {
            availability = .testing
            incompatiblePlatforms = nil
            chosenBuild = iosBuild
        } else if !otherActiveBuilds.isEmpty && !previouslyTestedFlag {
            availability = .incompatible
            var names: [String] = []
            for entry in otherActiveBuilds where !names.contains(entry.platform) {
                names.append(entry.platform)
            }
            incompatiblePlatforms = names
            chosenBuild = otherActiveBuilds.first?.build
        } else {
            availability = .previouslyTested
            incompatiblePlatforms = nil
            chosenBuild = iosFallbackBuild ?? anyFallbackBuild
        }

        let build = chosenBuild ?? [:]
        let bundleID = firstString(in: build, keys: ["bundleId", "bundleID"])
            ?? firstString(in: payload, keys: ["bundleId", "bundleID"]) ?? ""
        let buildFramework = (build["framework"] as? [String: Any]) ?? (payload["framework"] as? [String: Any])
        let cachedMeta = bundleID.isEmpty ? nil : cachedInstallMetadata(bundle: bundleID)
        let localizedFrameworkName = localizedValue(from: buildFramework?["displayName"])
            ?? localizedValue(from: build["displayName"])
            ?? localizedValue(from: payload["displayName"])
            ?? cachedMeta?.displayName
        let name = localizedFrameworkName
            ?? firstString(in: build, keys: ["name"])
            ?? firstString(in: payload, keys: ["name"])
            ?? fallbackName ?? appID
        let rawDeveloper = firstString(in: build, keys: ["providerName", "developerName"])
            ?? firstString(in: payload, keys: ["providerName", "developerName"])
            ?? cachedMeta?.developerName
            ?? fallbackDeveloper ?? ""
        let developer = TFAppDetail.cleanDeveloperName(rawDeveloper)
        let buildID = firstString(in: build, keys: ["id"]) ?? ""
        let shortVersion = firstString(in: build, keys: ["cfBundleShortVersion", "shortVersion"]) ?? ""
        let buildVersion = firstString(in: build, keys: ["cfBundleVersion", "version"]) ?? ""
        let expiration = firstString(in: build, keys: ["expiration", "expirationDate"])
        let releaseDate = firstString(in: build, keys: ["releaseDate", "lastModified"])
        let localizedFrameworkNotes = localizedValue(from: buildFramework?["testNotes"])
            ?? cachedMeta?.testNotes
        let whatsNew = localizedFrameworkNotes
            ?? (build["whatsNew"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (build["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileSize = (build["fileSize"] as? NSNumber)?.int64Value
        let fileSizeUncompressed = (build["fileSizeUncompressed"] as? NSNumber)?.int64Value
        let compatibility = firstString(in: build, keys: ["compatibilityMessage", "compatibilityStatement"])
        let supportEmail = firstString(in: build, keys: ["supportEmail", "feedbackEmail"])
        let shareURL = firstString(in: payload, keys: ["shareUrl", "publicUrl"])
            ?? firstString(in: build, keys: ["shareUrl"])
        let privacyPolicyURL = firstString(in: build, keys: ["privacyPolicyUrl"])
            ?? firstString(in: payload, keys: ["privacyPolicyUrl"])

        var devices: [String] = []
        if let families = build["deviceFamilyInfo"] as? [[String: Any]] {
            for family in families {
                if let raw = (family["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                    let display = raw.lowercased() == "ios" ? "iPhone" : raw
                    if !devices.contains(display) { devices.append(display) }
                }
            }
        }
        for p in platforms {
            if let pname = (p["name"] as? String)?.lowercased() {
                let display: String? = pname == "osx" ? "Mac" : (pname == "appletvos" ? "Apple TV" : (pname == "xros" ? "Apple Vision" : nil))
                if let display, !devices.contains(display) { devices.append(display) }
            }
        }
        let rawTerms = (build["termsOfService"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTerms = rawTerms.flatMap { text -> String? in
            guard !text.isEmpty else { return nil }
            let dev = developer.isEmpty ? name : developer
            return text.replacingOccurrences(of: "@@developerName@@", with: dev)
        }

        var iconAsset = (build["iconSet"] as? [[String: Any]]).flatMap { TFIcon.pickAsset(from: $0, buildID: buildID) }
        if iconAsset == nil {
            for p in platforms {
                if let pb = p["build"] as? [String: Any],
                   let set = pb["iconSet"] as? [[String: Any]],
                   let picked = TFIcon.pickAsset(from: set, buildID: buildID) {
                    iconAsset = picked
                    break
                }
            }
        }
        if iconAsset == nil, let payloadSet = payload["iconSet"] as? [[String: Any]] {
            iconAsset = TFIcon.pickAsset(from: payloadSet, buildID: buildID)
        }
        if iconAsset == nil, let rawAsset = (build["iconAsset"] as? [String: Any]) ?? (payload["iconAsset"] as? [String: Any]) {
            iconAsset = TFIcon.pickAsset(from: [["iconType": "largeApp", "iconAsset": rawAsset]], buildID: buildID)
        }
        if iconAsset == nil, let directURL = firstString(in: payload, keys: ["iconUrl", "iconURL", "artworkUrl512", "artworkUrl100"])
            ?? firstString(in: build, keys: ["iconUrl", "iconURL", "artworkUrl512", "artworkUrl100"]), directURL.contains("http") {
            iconAsset = TFIconAsset(urlTemplate: directURL, colors: nil, buildID: buildID)
        }

        return TFAppDetail(
            appID: appID,
            name: name,
            bundleID: bundleID,
            developerName: developer,
            buildID: buildID,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            expirationISO: expiration,
            releaseDateISO: releaseDate,
            whatsNew: whatsNew?.isEmpty == true ? nil : whatsNew,
            description: description?.isEmpty == true ? nil : description,
            fileSizeBytes: fileSize ?? fileSizeUncompressed,
            fileSizeUncompressedBytes: fileSizeUncompressed,
            compatibilityStatement: compatibility,
            supportEmail: supportEmail,
            shareURL: shareURL,
            privacyPolicyURL: privacyPolicyURL,
            supportedDevices: devices.isEmpty ? nil : devices,
            termsOfService: resolvedTerms,
            availability: availability,
            incompatiblePlatforms: incompatiblePlatforms,
            platformBuilds: activePlatformBuilds.isEmpty ? nil : activePlatformBuilds,
            iconAsset: iconAsset
        )
    }

    public static func appDetail(appID: String, session: TFSession,
                                 log: @escaping @Sendable (String) -> Void) async throws -> (bundle: String, builds: [String]) {
        let account = session.account.isEmpty ? session.dsid : session.account
        let path = "/v4/accounts/\(account)/apps/\(appID)"
        let data = try await signedGET(path: path, session: session, log: log)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TFError.malformed("detail: response is not a JSON object")
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        var bundle = ""
        var builds: [String] = []
        func walk(_ node: Any) {
            if let dictionary = node as? [String: Any] {
                for (key, value) in dictionary {
                    if let text = value as? String {
                        if bundle.isEmpty, ["bundleId", "bundleID", "bundle"].contains(key),
                           text.contains(".") {
                            bundle = text
                        }
                        if ["buildId", "buildID"].contains(key), !text.isEmpty {
                            builds.append(text)
                        }
                    } else if let number = value as? NSNumber,
                              ["buildId", "buildID"].contains(key) {
                        builds.append(number.stringValue)
                    }
                    walk(value)
                }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(payload)
        log("detail " + appID + ": bundle " + (bundle.isEmpty ? "-" : bundle)
            + " builds " + String(builds.count) + " | keys "
            + payload.keys.sorted().joined(separator: ","))
        return (bundle, builds)
    }

    public static func publicBundleID(appID: String,
                                      log: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=" + appID) else {
            throw TFError.malformed("lookup: bad app id")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, http) = try await TFNet.data(for: request, cookieStorage: nil, acceptCookies: false)
        let status = http.statusCode
        guard status == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first,
              let bundle = first["bundleId"] as? String, !bundle.isEmpty else {
            throw TFError.malformed("lookup: no bundleId for \(appID) (HTTP \(status))")
        }
        log("lookup " + appID + ": " + bundle + " (" + (first["trackName"] as? String ?? "-") + ")")
        return bundle
    }

    public static func resolveBundle(appID: String, session: TFSession,
                                     log: @escaping @Sendable (String) -> Void) async -> String {
        let account = session.account.isEmpty ? session.dsid : session.account
        let paths = [
            "/v3/accounts/\(account)/apps/\(appID)?allDetailsCount=10000",
            "/v2/accounts/\(account)/apps/\(appID)/builds",
        ]
        for path in paths {
            do {
                let data = try await signedGET(path: path, session: session, log: log)
                if let bundle = firstBundle(in: data) {
                    log("bundle: " + bundle + " (from " + path + ")")
                    return bundle
                }
                let keys = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                    .map { $0.keys.sorted().joined(separator: ",") } ?? "-"
                log(path + ": 200, no bundleId (keys " + keys + ")")
            } catch {
                log(path + ": " + shortText(error))
            }
        }
        return ""
    }

    static func firstBundle(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found: String?
        func walk(_ node: Any) {
            guard found == nil else { return }
            if let dictionary = node as? [String: Any] {
                for (key, value) in dictionary {
                    if found == nil, let text = value as? String,
                       ["bundleId", "bundleID", "appBundleId", "bundle"].contains(key),
                       text.contains(".") {
                        found = text
                    }
                    walk(value)
                }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(root)
        return found
    }

    static func shortText(_ error: Error) -> String {
        if case let TFError.http(status, path, _) = error { return "HTTP \(status) " + path }
        return error.localizedDescription
    }

    public static func buildID(appID: String, platform targetPlatform: String = "ios", session: TFSession,
                               log: @escaping @Sendable (String) -> Void) async throws -> String {
        let account = session.account.isEmpty ? session.dsid : session.account
        let path = "/v3/accounts/\(account)/apps/\(appID)"
        let data = try await signedGET(path: path, session: session, log: log)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TFError.malformed("builds: response is not a JSON object")
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        let platforms = (payload["platforms"] as? [[String: Any]]) ?? []
        let target = targetPlatform.lowercased()
        var best = 0
        var chosen = ""
        for platform in platforms {
            let name = (platform["name"] as? String)?.lowercased() ?? ""
            let matched = (name == target) || (target == "ios" && name.contains("ios"))
            guard matched else { continue }
            guard let build = platform["build"] as? [String: Any] else { continue }
            if let expired = build["expired"] as? Bool, expired { continue }
            let raw = (build["id"] as? NSNumber)?.stringValue ?? (build["id"] as? String) ?? ""
            guard let value = Int(raw) else { continue }
            log("  platform " + name + ": build " + String(value)
                + " (" + ((build["cfBundleShortVersion"] as? String) ?? "?")
                + "/" + ((build["cfBundleVersion"] as? String) ?? "?") + ")")
            if value > best { best = value; chosen = String(value) }
        }
        log("builds: " + String(platforms.count) + " platform(s), target " + target + ", picked " + (chosen.isEmpty ? "-" : chosen))
        guard !chosen.isEmpty else {
            let label = target == "ios" ? "iOS" : target
            throw TFError.noBuild(label)
        }
        return chosen
    }

    /// The tester API exposes the currently active build per platform only; expired builds are
    /// not listed for testers. One signed request replaces the old v1…v4 probing.
    public static func buildHistory(appID: String, session: TFSession,
                                    log: @escaping @Sendable (String) -> Void) async throws -> [TFBuild] {
        let account = session.account.isEmpty ? session.dsid : session.account
        let path = "/v3/accounts/\(account)/apps/\(appID)?allDetailsCount=10000"
        let data = try await signedGET(path: path, session: session, log: log)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TFError.malformed("history: response is not a JSON object")
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        let platforms = (payload["platforms"] as? [[String: Any]]) ?? []
        let framework = payload["framework"] as? [String: Any]
        let fallbackNotes = localizedValue(from: framework?["testNotes"])

        var builds: [TFBuild] = []
        for platform in platforms {
            guard let build = platform["build"] as? [String: Any] else { continue }
            let raw = (build["id"] as? NSNumber)?.stringValue ?? (build["id"] as? String) ?? ""
            guard !raw.isEmpty else { continue }
            let notes = localizedValue(from: build["testNotes"]) ?? fallbackNotes
            builds.append(TFBuild(
                id: raw,
                shortVersion: firstString(in: build, keys: ["cfBundleShortVersion", "shortVersion"]) ?? "",
                buildVersion: firstString(in: build, keys: ["cfBundleVersion", "version"]) ?? "",
                platform: (platform["name"] as? String) ?? "ios",
                expirationISO: firstString(in: build, keys: ["expiration", "expirationDate"]),
                releaseDateISO: firstString(in: build, keys: ["releaseDate", "lastModified"]),
                fileSizeBytes: (build["fileSize"] as? NSNumber)?.int64Value,
                whatsNew: notes,
                expired: (build["expired"] as? Bool) ?? false
            ))
        }
        log("history: \(builds.count) platform build(s)")
        guard !builds.isEmpty else { throw TFError.noBuild("history") }
        return builds.sorted {
            (Int64($0.id) ?? 0, $0.buildVersion) > (Int64($1.id) ?? 0, $1.buildVersion)
        }
    }

    public static func installMetadata(appID: String, buildID: String, session: TFSession,
                                       headers: [String: String], dsid: String, hardware20: Data,
                                       storefront: String,
                                       log: @escaping @Sendable (String) -> Void) async throws -> Data {
        let account = session.account.isEmpty ? session.dsid : session.account
        guard let dsidValue = UInt64(dsid) else { throw TFError.malformed("install: dsid 不是数字") }
        let kbsync = try StoreSupport.generateKBSync(dsid: dsidValue, hardware: hardware20)
        let shortFront = storefront.split(separator: ",").first.map(String.init) ?? storefront
        let payload: [String: Any] = [
            "deviceName": "iPadn",
            "isFromAutoUpdate": false,
            "kbSync": kbsync.base64EncodedString(),
            "storefrontId": shortFront,
            "udid": hardware20.map { String(format: "%02x", $0) }.joined(),
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        let path = "/v2/accounts/\(account)/apps/\(appID)/builds/\(buildID)/install"
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var request = URLRequest(url: URL(string: TFConstants.host + path)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(TFConstants.agent, forHTTPHeaderField: "User-Agent")
        request.setValue(session.id, forHTTPHeaderField: "X-Session-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Request-Id")
        request.setValue(digest(sessionID: session.id, requestID: requestID, dsid: session.dsid),
                         forHTTPHeaderField: "X-Session-Digest")
        for key in ["X-Apple-AMD-M", "X-Apple-Store-Front", "X-Apple-Device-Model", "X-Apple-TA-Device"] {
            if let value = headers[key] { request.setValue(value, forHTTPHeaderField: key) }
        }
        let summary = "install: app " + appID + " build " + buildID
            + " body " + String(body.count) + " B kbsync " + String(kbsync.count)
            + " B dsid ..." + String(dsid.suffix(4))
        log(summary)

        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let text = String(decoding: data.prefix(200), as: UTF8.self)
            if status == 404 || status == 410 {
                throw TFError.appUnavailable(appID)
            }
            throw TFError.http(status: status, path: path, body: TFRedaction.clean(text))
        }
        log("install: metadata " + String(data.count) + " B")
        return data
    }

    private static func signedGET(path: String, session: TFSession,
                                  log: @escaping @Sendable (String) -> Void) async throws -> Data {
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var request = URLRequest(url: URL(string: TFConstants.host + path)!)
        request.httpMethod = "GET"
        request.setValue(TFConstants.agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Locale.preferredLanguages.first ?? "en-US", forHTTPHeaderField: "Accept-Language")
        request.setValue(session.id, forHTTPHeaderField: "X-Session-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Request-Id")
        request.setValue(digest(sessionID: session.id, requestID: requestID, dsid: session.dsid),
                         forHTTPHeaderField: "X-Session-Digest")
        for key in ["X-Apple-AMD-M", "X-Apple-Store-Front", "X-Apple-Device-Model", "X-Apple-TA-Device"] {
            if let value = session.effectiveHeaders[key] { request.setValue(value, forHTTPHeaderField: key) }
        }
        log("GET " + (request.url?.absoluteString ?? path) + " · digest ok · req "
            + String(requestID.count) + " hex")

        let (data, response) = try await send(request)
        try ensure(response, data: data, path: path)
        return data
    }

    static func digest(sessionID: String, requestID: String, dsid: String) -> String {
        let material = sessionID + requestID + dsid + TFConstants.sessionSalt
        let hash = Insecure.SHA1.hash(data: Data(material.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func freshRequestID(uppercase: Bool) -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return uppercase ? raw.uppercased() : raw.lowercased()
    }

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = 30
        return try await TFNet.data(for: request, cookieStorage: .shared, acceptCookies: true)
    }

    private static func ensure(_ response: HTTPURLResponse, data: Data, path: String) throws {
        guard (200..<300).contains(response.statusCode) else {
            let body = String(decoding: data.prefix(400), as: UTF8.self)
            throw TFError.http(status: response.statusCode, path: path, body: TFRedaction.clean(body))
        }
    }

    static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
            if let value = dictionary[key] as? Int { return String(value) }
            if let value = dictionary[key] as? Int64 { return String(value) }
        }
        return nil
    }
}

public struct TFBuild: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let shortVersion: String
    public let buildVersion: String
    public let platform: String
    public let expirationISO: String?
    public let releaseDateISO: String?
    public let fileSizeBytes: Int64?
    public let whatsNew: String?
    public let expired: Bool

    public init(id: String, shortVersion: String, buildVersion: String, platform: String,
                expirationISO: String?, releaseDateISO: String?, fileSizeBytes: Int64?,
                whatsNew: String?, expired: Bool) {
        self.id = id
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.platform = platform
        self.expirationISO = expirationISO
        self.releaseDateISO = releaseDateISO
        self.fileSizeBytes = fileSizeBytes
        self.whatsNew = whatsNew
        self.expired = expired
    }

    public var versionSummary: String {
        if !shortVersion.isEmpty && !buildVersion.isEmpty { return "\(shortVersion) (\(buildVersion))" }
        if !shortVersion.isEmpty { return shortVersion }
        if !buildVersion.isEmpty { return "Build \(buildVersion)" }
        return "Build \(id)"
    }

    public var isExpired: Bool {
        if expired { return true }
        guard let expirationISO, let date = ISO8601DateFormatter().date(from: expirationISO) else { return false }
        return date < Date()
    }

    public func markingExpired() -> TFBuild {
        TFBuild(id: id, shortVersion: shortVersion, buildVersion: buildVersion,
                platform: platform, expirationISO: expirationISO,
                releaseDateISO: releaseDateISO, fileSizeBytes: fileSizeBytes,
                whatsNew: whatsNew, expired: true)
    }

    public var releaseDate: Date? {
        guard let releaseDateISO else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: releaseDateISO) ?? ISO8601DateFormatter().date(from: releaseDateISO)
    }
}
