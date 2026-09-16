import Foundation

enum CountryHelpers {
    static func flag(country: String) -> String {
        let base: UInt32 = 127397
        var s = ""
        for v in country.uppercased().unicodeScalars {
            if let scalar = UnicodeScalar(base + v.value) {
                s.unicodeScalars.append(scalar)
            }
        }
        return s
    }

    static func countryName(_ code: String) -> String {
        let locale = LanguageManager.shared.locale
        return locale.localizedString(forRegionCode: code) ?? code.uppercased()
    }
}
