import Foundation

typealias iTunesSearchResponse = iTunesResponse

public struct StoreAppVersion: Codable, Identifiable {
    public let id: UUID
    public var versionString: String
    public let versionId: String
    public let isCurrent: Bool
    public var releaseDate: Date?
    public var releaseNotes: String?

    public init(versionString: String, versionId: String, isCurrent: Bool, releaseDate: Date? = nil, releaseNotes: String? = nil) {
        self.id = UUID()
        self.versionString = versionString
        self.versionId = versionId
        self.isCurrent = isCurrent
        self.releaseDate = releaseDate
        self.releaseNotes = releaseNotes
    }

    public var displayName: String {
        return isCurrent ? "\(versionString) (当前版本)" : versionString
    }

    public var formattedReleaseDate: String? {
        guard let date = releaseDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

private struct BilinResponse: Codable {
    let code: Int?
    let msg: String?
    let total: Int?
    let data: [BilinAppVersion]?
}

private struct BilinAppVersion: Codable {
    let bundle_version: String
    let external_identifier: String
    let created_at: String?
    let size: String?
}

private struct AgzyResponse: Codable {
    let code: Int?
    let msg: String?
    let count: Int?
    let data: [AgzyAppVersion]?
}

private struct AgzyAppVersion: Codable {
    let version: String
    let versionId: Int
    let createTime: String?
    let size: String?
}

@MainActor
public class StoreClient: @unchecked Sendable {
    public static let shared = StoreClient()
    private let session: URLSession
    private init() {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
            "HTTPProxy": "",
            "HTTPSProxy": "",
            "SOCKSProxy": ""
        ]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        self.session = URLSession(configuration: config)
    }

    public func getAppVersions(
        trackId: String,
        account: Account,
        countryCode: String? = nil
    ) async -> Result<[StoreAppVersion], StoreError> {
        if let thirdPartyVersions = try? await fetchVersionsFromThirdPartyAPI(appId: trackId), !thirdPartyVersions.isEmpty {
            return .success(thirdPartyVersions)
        }
        if let trackIdInt = Int(trackId) {
            let regionToUse = countryCode ?? account.countryCode
            let primaryCountry = regionToUse.isEmpty ? "US" : regionToUse
            let countries = primaryCountry.uppercased() == "US" ? ["US"] : [primaryCountry, "US"]
            for cc in countries {
                if let infos = try? await iTunesClient.shared.versionHistory(id: trackIdInt, country: cc), !infos.isEmpty {
                    let list = infos.enumerated().map { idx, info in
                        StoreAppVersion(
                            versionString: info.version,
                            versionId: "",
                            isCurrent: idx == 0,
                            releaseDate: info.releaseDate,
                            releaseNotes: info.releaseNotes
                        )
                    }
                    if !list.isEmpty {
                        return .success(list)
                    }
                }
            }
        }
        return .failure(.invalidItem)
    }

    private func fetchVersionsFromThirdPartyAPI(appId: String) async throws -> [StoreAppVersion]? {
        if let v = try? await fetchVersionsFromBilin(appId: appId), !v.isEmpty {
            return v
        }
        if let v = try? await fetchVersionsFromAgzy(appId: appId), !v.isEmpty {
            return v
        }
        return nil
    }

    private func fetchVersionsFromBilin(appId: String) async throws -> [StoreAppVersion]? {
        let apiUrl = "https://apis.bilin.eu.org/history/\(appId)"
        guard let url = URL(string: apiUrl) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15.0)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
        let decoder = JSONDecoder()
        let wrapped = try decoder.decode(BilinResponse.self, from: data)
        guard let list = wrapped.data, !list.isEmpty else { return nil }
        let sorted = list.sorted { a, b -> Bool in
            let d1 = (a.created_at ?? ""), d2 = (b.created_at ?? "")
            if let date1 = parseDate(d1), let date2 = parseDate(d2) {
                return date1 > date2
            }
            return compareVersionStrings(a.bundle_version, b.bundle_version) > 0
        }
        let currentVer = sorted.first?.bundle_version
        return sorted.enumerated().map { idx, info in
            StoreAppVersion(
                versionString: info.bundle_version,
                versionId: info.external_identifier,
                isCurrent: info.bundle_version == currentVer,
                releaseDate: parseDate(info.created_at ?? "")
            )
        }
    }

    private func fetchVersionsFromAgzy(appId: String) async throws -> [StoreAppVersion]? {
        let apiUrl = "https://app.agzy.cn/searchVersion?appid=\(appId)"
        guard let url = URL(string: apiUrl) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15.0)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
        let decoder = JSONDecoder()
        let wrapped = try decoder.decode(AgzyResponse.self, from: data)
        guard let list = wrapped.data, !list.isEmpty else { return nil }
        let sorted = list.sorted { a, b -> Bool in
            let d1 = (a.createTime ?? ""), d2 = (b.createTime ?? "")
            if let date1 = parseDate(d1), let date2 = parseDate(d2) {
                return date1 > date2
            }
            return compareVersionStrings(a.version, b.version) > 0
        }
        let currentVer = sorted.first?.version
        return sorted.enumerated().map { idx, info in
            StoreAppVersion(
                versionString: info.version,
                versionId: String(info.versionId),
                isCurrent: info.version == currentVer,
                releaseDate: parseDate(info.createTime ?? "")
            )
        }
    }

    private func parseDate(_ dateString: String) -> Date? {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"]
        for fmt in formats {
            dateFormatter.dateFormat = fmt
            if let d = dateFormatter.date(from: dateString) {
                return d
            }
        }
        return nil
    }

    private func compareVersionStrings(_ v1: String, _ v2: String) -> Int {
        let components1 = v1.split(separator: ".").compactMap { Int($0) }
        let components2 = v2.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(components1.count, components2.count) {
            let num1 = i < components1.count ? components1[i] : 0
            let num2 = i < components2.count ? components2[i] : 0
            if num1 > num2 { return 1 }
            else if num1 < num2 { return -1 }
        }
        return 0
    }
}
