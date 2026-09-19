// FILE: DesktopExternalProvider.swift
// Purpose: Describes Veo-owned external model providers and their discovered models.
// Layer: Desktop app model

import Foundation

enum DesktopProviderWireAPI: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat
    case responses

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat Completions"
        case .responses: return "Responses"
        }
    }
}

enum DesktopProviderAuthKind: String, Codable, Sendable {
    case apiKey
    case oauth
}

enum DesktopExternalProviderPreset: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case deepseek
    case xai
    case grokOAuth = "grok-oauth"
    case kimi
    case kimiOAuth = "kimi-oauth"
    case openrouter
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .deepseek: return "DeepSeek"
        case .xai: return "xAI / Grok (API)"
        case .grokOAuth: return "Grok (OAuth)"
        case .kimi: return "Kimi Platform (API)"
        case .kimiOAuth: return "Kimi Code (OAuth)"
        case .openrouter: return "OpenRouter"
        case .custom: return "Custom"
        }
    }

    var detail: String {
        switch self {
        case .anthropic: return "Claude models with an Anthropic API key."
        case .deepseek: return "DeepSeek models with a DeepSeek API key."
        case .xai: return "Grok models with a billed xAI API key."
        case .grokOAuth: return "Sign in with SuperGrok or X Premium+ in Veo. No API key."
        case .kimi: return "Moonshot / Kimi Platform API key."
        case .kimiOAuth: return "Sign in with a Kimi Code subscription in Veo. No API key."
        case .openrouter: return "OpenRouter catalog with an OpenRouter API key."
        case .custom: return "Any OpenAI-compatible Chat Completions or Responses endpoint."
        }
    }

    var systemImage: String {
        switch self {
        case .anthropic: return "sparkle"
        case .deepseek: return "leaf"
        case .xai, .grokOAuth: return "bolt.fill"
        case .kimi, .kimiOAuth: return "moon.stars"
        case .openrouter: return "globe"
        case .custom: return "plus.circle"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .xai, .grokOAuth: return "https://api.x.ai/v1"
        case .kimi: return "https://api.moonshot.ai/v1"
        case .kimiOAuth: return "https://api.kimi.com/coding/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .custom: return "https://api.example.com/v1"
        }
    }

    var defaultWireAPI: DesktopProviderWireAPI {
        switch self {
        case .xai, .grokOAuth: return .responses
        case .anthropic, .deepseek, .kimi, .kimiOAuth, .openrouter, .custom: return .chat
        }
    }

    var authKind: DesktopProviderAuthKind {
        switch self {
        case .kimiOAuth, .grokOAuth: return .oauth
        case .anthropic, .deepseek, .xai, .kimi, .openrouter, .custom: return .apiKey
        }
    }

    var usesAnthropicAuth: Bool { self == .anthropic }

    var fallbackModels: [(id: String, name: String)] {
        switch self {
        case .kimiOAuth:
            return [
                ("k3", "Kimi K3"),
                ("kimi-for-coding", "K2.7 Coding"),
                ("kimi-for-coding-highspeed", "K2.7 Coding Highspeed"),
            ]
        case .grokOAuth:
            return [
                ("grok-4.6", "4.6 Grok"),
                ("grok-4.5", "4.5 Grok"),
                ("grok-4", "4 Grok"),
            ]
        default:
            return []
        }
    }

    var envKeyName: String {
        "VEO_PROVIDER_\(rawValue.uppercased().replacingOccurrences(of: "-", with: "_"))_KEY"
    }
}

struct DesktopExternalModelRecord: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var upstreamID: String
    var displayName: String
    var enabled: Bool

    init(id: String, upstreamID: String, displayName: String, enabled: Bool) {
        self.id = id
        self.upstreamID = upstreamID
        self.displayName = displayName
        self.enabled = enabled
    }
}

struct DesktopConnectedProvider: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var presetID: String?
    var name: String
    var baseURL: String
    var wireAPI: DesktopProviderWireAPI
    var envKey: String
    var usesAnthropicAuth: Bool
    var models: [DesktopExternalModelRecord]

    var preset: DesktopExternalProviderPreset? {
        presetID.flatMap(DesktopExternalProviderPreset.init(rawValue:))
    }

    var authKind: DesktopProviderAuthKind {
        preset?.authKind ?? .apiKey
    }

    var enabledModels: [DesktopExternalModelRecord] {
        models.filter(\.enabled)
    }

    var catalogID: String { id }

    static func make(
        preset: DesktopExternalProviderPreset,
        customID: String? = nil,
        customName: String? = nil,
        existingIDs: Set<String> = []
    ) -> DesktopConnectedProvider {
        let id: String
        if preset == .custom {
            id = Self.uniqueCustomID(from: customID ?? customName ?? "custom", existingIDs: existingIDs)
        } else {
            id = preset.rawValue
        }
        return DesktopConnectedProvider(
            id: id,
            presetID: preset == .custom ? nil : preset.rawValue,
            name: customName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? preset.title,
            baseURL: preset.defaultBaseURL,
            wireAPI: preset.defaultWireAPI,
            envKey: preset == .custom
                ? "VEO_PROVIDER_\(id.uppercased().replacingOccurrences(of: "-", with: "_"))_KEY"
                : preset.envKeyName,
            usesAnthropicAuth: preset.usesAnthropicAuth,
            models: []
        )
    }

    static func catalogModelID(providerID: String, upstreamID: String) -> String {
        if upstreamID.hasPrefix(providerID + "/") { return upstreamID }
        return "\(providerID)/\(upstreamID)"
    }

    private static func uniqueCustomID(from name: String, existingIDs: Set<String>) -> String {
        let slug = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "custom" : String(slug.prefix(32))
        if !existingIDs.contains(base) { return base }
        var index = 2
        while existingIDs.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
