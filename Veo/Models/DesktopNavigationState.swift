// FILE: DesktopNavigationState.swift
// Purpose: Owns navigation between the workspace and in-window settings pages.
// Layer: Desktop app model

import SwiftUI

enum DesktopRootPage: Equatable {
    case workspace
    case settings
}

enum DesktopSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case appearance
    case terminal
    case runtime
    case account
    case integrations

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .runtime: return "Runtime"
        case .account: return "Account"
        case .integrations: return "Integrations"
        }
    }

    var detail: String {
        switch self {
        case .general: return "Project, access, and utility model"
        case .appearance: return "Theme, accent, and materials"
        case .terminal: return "Docked terminal and agent CLIs"
        case .runtime: return "Local Codex connection"
        case .account: return "Identity, usage, and limits"
        case .integrations: return "Skills, plugins, apps, and MCP"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .terminal: return "apple.terminal"
        case .runtime: return "bolt.horizontal.circle"
        case .account: return "person.crop.circle"
        case .integrations: return "puzzlepiece.extension"
        }
    }
}

@MainActor
final class DesktopNavigationState: ObservableObject {
    @Published var page: DesktopRootPage = .workspace
    @Published var settingsCategory: DesktopSettingsCategory = .general

    func showSettings(_ category: DesktopSettingsCategory = .general) {
        settingsCategory = category
        page = .settings
    }

    func showWorkspace() {
        page = .workspace
    }
}
