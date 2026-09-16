import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case es = "es"
    case fr = "fr"
    case de = "de"
    case it = "it"
    case pt = "pt"
    case ru = "ru"
    case ar = "ar"
    case hi = "hi"
    case th = "th"
    case vi = "vi"
    case id = "id"
    case ms = "ms"
    case nl = "nl"
    case sv = "sv"
    case da = "da"
    case fi = "fi"
    case nb = "nb"
    case pl = "pl"
    case cs = "cs"
    case hu = "hu"
    case ro = "ro"
    case tr = "tr"
    case uk = "uk"
    case el = "el"
    case he = "he"
    case sk = "sk"
    case hr = "hr"
    case ca = "ca"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return LanguageManager.localized("system_language")
        case .zhHans:
            return LanguageManager.localized("lang_chinese_simplified")
        case .en:
            return LanguageManager.localized("lang_english")
        case .ja:
            return LanguageManager.localized("lang_japanese")
        case .ko:
            return LanguageManager.localized("lang_korean")
        case .es:
            return LanguageManager.localized("lang_spanish")
        case .fr:
            return LanguageManager.localized("lang_french")
        case .de:
            return LanguageManager.localized("lang_german")
        case .it:
            return LanguageManager.localized("lang_italian")
        case .pt:
            return LanguageManager.localized("lang_portuguese")
        case .ru:
            return LanguageManager.localized("lang_russian")
        case .ar:
            return LanguageManager.localized("lang_arabic")
        case .hi:
            return LanguageManager.localized("lang_hindi")
        case .th:
            return LanguageManager.localized("lang_thai")
        case .vi:
            return LanguageManager.localized("lang_vietnamese")
        case .id:
            return LanguageManager.localized("lang_indonesian")
        case .ms:
            return LanguageManager.localized("lang_malay")
        case .nl:
            return LanguageManager.localized("lang_dutch")
        case .sv:
            return LanguageManager.localized("lang_swedish")
        case .da:
            return LanguageManager.localized("lang_danish")
        case .fi:
            return LanguageManager.localized("lang_finnish")
        case .nb:
            return LanguageManager.localized("lang_norwegian")
        case .pl:
            return LanguageManager.localized("lang_polish")
        case .cs:
            return LanguageManager.localized("lang_czech")
        case .hu:
            return LanguageManager.localized("lang_hungarian")
        case .ro:
            return LanguageManager.localized("lang_romanian")
        case .tr:
            return LanguageManager.localized("lang_turkish")
        case .uk:
            return LanguageManager.localized("lang_ukrainian")
        case .el:
            return LanguageManager.localized("lang_greek")
        case .he:
            return LanguageManager.localized("lang_hebrew")
        case .sk:
            return LanguageManager.localized("lang_slovak")
        case .hr:
            return LanguageManager.localized("lang_croatian")
        case .ca:
            return LanguageManager.localized("lang_catalan")
        }
    }

    var nativeName: String {
        switch self {
        case .system: return "system_language".localized
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .ru: return "Русский"
        case .ar: return "العربية"
        case .hi: return "हिन्दी"
        case .th: return "ไทย"
        case .vi: return "Tiếng Việt"
        case .id: return "Bahasa Indonesia"
        case .ms: return "Bahasa Melayu"
        case .nl: return "Nederlands"
        case .sv: return "Svenska"
        case .da: return "Dansk"
        case .fi: return "Suomi"
        case .nb: return "Norsk"
        case .pl: return "Polski"
        case .cs: return "Čeština"
        case .hu: return "Magyar"
        case .ro: return "Română"
        case .tr: return "Türkçe"
        case .uk: return "Українська"
        case .el: return "Ελληνικά"
        case .he: return "עברית"
        case .sk: return "Slovenčina"
        case .hr: return "Hrvatski"
        case .ca: return "Català"
        }
    }

    var flag: String {
        switch self {
        case .system: return "⚙️"
        case .zhHans: return "🇨🇳"
        case .en: return "🇺🇸"
        case .ja: return "🇯🇵"
        case .ko: return "🇰🇷"
        case .es: return "🇪🇸"
        case .fr: return "🇫🇷"
        case .de: return "🇩🇪"
        case .it: return "🇮🇹"
        case .pt: return "🇵🇹"
        case .ru: return "🇷🇺"
        case .ar: return "🇸🇦"
        case .hi: return "🇮🇳"
        case .th: return "🇹🇭"
        case .vi: return "🇻🇳"
        case .id: return "🇮🇩"
        case .ms: return "🇲🇾"
        case .nl: return "🇳🇱"
        case .sv: return "🇸🇪"
        case .da: return "🇩🇰"
        case .fi: return "🇫🇮"
        case .nb: return "🇳🇴"
        case .pl: return "🇵🇱"
        case .cs: return "🇨🇿"
        case .hu: return "🇭🇺"
        case .ro: return "🇷🇴"
        case .tr: return "🇹🇷"
        case .uk: return "🇺🇦"
        case .el: return "🇬🇷"
        case .he: return "🇮🇱"
        case .sk: return "🇸🇰"
        case .hr: return "🇭🇷"
        case .ca: return "🇦🇩"
        }
    }

    var isRTL: Bool {
        switch self {
        case .ar, .he:
            return true
        case .system:
            return UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
        default:
            return false
        }
    }

    var layoutDirection: LayoutDirection {
        isRTL ? .rightToLeft : .leftToRight
    }
}

