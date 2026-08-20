// FILE: DesktopTerminalWorkspaceView.swift
// Purpose: Main-canvas multiplexer for terminal workspace mode (focused pane, splits, templates).
// Layer: Desktop app view

import AppKit
import SwiftUI

struct DesktopTerminalWorkspaceView: View {
    @ObservedObject var store: DesktopCodexStore
    @ObservedObject var hub: DesktopLocalTerminalHub
    @Binding var isWorkspace: Bool
    @Binding var isPresented: Bool

    private var bootstrapCols: Int { 80 }
    private var bootstrapRows: Int { 24 }

    var body: some View {
        VStack(spacing: 0) {
            chrome
                .zIndex(1)
            Divider().overlay(DesktopTheme.hairline)
            gridBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panelBackground)
        .clipped()
        .navigationTitle(store.hasExplicitWorkspace ? store.effectiveWorkspaceURL.lastPathComponent : "Terminal")
        .onAppear {
            ensureSessions()
            hub.ensureWorkspaceLayout()
        }
        .onChange(of: store.effectiveWorkspaceURL.path) { _, _ in
            ensureSessions(relocateExisting: true)
            hub.ensureWorkspaceLayout()
        }
        .onChange(of: store.hasExplicitWorkspace) { _, hasWorkspace in
            if hasWorkspace {
                ensureSessions()
                hub.ensureWorkspaceLayout()
            } else {
                hub.terminateAll()
                isWorkspace = false
                isPresented = false
            }
        }
    }

    private var panelBackground: Color {
        Color(red: 0.09, green: 0.095, blue: 0.10)
    }

