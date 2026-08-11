// FILE: DesktopMenuBarController.swift
// Purpose: Owns Veo's optional AppKit status item without a dynamic SwiftUI scene.
// Layer: Desktop app service

import AppKit
import Combine

/// `MenuBarExtra(isInserted:)` can trap SwiftUI in a scene update loop and starve
/// Veo's app-server callbacks. This narrow AppKit bridge owns only the status item;
/// SwiftUI remains the source of truth for its visibility preference and app state.
@MainActor
final class DesktopMenuBarController: NSObject, ObservableObject, NSMenuDelegate {
    private weak var store: DesktopCodexStore?
    private var statusItem: NSStatusItem?
    private var openWorkspace: (() -> Void)?
    private var runningCancellable: AnyCancellable?

    func configure(store: DesktopCodexStore, openWorkspace: @escaping () -> Void) {
        self.store = store
        self.openWorkspace = openWorkspace
        if runningCancellable == nil {
            runningCancellable = store.$isRunningTurn
                .removeDuplicates()
                .sink { [weak self] _ in
                    self?.updateIcon()
                }
        }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            installIfNeeded()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func installIfNeeded() {
        guard statusItem == nil else {
            updateIcon()
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()
        rebuildMenu(menu)
    }

    private func updateIcon() {
        let symbol = store?.isRunningTurn == true ? "waveform" : "sparkles"
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: store?.isRunningTurn == true ? "Veo is working" : "Veo"
        )
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(
            title: store?.runtimeState.title ?? "Starting Codex",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(menuItem("Open Veo", action: #selector(openVeo)))
        menu.addItem(menuItem("New Chat", action: #selector(newChat)))
        menu.addItem(menuItem("Open Project…", action: #selector(openProject)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Veo", action: #selector(quitVeo)))
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func showWorkspace() {
        openWorkspace?()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openVeo() {
        showWorkspace()
    }

    @objc private func newChat() {
        store?.beginNewChat()
        showWorkspace()
    }

    @objc private func openProject() {
        store?.chooseWorkspace()
        showWorkspace()
    }

    @objc private func quitVeo() {
        NSApp.terminate(nil)
    }
}
