// FILE: DesktopTerminalWorkspaceView.swift
// Purpose: Main-canvas multiplexer for terminal workspace mode (focused pane, splits, templates).
// Layer: Desktop app view

import AppKit
import SwiftUI

struct DesktopTerminalWorkspaceView: View {
    @Bindable var store: DesktopCodexStore
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
        .sheet(isPresented: Binding(
            get: { hub.isAgentCLIPermissionPromptPresented },
            set: { if !$0, hub.isAgentCLIPermissionPromptPresented { hub.denyAgentCLIsFromPrompt() } }
        )) {
            if let prompt = hub.agentCLIPermissionPrompt {
                DesktopAgentCLIPermissionSheet(prompt: prompt, hub: hub)
                    .interactiveDismissDisabled()
            }
        }
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
        DesktopTheme.canvas
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

            DesktopBackgroundAgentTerminalsButton(store: store)

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
            .accessibilityLabel("Split terminal right")
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
            .accessibilityLabel("Split terminal down")
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
            .accessibilityLabel("Hide terminal panel")
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(DesktopTheme.raised)
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
            DesktopTheme.canvas
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
                DesktopTheme.canvas
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
    @FocusState private var dividerFocused: Bool
    @Environment(\.veoAccent) private var veoAccent

    private let handleThickness: CGFloat = 7
    private let minPane: CGFloat = 90

    var body: some View {
        GeometryReader { geo in
            let isHorizontal = axis == .horizontal
            let span = isHorizontal ? geo.size.width : geo.size.height
            let usable = max(0, span - handleThickness)
            let leading = clampedLeading(in: usable)

            if isHorizontal {
                HStack(spacing: 0) {
                    child(first)
                        .frame(width: leading)
                    splitHandle(total: usable)
                    child(second)
                        .frame(width: max(0, usable - leading))
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    child(first)
                        .frame(height: leading)
                    splitHandle(total: usable)
                    child(second)
                        .frame(height: max(0, usable - leading))
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
        let minimum = min(minPane, usable / 2)
        return min(max(usable * displayed, minimum), usable - minimum)
    }

    private func splitHandle(total usable: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(dividerFocused ? 0.12 : 0.045))
            .frame(
                width: axis == .horizontal ? handleThickness : nil,
                height: axis == .vertical ? handleThickness : nil
            )
            .overlay {
                Rectangle()
                    .fill(dividerFocused ? veoAccent : Color.primary.opacity(0.22))
                    .frame(
                        width: axis == .horizontal ? 1 : 28,
                        height: axis == .vertical ? 1 : 28
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartRatio == nil {
                            dragStartRatio = liveRatio ?? ratio
                        }
                        guard usable > 0 else { return }
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
            .focusable()
            .focused($dividerFocused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { adjustRatio(by: -0.05); return .handled }
            .onKeyPress(.rightArrow) { adjustRatio(by: 0.05); return .handled }
            .onKeyPress(.upArrow) { adjustRatio(by: -0.05); return .handled }
            .onKeyPress(.downArrow) { adjustRatio(by: 0.05); return .handled }
            .accessibilityElement()
            .accessibilityLabel(axis == .horizontal ? "Terminal column split" : "Terminal row split")
            .accessibilityValue("\(Int((liveRatio ?? ratio) * 100)) percent")
            .accessibilityHint("Use the arrow keys to change the pane sizes")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjustRatio(by: 0.05)
                case .decrement: adjustRatio(by: -0.05)
                @unknown default: break
                }
            }
    }

    private func adjustRatio(by amount: CGFloat) {
        hub.setSplitRatio(splitID, ratio: min(0.8, max(0.2, (liveRatio ?? ratio) + amount)))
    }
}

private struct DesktopTerminalWorkspaceLeaf: View {
    @Environment(\.terminalContextInsertion) private var insertTerminalContext
    @ObservedObject var session: DesktopLocalTerminalSession
    @ObservedObject var hub: DesktopLocalTerminalHub
    let isFocused: Bool
    let onClose: () -> Void
    @Environment(\.veoAccent) private var veoAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTarget = false
    @State private var isFileDropTargeted = false

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
                    isFileDropTargeted || isDropTarget
                        ? veoAccent.opacity(0.85)
                        : (isFocused ? veoAccent.opacity(0.55) : Color.primary.opacity(0.06)),
                    lineWidth: isFileDropTargeted || isDropTarget ? 2 : 1
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
        .background(Color.primary.opacity(isFocused ? 0.055 : 0.025))
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
                .background(DesktopTheme.canvas)
            } else {
                GeometryReader { geo in
                    DesktopTerminalView(
                        session: session,
                        hub: hub,
                        viewportSize: geo.size,
                        requestsFocus: isFocused,
                        onAddContext: insertTerminalContext,
                        isFileDropTargeted: $isFileDropTargeted
                    )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .id(session.id)
                .clipped()
                .blur(radius: workspaceDropOrPermissionBlur)
                .allowsHitTesting(hub.agentCLIPermissionPrompt?.sessionID != session.id)
            }

            DesktopTerminalDropOverlay(
                isActive: isFileDropTargeted && hub.agentCLIPermissionPrompt?.sessionID != session.id
            )

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFileDropTargeted)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hub.isAgentCLIPermissionPromptPresented)
        .onChange(of: session.id) { _, _ in
            isFileDropTargeted = false
        }
        .onDisappear {
            isFileDropTargeted = false
        }
    }

    private var workspaceDropOrPermissionBlur: CGFloat {
        if hub.agentCLIPermissionPrompt?.sessionID == session.id { return 5 }
        if isFileDropTargeted { return 8 }
        return 0
    }
}

private struct TerminalContextInsertionKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var terminalContextInsertion: ((String) -> Void)? {
        get { self[TerminalContextInsertionKey.self] }
        set { self[TerminalContextInsertionKey.self] = newValue }
    }
}
