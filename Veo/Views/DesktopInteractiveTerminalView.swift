// FILE: DesktopInteractiveTerminalView.swift
// Purpose: Docked project terminal panel with a real local PTY surface.
// Layer: Desktop app view

import AppKit
import SwiftUI

struct DesktopInteractiveTerminalPanel: View {
    @ObservedObject var store: DesktopCodexStore
    @ObservedObject var hub: DesktopLocalTerminalHub
    @Binding var isPresented: Bool

    @State private var panelHeight: CGFloat = 240
    @State private var dragStartHeight: CGFloat = 240
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
                isPresented = false
            }
        }
        .onChange(of: panelHeight) { _, height in
            guard !isDraggingResize else { return }
            hub.resizeAll(columns: estimatedCols, rows: estimatedRows(for: height))
        }
    }

    private var panelBackground: Color {
        Color(red: 0.09, green: 0.095, blue: 0.10)
    }

    private var estimatedCols: Int {
        max(40, Int((NSScreen.main?.visibleFrame.width ?? 900) / 7.2) - 12)
    }

    private func estimatedRows(for height: CGFloat) -> Int {
        max(8, Int((height - 40) / 16))
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
                        hub.resizeAll(
                            columns: estimatedCols,
                            rows: estimatedRows(for: panelHeight)
                        )
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
                }
            }

            Button {
                guard store.hasExplicitWorkspace else { return }
                hub.addTab(
                    in: store.effectiveWorkspaceURL,
                    columns: estimatedCols,
                    rows: estimatedRows(for: panelHeight)
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

            if activeSession?.isStarting == true {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer(minLength: 8)

            Button {
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
                        columns: estimatedCols,
                        rows: estimatedRows(for: panelHeight)
                    )
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.35))
        } else if let session = activeSession {
            // Identity by tab so switching tabs remounts the correct PTY surface.
            DesktopTerminalView(session: session)
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.black.opacity(0.35)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func ensureSession(relocateExisting: Bool = false) {
        guard store.hasExplicitWorkspace else { return }
        let cwd = store.effectiveWorkspaceURL
        let cols = estimatedCols
        let rows = estimatedRows(for: panelHeight)
        if relocateExisting, !hub.tabs.isEmpty {
            hub.relocateAll(to: cwd, columns: cols, rows: rows)
        } else {
            hub.ensureActiveTab(in: cwd, columns: cols, rows: rows)
        }
    }
}
