import Foundation

struct DesktopInlineContext {
    let range: NSRange
    let label: String
    let url: URL
    let source: String

    private static let pattern = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(((?:veo-(?:context|quote)|plugin)://[^\s)]+)\)"#)

    static func scan(_ draft: String) -> [Self] {
        let source = draft as NSString
        return pattern.matches(in: draft, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let url = URL(string: source.substring(with: match.range(at: 2))) else { return nil }
            let text = source.substring(with: match.range(at: 1))
            let label = url.scheme == "plugin" && !text.hasPrefix("@") ? "@" + text : text
            return .init(range: match.range, label: label, url: url, source: source.substring(with: match.range))
        }
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
        let result = NSMutableString(string: source)
        for context in scan(source).reversed() { result.replaceCharacters(in: context.range, with: context.label) }
        return result as String
    }
}