    private var chrome: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)

            Menu {
                ForEach(DesktopTerminalGridTemplate.allCases) { template in
                    Button {
                        applyTemplate(template)
                    } label: {
                        Label(template.title, systemImage: template.systemImage)
                    }
                }
            } label: {
                Label("Layout", systemImage: "square.split.2x1")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!store.hasExplicitWorkspace)
            .help("Terminal grid layout")

            Button {
                split(.horizontal)
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Split right (⌘D)")
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!store.hasExplicitWorkspace || !hub.canSplitFocusedPane)

            Button {
                split(.vertical)
            } label: {
                Image(systemName: "rectangle.split.1x2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Split down")
            .disabled(!store.hasExplicitWorkspace || !hub.canSplitFocusedPane)

            if hub.selectedSession?.isStarting == true {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 4)
            }

            Spacer(minLength: 8)

            Button {
                isWorkspace = false
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Restore terminal panel")
            .accessibilityLabel("Restore terminal panel")

            Button {
                isWorkspace = false
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide terminal panel")
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(Color.black.opacity(0.18))
    }

    @ViewBuilder
    private var gridBody: some View {
        if !store.hasExplicitWorkspace {
            ContentUnavailableView(
                "Open a project",
                systemImage: "folder",
                description: Text("Choose a project folder to open a terminal.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let tree = hub.paneTree {
            DesktopTerminalPaneTreeView(node: tree, hub: hub, onClosePane: closePane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Color.black.opacity(0.35)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func split(_ axis: DesktopTerminalSplitAxis) {
        guard store.hasExplicitWorkspace else { return }
        hub.splitFocusedPane(
            axis: axis,
            in: store.effectiveWorkspaceURL,
            columns: bootstrapCols,
            rows: bootstrapRows
        )
    }

    private func applyTemplate(_ template: DesktopTerminalGridTemplate) {
        guard store.hasExplicitWorkspace else { return }
        hub.applyGridTemplate(
            template,
            in: store.effectiveWorkspaceURL,
            columns: bootstrapCols,
            rows: bootstrapRows
        )
    }

    private func ensureSessions(relocateExisting: Bool = false) {
        guard store.hasExplicitWorkspace else { return }
        let cwd = store.effectiveWorkspaceURL
        if relocateExisting, !hub.tabs.isEmpty {
            hub.relocateAll(to: cwd, columns: bootstrapCols, rows: bootstrapRows)
        } else {
            hub.ensureActiveTab(in: cwd, columns: bootstrapCols, rows: bootstrapRows)
        }
    }

    private func closePane(_ id: UUID) {
        if !hub.closeTab(id) {
            isWorkspace = false
            isPresented = false
        }
    }
}

private struct DesktopTerminalPaneTreeView: View {
    let node: DesktopTerminalPaneNode
    @ObservedObject var hub: DesktopLocalTerminalHub
    let onClosePane: (UUID) -> Void

    var body: some View {
        switch node {
        case .leaf(let id):
            if let session = hub.tabs.first(where: { $0.id == id }) {
                DesktopTerminalWorkspaceLeaf(
                    session: session,
                    hub: hub,
                    isFocused: hub.focusedSessionID == id,
                    onClose: { onClosePane(id) }
                )
            } else {
                Color(red: 0.09, green: 0.095, blue: 0.10)
            }
        case .split(let splitID, let axis, let ratio, let first, let second):
            DesktopTerminalSplitStack(
                splitID: splitID,
                axis: axis,
                ratio: ratio,
                first: first,
                second: second,
                hub: hub,
                onClosePane: onClosePane
            )
        }
    }
}

private struct DesktopTerminalSplitStack: View {
    let splitID: UUID
    let axis: DesktopTerminalSplitAxis
    let ratio: CGFloat
    let first: DesktopTerminalPaneNode
    let second: DesktopTerminalPaneNode
    @ObservedObject var hub: DesktopLocalTerminalHub
    let onClosePane: (UUID) -> Void

    @State private var dragStartRatio: CGFloat?
    @State private var liveRatio: CGFloat?

    private let handleThickness: CGFloat = 7
    private let minPane: CGFloat = 90

    var body: some View {
        GeometryReader { geo in
            let isHorizontal = axis == .horizontal
            let span = isHorizontal ? geo.size.width : geo.size.height
            let usable = max(span - handleThickness, minPane * 2)
            let leading = clampedLeading(in: usable)

            if isHorizontal {
                HStack(spacing: 0) {
                    child(first)
                        .frame(width: leading)
                    splitHandle(total: usable)
                    child(second)
                        .frame(width: max(minPane, usable - leading))
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    child(first)
                        .frame(height: leading)
                    splitHandle(total: usable)
                    child(second)
                        .frame(height: max(minPane, usable - leading))
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
    }

    private func child(_ node: DesktopTerminalPaneNode) -> some View {
        DesktopTerminalPaneTreeView(node: node, hub: hub, onClosePane: onClosePane)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    private func clampedLeading(in usable: CGFloat) -> CGFloat {
        let displayed = liveRatio ?? ratio
        return min(max(usable * displayed, minPane), usable - minPane)
    }

    private func splitHandle(total usable: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(
                width: axis == .horizontal ? handleThickness : nil,
                height: axis == .vertical ? handleThickness : nil
            )
            .overlay {
                Rectangle()
                    .fill(Color.white.opacity(0.22))
                    .frame(
                        width: axis == .horizontal ? 1 : 28,
                        height: axis == .vertical ? 1 : 28
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartRatio == nil {
                            dragStartRatio = liveRatio ?? ratio
                        }
                        let start = dragStartRatio ?? ratio
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        liveRatio = min(0.8, max(0.2, start + delta / usable))
                    }
                    .onEnded { _ in
                        if let liveRatio {
                            hub.setSplitRatio(splitID, ratio: liveRatio)
                        }
                        dragStartRatio = nil
                        liveRatio = nil
                    }
            )
            .onHover { hovering in
                if hovering {
                    if axis == .horizontal {
                        NSCursor.resizeLeftRight.set()
                    } else {
                        NSCursor.resizeUpDown.set()
                    }
                } else {
                    NSCursor.arrow.set()
                }
            }
            .accessibilityLabel(axis == .horizontal ? "Resize columns" : "Resize rows")
    }
}

private struct DesktopTerminalWorkspaceLeaf: View {
    @ObservedObject var session: DesktopLocalTerminalSession
    @ObservedObject var hub: DesktopLocalTerminalHub
    let isFocused: Bool
    let onClose: () -> Void
    @Environment(\.veoAccent) private var veoAccent
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            paneBar
            Divider().overlay(DesktopTheme.hairline)
            terminalSurface
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay {
            Rectangle()
                .stroke(
                    isDropTarget
                        ? veoAccent.opacity(0.85)
                        : (isFocused ? veoAccent.opacity(0.55) : Color.white.opacity(0.06)),
                    lineWidth: isDropTarget ? 2 : 1
                )
                .allowsHitTesting(false)
        }
    }

    private var paneBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
                .padding(.leading, 6)
                .help("Drag to rearrange panes")
                .draggable(session.id.uuidString) {
                    Text(session.tabTitle)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .onHover { hovering in
                    if hovering {
                        NSCursor.openHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }

            Button {
                hub.focusWorkspaceSession(session.id)
            } label: {
                HStack(spacing: 6) {
                    Text(session.tabTitle)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(isFocused ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Text(session.agentLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(isFocused ? veoAccent : Color.secondary.opacity(0.8))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .draggable(session.id.uuidString) {
                Text(session.tabTitle)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .help("Click to focus; drag to rearrange panes")

            if hub.visibleSessionIDs.count > 1 {
                Menu {
                    ForEach(otherVisibleSessions) { other in
                        Button("Swap with \(other.tabTitle)") {
                            hub.swapWorkspacePanes(session.id, other.id)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Rearrange pane")
                .accessibilityLabel("Rearrange \(session.tabTitle)")
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close terminal")
            .accessibilityLabel("Close terminal")
            .padding(.trailing, 4)
        }
        .frame(height: 28)
        .background(Color.black.opacity(isFocused ? 0.28 : 0.18))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = UUID(uuidString: raw) else { return false }
            hub.swapWorkspacePanes(dragged, session.id)
            return true
        } isTargeted: { hovering in
            isDropTarget = hovering
        }
    }

    private var otherVisibleSessions: [DesktopLocalTerminalSession] {
        hub.tabs.filter { tab in
            tab.id != session.id && hub.visibleSessionIDs.contains(tab.id)
        }
    }

    @ViewBuilder
    private var terminalSurface: some View {
        ZStack {
            if let error = session.startupError {
                VStack(spacing: 10) {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.35))
            } else {
                GeometryReader { geo in
                    DesktopTerminalView(
                        session: session,
                        hub: hub,
                        viewportSize: geo.size,
                        requestsFocus: isFocused
                    )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .id(session.id)
                .clipped()
                .blur(radius: hub.agentCLIPermissionPrompt?.sessionID == session.id ? 5 : 0)
                .allowsHitTesting(hub.agentCLIPermissionPrompt?.sessionID != session.id)
            }

            if let prompt = hub.agentCLIPermissionPrompt, prompt.sessionID == session.id {
                DesktopAgentCLIPermissionOverlay(prompt: prompt, hub: hub)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeOut(duration: 0.16), value: hub.isAgentCLIPermissionPromptPresented)
    }
}
