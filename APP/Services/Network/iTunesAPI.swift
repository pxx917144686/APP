import Foundation

enum SearchError: Error, LocalizedError {
    case networkError(Error)
    case invalidResponse
    case noResults
    case invalidAppIdentifier
    case rateLimited
    case emptyQuery
    case invalidLimit
    case invalidBundleId
    case invalidTrackId
    case missingIdentifier
    case appNotFound
    var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .invalidResponse:
            return "无效的API响应"
        case .noResults:
            return "未找到相关应用"
        case .invalidAppIdentifier:
            return "无效的应用标识符"
        case .rateLimited:
            return "请求频率过高，请稍后重试"
        case .emptyQuery:
            return "搜索词不能为空"
        case .invalidLimit:
            return "搜索结果数量限制无效（1-200）"
        case .invalidBundleId:
            return "无效的应用包标识符"
        case .invalidTrackId:
            return "无效的Track ID"
        case .missingIdentifier:
            return "缺少应用标识符或Track ID"
        case .appNotFound:
            return "未找到指定的应用"
        }
    }
}

enum DeviceFamily: String, CaseIterable, Codable {
    case phone = "iPhone"
    case pad = "iPad"

    static let `default` = DeviceFamily.phone

    var displayName: String {
        switch self {
        case .phone:
            return "iPhone"
        case .pad:
            return "iPad"
        }
    }

    var softwareType: String {
        switch self {
        case .phone: return "software"
        case .pad: return "iPadSoftware"
        }
    }

    var identifier: String {
        return self.rawValue
    }
}

struct iTunesResponse: Codable {
    let resultCount: Int
    let results: [iTunesSearchResult]
}

struct iTunesSearchResult: Codable, Identifiable, Hashable {
    let trackId: Int
    let trackName: String
    let artistName: String?
    let bundleId: String
    let version: String
    let formattedPrice: String?
    let price: Double?
    let currency: String?
    let trackViewUrl: String
    let artworkUrl60: String?
    let artworkUrl100: String?
    let artworkUrl512: String?
    let screenshotUrls: [String]?
    let ipadScreenshotUrls: [String]?
    let description: String?
    let releaseNotes: String?
    let sellerName: String?
    let genres: [String]?
    let primaryGenreName: String?
    let contentAdvisoryRating: String?
    let averageUserRating: Double?
    let userRatingCount: Int?
    let fileSizeBytes: String?
    let minimumOsVersion: String?
    let currentVersionReleaseDate: String?
    let releaseDate: String?
    let isGameCenterEnabled: Bool?
    let supportedDevices: [String]?
    let languageCodesISO2A: [String]?
    let advisories: [String]?
    let features: [String]?

    var id: Int { trackId }

    enum CodingKeys: String, CodingKey {
        case trackId, trackName, artistName, bundleId, version, formattedPrice, price, currency, trackViewUrl
        case artworkUrl60, artworkUrl100, artworkUrl512
        case screenshotUrls, ipadScreenshotUrls, description, releaseNotes
        case sellerName, genres, primaryGenreName, contentAdvisoryRating
        case averageUserRating, userRatingCount, fileSizeBytes
        case minimumOsVersion, currentVersionReleaseDate, releaseDate
        case isGameCenterEnabled, supportedDevices, languageCodesISO2A
        case advisories, features
    }
}

