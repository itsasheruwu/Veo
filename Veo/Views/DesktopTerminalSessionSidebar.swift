// FILE: DesktopTerminalSessionSidebar.swift
// Purpose: Session catalog that replaces the chat sidebar in terminal workspace mode.
// Layer: Desktop app view

import SwiftUI

struct DesktopTerminalSessionSidebar: View {
    @ObservedObject var store: DesktopCodexStore
    @ObservedObject var hub: DesktopLocalTerminalHub
    @Binding var isWorkspace: Bool
    @Binding var isPresented: Bool
    let openSettings: () -> Void
    @Environment(\.veoAccent) private var veoAccent
    @AppStorage(DesktopAppearancePreferences.leftSidebarMaterialKey) private var sidebarMaterialRaw =
        DesktopSidebarMaterial.solid.rawValue
    @State private var hoveredSessionID: UUID?
    @State private var settingsGearTurns = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selection: Binding<UUID?> {
        Binding(
            get: { hub.focusedSessionID ?? hub.selectedTabID },
            set: { id in
                guard let id else { return }
                hub.activateSessionInWorkspace(id)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            primaryActions

            HStack {
                Text("Terminals")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, DesktopTheme.spaceL)
            .padding(.bottom, DesktopTheme.spaceXS)

            List(selection: selection) {
                ForEach(hub.tabs) { tab in
                    DesktopTerminalSessionRow(
                        session: tab,
                        isVisibleInGrid: hub.visibleSessionIDs.contains(tab.id),
                        isSelected: (hub.focusedSessionID ?? hub.selectedTabID) == tab.id,
                        isHovered: hoveredSessionID == tab.id,
                        onClose: { closeSession(tab.id) }
                    )
                    .tag(tab.id)
                    .listRowBackground(
                        ((hub.focusedSessionID ?? hub.selectedTabID) == tab.id)
                            ? veoAccent.opacity(0.22)
                            : Color.clear
                    )
                    .onHover { hovering in
                        hoveredSessionID = hovering ? tab.id : nil
                    }
                    .contextMenu {
                        Button("Close Session") {
                            closeSession(tab.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 30)
            .background(DesktopSidebarListSelectionStyle())

            sidebarFooter
        }
        .desktopSidebarChrome(DesktopSidebarMaterial(rawValue: sidebarMaterialRaw) ?? .solid)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var primaryActions: some View {
        VStack(spacing: 2) {
            Button {
                addSession()
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(!store.hasExplicitWorkspace)

            Button {
                isWorkspace = false
            } label: {
                Label("Back to Chat", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13.5, weight: .medium))
        .labelStyle(DesktopTerminalSidebarLabelStyle())
        .padding(.horizontal, 10)
        .padding(.top, DesktopTheme.sidebarTitlebarClearance)
        .padding(.bottom, DesktopTheme.spaceL)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(store.hasExplicitWorkspace ? store.effectiveWorkspaceURL.lastPathComponent : "No project")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    openSettingsFromGear()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .rotationEffect(.degrees(Double(settingsGearTurns) * 360))
                        .frame(width: 26, height: 26, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, DesktopTheme.spaceM)
            .padding(.top, 9)
            .padding(.bottom, DesktopTheme.spaceM)
        }
    }

    private func addSession() {
        guard store.hasExplicitWorkspace else { return }
        hub.addWorkspaceSession(
            in: store.effectiveWorkspaceURL,
            columns: 80,
            rows: 24
        )
    }

    private func closeSession(_ id: UUID) {
        if !hub.closeTab(id) {
            isWorkspace = false
            isPresented = false
        }
    }

    private func openSettingsFromGear() {
        guard !reduceMotion else {
            openSettings()
            return
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            settingsGearTurns += 1
        } completion: {
            openSettings()
        }
    }
}

private struct DesktopTerminalSessionRow: View {
    @ObservedObject var session: DesktopLocalTerminalSession
    let isVisibleInGrid: Bool
    let isSelected: Bool
    let isHovered: Bool
    let onClose: () -> Void
    @Environment(\.veoAccent) private var veoAccent

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isRunning ? veoAccent : Color.secondary.opacity(0.35))
                .frame(width: 5, height: 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.tabTitle)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(session.agentLabel)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? veoAccent : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isVisibleInGrid {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            if isHovered || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close session")
            }
        }
        .padding(.vertical, DesktopTheme.spaceXS)
        .contentShape(Rectangle())
        .help(session.workingDirectoryPath)
    }
}

private struct DesktopTerminalSidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: 17)
            configuration.title
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
}
