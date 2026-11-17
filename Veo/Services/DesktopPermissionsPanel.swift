import AppKit
import SwiftUI

/// A utility window so the checklist remains visible while macOS handles access.
@MainActor
final class DesktopPermissionsPanel: NSObject, ObservableObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var movedAside = false

    func show(notifications: DesktopNotificationService, audio: RealtimeAudioCoordinator, colorScheme: ColorScheme?) {
        let appearance = colorScheme.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
        if let panel {
            panel.appearance = appearance
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let content = DesktopPermissionsView(
            notifications: notifications,
            audio: audio,
            openSettings: { [weak self] in self?.moveAside() },
            close: { [weak self] in self?.panel?.close() }
        )
        let hosting = NSHostingController(rootView: content)
        hosting.safeAreaRegions = []
        let size = hosting.sizeThatFits(in: CGSize(
            width: DesktopPermissionsView.width, height: .greatestFiniteMagnitude
        ))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Manage Permissions"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.appearance = appearance
        panel.contentViewController = hosting
        panel.delegate = self
        self.panel = panel
        movedAside = false

        if let parent, let screen = parent.screen {
            let bounds = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: min(max(parent.frame.midX - panel.frame.width / 2, bounds.minX), bounds.maxX - panel.frame.width),
                y: min(max(parent.frame.midY - panel.frame.height / 2, bounds.minY), bounds.maxY - panel.frame.height)
            ))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func moveAside() {
        guard !movedAside, let panel, let screen = panel.screen else { return }
        movedAside = true
        let bounds = screen.visibleFrame
        // Leave System Settings’ switches reachable on narrow displays.
        let x = bounds.width < 1450 ? bounds.minX + 16 : bounds.maxX - panel.frame.width - 16
        panel.setFrameOrigin(NSPoint(x: x, y: panel.frame.minY))
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}
