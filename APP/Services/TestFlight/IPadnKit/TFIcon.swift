import Foundation

public struct TFIconColors: Codable, Equatable, Sendable {
    public var bgHex: String?
    public var gradientHexes: [String]

    public init(bgHex: String? = nil, gradientHexes: [String] = []) {
        self.bgHex = bgHex
        self.gradientHexes = gradientHexes
    }

    public var isEmpty: Bool {
        (bgHex == nil || bgHex?.isEmpty == true) && gradientHexes.isEmpty
    }
}

public struct TFIconAsset: Codable, Equatable, Sendable {
    public var urlTemplate: String?
    public var colors: TFIconColors?
    public var buildID: String?
    public var cachedAt: Date?

    public init(urlTemplate: String? = nil, colors: TFIconColors? = nil,
                buildID: String? = nil, cachedAt: Date? = nil) {
        self.urlTemplate = urlTemplate
        self.colors = colors
        self.buildID = buildID
        self.cachedAt = cachedAt
    }
}

public enum TFIcon {
    public static let cacheTTL: TimeInterval = 7 * 24 * 3600

    public static func pickTemplate(from iconSet: [[String: Any]]) -> String? {
        pickAsset(from: iconSet)?.urlTemplate
    }

    public static func pickAsset(from iconSet: [[String: Any]], buildID: String? = nil) -> TFIconAsset? {
        let ordered = iconSet.sorted { lhs, rhs in
            (lhs["iconType"] as? String) == "largeApp" && (rhs["iconType"] as? String) != "largeApp"
        }
        var chosenTemplate: String?
        var chosenColors: TFIconColors?
        for item in ordered {
            guard let asset = item["iconAsset"] as? [String: Any] else { continue }
            if chosenTemplate == nil, let value = asset["URLTemplate"] as? String, value.contains("http") {
                chosenTemplate = value
            }
            if chosenColors == nil, let colors = parseColors(from: asset), !colors.isEmpty {
                chosenColors = colors
            }
            if chosenTemplate != nil && chosenColors != nil { break }
        }
        guard chosenTemplate != nil || chosenColors != nil else { return nil }
        return TFIconAsset(urlTemplate: chosenTemplate, colors: chosenColors, buildID: buildID)
    }

    private static func parseColors(from asset: [String: Any]) -> TFIconColors? {
        var bg: String?
        var gradient: [String] = []

        if let colors = asset["colors"] as? [String: Any] {
            for key in ["bg", "bgColor", "backgroundColor", "background"] {
                if let raw = colors[key] as? String, let hex = normalizeHex(raw) {
                    bg = hex
                    break
                }
            }
            if let list = colors["gradient"] as? [String] {
                gradient = list.compactMap(normalizeHex)
            } else if let dict = colors["gradient"] as? [String: Any] {
                let top = (dict["top"] as? String) ?? (dict["start"] as? String) ?? (dict["from"] as? String)
                let bottom = (dict["bottom"] as? String) ?? (dict["end"] as? String) ?? (dict["to"] as? String)
                gradient = [top, bottom].compactMap { $0.flatMap(normalizeHex) }
            }
        }
        if bg == nil {
            for key in ["bgColor", "bg", "backgroundColor"] {
                if let raw = asset[key] as? String, let hex = normalizeHex(raw) {
                    bg = hex
                    break
                }
            }
        }
        let result = TFIconColors(bgHex: bg, gradientHexes: gradient)
        return result.isEmpty ? nil : result
    }

