import Foundation

public enum TFBundleName {

    public struct Resolution {
        public let name: String
        public let source: String
    }

    public static func resolve(ipa: URL, language: String? = nil) -> Resolution? {
        guard let archive = try? ZipReader(url: ipa) else { return nil }
        let lang = language ?? Locale.preferredLanguages.first ?? "en"
        let short = String(lang.split(separator: "-").first ?? "en")

        if let data = archive.data(named: "iTunesMetadata.plist"),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let item = plist["itemName"] as? String, !item.isEmpty {
            return Resolution(name: item, source: "iTunesMetadata.itemName")
        }

        guard let appPath = archive.entire.first(where: {
            $0.hasPrefix("Payload/") && $0.hasSuffix(".app/Info.plist")
        }) else { return nil }
        let prefix = String(appPath.dropLast("Info.plist".count))

        let candidates = archive.entire.filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(".lproj/InfoPlist.strings")
        }
        let ordered = candidates.sorted { lhs, rhs in
            let left = ((lhs as NSString).deletingLastPathComponent as NSString).lastPathComponent
                .replacingOccurrences(of: ".lproj", with: "")
            let right = ((rhs as NSString).deletingLastPathComponent as NSString).lastPathComponent
                .replacingOccurrences(of: ".lproj", with: "")
            return rank(left, lang: lang, short: short) < rank(right, lang: lang, short: short)
        }
        for path in ordered {
            let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let folderName = folder.replacingOccurrences(of: ".lproj", with: "")
            guard folderName == lang || folderName == short || folderName.hasPrefix(short) else { continue }
            guard let data = archive.data(named: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = plist[key] as? String, !value.isEmpty {
                    return Resolution(name: value, source: folderName + ".InfoPlist.strings")
                }
            }
        }

        if let data = archive.data(named: appPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = plist[key] as? String, !value.isEmpty {
                    return Resolution(name: value, source: "Info.plist." + key)
                }
            }
        }
        return nil
    }

    private static func rank(_ folder: String, lang: String, short: String) -> Int {
        if folder == lang { return 0 }
        if folder == short { return 1 }
        if folder.hasPrefix(short) { return 2 }
        return 3
    }

    public static func isDegraded(_ new: String, over old: String) -> Bool {
        guard !old.isEmpty else { return false }
        let newIsASCII = new.allSatisfy { $0.isASCII }
        let oldHasNonASCII = old.contains { !$0.isASCII }
        return newIsASCII && oldHasNonASCII
    }
}
