import Foundation

enum RegionNames {

    static func localizedName(for code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count == 2 else { return code }

        if let name = LanguageManager.shared.locale.localizedString(forRegionCode: normalized),
           !name.isEmpty {
            return name
        }
        return normalized
    }
}
