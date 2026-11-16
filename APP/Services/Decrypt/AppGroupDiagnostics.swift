import Foundation

enum AppGroupDiagnostics {

    struct Report {
        let bundleIdentifier: String
        let applicationIdentifier: String?
        let teamIdentifier: String?
        let profileName: String?
        let signatureGroups: [String]
        let profileGroups: [String]
        let resolvedGroups: [String]
        let source: String

        var isUsable: Bool { !resolvedGroups.isEmpty }

        var isWildcardAppID: Bool {
            guard let appID = applicationIdentifier else { return false }
            return appID.hasSuffix(".*") || appID.contains("*")
        }

        var facts: String {
            var lines: [String] = []
            lines.append("Team: \(teamIdentifier ?? "unknown")")
            lines.append("App ID: \(applicationIdentifier ?? "unknown")")
            lines.append("Profile: \(profileName ?? "-")")
            lines.append("source: \(source)")
            lines.append("sig groups: \(signatureGroups.isEmpty ? "none" : signatureGroups.joined(separator: ","))")
            lines.append("profile groups: \(profileGroups.isEmpty ? "none" : profileGroups.joined(separator: ","))")
            lines.append("granted: \(resolvedGroups.isEmpty ? "none" : resolvedGroups.joined(separator: ","))")
            if isWildcardAppID {
                lines.append("wildcard app id: yes")
            }
            return lines.joined(separator: "\n")
        }

        var headline: String {
            if isWildcardAppID { return "dc_group_wildcard".localized }
            if signatureGroups.isEmpty && profileGroups.isEmpty {
                return "dc_group_none".localized
            }
            if resolvedGroups.isEmpty { return "dc_group_notgranted".localized }
            return "dc_group_ok".localized
        }
    }

    static func candidateGroups() -> [String] {
        var groups: [String] = []

        if let configured = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !configured.isEmpty {
            groups.append(configured)
        }

        let live = liveEntitlements()
        let fromSignature = (live?["com.apple.security.application-groups"] as? [String]) ?? []
        groups.append(contentsOf: fromSignature)

        if fromSignature.isEmpty {
            groups.append(contentsOf: profileGroups())
        }

        var seen = Set<String>()
        return groups.filter { seen.insert($0).inserted }
    }

    static func inspect() -> Report {
        let live = liveEntitlements()
        let signature = (live?["com.apple.security.application-groups"] as? [String]) ?? []
        let profile = readEmbeddedProfile()
        let tried = candidateGroups()

        var resolved: [String] = []
        for group in tried {
            if FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group
            ) != nil {
                resolved.append(group)
            }
        }

        let appID = live?["application-identifier"] as? String
        let team = live?["com.apple.developer.team-identifier"] as? String
            ?? profile?.team
            ?? appID?.split(separator: ".").first.map(String.init)

        let source: String
        switch (live != nil, signature.isEmpty) {
        case (true, false):  source = "code signature"
        case (true, true):   source = "code signature (no groups)"
        case (false, _):     source = "unavailable"
        }

