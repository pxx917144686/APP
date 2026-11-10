import Foundation

enum ApplePropertyListError: String, LocalizedError {
    case empty, malformed, unsupportedEnvelope, expectedDictionary
    var errorDescription: String? { "auth_err_unrecognized_data".localized }
}

enum ApplePropertyList {
    static func dictionary(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { throw ApplePropertyListError.empty }
        if let value = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            guard let dictionary = value as? [String: Any] else { throw ApplePropertyListError.expectedDictionary }
            return dictionary
        }
        guard data.count <= 4 * 1024 * 1024 else { throw ApplePropertyListError.malformed }
        let delegate = Envelope()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { throw ApplePropertyListError.malformed }
        var payload = [root]
        for wrapper in ["Document", "Protocol"] {
            if payload.count == 1, payload[0].name == wrapper {
                guard payload[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ApplePropertyListError.unsupportedEnvelope
                }
                payload = payload[0].children
            }
        }
        let xml: String
        if payload.count == 1, payload[0].name == "plist" { xml = payload[0].xml }
        else if payload.count == 1, payload[0].name == "dict" { xml = "<plist version=\"1.0\">" + payload[0].xml + "</plist>" }
        else if payload.first?.name == "key" {
            xml = "<plist version=\"1.0\"><dict>" + payload.map(\.xml).joined() + "</dict></plist>"
        } else { throw ApplePropertyListError.unsupportedEnvelope }
        guard let dictionary = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any] else {
            throw ApplePropertyListError.malformed
        }
        return dictionary
    }

    static func format(_ data: Data) -> String {
        if data.isEmpty { return "empty" }
        if data.starts(with: Data("bplist".utf8)) { return "binary-plist" }
        let prefix = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if prefix.contains("<document") { return "apple-document" }
        if prefix.contains("<html") || prefix.hasPrefix("<!doctype html") { return "html" }
        if prefix.hasPrefix("<?xml") || prefix.hasPrefix("<plist") || prefix.hasPrefix("<dict") { return "xml" }
        if prefix.hasPrefix("{") || prefix.hasPrefix("[") { return "json" }
        return "other"
    }

    private final class Node {
        let name: String
        var text = ""
        var children: [Node] = []
        init(_ name: String) { self.name = name }
        var xml: String {
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            let opening = name == "plist" ? "<plist version=\"1.0\">" : "<\(name)>"
            return opening + escaped + children.map(\.xml).joined() + "</\(name)>"
        }
    }

    private final class Envelope: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        var count = 0
        let allowed: Set<String> = ["Document", "Protocol", "plist", "dict", "array", "key", "string", "data", "integer", "real", "date", "true", "false"]
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            count += 1
            guard allowed.contains(elementName), stack.count < 64, count <= 100_000 else { parser.abortParsing(); return }
            let node = Node(elementName)
            if let parent = stack.last { parent.children.append(node) }
            else if root == nil { root = node }
            else { parser.abortParsing(); return }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let text = String(data: CDATABlock, encoding: .utf8) else { parser.abortParsing(); return }
            stack.last?.text += text
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
    }
}