final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published private(set) var currentLanguage: AppLanguage

    private let userDefaultsKey = "AppleLanguages"
    private var currentBundle: Bundle?

    private init() {
        if let languages = UserDefaults.standard.array(forKey: userDefaultsKey) as? [String],
           let firstLang = languages.first,
           let lang = AppLanguage(rawValue: firstLang) {
            currentLanguage = lang
        } else {
            currentLanguage = .system
        }
        updateCurrentBundle()
    }

    func setLanguage(_ language: AppLanguage) {
        currentLanguage = language

        if language == .system {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: userDefaultsKey)
        }
        UserDefaults.standard.synchronize()

        updateCurrentBundle()

        NotificationCenter.default.post(name: NSNotification.Name("AppLanguageChanged"), object: nil)
    }

    private func updateCurrentBundle() {
        switch currentLanguage {
        case .system:
            currentBundle = Bundle.main
        default:
            currentBundle = bundle(for: currentLanguage.rawValue)
        }
    }

    private func bundle(for language: String) -> Bundle? {
        if let path = Bundle.main.path(forResource: language, ofType: "lproj") {
            return Bundle(path: path)
        }
        return Bundle.main
    }

    static func localized(_ key: String) -> String {
        guard let bundle = shared.currentBundle else {
            return NSLocalizedString(key, comment: "")
        }
        return NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func localized(_ key: String, _ arguments: CVarArg...) -> String {
        let format = localized(key)
        return String(format: format, locale: shared.locale, arguments: arguments)
    }

    static func localized(_ key: String, arguments: [String: String]) -> String {
        var result = localized(key)
        for (key, value) in arguments {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }

    var isRTL: Bool {
        currentLanguage.isRTL
    }

    var layoutDirection: LayoutDirection {
        currentLanguage.layoutDirection
    }

    var locale: Locale {
        switch currentLanguage {
        case .system:
            return Locale.current
        case .zhHans:
            return Locale(identifier: "zh_Hans_CN")
        case .en:
            return Locale(identifier: "en_US")
        case .ja:
            return Locale(identifier: "ja_JP")
        case .ko:
            return Locale(identifier: "ko_KR")
        case .es:
            return Locale(identifier: "es_ES")
        case .fr:
            return Locale(identifier: "fr_FR")
        case .de:
            return Locale(identifier: "de_DE")
        case .it:
            return Locale(identifier: "it_IT")
        case .pt:
            return Locale(identifier: "pt_PT")
        case .ru:
            return Locale(identifier: "ru_RU")
        case .ar:
            return Locale(identifier: "ar_SA")
        case .hi:
            return Locale(identifier: "hi_IN")
        case .th:
            return Locale(identifier: "th_TH")
        case .vi:
            return Locale(identifier: "vi_VN")
        case .id:
            return Locale(identifier: "id_ID")
        case .ms:
            return Locale(identifier: "ms_MY")
        case .nl:
            return Locale(identifier: "nl_NL")
        case .sv:
            return Locale(identifier: "sv_SE")
        case .da:
            return Locale(identifier: "da_DK")
        case .fi:
            return Locale(identifier: "fi_FI")
        case .nb:
            return Locale(identifier: "nb_NO")
        case .pl:
            return Locale(identifier: "pl_PL")
        case .cs:
            return Locale(identifier: "cs_CZ")
        case .hu:
            return Locale(identifier: "hu_HU")
        case .ro:
            return Locale(identifier: "ro_RO")
        case .tr:
            return Locale(identifier: "tr_TR")
        case .uk:
            return Locale(identifier: "uk_UA")
        case .el:
            return Locale(identifier: "el_GR")
        case .he:
            return Locale(identifier: "he_IL")
        case .sk:
            return Locale(identifier: "sk_SK")
        case .hr:
            return Locale(identifier: "hr_HR")
        case .ca:
            return Locale(identifier: "ca_ES")
        }
    }
}

extension String {
    var localized: String {
        LanguageManager.localized(self)
    }

    func localized(_ arguments: CVarArg...) -> String {
        LanguageManager.localized(self, arguments)
    }

    func localized(arguments: [String: String]) -> String {
        LanguageManager.localized(self, arguments: arguments)
    }
}
