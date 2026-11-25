import Foundation

public enum SigningCapability {

    public struct Resolution: Equatable {
        public let url: URL
        public let identifier: String
    }

    public enum State: Equatable {
        case available(Resolution)
        case unavailable

        public var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }
    }

    public static func groups() -> [String] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fp-no-group") { return [] }
        #endif
        return candidates
    }

    private static let candidates: [String] = {
        var values: [String] = []
        if let configured = Bundle.main.object(forInfoDictionaryKey: "FairPlayAppGroup") as? String,
           !configured.isEmpty {
            values.append(configured)
        }
        values.append(contentsOf: profileGroups)
        values.append(contentsOf: researchGroups)
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }()

    static let profileGroups: [String] = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let start = raw.range(of: Data("<?xml".utf8)),
              let end = raw.range(of: Data("</plist>".utf8), options: .backwards),
              start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(
                from: raw.subdata(in: start.lowerBound..<end.upperBound), format: nil),
              let dictionary = plist as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }()

    static let researchGroups = [
        "group.b049540b2af108ef.1",
        "group.b049540b2af108ef.2",
        "group.b049540b2af108ef.3",
        "group.b049540b2af108ef.4",
        "group.b049540b2af108ef.5",
    ]

    public static let state: State = {
        #if canImport(Darwin)
        let manager = FileManager.default
        for identifier in groups() {
            guard let container = manager.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
                continue
            }
            let probe = container.appendingPathComponent(".probe-\(UUID().uuidString)", isDirectory: true)
            do {
                try manager.createDirectory(at: probe, withIntermediateDirectories: false)
                try? manager.removeItem(at: probe)
            } catch {
                continue
            }
            return .available(Resolution(url: container, identifier: identifier))
        }
        #endif
        return .unavailable
    }()

    public static var resolved: Resolution? {
        if case let .available(value) = state { return value }
        return nil
    }

    public static var isMissingAppGroup: Bool {
        state == .unavailable
    }
}
