// FILE: DesktopInteractiveTerminalView.swift
// Purpose: Docked project terminal panel with a real local PTY surface.
// Layer: Desktop app view

import AppKit
import SwiftUI

struct DesktopInteractiveTerminalPanel: View {
    @Bindable var store: DesktopCodexStore
    @ObservedObject var hub: DesktopLocalTerminalHub
    @Binding var isPresented: Bool
    @Binding var isWorkspace: Bool
    /// Full conversation container height before the terminal is laid out.
    var availableHeight: CGFloat = 640

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var panelHeight: CGFloat = 288
    @State private var dragStartHeight: CGFloat = 288
    @State private var isDraggingResize = false
    @State private var isFileDropTargeted = false
    @FocusState private var resizeFocused: Bool

    private let minHeight: CGFloat = 140
    private let maxHeight: CGFloat = 520

    private var maximumPanelHeight: CGFloat {
        min(maxHeight, max(minHeight, availableHeight - 320))
    }

    private var displayedPanelHeight: CGFloat {
        min(panelHeight, maximumPanelHeight)
    }

    private var activeSession: DesktopLocalTerminalSession? {
        hub.selectedSession
    }

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            tabBar
            Divider().overlay(DesktopTheme.hairline)
            terminalBody
        }
        .frame(height: displayedPanelHeight)
        .frame(maxWidth: .infinity)
        .background(panelBackground)
        .overlay(alignment: .top) {
            DesktopTheme.hairline.frame(height: 1)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: agentCLIPermissionPresented) {
            if let prompt = hub.agentCLIPermissionPrompt {
                DesktopAgentCLIPermissionSheet(prompt: prompt, hub: hub)
                    .interactiveDismissDisabled()
            }
        }
        .onAppear {
            ensureSession()
        }
        .onChange(of: store.effectiveWorkspaceURL.path) { _, _ in
            ensureSession(relocateExisting: true)
        }
        .onChange(of: store.hasExplicitWorkspace) { _, hasWorkspace in
            if hasWorkspace {
                ensureSession()
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

    /// Seed size for `openpty` before SwiftTerm lays out. Live size comes from the view.
    private var bootstrapCols: Int {
        hub.selectedSession?.ptyColumns ?? 80
    }

    private var bootstrapRows: Int {
        hub.selectedSession?.ptyRows ?? max(8, Int((displayedPanelHeight - 40) / 16))
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(DesktopTheme.raised)
            .frame(height: 7)
            .overlay {
                Capsule()
                    .fill(Color.primary.opacity(resizeFocused ? 0.42 : 0.18))
                    .frame(width: 36, height: 3)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDraggingResize {
                            isDraggingResize = true
                            dragStartHeight = displayedPanelHeight
                        }
                        let next = dragStartHeight - value.translation.height
                        panelHeight = min(maximumPanelHeight, max(minHeight, next))
                    }
                    .onEnded { _ in
                        isDraggingResize = false
                        dragStartHeight = displayedPanelHeight
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .focusable()
            .focused($resizeFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { adjustHeight(by: 24); return .handled }
            .onKeyPress(.downArrow) { adjustHeight(by: -24); return .handled }
            .accessibilityElement()
            .accessibilityLabel("Terminal height")
            .accessibilityValue("\(Int(displayedPanelHeight)) points")
            .accessibilityHint("Use the up and down arrow keys to resize the terminal")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjustHeight(by: 24)
                case .decrement: adjustHeight(by: -24)
                @unknown default: break
                }
            }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(hub.tabs) { tab in
                        terminalTabChip(tab)
                    }

                    Button {
                        guard store.hasExplicitWorkspace else { return }
                        hub.addTab(
                            in: store.effectiveWorkspaceURL,
                            columns: bootstrapCols,
                            rows: bootstrapRows
                        )
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New terminal tab")
                    .accessibilityLabel("New terminal tab")
                    .disabled(!store.hasExplicitWorkspace)
                }
            }

            if activeSession?.isStarting == true {
                ProgressView()
                    .controlSize(.mini)
            }

            DesktopBackgroundAgentTerminalsButton(store: store)

            Spacer(minLength: 8)

            Button {
                isWorkspace = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Full screen terminal")
            .accessibilityLabel("Full screen terminal")

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

    private func terminalTabChip(_ tab: DesktopLocalTerminalSession) -> some View {
        let isSelected = tab.id == hub.selectedTabID
        return HStack(spacing: 6) {
            Button {
                hub.selectTab(tab.id)
            } label: {
                Text(tab.tabTitle)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)

            Button {
                if !hub.closeTab(tab.id) {
                    isWorkspace = false
                    isPresented = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close terminal tab")
            .accessibilityLabel("Close terminal \(tab.tabTitle)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Color.primary.opacity(isSelected ? 0.085 : 0.035),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? DesktopTheme.hairline : Color.clear, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private var terminalBody: some View {
        if !store.hasExplicitWorkspace {
            ContentUnavailableView(
                "Open a project",
                systemImage: "folder",
                description: Text("Choose a project folder to open a terminal.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let session = activeSession, let error = session.startupError {
            VStack(spacing: 10) {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    hub.restartSelected(
                        in: store.effectiveWorkspaceURL,
                        columns: bootstrapCols,
                        rows: bootstrapRows
                    )
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesktopTheme.canvas)
        } else if let session = activeSession {
            // Identity by tab so switching tabs remounts the correct PTY surface.
            // GeometryReader is required: SwiftUI does not reliably call setFrameSize,
            // and Claude/Ink TUIs shatter when PTY cols disagree with the renderer.
            ZStack {
                GeometryReader { geo in
                    DesktopTerminalView(
                        session: session,
                        hub: hub,
                        viewportSize: geo.size,
                        onAddContext: store.addTerminalContext,
                        isFileDropTargeted: $isFileDropTargeted
                    )
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .id(session.id)
                .blur(radius: dropOrPermissionBlur)
                .allowsHitTesting(!hub.isAgentCLIPermissionPromptPresented)

                DesktopTerminalDropOverlay(isActive: isFileDropTargeted && hub.agentCLIPermissionPrompt == nil)

            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFileDropTargeted)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hub.isAgentCLIPermissionPromptPresented)
            .onChange(of: session.id) { _, _ in
                isFileDropTargeted = false
            }
            .onDisappear {
                isFileDropTargeted = false
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DesktopTheme.canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var agentCLIPermissionPresented: Binding<Bool> {
        Binding(
            get: { hub.isAgentCLIPermissionPromptPresented },
            set: { if !$0, hub.isAgentCLIPermissionPromptPresented { hub.denyAgentCLIsFromPrompt() } }
        )
    }

    private func adjustHeight(by amount: CGFloat) {
        panelHeight = min(maximumPanelHeight, max(minHeight, displayedPanelHeight + amount))
    }

    private var dropOrPermissionBlur: CGFloat {
        if hub.isAgentCLIPermissionPromptPresented { return 5 }
        if isFileDropTargeted { return 8 }
        return 0
    }

    private func ensureSession(relocateExisting: Bool = false) {
        guard store.hasExplicitWorkspace else { return }
        let cwd = store.effectiveWorkspaceURL
        let cols = bootstrapCols
        let rows = bootstrapRows
        if relocateExisting, !hub.tabs.isEmpty {
            hub.relocateAll(to: cwd, columns: cols, rows: rows)
        } else {
            hub.ensureActiveTab(in: cwd, columns: cols, rows: rows)
        }
    }
}

struct DesktopAgentCLIPermissionSheet: View {
    let prompt: DesktopAgentCLIPermissionPrompt
    @ObservedObject var hub: DesktopLocalTerminalHub
    @Environment(\.veoAccent) private var veoAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Allow agent CLIs?", systemImage: "terminal")
                        .font(.system(size: 18, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("You typed \(prompt.commandName).")
                        .font(.system(size: 13, weight: .medium))
                    Text("Allow Claude, Codex, and similar tools to run in the Veo terminal. This enables Agent CLIs for future terminal sessions too. You can change it in Settings → Terminal.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
            .frame(maxHeight: 260)

            Divider()

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Not Now") { hub.denyAgentCLIsFromPrompt() }
                    .keyboardShortcut(.cancelAction)
                Button("Allow Agent CLIs") { hub.allowAgentCLIsFromPrompt() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 430)
        .tint(veoAccent)
    }
}
