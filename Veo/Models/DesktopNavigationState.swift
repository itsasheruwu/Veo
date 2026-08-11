// FILE: DesktopNavigationState.swift
// Purpose: Owns navigation between the workspace and in-window settings pages.
// Layer: Desktop app model

import SwiftUI

enum DesktopRootPage: Equatable {
    case workspace
    case settings
}

enum DesktopSettingsAnchor: Hashable {
    case notificationMaterial
}

enum DesktopSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case appearance
    case notifications
    case terminal
    case runtime
    case updates
    case account
    case integrations

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .notifications: return "Notifications"
        case .terminal: return "Terminal"
        case .runtime: return "Runtime"
        case .updates: return "Updates"
        case .account: return "Account"
        case .integrations: return "Integrations"
        }
    }

    var detail: String {
        switch self {
        case .general: return "Project, access, and utility model"
        case .appearance: return "Theme, accent, and materials"
        case .notifications: return "Alerts, menu bar, and sounds"
        case .terminal: return "Docked terminal and agent CLIs"
        case .runtime: return "Local Codex connection"
        case .updates: return "Version checks and auto updates"
        case .account: return "Identity, usage, and limits"
        case .integrations: return "Skills, plugins, apps, and MCP"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .notifications: return "bell"
        case .terminal: return "apple.terminal"
        case .runtime: return "bolt.horizontal.circle"
        case .updates: return "arrow.down.circle"
        case .account: return "person.crop.circle"
        case .integrations: return "puzzlepiece.extension"
        }
    }
}

@MainActor
final class DesktopNavigationState: ObservableObject {
    @Published var page: DesktopRootPage = .workspace
    @Published var settingsCategory: DesktopSettingsCategory = .general
    @Published var settingsAnchor: DesktopSettingsAnchor?

    func showSettings(
        _ category: DesktopSettingsCategory = .general,
        anchor: DesktopSettingsAnchor? = nil
    ) {
        settingsCategory = category
        settingsAnchor = anchor
        page = .settings
    }

    func showWorkspace() {
        page = .workspace
    }
}
