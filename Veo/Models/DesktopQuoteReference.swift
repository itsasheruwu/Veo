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

    private static let sourcePattern = try! NSRegularExpression(pattern: #"veo-quote://source\?[^\s)]+"#)

    static func parse(_ text: String) -> [DesktopQuoteReference] {
        guard text.utf8.contains(0x3A) else { return [] }
        return sourcePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text),
                  let parts = URLComponents(string: String(text[range])),
                  let threadID = parts.queryItems?.first(where: { $0.name == "thread" })?.value,
                  let itemID = parts.queryItems?.first(where: { $0.name == "item" })?.value else { return nil }
            return .init(threadID: threadID, itemID: itemID)
        }
    }
}
