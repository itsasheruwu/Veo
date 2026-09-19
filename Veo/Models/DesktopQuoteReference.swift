import Foundation

struct DesktopQuoteReference {
    let threadID: String
    let itemID: String

    var url: URL {
        var components = URLComponents()
        components.scheme = "veo-quote"
        components.host = "source"
        components.queryItems = [.init(name: "thread", value: threadID), .init(name: "item", value: itemID)]
        return components.url!
    }

    static func parse(_ text: String) -> [DesktopQuoteReference] {
        guard let regex = try? NSRegularExpression(pattern: #"veo-quote://source\?[^\s)]+"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text),
                  let parts = URLComponents(string: String(text[range])),
                  let threadID = parts.queryItems?.first(where: { $0.name == "thread" })?.value,
                  let itemID = parts.queryItems?.first(where: { $0.name == "item" })?.value else { return nil }
            return .init(threadID: threadID, itemID: itemID)
        }
    }
}
