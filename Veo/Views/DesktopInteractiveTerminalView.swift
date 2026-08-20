// FILE: DesktopInteractiveTerminalView.swift
// Purpose: Docked project terminal panel with a real local PTY surface.
// Layer: Desktop app view

import AppKit
import SwiftUI

struct DesktopInteractiveTerminalPanel: View {
    @ObservedObject var store: DesktopCodexStore
    @ObservedObject var hub: DesktopLocalTerminalHub
    @Binding var isPresented: Bool
    @Binding var isWorkspace: Bool

    @State private var panelHeight: CGFloat = 288
    @State private var dragStartHeight: CGFloat = 288
    @State private var isDraggingResize = false

    private let minHeight: CGFloat = 140
    private let maxHeight: CGFloat = 520

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
        .frame(height: panelHeight)
        .frame(maxWidth: .infinity)
        .background(panelBackground)
        .overlay(alignment: .top) {
            DesktopTheme.hairline.frame(height: 1)
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
        Color(red: 0.09, green: 0.095, blue: 0.10)
    }

    /// Seed size for `openpty` before SwiftTerm lays out. Live size comes from the view.
    private var bootstrapCols: Int {
        hub.selectedSession?.ptyColumns ?? 80
    }

    private var bootstrapRows: Int {
        hub.selectedSession?.ptyRows ?? max(8, Int((panelHeight - 40) / 16))
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 5)
            .overlay {
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 36, height: 3)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDraggingResize {
                            isDraggingResize = true
                            dragStartHeight = panelHeight
                        }
                        let next = dragStartHeight - value.translation.height
                        panelHeight = min(maxHeight, max(minHeight, next))
                    }
                    .onEnded { _ in
                        isDraggingResize = false
                        dragStartHeight = panelHeight
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .accessibilityLabel("Resize terminal")
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
                    .disabled(!store.hasExplicitWorkspace)
                }
            }

            if activeSession?.isStarting == true {
                ProgressView()
                    .controlSize(.mini)
            }

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
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(Color.black.opacity(0.18))
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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (isSelected ? Color.white.opacity(0.10) : Color.white.opacity(0.04)),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? DesktopTheme.hairline : Color.clear, lineWidth: 1)
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
            .background(Color.black.opacity(0.35))
        } else if let session = activeSession {
            // Identity by tab so switching tabs remounts the correct PTY surface.
            // GeometryReader is required: SwiftUI does not reliably call setFrameSize,
            // and Claude/Ink TUIs shatter when PTY cols disagree with the renderer.
            ZStack {
                GeometryReader { geo in
                    DesktopTerminalView(session: session, hub: hub, viewportSize: geo.size)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .id(session.id)
                .blur(radius: hub.isAgentCLIPermissionPromptPresented ? 5 : 0)
                .allowsHitTesting(!hub.isAgentCLIPermissionPromptPresented)

                if let prompt = hub.agentCLIPermissionPrompt {
                    DesktopAgentCLIPermissionOverlay(prompt: prompt, hub: hub)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.easeOut(duration: 0.16), value: hub.isAgentCLIPermissionPromptPresented)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.black.opacity(0.35)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

struct DesktopAgentCLIPermissionOverlay: View {
    let prompt: DesktopAgentCLIPermissionPrompt
    @ObservedObject var hub: DesktopLocalTerminalHub
    @Environment(\.veoAccent) private var veoAccent

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .background(.ultraThinMaterial)

            VStack(spacing: 14) {
                Image(systemName: "hammer")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(veoAccent)

                Text("Allow agent CLIs in the Veo terminal?")
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)

                Text("You typed \(prompt.commandName). Turn on Agent CLIs to run Claude, Codex, and similar tools here. You can change this later in Settings → Terminal.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                HStack(spacing: 10) {
                    Button("Not Now") {
                        hub.denyAgentCLIsFromPrompt()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)

                    Button("Allow") {
                        hub.allowAgentCLIsFromPrompt()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
