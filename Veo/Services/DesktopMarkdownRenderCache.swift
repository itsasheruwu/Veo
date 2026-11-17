// Purpose: Reuses parsed Markdown without retaining an unbounded conversation history.

import Foundation

@MainActor
enum DesktopMarkdownRenderCache {
    private final class Blocks {
        let value: [MarkdownBlock]
        init(_ value: [MarkdownBlock]) { self.value = value }
    }

    private final class Prose {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let blockCache: NSCache<NSString, Blocks> = {
        let cache = NSCache<NSString, Blocks>()
        cache.countLimit = 128
        cache.totalCostLimit = 4 * 1_024 * 1_024
        return cache
    }()

    private static let proseCache: NSCache<NSString, Prose> = {
        let cache = NSCache<NSString, Prose>()
        cache.countLimit = 256
        cache.totalCostLimit = 4 * 1_024 * 1_024
        return cache
    }()

    private static let activityProseCache: NSCache<NSString, Prose> = {
        let cache = NSCache<NSString, Prose>()
        cache.countLimit = 256
        cache.totalCostLimit = 4 * 1_024 * 1_024
        return cache
    }()

    static func blocks(for source: String) -> [MarkdownBlock] {
        let key = source as NSString
        if let cached = blockCache.object(forKey: key) { return cached.value }
        let blocks = MarkdownBlock.parse(source)
        blockCache.setObject(Blocks(blocks), forKey: key, cost: source.utf8.count * 3)
        return blocks
    }

    static func inlineAttributed(_ source: String) -> AttributedString {
        let key = source as NSString
        if let cached = proseCache.object(forKey: key) { return cached.value }
        // Inline-only preserves paragraph breaks when rendered as one Text.
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let value = (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
        proseCache.setObject(Prose(value), forKey: key, cost: source.utf8.count * 6)
        return value
    }

    static func activityInlineAttributed(_ source: String) -> AttributedString {
        let key = source as NSString
        if let cached = activityProseCache.object(forKey: key) { return cached.value }
        // Activity rows intentionally retain AttributedString's default extended-
        // attribute and failure-policy behavior; assistant prose uses different options.
        let value = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        activityProseCache.setObject(Prose(value), forKey: key, cost: source.utf8.count * 6)
        return value
    }
}
