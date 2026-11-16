import Foundation

struct IPADetails {
    struct Component: Identifiable {
        enum Kind: String {
            case main = "Main"
            case appex = "Extension"
            case framework = "Framework"
            case watch = "Watch"
            case bundle = "Bundle"

            var icon: String {
                switch self {
                case .main: return "shippingbox.fill"
                case .appex: return "puzzlepiece.extension.fill"
                case .framework: return "square.stack.3d.up.fill"
                case .watch: return "applewatch"
                case .bundle: return "folder.fill"
                }
            }
        }

        let id = UUID()
        let path: String
        let kind: Kind
        let size: Int64
        let isEncrypted: Bool
    }

    struct Entitlement: Identifiable {
        let id = UUID()
        let key: String
        let value: String
        let isHighlighted: Bool
    }

    var name: String = ""
    var bundleIdentifier: String = ""
    var version: String = ""
    var buildNumber: String = ""
    var minimumOS: String = ""
    var deviceFamilies: [String] = []
    var architectures: [String] = []

    var binaryCount: Int = 0
    var encryptedCount: Int = 0
    var totalSize: Int64 = 0
    var fileCount: Int = 0

    var teamIdentifier: String?
    var profileName: String?
    var profileExpiry: Date?
    var provisionedDevices: Int = 0

    var entitlements: [Entitlement] = []
    var linkedLibraries: [String] = []
    var components: [Component] = []

    var iconPath: String?
    var hasSCInfo: Bool = false

    var isEncrypted: Bool { encryptedCount > 0 }
}

enum IPAAnalyzer {

    enum AnalysisError: LocalizedError {
        case badArchive(String)
        case noPayload

        var errorDescription: String? {
            switch self {
            case .badArchive(let detail):
                return "dc_err_unzip".localized + " (\(detail))"
            case .noPayload:
                return "dc_err_no_binary".localized
            }
        }
    }

    static func analyze(ipaURL: URL, progress: ((String) -> Void)? = nil) throws -> IPADetails {
        let manager = FileManager.default
        let work = manager.temporaryDirectory
            .appendingPathComponent("ipadetail-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: work) }
        try manager.createDirectory(at: work, withIntermediateDirectories: true)

        progress?("UNPACK")
        var errBuf = [CChar](repeating: 0, count: 512)
        let status = ipaURL.path.withCString { src in
            work.path.withCString { dst in
                fp_zip_unpack(src, dst, &errBuf, Int32(errBuf.count))
            }
        }
        guard status == 0 else {
            throw AnalysisError.badArchive(String(cString: errBuf))
        }

        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let entries = (try? manager.contentsOfDirectory(atPath: payload.path)) ?? []
        guard let bundleName = entries.first(where: { $0.hasSuffix(".app") }) else {
            throw AnalysisError.noPayload
        }
        let appDir = payload.appendingPathComponent(bundleName, isDirectory: true)

        progress?("METADATA")
        var details = IPADetails()
        details.name = bundleName.replacingOccurrences(of: ".app", with: "")

        let infoURL = appDir.appendingPathComponent("Info.plist")
        if let info = NSDictionary(contentsOf: infoURL) as? [String: Any] {
            details.bundleIdentifier = info["CFBundleIdentifier"] as? String ?? ""
            details.version = info["CFBundleShortVersionString"] as? String ?? ""
            details.buildNumber = info["CFBundleVersion"] as? String ?? ""
            details.minimumOS = info["MinimumOSVersion"] as? String ?? ""
            if let families = info["UIDeviceFamily"] as? [Int] {
                details.deviceFamilies = families.map { familyName($0) }
            }
            if let icons = info["CFBundleIcons"] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
               let files = primary["CFBundleIconFiles"] as? [String],
               let last = files.last {
                details.iconPath = iconFile(named: last, in: appDir)
            }
        }

        progress?("SIGNING")
        let profileURL = appDir.appendingPathComponent("embedded.mobileprovision")
        if let profile = readProvisioningProfile(at: profileURL) {
            details.teamIdentifier = profile.teamIdentifier
            details.profileName = profile.name
            details.profileExpiry = profile.expiry
            details.provisionedDevices = profile.deviceCount
            details.entitlements = profile.entitlements
        }

        details.hasSCInfo = manager.fileExists(
            atPath: appDir.appendingPathComponent("SC_Info").path
        )

        progress?("SCAN")
        details.components = scanTree(appDir: appDir, details: &details)

        progress?("BINARY")
        if let executable = executableName(in: appDir) {
            let binaryURL = appDir.appendingPathComponent(executable)
            let inspection = MachOInspector.inspect(url: binaryURL)
            details.architectures = inspection.architectures
            details.linkedLibraries = inspection.libraries
            if details.minimumOS.isEmpty, let minOS = inspection.minimumOS {
                details.minimumOS = minOS
            }
        }

        return details
    }

    private static func scanTree(appDir: URL, details: inout IPADetails) -> [IPADetails.Component] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: appDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var components: [IPADetails.Component] = []
        var componentSizes: [String: Int64] = [:]
        var componentEncrypted: [String: Bool] = [:]

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }

