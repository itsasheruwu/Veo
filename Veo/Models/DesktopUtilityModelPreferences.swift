// FILE: DesktopUtilityModelPreferences.swift
// Purpose: Defines the shared model preference for Veo's background intelligence features.
// Layer: Desktop app model

import Foundation

enum DesktopUtilityModelPreferences {
    static let modelIDKey = "VeoDesktop.utilityModelID"
    static let defaultModelName = "gpt-5.6-luna"
    static let reasoningEffort = "low"
}

enum DesktopAutoRouterMode: String, CaseIterable, Identifiable, Codable {
    case jev
    case utility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jev: return "Jev"
        case .utility: return "Utility"
        }
    }
}

enum DesktopAutoSpeedPolicy: String, CaseIterable, Identifiable, Codable {
    case disallow
    case allow

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum DesktopAutoRouterPreferences {
    static let modeKey = "VeoDesktop.autoRouterMode"
    static let speedPolicyKey = "VeoDesktop.autoRouterSpeedPolicy"
    static let allowsUltraReasoningKey = "VeoDesktop.autoRouterAllowsUltraReasoning"
}
