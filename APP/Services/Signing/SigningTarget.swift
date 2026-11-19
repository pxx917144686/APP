import Foundation

struct SigningTarget: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case main
        case widget
        case controlCenter
        case networkExtension
        case watchApp
        case appClip
        case share
        case notification
        case intents
        case other

        var title: String {
            switch self {
            case .main: return "sign_target_main".localized
            case .widget: return "sign_target_widget".localized
            case .controlCenter: return "sign_target_control_center".localized
            case .networkExtension: return "sign_target_ne".localized
            case .watchApp: return "sign_target_watch".localized
            case .appClip: return "sign_target_app_clip".localized
            case .share: return "sign_target_share".localized
            case .notification: return "sign_target_notification".localized
            case .intents: return "sign_target_intents".localized
            case .other: return "sign_target_other".localized
            }
        }

        var icon: String {
            switch self {
            case .main: return "app.fill"
            case .widget: return "square.grid.2x2.fill"
            case .controlCenter: return "switch.2"
            case .networkExtension: return "network"
            case .watchApp: return "applewatch"
            case .appClip: return "app.badge"
            case .share: return "square.and.arrow.up.fill"
            case .notification: return "bell.badge.fill"
            case .intents: return "waveform.circle.fill"
            case .other: return "puzzlepiece.extension.fill"
            }
        }

        var sortOrder: Int {
            switch self {
            case .main: return 0
            case .widget: return 1
            case .controlCenter: return 2
            case .networkExtension: return 3
            case .watchApp: return 4
            case .appClip: return 5
            case .share: return 6
            case .notification: return 7
            case .intents: return 8
            case .other: return 9
            }
        }
    }

    let id: String
    let bundlePath: String
    let displayName: String
    let bundleIdentifier: String
    let executableName: String
    let kind: Kind
    let extensionPoint: String?
    let requiredEntitlementKeys: Set<String>
    let requiredAppGroups: [String]
    let requiredKeychainGroups: [String]
    let hasOriginalProfile: Bool

    static func mainFallback(info: SigningIPAInfo) -> SigningTarget {
        SigningTarget(
            id: ".",
            bundlePath: ".",
            displayName: info.displayName.isEmpty ? info.name : info.displayName,
            bundleIdentifier: info.bundleIdentifier,
            executableName: "",
            kind: .main,
            extensionPoint: nil,
            requiredEntitlementKeys: [],
            requiredAppGroups: [],
            requiredKeychainGroups: [],
            hasOriginalProfile: false
        )
    }
}

