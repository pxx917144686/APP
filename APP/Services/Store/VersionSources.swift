import Foundation

struct IPadnVersionSource: Sendable {
    let name: String
    let urlTemplate: String
    let containerKey: String
    let reverse: Bool
}

enum IPadnVersionSources {
    static let defaults: [IPadnVersionSource] = [
        .init(name: "Timbrd",
              urlTemplate: "https://api.timbrd.com/apple/app-version/index.php?id={id}",
              containerKey: "", reverse: true),
        .init(name: "Bilin",
              urlTemplate: "https://apis.bilin.eu.org/history/{id}",
              containerKey: "data", reverse: false)
    ]

    static func fetch(appID: String) async -> [(version: String, versionId: String, releaseDate: Date?)] {
        await withTaskGroup(of: [(String, String, Date?)].self) { group in
            for source in defaults {
                group.addTask { await fetchOne(appID: appID, source: source) }
            }
            var merged: [(String, String, Date?)] = []
            var seen = Set<String>()
            for await list in group {
                for (version, versionId, date) in list where seen.insert(versionId).inserted {
                    merged.append((version, versionId, date))
                }
            }
            return merged
        }
    }

    private static func fetchOne(appID: String, source: IPadnVersionSource) async -> [(String, String, Date?)] {
        guard let url = URL(string: source.urlTemplate.replacingOccurrences(of: "{id}", with: appID)),
              url.scheme == "https" else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let value: Any? = source.containerKey.isEmpty ? object : (object as? [String: Any])?[source.containerKey]
        guard let records = value as? [[String: Any]] else { return [] }
        let ordered = source.reverse ? Array(records.reversed()) : records
        var out: [(String, String, Date?)] = []
        for record in ordered {
            let versionId = plistString(record["external_identifier"]).isEmpty
                ? plistString(record["versionid"]) : plistString(record["external_identifier"])
            guard !versionId.isEmpty, versionId.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            let version = plistString(record["bundle_version"]).isEmpty
                ? plistString(record["version"]) : plistString(record["bundle_version"])
            out.append((version.isEmpty ? "version_unknown".localized : version, versionId, parseDate(plistString(record["created_at"]))))
        }
        return out
    }

    private static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}
