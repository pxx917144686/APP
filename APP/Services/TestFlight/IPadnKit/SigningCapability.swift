import Foundation

/// Which App Group this build may actually use, resolved once per process.
///
/// FairPlay only reads packages staged inside a shared container, so a re-sign without
/// `com.apple.security.application-groups` (AltStore, free personal team) has no place to
/// stage at all — the capability does not exist, which is a state, not an error code.
///
/// Sources, in order:
/// 1. `Info.plist` `FairPlayAppGroup` (an explicit override for self-built signing);
/// 2. the entitlements inside the embedded provisioning profile — this is the truth for a
///    re-signed build, and it is what makes the app certificate-independent;
/// 3. the identifiers used by the research builds, kept only as a last resort.
///
/// Every candidate must then pass a real writability probe: `containerURL` returning non-nil
/// is necessary but not sufficient (a container can exist without being usable), so each one
/// gets a directory-creation attempt. No `SecTask*` API is involved: that family is
/// undocumented and would put unrelated review risk on every build.
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

    /// Candidates after the source merge, before probing.
    public static func groups() -> [String] {
        #if DEBUG
        // Simulates "this signing profile grants nothing" without re-signing anything.
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

    /// App Groups granted by the provisioning profile embedded at signing time.
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

    /// Identifiers of the research builds. Last resort only: a build without the entitlement
    /// still fails the probe below, so this cannot fake capability.
    static let researchGroups = [
        "group.b049540b2af108ef.1",
        "group.b049540b2af108ef.2",
        "group.b049540b2af108ef.3",
        "group.b049540b2af108ef.4",
        "group.b049540b2af108ef.5",
    ]

    /// Resolved once per process: parsing the profile on every decrypt run would be waste,
    /// and the answer cannot change while the app is running.
    public static let state: State = {
        #if canImport(Darwin)
        let manager = FileManager.default
        for identifier in groups() {
            guard let container = manager.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
                continue
            }
            // Existence is not usability: prove we can create a directory inside it.
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

    /// True when this signing profile grants no shared container at all — the AltStore /
    /// free-account case, which the UI words in plain language instead of an errno.
    public static var isMissingAppGroup: Bool {
        state == .unavailable
    }
}
