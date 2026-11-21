import Foundation

struct IPadnVersionSource: Sendable {
    let name: String
    let urlTemplate: String
    let containerKey: String
    let reverse: Bool
}

enum IPadnVersionSources {
    static let defaults: [IPadnVersionSource] = [
        .init(name: "iosdump",
              urlTemplate: "https://iosdump.apdoilaan.work/history/{id}",
              containerKey: "data", reverse: false),
        .init(name: "Agzy",
              urlTemplate: "https://app.agzy.cn/searchVersion?appid={id}",
              containerKey: "data", reverse: false),
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
                for (version, versionId, date) in list
                where seen.insert("\(version)|\(versionId)").inserted {
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
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let value: Any? = source.containerKey.isEmpty ? object : (object as? [String: Any])?[source.containerKey]
        guard let records = value as? [[String: Any]] else { return [] }
        let ordered = source.reverse ? Array(records.reversed()) : records
        var out: [(String, String, Date?)] = []
        for record in ordered {
            let versionId = firstValue(record, keys: ["external_identifier", "versionid", "versionId"])
            guard !versionId.isEmpty, versionId.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            let version = firstValue(record, keys: ["bundle_version", "version"])
            let createdAt = firstValue(record, keys: ["created_at", "createTime"])
            out.append((version.isEmpty ? "version_unknown".localized : version, versionId, parseDate(createdAt)))
        }
        return out
    }

    private static func firstValue(_ record: [String: Any], keys: [String]) -> String {
        for key in keys where !plistString(record[key]).isEmpty {
            return plistString(record[key])
        }
        return ""
    }

    private static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        return nil
    }
}
