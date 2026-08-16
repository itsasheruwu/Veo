// FILE: DesktopComposerPreferences.swift
// Purpose: Persisted preferences for optional composer status indicators.
// Layer: Desktop app model

import Foundation

enum DesktopContextWindowUsageStyle: String, CaseIterable, Identifiable {
    case percent
    case circle
    case bar

    var id: Self { self }

    var title: String {
        switch self {
        case .percent: return "Percent"
        case .circle: return "Circle"
        case .bar: return "Bar"
        }
    }
}

enum DesktopComposerPreferences {
    static let showsTurnStatusKey = "VeoDesktop.showsTurnStatus"
    static let showsContextWindowUsageKey = "VeoDesktop.showsContextWindowUsage"
    static let contextWindowUsageStyleKey = "VeoDesktop.contextWindowUsageStyle"
}
