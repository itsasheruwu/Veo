import Foundation

struct DesktopInlineContext {
    let range: NSRange
    let label: String
    let url: URL
    let source: String

    // A quote keeps its full Markdown passage in the draft and occupies one editor attachment.
    private static let pattern = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((veo-quote://[^\s)]+)\):\n(>[^\n]*(?:\n>[^\n]*)*)(?:\n\n)?|\[([^\]\n]+)\]\(((?:veo-(?:context|quote)|plugin)://[^\s)]+)\)"#)

    static func scan(_ draft: String) -> [Self] {
        guard draft.utf8.contains(0x5B) else { return [] }
        let source = draft as NSString
        return pattern.matches(in: draft, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let isQuote = match.range(at: 3).location != NSNotFound
            guard let url = URL(string: source.substring(with: match.range(at: isQuote ? 2 : 5))) else { return nil }
            let label: String
            if isQuote {
                let passage = source.substring(with: match.range(at: 3))
                    .components(separatedBy: "\n")
                    .map { $0.dropFirst().trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let preview = passage.count > 36 ? String(passage.prefix(35)) + "…" : passage
                label = "“\(preview)”"
            } else {
                let text = source.substring(with: match.range(at: 4))
                label = url.scheme == "plugin" && !text.hasPrefix("@") ? "@" + text : text
            }
            return .init(range: match.range, label: label, url: url, source: source.substring(with: match.range))
        }
    }

    static func linkedText(_ draft: String) -> AttributedString {
        let source = draft as NSString
        var result = AttributedString()
        var offset = 0
        for context in scan(draft) {
            result += AttributedString(source.substring(with: NSRange(location: offset, length: context.range.location - offset)))
            var link = AttributedString(context.label)
            link.link = context.url
            result += link
            offset = NSMaxRange(context.range)
            if context.url.scheme == "veo-quote", context.source.hasSuffix("\n\n"), offset < source.length,
               !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(source.character(at: offset)) ?? " ") {
                result += AttributedString(" ")
            }
        }
        result += AttributedString(source.substring(from: offset))
        return result
    }

    static func reference(_ label: String, kind: String, value: String, line: Int? = nil) -> String {
        var url = URLComponents()
        url.scheme = "veo-context"
        url.host = kind
        url.queryItems = [.init(name: "value", value: value)]
        if let line { url.queryItems?.append(.init(name: "line", value: String(line))) }
        let safeLabel = label.replacingOccurrences(of: "]", with: "）").replacingOccurrences(of: "\n", with: " ")
        guard let link = url.url?.absoluteString.replacingOccurrences(of: ")", with: "%29") else { return safeLabel }
        return "[\(safeLabel)](\(link))"
    }

    static func value(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "value" }?.value
    }

    static func line(in url: URL) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "line" }?.value.flatMap(Int.init)
    }

    private static let pluginID = try! NSRegularExpression(pattern: #"^[a-zA-Z0-9_.-]+@[a-zA-Z0-9_.-]+$"#)

    static func validPluginID(_ id: String) -> Bool {
        pluginID.firstMatch(in: id, range: NSRange(location: 0, length: (id as NSString).length)) != nil
    }

    static func pluginProtocolText(_ source: String) -> String {
        let result = NSMutableString(string: source)
        for chip in scan(source).reversed() where chip.url.host == "plugin" {
            guard let id = value(in: chip.url), validPluginID(id) else {
                result.replaceCharacters(in: chip.range, with: chip.label)
                continue
            }
            let label = chip.label.hasPrefix("@") ? String(chip.label.dropFirst()) : chip.label
            result.replaceCharacters(in: chip.range, with: "[\(label)](plugin://\(id))")
        }
        return (result as String).replacingOccurrences(
            of: "](plugin://browser@openai-bundled?browserFamily=chrome)",
            with: "](plugin://chrome@openai-bundled)"
        )
    }

    static func displayText(_ source: String) -> String {
        let contexts = scan(source)
        guard !contexts.isEmpty else { return source }
        let result = NSMutableString(string: source)
        for context in contexts.reversed() { result.replaceCharacters(in: context.range, with: context.label) }
        return result as String
    }
}
