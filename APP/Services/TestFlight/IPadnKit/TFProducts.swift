import Foundation

public enum TFProducts {

    public struct Product {
        public let buildID: String
        public let ipa: URL
        public let directory: URL
        public let version: String?
        public let platform: String?
        public let downloadedAt: Date?
    }

    public static func newest(bundle: String) -> Product? {
        all(bundle: bundle).first
    }

    public static func newest(bundle: String, matchingPlatform platform: String) -> Product? {
        let target = platform.lowercased()
        return all(bundle: bundle).first { product in
            guard let recorded = product.platform?.lowercased(), !recorded.isEmpty else {
                return target == "ios"
            }
            return recorded == target
        }
    }

    public static func product(bundle: String, buildID: String) -> Product? {
        guard !buildID.isEmpty else { return newest(bundle: bundle) }
        return all(bundle: bundle).first { $0.buildID == buildID }
    }

    public static func all(bundle: String) -> [Product] {
        guard let root = TFDownload.directoryURL(bundle: bundle),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var found: [Product] = []
        for name in entries {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            let ipa = directory.appendingPathComponent(bundle + ".ipa")
            guard FileManager.default.fileExists(atPath: ipa.path) else { continue }
            let meta = metadata(in: directory)
            found.append(Product(buildID: name,
                                 ipa: ipa,
                                 directory: directory,
                                 version: meta?["version"] as? String,
                                 platform: meta?["platform"] as? String,
                                 downloadedAt: (meta?["downloadedAt"] as? String).flatMap { TFAppDetail.parseISO8601($0) }))
        }
        return found.sorted { lhs, rhs in
            if lhs.buildID == "legacy" { return false }
            if rhs.buildID == "legacy" { return true }
            return (Int64(lhs.buildID) ?? 0) > (Int64(rhs.buildID) ?? 0)
        }
    }

    static func metadata(in directory: URL) -> [String: Any]? {
        let url = directory.appendingPathComponent("product.json")
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return payload
    }

    @discardableResult
    public static func migrateFlatLayout() -> Int {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("TestFlight", isDirectory: true)
        guard let bundles = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return 0 }
        var moved = 0
        for bundle in bundles where bundle.contains(".") {
            let bundleDir = root.appendingPathComponent(bundle, isDirectory: true)
            let flat = bundleDir.appendingPathComponent(bundle + ".ipa")
            guard FileManager.default.fileExists(atPath: flat.path) else {
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: bundleDir.path),
                   contents.isEmpty {
                    try? FileManager.default.removeItem(at: bundleDir)
                }
                continue
            }
            let target = bundleDir.appendingPathComponent("legacy", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let destination = target.appendingPathComponent(bundle + ".ipa")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: flat, to: destination)
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
                TFDownload.writeProductMeta(directory: target, bundle: bundle, buildID: "legacy",
                                            versionLabel: nil, bytes: size)
                moved += 1
            } catch {
                TFLog.append("migrate: " + bundle + " 迁移失败 " + error.localizedDescription)
            }
        }
        if moved > 0 { TFLog.append("migrate: 旧布局产物 " + String(moved) + " 个 -> <bundle>/legacy/") }
        return moved
    }
}
