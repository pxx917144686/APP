import Foundation

enum CompactNumber {

    static func string(_ value: Int) -> String {
        let style = IntegerFormatStyle<Int>.number
            .notation(.compactName)
            .locale(LanguageManager.shared.locale)
        return value.formatted(style)
    }
}
