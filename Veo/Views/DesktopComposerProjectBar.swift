// FILE: DesktopComposerProjectBar.swift
// Purpose: Owns the project chooser shown only on the new-chat composer.
// Layer: Desktop app view

import SwiftUI

struct DesktopComposerProjectBar: View {
    @Environment(\.veoAccent) private var veoAccent
    @Bindable var store: DesktopCodexStore
    @AppStorage("VeoDesktop.projectDisplayNames") private var projectDisplayNamesJSON = "{}"
    @State private var isChooserPresented = false

    var body: some View {
        HStack {
            Spacer(minLength: 0)

            Button {
                isChooserPresented.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                    Text("Choose project")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose the project for this chat")
            .accessibilityLabel("Choose project")
            .popover(isPresented: $isChooserPresented, arrowEdge: .bottom) {
                projectChooser
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesktopTheme.spaceM)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Divider()
                .opacity(0.7)
                .allowsHitTesting(false)
        }
    }

    private var projectChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose project")
                .font(.system(size: 13, weight: .semibold))

            if knownProjects.isEmpty {
                Text("No existing projects yet")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(knownProjects, id: \.path) { project in
                            Button {
                                isChooserPresented = false
                                store.beginProjectChat(at: URL(fileURLWithPath: project.path, isDirectory: true))
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(veoAccent)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(project.name)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                        Text(project.path)
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    if project.path == store.effectiveWorkspaceURL.path,
                                       store.currentWorkspaceKind == .project {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(veoAccent)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(project.path)
                            .accessibilityLabel("Use project \(project.name)")
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Divider()

            Button {
                isChooserPresented = false
                DispatchQueue.main.async { store.chooseWorkspace() }
            } label: {
                Label("Add project…", systemImage: "folder.badge.plus")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 310)
        .background(.regularMaterial)
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
