// FILE: DesktopSiteIconLoader.swift
// Purpose: Resolves and caches website icons declared by pages shown in activity summaries.
// Layer: Desktop app service

import AppKit
import Combine
import Foundation

@MainActor
final class DesktopSiteIconLoader: ObservableObject {
    @Published private(set) var image: NSImage?

    private let pageURL: URL

    init(pageURL: URL) {
        self.pageURL = pageURL
    }

    func load() async {
        guard image == nil,
              let data = await DesktopSiteIconCache.shared.iconData(for: pageURL),
              let resolvedImage = NSImage(data: data) else { return }
        image = resolvedImage
    }
}

private actor DesktopSiteIconCache {
    static let shared = DesktopSiteIconCache()

    private var cachedData: [String: Data] = [:]
    private var failedKeys = Set<String>()
    private var inFlight: [String: Task<Data?, Never>] = [:]

    func iconData(for pageURL: URL) async -> Data? {
        guard let key = pageURL.host?.lowercased() else { return nil }
        if let data = cachedData[key] { return data }
        if failedKeys.contains(key) { return nil }
        if let task = inFlight[key] { return await task.value }

        let task = Task { await Self.resolveIconData(for: pageURL) }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil

        if let data {
            cachedData[key] = data
        } else {
            failedKeys.insert(key)
        }
        return data
    }

    private static func resolveIconData(for pageURL: URL) async -> Data? {
        guard isSafeHTTPS(pageURL) else { return nil }

        let declaredURLs = await declaredIconURLs(for: pageURL)
        let candidates = deduplicated(declaredURLs + conventionalIconURLs(for: pageURL))

        for candidate in candidates {
            guard let (data, response) = try? await URLSession.shared.data(from: candidate),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count <= 2_000_000,
                  NSImage(data: data) != nil else { continue }
            return data
        }
        return nil
    }

    private static func declaredIconURLs(for pageURL: URL) async -> [URL] {
        guard let rootURL = rootURL(for: pageURL) else { return [] }

        var request = URLRequest(url: rootURL)
        request.timeoutInterval = 10
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= 2_000_000,
              let html = String(data: data, encoding: .utf8) else { return [] }

        return iconDeclarations(in: html, relativeTo: rootURL)
            .sorted { $0.score > $1.score }
            .map(\.url)
    }

    private static func iconDeclarations(in html: String, relativeTo baseURL: URL) -> [(url: URL, score: Int)] {
        guard let linkExpression = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive]) else {
            return []
        }

        let htmlRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return linkExpression.matches(in: html, range: htmlRange).compactMap { match in
            guard let tagRange = Range(match.range, in: html) else { return nil }
            let tag = String(html[tagRange])
            guard let relation = attribute("rel", in: tag)?.lowercased(), relation.contains("icon"),
                  !relation.contains("mask-icon"),
                  let rawHref = attribute("href", in: tag)?.replacingOccurrences(of: "&amp;", with: "&"),
                  let resolvedURL = URL(string: rawHref, relativeTo: baseURL)?.absoluteURL,
                  isSafeHTTPS(resolvedURL) else { return nil }

            var score = relation == "icon" || relation == "shortcut icon" ? 100 : 55
            if attribute("type", in: tag)?.localizedCaseInsensitiveContains("png") == true { score += 12 }
            if let size = preferredPixelSize(from: attribute("sizes", in: tag)) {
                score += max(0, 48 - abs(size - 32))
            }
            return (resolvedURL, score)
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\b"# + escapedName + #"\s*=\s*(?:[\"']([^\"']+)[\"']|([^\s>]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = expression.firstMatch(in: tag, range: range) else { return nil }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            guard let valueRange = Range(match.range(at: index), in: tag) else { continue }
            return String(tag[valueRange])
        }
        return nil
    }

    private static func preferredPixelSize(from sizes: String?) -> Int? {
        guard let sizes,
              let expression = try? NSRegularExpression(pattern: #"(\d+)[xX](\d+)"#),
              let match = expression.firstMatch(
                in: sizes,
                range: NSRange(sizes.startIndex..<sizes.endIndex, in: sizes)
              ),
              let widthRange = Range(match.range(at: 1), in: sizes) else { return nil }
        return Int(sizes[widthRange])
    }

    private static func conventionalIconURLs(for pageURL: URL) -> [URL] {
        guard let root = rootURL(for: pageURL) else { return [] }
        return ["favicon.png", "favicon.ico", "apple-touch-icon.png"].compactMap {
            URL(string: $0, relativeTo: root)?.absoluteURL
        }
    }

    private static func rootURL(for pageURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = pageURL.host
        components.port = pageURL.port
        components.path = "/"
        guard let url = components.url, isSafeHTTPS(url) else { return nil }
        return url
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func isSafeHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
    }
}
