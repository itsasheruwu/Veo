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
    case runtime
    case account
    case integrations

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .runtime: return "Runtime"
        case .account: return "Account"
        case .integrations: return "Integrations"
        }
    }

    var detail: String {
        switch self {
        case .general: return "Project and access defaults"
        case .runtime: return "Local Codex connection"
        case .account: return "Identity, usage, and limits"
        case .integrations: return "Skills, plugins, apps, and MCP"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .runtime: return "terminal"
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
