// FILE: DesktopSidebarPreferences.swift
// Purpose: Defines the persisted organization and sorting choices for the chat sidebar.
// Layer: Desktop app model

import Foundation

enum DesktopSidebarOrganization: String, CaseIterable, Identifiable {
    case byProject
    case oneList

    var id: Self { self }

    var title: String {
        switch self {
        case .byProject: return "By project"
        case .oneList: return "In one list"
        }
    }
}

enum DesktopSidebarSortMode: String, CaseIterable, Identifiable {
    case priority
    case lastUpdated
    case manual

    var id: Self { self }

    var title: String {
        switch self {
        case .priority: return "Priority"
        case .lastUpdated: return "Last updated"
        case .manual: return "Manual order"
        }
    }
}
