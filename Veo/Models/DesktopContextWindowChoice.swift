// FILE: DesktopContextWindowChoice.swift
// Purpose: Stores a model-specific requested context window and parses inline token input.

import Foundation

struct DesktopContextWindowChoice: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case `default`, preset, custom }

    let kind: Kind
    let tokens: Int?

    static let `default` = Self(kind: .default, tokens: nil)
    static let presets: [(title: String, tokens: Int)] = [
        ("200K", 200_000), ("300K", 300_000), ("500K", 500_000), ("1 million", 1_000_000),
    ]

    var title: String {
        switch kind {
        case .default: "Default"
        case .preset: Self.presets.first(where: { $0.tokens == tokens })?.title ?? "Default"
        case .custom: tokens.map { Self.formatted($0) } ?? "Custom"
        }
    }

    static func formatted(_ tokens: Int) -> String {
        tokens.formatted() + " tokens"
    }

    /// Accept integers or a decimal with a K/M suffix; never round a fractional token.
    static func parse(_ input: String) -> Int? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .lowercased()
        guard !value.isEmpty else { return nil }
        let multiplier: Decimal
        let digits: String
        if value.hasSuffix("k") {
            multiplier = 1_000
            digits = String(value.dropLast())
        } else if value.hasSuffix("m") {
            multiplier = 1_000_000
            digits = String(value.dropLast())
        } else {
            multiplier = 1
            digits = value
        }
        guard digits.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
              let number = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let result = number * multiplier
        let integer = NSDecimalNumber(decimal: result)
        guard integer != .notANumber,
              integer.compare(1) != .orderedAscending,
              integer.compare(NSNumber(value: Int.max)) != .orderedDescending,
              integer.decimalValue == Decimal(integer.intValue) else { return nil }
        return integer.intValue
    }
}

struct DesktopContextWindowLimits: Equatable, Sendable {
    let suggested: Int?
    let maximum: Int

    init?(suggested: Int?, maximum: Int) {
        guard maximum > 0 else { return nil }
        if let suggested, suggested <= 0 || suggested > maximum { return nil }
        self.suggested = suggested
        self.maximum = maximum
    }
}