        return Report(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "-",
            applicationIdentifier: appID,
            teamIdentifier: team,
            profileName: profile?.name,
            signatureGroups: signature,
            profileGroups: profile?.groups ?? [],
            resolvedGroups: resolved,
            source: source
        )
    }

    private static func liveEntitlements() -> [String: Any]? {
        if let fromMachO = machOEntitlements() { return fromMachO }
        return secTaskEntitlements()
    }

    private static func machOEntitlements() -> [String: Any]? {
        guard let exe = Bundle.main.executableURL,
              let handle = try? FileHandle(forReadingFrom: exe) else { return nil }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: 32), head.count >= 32 else { return nil }
        let rawMagic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }

        var sliceOffset: UInt64 = 0
        var header = head

        if rawMagic == 0xBEBAFECA {
            let count = head.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            }.byteSwapped
            guard count > 0, count < 16 else { return nil }

            let offset = head.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
            }.byteSwapped
            sliceOffset = UInt64(offset)

            guard (try? handle.seek(toOffset: sliceOffset)) != nil,
                  let sliceHead = try? handle.read(upToCount: 32),
                  sliceHead.count >= 32 else { return nil }
            header = sliceHead
        }

        let sliceMagic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard sliceMagic == 0xFEEDFACF else { return nil }

        let ncmds = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        let sizeofcmds = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        guard ncmds > 0, ncmds < 8192, sizeofcmds > 0, sizeofcmds < 4 << 20 else { return nil }

        guard let cmds = try? handle.read(upToCount: Int(sizeofcmds)),
              cmds.count == Int(sizeofcmds) else { return nil }

        let bytes = [UInt8](cmds)
        var dataOffset: UInt32 = 0
        var dataSize: UInt32 = 0
        var cursor = 0

        for _ in 0..<Int(ncmds) {
            guard cursor + 8 <= bytes.count else { break }
            let cmd = readLE32(bytes, cursor)
            let size = readLE32(bytes, cursor + 4)
            guard size >= 8, cursor + Int(size) <= bytes.count else { break }
            if cmd == 0x1D, size >= 16 {
                dataOffset = readLE32(bytes, cursor + 8)
                dataSize = readLE32(bytes, cursor + 12)
            }
            cursor += Int(size)
        }

        guard dataOffset > 0, dataSize > 0,
              (try? handle.seek(toOffset: sliceOffset + UInt64(dataOffset))) != nil,
              let blob = try? handle.read(upToCount: Int(dataSize)),
              blob.count == Int(dataSize) else { return nil }

        return parseSuperBlob([UInt8](blob))
    }

    private static func parseSuperBlob(_ bytes: [UInt8]) -> [String: Any]? {
        guard bytes.count >= 12, readBE32(bytes, 0) == 0xFADE0CC0 else { return nil }

        let count = Int(readBE32(bytes, 8))
        guard count > 0, count < 64, 12 + count * 8 <= bytes.count else { return nil }

        for index in 0..<count {
            let base = 12 + index * 8
            let type = readBE32(bytes, base)
            let offset = Int(readBE32(bytes, base + 4))
            guard type == 5, offset >= 0, offset + 8 <= bytes.count else { continue }
            guard readBE32(bytes, offset) == 0xFADE7171 else { continue }

            let length = Int(readBE32(bytes, offset + 4))
            guard length > 8, offset + length <= bytes.count else { continue }

            let plistData = Data(bytes[(offset + 8)..<(offset + length)])
            guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
                  let dict = plist as? [String: Any] else { return nil }
            return dict
        }
        return nil
    }

    private static func secTaskEntitlements() -> [String: Any]? {
        typealias CreateFn = @convention(c) (CFAllocator?) -> CFTypeRef?
        typealias CopyFn = @convention(c) (CFTypeRef?, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

        let path = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }

        guard let createPtr = dlsym(handle, "SecTaskCreateFromSelf"),
              let copyPtr = dlsym(handle, "SecTaskCopyValueForEntitlement") else {
            return nil
        }

        let create = unsafeBitCast(createPtr, to: CreateFn.self)
        let copy = unsafeBitCast(copyPtr, to: CopyFn.self)
        guard let task = create(nil) else { return nil }

        var dict: [String: Any] = [:]
        for key in ["com.apple.security.application-groups",
                    "application-identifier",
                    "com.apple.developer.team-identifier"] {
            if let value = copy(task, key as CFString, nil) {
                dict[key] = value
            }
        }
        return dict.isEmpty ? nil : dict
    }

    private struct EmbeddedProfile {
        let name: String?
        let team: String?
        let groups: [String]
    }

    private static func readEmbeddedProfile() -> EmbeddedProfile? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.count) else {
            return nil
        }

        let slice = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: slice, format: nil),
              let dict = plist as? [String: Any] else { return nil }

        let entitlements = dict["Entitlements"] as? [String: Any]
        let groups = (entitlements?["com.apple.security.application-groups"] as? [String]) ?? []

        return EmbeddedProfile(
            name: dict["Name"] as? String,
            team: (dict["TeamIdentifier"] as? [String])?.first,
            groups: groups
        )
    }

    private static func profileGroups() -> [String] {
        readEmbeddedProfile()?.groups ?? []
    }

    private static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func readBE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}