    private static func normalizeHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard (stripped.count == 6 || stripped.count == 8), stripped.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return "#" + stripped.uppercased()
    }

    public static func url(from template: String, side: Int = 128) -> URL? {
        var text = template
        text = text.replacingOccurrences(of: "{w}", with: String(side))
        text = text.replacingOccurrences(of: "{h}", with: String(side))
        text = text.replacingOccurrences(of: "{c}", with: "bb")
        text = text.replacingOccurrences(of: "{f}", with: "png")
        guard !text.contains("{"), !text.contains("}") else { return nil }
        return URL(string: text)
    }

    public static func directory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("TestFlight/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public static func cached(appID: String) -> URL? {
        let url = directory().appendingPathComponent(appID + ".png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func resolvedURL(storedURL: URL?, appID: String?) -> URL? {
        if let storedURL {
            if storedURL.isFileURL {
                if FileManager.default.fileExists(atPath: storedURL.path) { return storedURL }
            } else if let scheme = storedURL.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" {
                return storedURL
            }
        }
        if let appID, !appID.isEmpty, let current = cached(appID: appID) {
            return current
        }
        return nil
    }

    private static func metaURL(appID: String) -> URL {
        directory().appendingPathComponent(appID + ".meta.json")
    }

    public static func cachedAsset(appID: String) -> TFIconAsset? {
        guard let data = try? Data(contentsOf: metaURL(appID: appID)) else { return nil }
        return try? JSONDecoder().decode(TFIconAsset.self, from: data)
    }

    public static func saveAsset(_ asset: TFIconAsset, appID: String) {
        guard let data = try? JSONEncoder().encode(asset) else { return }
        try? data.write(to: metaURL(appID: appID), options: .atomic)
    }

    public static func isCacheFresh(appID: String, buildID: String? = nil, template: String? = nil,
                                    now: Date = Date()) -> Bool {
        guard let png = cached(appID: appID) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: png.path)
        let modified = (attrs?[.modificationDate] as? Date) ?? .distantPast
        guard now.timeIntervalSince(modified) < cacheTTL else { return false }
        if let meta = cachedAsset(appID: appID) {
            if let buildID, !buildID.isEmpty, let oldBuild = meta.buildID, !oldBuild.isEmpty, oldBuild != buildID {
                return false
            }
            if let template, !template.isEmpty, let oldTemplate = meta.urlTemplate, !oldTemplate.isEmpty, oldTemplate != template {
                return false
            }
        }
        return true
    }

    @discardableResult
    public static func cache(appID: String, template: String?,
                             log: @escaping @Sendable (String) -> Void) async -> URL? {
        let asset = template.map { TFIconAsset(urlTemplate: $0) }
        return await cache(appID: appID, asset: asset, force: false, log: log)
    }

    @discardableResult
    public static func cache(appID: String, asset: TFIconAsset?, force: Bool = false,
                             log: @escaping @Sendable (String) -> Void) async -> URL? {
        let existing = cached(appID: appID)
        if !force, isCacheFresh(appID: appID, buildID: asset?.buildID, template: asset?.urlTemplate), let existing {
            if var updated = asset {
                updated.cachedAt = cachedAsset(appID: appID)?.cachedAt ?? Date()
                saveAsset(updated, appID: appID)
            }
            return existing
        }
        if var metadata = asset {
            metadata.cachedAt = Date()
            saveAsset(metadata, appID: appID)
        }
        guard let template = asset?.urlTemplate, let url = url(from: template) else {
            log("icon: " + appID + " 无来源（TF-only 应用用占位）")
            return existing
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, http) = try? await TFNet.data(for: request, cookieStorage: nil, acceptCookies: false),
              http.statusCode == 200, data.count > 512 else {
            log("icon: " + appID + " 下载失败（host " + (url.host ?? "-") + "）")
            return existing
        }
        let target = directory().appendingPathComponent(appID + ".png")
        guard (try? data.write(to: target, options: .atomic)) != nil else { return existing }
        if var metadata = asset {
            metadata.cachedAt = Date()
            saveAsset(metadata, appID: appID)
        }
        log("icon: " + appID + " 缓存 " + String(data.count) + " B"
            + (asset?.buildID.map { " (build \($0))" } ?? ""))
        return target
    }

    public static func publicArtworkAsset(appID: String, country: String? = nil,
                                          log: @escaping @Sendable (String) -> Void) async -> TFIconAsset? {
        var countries = ["cn", "us", "hk", "jp", "tw"]
        if let country, !country.isEmpty {
            countries = [country.lowercased()] + countries.filter { $0 != country.lowercased() }
        }
        for country in countries {
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(appID)&country=\(country)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            guard let (data, http) = try? await TFNet.data(for: request, cookieStorage: nil, acceptCookies: false),
                  http.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [[String: Any]],
                  let first = results.first else { continue }
            let raw = (first["artworkUrl512"] as? String)
                ?? (first["artworkUrl100"] as? String)
                ?? (first["artworkUrl60"] as? String)
            if let raw, raw.contains("http") {
                log("icon: \(appID) 命中公开商店图标 (\(country))")
                return TFIconAsset(urlTemplate: raw, colors: nil, buildID: nil)
            }
        }
        return nil
    }
}
