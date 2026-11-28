// FILE: DesktopComposerProjectBar.swift
// Purpose: Keeps workspace and provider choices beneath the chat composer.
// Layer: Desktop app view

import SwiftUI

struct DesktopComposerProjectBar: View {
    @Bindable var store: DesktopCodexStore
    @AppStorage("VeoDesktop.projectDisplayNames") private var projectDisplayNamesJSON = "{}"
    let isWelcome: Bool

    var body: some View {
        HStack(spacing: 12) {
            DesktopComposerFooterMenu(title: selectedProjectTitle, accessibilityName: "Choose workspace") {
                Image(systemName: "folder")
            } content: {
                projectChoices
            }
            .help(store.currentWorkspaceKind == .project ? store.effectiveWorkspaceURL.path : "Choose workspace")

            Spacer(minLength: 0)

            DesktopComposerProviderPicker(store: store)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
    }

    private var selectedProjectTitle: String {
        guard store.currentWorkspaceKind == .project else { return "Temporary workspace" }
        let path = store.effectiveWorkspaceURL.path
        return projectDisplayNames[path] ?? store.effectiveWorkspaceURL.lastPathComponent
    }

    @ViewBuilder
    private var projectChoices: some View {
        let projects = knownProjects
        let names = Dictionary(grouping: projects, by: \.name)
        let inProject = store.currentWorkspaceKind == .project
        Section(isWelcome ? "Workspace" : "Start a new chat in") {
            Button {
                if inProject { store.beginNewChat() }
            } label: {
                Label("Temporary workspace", systemImage: inProject ? "folder" : "checkmark")
            }
            ForEach(projects, id: \.path) { project in
                let selected = inProject && project.path == store.effectiveWorkspaceURL.path
                Button {
                    if !selected {
                        store.beginProjectChat(at: URL(fileURLWithPath: project.path, isDirectory: true))
                    }
                } label: {
                    let hasDuplicateName = (names[project.name]?.count ?? 0) > 1
                    Label(hasDuplicateName ? project.path : project.name, systemImage: selected ? "checkmark" : "folder")
                }
                .help(project.path)
            }
        }
        Divider()
        Button("Open project…", systemImage: "folder.badge.plus") { store.chooseWorkspace() }
    }

    private var projectDisplayNames: [String: String] {
        guard let data = projectDisplayNamesJSON.data(using: .utf8),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return names
    }

    private var knownProjects: [(path: String, name: String)] {
        var latestUpdateByPath: [String: Date] = [:]
        for thread in store.threads where thread.workspaceKind == .project {
            latestUpdateByPath[thread.cwd] = max(latestUpdateByPath[thread.cwd] ?? .distantPast, thread.updatedAt)
        }
        if let workspaceURL = store.workspaceURL {
            latestUpdateByPath[workspaceURL.path] = max(latestUpdateByPath[workspaceURL.path] ?? .distantPast, .now)
        }
        return latestUpdateByPath.sorted { $0.value > $1.value }.map { path, _ in
            (path: path, name: projectDisplayNames[path] ?? URL(fileURLWithPath: path).lastPathComponent)
        }
    }
}

struct DesktopComposerFooterMenu<Icon: View, Content: View>: View {
    let title: String
    let accessibilityName: String
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            HStack(spacing: 5) {
                icon()
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(title)
    }
}