@MainActor
class iTunesClient: @unchecked Sendable {
    static let shared = iTunesClient()
    private let session: URLSession
    private let baseURL = "https://itunes.apple.com"

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
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.networkServiceType = .responsiveData
        self.session = URLSession(configuration: config)
    }

    private func storefrontCode(for countryCode: String) -> String {
        let cc = countryCode.uppercased()
        return Apple.storeFrontCodeMap[cc] ?? "143441"
    }
    private func appsPageURL(country: String, appId: Int) -> URL {
        return URL(string: "https://apps.apple.com/\(country)/app/id\(appId)")!
    }
    private func fetchAMPTargetToken(country: String, appId: Int) async throws -> String {
        let url = appsPageURL(country: country, appId: appId)
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw SearchError.invalidResponse
        }

        let patterns = [
            #"token%22%3A%22([^%]+)%22%7D"#,
            #""token":"([^"]+)""#,
            #"token%22%3A%22([a-zA-Z0-9_\-]+)\"#,
            #"media-api.*?token.*?([a-zA-Z0-9_\.]{50,})"#
        ]

        for pattern in patterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(location: 0, length: html.utf16.count)
            if let match = regex?.firstMatch(in: html, options: [], range: range), match.numberOfRanges >= 2,
               let tokenRange = Range(match.range(at: 1), in: html) {
                let token = String(html[tokenRange])
                if !token.isEmpty {
                    return token
                }
            }
        }

        throw SearchError.invalidResponse
    }

    func search(
        term: String,
        limit: Int = 50,
        countryCode: String = "",
        deviceFamily: DeviceFamily = .phone
    ) async throws -> [iTunesSearchResult]? {
        var components = URLComponents(string: "\(baseURL)/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: countryCode.lowercased()),
            URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "entity", value: deviceFamily.softwareType),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("iTunes/12.12.0 (Macintosh; OS X 10.15.7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        let iTunesResponse = try decoder.decode(iTunesResponse.self, from: data)
        return iTunesResponse.results.isEmpty ? nil : iTunesResponse.results
    }

    func lookup(
        bundleIdentifier: String,
        countryCode: String = "",
        deviceFamily: DeviceFamily = .phone
    ) async throws -> iTunesSearchResult? {
        var components = URLComponents(string: "\(baseURL)/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier),
            URLQueryItem(name: "country", value: countryCode.lowercased()),
            URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "entity", value: deviceFamily.softwareType),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("iTunes/12.12.0 (Macintosh; OS X 10.15.7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        let iTunesResponse = try decoder.decode(iTunesResponse.self, from: data)
        return iTunesResponse.resultCount > 0 ? iTunesResponse.results.first : nil
    }

    enum ReviewSort: String { case mostRecent = "mostRecent", mostHelpful = "mostHelpful" }
    struct AppReview: Codable, Identifiable, Hashable {
        let id: String
        let userName: String
        let userUrl: String
        let version: String
        let score: Int
        let title: String
        let text: String
        let url: String
        let updated: String
    }
    func reviews(
        id: Int,
        country: String = "",
        page: Int = 1,
        sort: ReviewSort = .mostRecent
    ) async throws -> [AppReview] {
        let url = URL(string: "https://itunes.apple.com/\(country.isEmpty ? "us" : country)/rss/customerreviews/page=\(page)/id=\(id)/sortby=\(sort.rawValue)/json")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SearchError.invalidResponse }

        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let feed = json?["feed"] as? [String: Any]
        let entries = (feed?["entry"] as? [[String: Any]]) ?? []
        let map: ( [String: Any] ) -> AppReview? = { entry in
            guard let id = (entry["id"] as? [String: Any])?["label"] as? String,
                  let author = entry["author"] as? [String: Any],
                  let name = (author["name"] as? [String: Any])?["label"] as? String,
                  let uri = (author["uri"] as? [String: Any])?["label"] as? String,
                  let version = ((entry["im:version"] as? [String: Any])?["label"]) as? String,
                  let ratingStr = ((entry["im:rating"] as? [String: Any])?["label"]) as? String,
                  let rating = Int(ratingStr),
                  let title = (entry["title"] as? [String: Any])?["label"] as? String,
                  let text = (entry["content"] as? [String: Any])?["label"] as? String,
                  let link = (entry["link"] as? [String: Any])?["attributes"] as? [String: Any],
                  let href = link["href"] as? String,
                  let updated = (entry["updated"] as? [String: Any])?["label"] as? String
            else { return nil }
            return AppReview(id: id, userName: name, userUrl: uri, version: version, score: rating, title: title, text: text, url: href, updated: updated)
        }
        return entries.compactMap(map)
    }

    struct AppVersionInfo: Codable, Identifiable, Hashable {

        let version: String

        let releaseDate: Date

        let releaseNotes: String?

        var id: String { "\(version)_\(releaseDate.timeIntervalSince1970)" }

        var formattedDate: String {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: releaseDate)
        }

        enum CodingKeys: String, CodingKey {
            case version = "versionDisplay"
            case releaseDate = "releaseDate"
            case releaseNotes = "releaseNotes"
            case releaseTimestamp = "releaseTimestamp"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encodeIfPresent(releaseNotes, forKey: .releaseNotes)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let dateString = formatter.string(from: releaseDate)
            try container.encode(dateString, forKey: .releaseDate)
        }

        init(version: String, releaseDate: Date, releaseNotes: String?) {
            self.version = version
            self.releaseDate = releaseDate
            self.releaseNotes = releaseNotes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(String.self, forKey: .version)
            releaseNotes = try container.decodeIfPresent(String.self, forKey: .releaseNotes)

            let dateString = try container.decode(String.self, forKey: .releaseDate)
            let timestampString = try container.decodeIfPresent(String.self, forKey: .releaseTimestamp)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            if let date = formatter.date(from: dateString) {
                releaseDate = date
            } else if let timestampString = timestampString,
                      let timestamp = TimeInterval(timestampString) {
                releaseDate = Date(timeIntervalSince1970: timestamp / 1000.0)
            } else {

                releaseDate = Date()
            }
        }
    }

    func versionHistory(id: Int, country: String = "US") async throws -> [AppVersionInfo] {
        let countryCode = country.isEmpty ? "US" : country

        if let versions = try? await fetchVersionHistoryFromAMPApi(id: id, country: countryCode) {
            return versions
        }

        if let versions = try? await fetchVersionHistoryFromLookupApi(id: id, country: countryCode) {
            return versions
        }

        throw SearchError.invalidResponse
    }

    private func fetchVersionHistoryFromAMPApi(id: Int, country: String) async throws -> [AppVersionInfo] {
        let token = try await fetchAMPTargetToken(country: country, appId: id)
        let urlString = "https://amp-api-edge.apps.apple.com/v1/catalog/\(country.lowercased())/apps/\(id)?platform=web&extend=versionHistory"
        guard let url = URL(string: urlString) else {
            throw SearchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("https://apps.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SearchError.invalidResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let firstApp = dataArray.first,
              let attributes = firstApp["attributes"] as? [String: Any] else {
            throw SearchError.invalidResponse
        }

        if let platformAttrs = attributes["platformAttributes"] as? [String: Any] {
            for platformKey in ["ios", "iPhone OS", "ipad", "appleTV", "mac"] {
                if let platform = platformAttrs[platformKey] as? [String: Any],
                   let versions = platform["versionHistory"] as? [Any], !versions.isEmpty {
                    return try parseVersionHistory(from: versions)
                }
            }
        }

        if let versions = attributes["versionHistory"] as? [Any], !versions.isEmpty {
            return try parseVersionHistory(from: versions)
        }

        if let relationships = attributes["platformAttributes"] as? [String: Any] ?? attributes["relationships"] as? [String: Any] {
            for (_, value) in relationships {
                if let dict = value as? [String: Any],
                   let versions = dict["versionHistory"] as? [Any], !versions.isEmpty {
                    return try parseVersionHistory(from: versions)
                }
            }
        }

        throw SearchError.invalidResponse
    }

    private func fetchVersionHistoryFromLookupApi(id: Int, country: String) async throws -> [AppVersionInfo] {
        let url = URL(string: "\(baseURL)/lookup?id=\(id)&country=\(country.lowercased())")!
        let (data, _) = try await session.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let firstResult = results.first else {
            throw SearchError.invalidResponse
        }

        var versions: [AppVersionInfo] = []

        if let version = firstResult["version"] as? String,
           let currentVersionReleaseDate = firstResult["currentVersionReleaseDate"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let releaseDate = formatter.date(from: currentVersionReleaseDate) ?? Date()

            let versionInfo = AppVersionInfo(
                version: version,
                releaseDate: releaseDate,
                releaseNotes: firstResult["releaseNotes"] as? String
            )
            versions.append(versionInfo)
        }

        if let versionHistory = firstResult["versionHistory"] as? [[String: Any]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            for item in versionHistory {
                if let version = item["version"] as? String,
                   let releaseDateStr = item["releaseDate"] as? String,
                   let releaseDate = formatter.date(from: releaseDateStr) {
                    let versionInfo = AppVersionInfo(
                        version: version,
                        releaseDate: releaseDate,
                        releaseNotes: item["releaseNotes"] as? String
                    )
                    versions.append(versionInfo)
                }
            }
        }

        return versions.sorted { $0.releaseDate > $1.releaseDate }
    }

    private func parseVersionHistory(from jsonArray: [Any]) throws -> [AppVersionInfo] {
        let decoder = JSONDecoder()
        let data = try JSONSerialization.data(withJSONObject: jsonArray)
        return try decoder.decode([AppVersionInfo].self, from: data)
    }

    struct SuggestTerm: Codable, Identifiable, Hashable { let term: String; var id: String { term } }

    func suggest(term: String) async throws -> [SuggestTerm] {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        let url = URL(string: "https://search.itunes.apple.com/WebObjects/MZSearchHints.woa/wa/hints?clientApplication=Software&term=\(encoded)")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SearchError.invalidResponse }
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: Any],
              let arr = ((dict["plist"] as? [String: Any])?["dict"] as? [String: Any])?["array"] as? [[String: Any]] ?? (dict["array"] as? [[String: Any]]),
              let list = arr.first? ["dict"] as? [[String: Any]] else { return [] }
        var terms: [SuggestTerm] = []
        for entry in list {
            if let s = entry["string"] as? [String], let t = s.first { terms.append(SuggestTerm(term: t)) }
        }
        return terms
    }
}

extension iTunesSearchResult {

    var name: String { trackName }
}
