import SwiftUI
import UIKit

// MARK: - 代码语言识别

enum SourceCodeLanguage: String {
    case swift
    case pythonLike
    case cLike
    case shell
    case yamlLike
    case markdown
    case unknown

    static func detect(fileName: String) -> SourceCodeLanguage {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":
            return .swift
        case "py", "pyw", "rb", "rake":
            return .pythonLike
        case "js", "ts", "jsx", "tsx", "mjs", "cjs", "java", "kt", "kts", "cs",
             "go", "c", "h", "cpp", "hpp", "cc", "hh", "m", "mm":
            return .cLike
        case "sh", "zsh", "bash", "command":
            return .shell
        case "yml", "yaml", "json", "toml", "xml", "plist", "entitlements", "html", "css", "scss":
            return .yamlLike
        case "md":
            return .markdown
        default:
            return .unknown
        }
    }
}

// MARK: - 跨行状态（块注释 / 三引号字符串 / 围栏代码块）

struct SourceSyntaxScanState {
    var inBlockComment = false
    var inTripleString = false
    var inCodeFence = false
}

// MARK: - 轻量语法高亮（GitHub 风格配色，深浅色自适应）

enum SourceSyntaxHighlighter {

    private static func dynamicColor(lightHex: String, darkHex: String) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(Color(hex: darkHex)) : UIColor(Color(hex: lightHex))
        })
    }

    private static let keywordColor = dynamicColor(lightHex: "CF222E", darkHex: "FF7B72")
    private static let stringColor = dynamicColor(lightHex: "0A3069", darkHex: "A5D6FF")
    private static let commentColor = dynamicColor(lightHex: "6E7781", darkHex: "8B949E")
    private static let numberColor = dynamicColor(lightHex: "0550AE", darkHex: "79C0FF")
    private static let attributeColor = dynamicColor(lightHex: "8250DF", darkHex: "D2A8FF")
    private static let tagColor = dynamicColor(lightHex: "116329", darkHex: "7EE787")

    static func highlight(_ line: String,
                          language: SourceCodeLanguage,
                          state: inout SourceSyntaxScanState) -> AttributedString {
        switch language {
        case .markdown:
            return markdown(line, state: &state)
        case .unknown:
            return AttributedString(line)
        default:
            return code(line, language: language, state: &state)
        }
    }

    // MARK: 通用代码行

    private static func code(_ line: String,
                             language: SourceCodeLanguage,
                             state: inout SourceSyntaxScanState) -> AttributedString {
        let chars = Array(line)
        let n = chars.count
        var out = AttributedString()
        var plain = ""

        let usesSlashComments = language == .swift || language == .cLike
        let usesHashComments = language == .pythonLike || language == .shell || language == .yamlLike
        let supportsTripleQuote = language == .swift || language == .pythonLike
        let keywords = keywords(for: language)

        func flushPlain() {
            guard !plain.isEmpty else { return }
            out += AttributedString(plain)
            plain = ""
        }

        func push(_ text: String, _ color: Color?) {
            if let color {
                flushPlain()
                guard !text.isEmpty else { return }
                var piece = AttributedString(text)
                piece.foregroundColor = color
                out += piece
            } else {
                plain += text
            }
        }

        func slice(_ start: Int, _ end: Int, _ color: Color?) {
            guard start < end else { return }
            push(String(chars[start..<end]), color)
        }

        func find(_ needle: [Character], from: Int) -> Int? {
            guard !needle.isEmpty else { return nil }
            var i = from
            while i + needle.count <= n {
                if Array(chars[i..<i + needle.count]) == needle { return i }
                i += 1
            }
            return nil
        }

        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_"
        }

        var i = 0
        while i < n {
            // 块注释延续
            if state.inBlockComment {
                if let close = find(["*", "/"], from: i) {
                    slice(i, close + 2, commentColor)
                    i = close + 2
                    state.inBlockComment = false
                } else {
                    slice(i, n, commentColor)
                    i = n
                }
                continue
            }

            // 三引号字符串延续
            if state.inTripleString {
                if let close = find(["\"", "\"", "\""], from: i) {
                    slice(i, close + 3, stringColor)
                    i = close + 3
                    state.inTripleString = false
                } else {
                    slice(i, n, stringColor)
                    i = n
                }
                continue
            }

            let c = chars[i]
            let next = i + 1 < n ? chars[i + 1] : nil

            // 行注释
            if usesSlashComments && c == "/" && next == "/" {
                slice(i, n, commentColor)
                i = n
                continue
            }
            if usesHashComments && c == "#" {
                slice(i, n, commentColor)
                i = n
                continue
            }

            // 块注释开始
            if usesSlashComments && c == "/" && next == "*" {
                if let close = find(["*", "/"], from: i + 2) {
                    slice(i, close + 2, commentColor)
                    i = close + 2
                } else {
                    slice(i, n, commentColor)
                    i = n
                    state.inBlockComment = true
                }
                continue
            }

            // XML / HTML 标签
            if language == .yamlLike && c == "<" {
                if let close = find([">"], from: i) {
                    slice(i, close + 1, tagColor)
                    i = close + 1
                } else {
                    slice(i, n, tagColor)
                    i = n
                }
                continue
            }

            // 字符串
            if c == "\"" {
                if supportsTripleQuote && find(["\"", "\"", "\""], from: i) == i {
                    if let close = find(["\"", "\"", "\""], from: i + 3) {
                        slice(i, close + 3, stringColor)
                        i = close + 3
                    } else {
                        slice(i, n, stringColor)
                        i = n
                        state.inTripleString = true
                    }
                    continue
                }
                var j = i + 1
                while j < n {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == "\"" { j += 1; break }
                    j += 1
                }
                j = min(j, n)
                slice(i, j, stringColor)
                i = j
                continue
            }
            if c == "'" {
                var j = i + 1
                while j < n {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == "'" { j += 1; break }
                    j += 1
                }
                j = min(j, n)
                slice(i, j, stringColor)
                i = j
                continue
            }

            // @属性 / #指令
            if (c == "@" || (c == "#" && (language == .swift || language == .cLike))) && i + 1 < n && isWordChar(chars[i + 1]) {
                var j = i + 1
                while j < n && isWordChar(chars[j]) { j += 1 }
                slice(i, j, attributeColor)
                i = j
                continue
            }

            // 数字
            if c.isNumber && (i == 0 || !isWordChar(chars[i - 1])) {
                var j = i
                while j < n && (isWordChar(chars[j]) || chars[j] == ".") { j += 1 }
                slice(i, j, numberColor)
                i = j
                continue
            }

            // 标识符 / 关键字
            if c.isLetter || c == "_" {
                var j = i
                while j < n && isWordChar(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                if keywords.contains(word) {
                    slice(i, j, keywordColor)
                } else {
                    slice(i, j, nil)
                }
                i = j
                continue
            }

            plain.append(c)
            i += 1
        }
        flushPlain()
        return out
    }

    // MARK: Markdown

    private static func markdown(_ line: String, state: inout SourceSyntaxScanState) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") {
            state.inCodeFence.toggle()
            var piece = AttributedString(line)
            piece.foregroundColor = commentColor
            return piece
        }
        if state.inCodeFence {
            var piece = AttributedString(line)
            piece.foregroundColor = stringColor
            return piece
        }
        if trimmed.hasPrefix("#") {
            var piece = AttributedString(line)
            piece.foregroundColor = keywordColor
            return piece
        }

        // 行内 `code` 片段
        var out = AttributedString()
        let parts = line.split(separator: "`", omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            if index > 0 {
                var tick = AttributedString("`")
                tick.foregroundColor = commentColor
                out += tick
            }
            if index % 2 == 1 {
                var piece = AttributedString(String(part))
                piece.foregroundColor = stringColor
                out += piece
            } else {
                out += AttributedString(String(part))
            }
        }
        return out
    }

    // MARK: 关键字表

    private static func keywords(for language: SourceCodeLanguage) -> Set<String> {
        switch language {
        case .swift:
            return [
                "associatedtype", "actor", "class", "deinit", "enum", "extension", "fileprivate",
                "func", "import", "init", "inout", "internal", "let", "open", "operator", "private",
                "precedencegroup", "protocol", "public", "rethrows", "static", "struct", "subscript",
                "typealias", "var",
                "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough",
                "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while",
                "as", "Any", "any", "is", "nil", "super", "self", "Self", "throw", "throws", "try",
                "await", "async", "indirect", "lazy", "mutating", "nonmutating", "required", "some",
                "unowned", "weak", "willSet", "didSet", "get", "set", "true", "false"
            ]
        case .pythonLike:
            return [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
                "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
                "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while",
                "with", "yield", "True", "False", "None", "self"
            ]
        case .cLike:
            return [
                "auto", "bool", "break", "case", "catch", "char", "class", "const", "constexpr",
                "continue", "default", "delete", "do", "double", "else", "enum", "explicit", "export",
                "extern", "false", "final", "float", "for", "friend", "func", "goto", "if", "implements",
                "import", "inline", "instanceof", "int", "interface", "internal", "long", "namespace",
                "new", "noexcept", "nullptr", "open", "operator", "override", "package", "private",
                "protected", "public", "range", "readonly", "return", "sealed", "short", "signed",
                "sizeof", "static", "struct", "switch", "template", "this", "throw", "throws", "true",
                "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void",
                "volatile", "while"
            ]
        case .shell:
            return [
                "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
                "esac", "function", "return", "in", "local", "export", "source", "echo", "exit"
            ]
        case .yamlLike:
            return ["true", "false", "yes", "no", "on", "off", "null"]
        default:
            return []
        }
    }
}