            let size = Int64(values?.fileSize ?? 0)
            details.totalSize += size
            details.fileCount += 1

            let relative = url.path.replacingOccurrences(of: appDir.path + "/", with: "")
            guard let key = componentKey(for: relative) else { continue }
            componentSizes[key, default: 0] += size

            guard let handle = try? FileHandle(forReadingFrom: url),
                  let head = try? handle.read(upToCount: 4) else { continue }
            try? handle.close()
            guard head.count == 4, isMachO(head) else { continue }

            details.binaryCount += 1
            if MachOScanner.scan(fileURL: url).contains(where: { $0.isEncrypted }) {
                details.encryptedCount += 1
                componentEncrypted[key] = true
            }
        }

        for (path, size) in componentSizes.sorted(by: { $0.value > $1.value }) {
            components.append(IPADetails.Component(
                path: path,
                kind: kind(for: path),
                size: size,
                isEncrypted: componentEncrypted[path] ?? false
            ))
        }
        return components
    }

    private static func componentKey(for relative: String) -> String? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let first = parts.first else { return nil }

        if first == "PlugIns", parts.count > 1 { return "PlugIns/\(parts[1])" }
        if first == "Extensions", parts.count > 1 { return "Extensions/\(parts[1])" }
        if first == "Frameworks", parts.count > 1 { return "Frameworks/\(parts[1])" }
        if first == "Watch" { return "Watch" }
        if first == "SC_Info" { return nil }
        if first.hasSuffix(".app") || first.hasSuffix(".appex") { return first }
        return "Main Bundle"
    }

    private static func kind(for path: String) -> IPADetails.Component.Kind {
        if path.hasPrefix("Watch") { return .watch }
        if path.hasSuffix(".appex") { return .appex }
        if path.hasSuffix(".framework") { return .framework }
        if path.hasSuffix(".bundle") { return .bundle }
        if path.hasPrefix("PlugIns") || path.hasPrefix("Extensions") { return .appex }
        if path.hasPrefix("Frameworks") { return .framework }
        return .main
    }

    private static func isMachO(_ head: Data) -> Bool {
        guard head.count == 4 else { return false }
        let le = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let be = le.byteSwapped
        return be == 0xFEEDFACF || be == 0xFEEDFACE || be == 0xCAFEBABE
            || le == 0xFEEDFACF || le == 0xFEEDFACE
    }

    private static func executableName(in appDir: URL) -> String? {
        let infoURL = appDir.appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              let name = info["CFBundleExecutable"] as? String else { return nil }
        return name
    }

    private static func iconFile(named base: String, in appDir: URL) -> String? {
        let manager = FileManager.default
        for suffix in ["@3x.png", "@2x.png", ".png"] {
            let candidate = appDir.appendingPathComponent(base + suffix)
            if manager.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    private static func familyName(_ id: Int) -> String {
        switch id {
        case 1: return "iPhone"
        case 2: return "iPad"
        case 3: return "Apple TV"
        case 4: return "Apple Watch"
        case 6: return "Mac"
        case 7: return "Vision"
        default: return "Family \(id)"
        }
    }

    struct ProvisioningProfile {
        let name: String?
        let teamIdentifier: String?
        let expiry: Date?
        let deviceCount: Int
        let entitlements: [IPADetails.Entitlement]
    }

    static func readProvisioningProfile(at url: URL) -> ProvisioningProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.count) else {
            return nil
        }
        let plistData = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let dict = plist as? [String: Any] else { return nil }

        let name = dict["Name"] as? String
        let team = (dict["TeamIdentifier"] as? [String])?.first
        let expiry = dict["ExpirationDate"] as? Date
        let devices = (dict["ProvisionedDevices"] as? [String])?.count ?? 0

        var items: [IPADetails.Entitlement] = []
        if let ents = dict["Entitlements"] as? [String: Any] {
            for key in ents.keys.sorted() {
                let value = ents[key]
                items.append(IPADetails.Entitlement(
                    key: key,
                    value: describe(value),
                    isHighlighted: highlightedEntitlement(key)
                ))
            }
        }

        return ProvisioningProfile(
            name: name,
            teamIdentifier: team,
            expiry: expiry,
            deviceCount: devices,
            entitlements: items
        )
    }

    private static func highlightedEntitlement(_ key: String) -> Bool {
        key.contains("application-groups")
            || key.contains("get-task-allow")
            || key.contains("team-identifier")
            || key.contains("application-identifier")
            || key.contains("aps-environment")
    }

    private static func describe(_ value: Any?) -> String {
        guard let value else { return "—" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [Any] {
            return array.map { describe($0) }.joined(separator: ", ")
        }
        if let dict = value as? [String: Any] {
            if JSONSerialization.isValidJSONObject(dict),
               let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return dict.description
        }
        return String(describing: value)
    }
}