enum SigningTargetScanner {
    static func scan(ipaURL: URL) throws -> [SigningTarget] {
        let data = try Data(contentsOf: ipaURL, options: .alwaysMapped)
        guard let eocd = FastZipArchive.findEndOfCentralDirectory(in: data),
              let entries = try? FastZipArchive.readCentralDirectory(from: data, eocd: eocd) else {
            return []
        }

        guard let mainEntry = entries.first(where: { entry in
            let parts = entry.filename.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else {
            return []
        }

        let appPrefix = String(mainEntry.filename.dropLast("Info.plist".count))
        var targets: [SigningTarget] = []

        if let info = plist(data, entry: mainEntry) {
            let displayName = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? "App"
            let executable = (info["CFBundleExecutable"] as? String) ?? ""
            let bundleID = (info["CFBundleIdentifier"] as? String) ?? ""
            let requirements = profileRequirements(
                data: data,
                entries: entries,
                path: appPrefix + "embedded.mobileprovision"
            )
            targets.append(
                SigningTarget(
                    id: ".",
                    bundlePath: ".",
                    displayName: displayName,
                    bundleIdentifier: bundleID,
                    executableName: executable,
                    kind: .main,
                    extensionPoint: nil,
                    requiredEntitlementKeys: requirements.keys,
                    requiredAppGroups: requirements.appGroups,
                    requiredKeychainGroups: requirements.keychainGroups,
                    hasOriginalProfile: requirements.known
                )
            )
        }

        for entry in entries where entry.filename.hasPrefix(appPrefix) {
            let relative = String(entry.filename.dropFirst(appPrefix.count))
            guard relative.hasSuffix(".appex/Info.plist") else { continue }
            guard let range = relative.range(of: ".appex/Info.plist") else { continue }
            let bundlePath = String(relative[..<range.lowerBound]) + ".appex"
            guard let info = plist(data, entry: entry) else { continue }
            let extensionInfo = info["NSExtension"] as? [String: Any]
            let point = extensionInfo?["NSExtensionPointIdentifier"] as? String
            let kind = classify(point)
            let displayName = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".appex", with: "")
            let executable = (info["CFBundleExecutable"] as? String) ?? ""
            let bundleID = (info["CFBundleIdentifier"] as? String) ?? ""
            let requirements = profileRequirements(
                data: data,
                entries: entries,
                path: appPrefix + bundlePath + "/embedded.mobileprovision"
            )
            targets.append(
                SigningTarget(
                    id: bundlePath,
                    bundlePath: bundlePath,
                    displayName: displayName,
                    bundleIdentifier: bundleID,
                    executableName: executable,
                    kind: kind,
                    extensionPoint: point,
                    requiredEntitlementKeys: requirements.keys,
                    requiredAppGroups: requirements.appGroups,
                    requiredKeychainGroups: requirements.keychainGroups,
                    hasOriginalProfile: requirements.known
                )
            )
        }

        for entry in entries where entry.filename.hasPrefix(appPrefix) {
            let relative = String(entry.filename.dropFirst(appPrefix.count))
            guard relative.hasSuffix(".app/Info.plist"), !relative.hasSuffix(".appex/Info.plist") else { continue }
            guard relative.hasPrefix("Watch/") || relative.hasPrefix("AppClips/") else { continue }
            guard let range = relative.range(of: ".app/Info.plist") else { continue }
            let bundlePath = String(relative[..<range.lowerBound]) + ".app"
            guard let info = plist(data, entry: entry) else { continue }
            let kind: SigningTarget.Kind = bundlePath.hasPrefix("Watch/") ? .watchApp : .appClip
            let displayName = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            let executable = (info["CFBundleExecutable"] as? String) ?? ""
            let bundleID = (info["CFBundleIdentifier"] as? String) ?? ""
            let requirements = profileRequirements(
                data: data,
                entries: entries,
                path: appPrefix + bundlePath + "/embedded.mobileprovision"
            )
            targets.append(
                SigningTarget(
                    id: bundlePath,
                    bundlePath: bundlePath,
                    displayName: displayName,
                    bundleIdentifier: bundleID,
                    executableName: executable,
                    kind: kind,
                    extensionPoint: nil,
                    requiredEntitlementKeys: requirements.keys,
                    requiredAppGroups: requirements.appGroups,
                    requiredKeychainGroups: requirements.keychainGroups,
                    hasOriginalProfile: requirements.known
                )
            )
        }

        return targets.sorted {
            if $0.kind.sortOrder != $1.kind.sortOrder {
                return $0.kind.sortOrder < $1.kind.sortOrder
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func profileRequirements(
        data: Data,
        entries: [FastZipArchive.CentralDirectoryEntry],
        path: String
    ) -> (keys: Set<String>, appGroups: [String], keychainGroups: [String], known: Bool) {
        guard let entry = entries.first(where: { $0.filename == path }),
              let profileData = try? FastZipArchive.extractSingleEntry(from: data, entry: entry),
              let metadata = try? SigningParser.profile(data: profileData) else {
            return ([], [], [], false)
        }
        var dictionary: [String: Any] = [:]
        if let entitlementsData = metadata.entitlementsData,
           let parsed = try? PropertyListSerialization.propertyList(from: entitlementsData, format: nil) as? [String: Any] {
            dictionary = parsed
        }
        let appGroups = dictionary["com.apple.security.application-groups"] as? [String] ?? []
        let keychainGroups = dictionary["keychain-access-groups"] as? [String] ?? []
        return (Set(metadata.entitlementKeys), appGroups, keychainGroups, true)
    }

    private static func plist(_ data: Data, entry: FastZipArchive.CentralDirectoryEntry) -> [String: Any]? {
        guard let entryData = try? FastZipArchive.extractSingleEntry(from: data, entry: entry),
              let plist = try? PropertyListSerialization.propertyList(from: entryData, format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    private static func classify(_ point: String?) -> SigningTarget.Kind {
        let lower = (point ?? "").lowercased()
        if lower.contains("widget") { return .widget }
        if lower.contains("control-center") || lower.contains("controlcenter") { return .controlCenter }
        if lower.contains("network-extension") || lower.contains("networkextension") || lower.contains("packet-tunnel") || lower.contains("packettunnel") || lower.contains("dns-proxy") {
            return .networkExtension
        }
        if lower.contains("share-services") { return .share }
        if lower.contains("notification") || lower.contains("usernotifications") { return .notification }
        if lower.contains("intents") { return .intents }
        return .other
    }
}
