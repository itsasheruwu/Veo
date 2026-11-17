// FILE: VeoApp.swift
// Purpose: Entry point for the native Veo macOS workspace and its quick-access menu.
// Layer: Desktop app
// Exports: VeoApp
// Depends on: SwiftUI, DesktopCodexStore, DesktopWorkspaceView

import SwiftUI

@main
struct VeoApp: App {
    @State private var store = DesktopCodexStore()
    @State private var keybindings = DesktopKeyboardPreferences.shared
    @StateObject private var navigation = DesktopNavigationState()
    @StateObject private var updateService = DesktopUpdateService()
    @StateObject private var notifications = DesktopNotificationService()
    @StateObject private var permissionsPanel = DesktopPermissionsPanel()
    @StateObject private var menuBarController = DesktopMenuBarController()
    @AppStorage(DesktopAppearancePreferences.appearanceModeKey) private var appearanceModeRaw =
        DesktopAppearanceMode.dark.rawValue

    init() {
        DesktopNotificationPreferences.registerDefaults()
        DesktopBrowserPreferences.registerDefaults()
        DesktopAutoContinuationPreferences.registerDefaults()
    }

    private var preferredColorScheme: ColorScheme? {
        (DesktopAppearanceMode(rawValue: appearanceModeRaw) ?? .dark).preferredColorScheme
    }

    var body: some Scene {
        WindowGroup("Veo", id: "workspace") {
            DesktopWorkspaceView(store: store, navigation: navigation)
                .environmentObject(updateService)
                .environmentObject(notifications)
                .environmentObject(permissionsPanel)
                .environmentObject(menuBarController)
                .preferredColorScheme(preferredColorScheme)
        }
        .defaultSize(width: 1440, height: 900)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            ToolbarCommands()

            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    store.beginNewChat()
                }
                .keyboardShortcut(keybindings.shortcut(for: "newChat"))

                Button("Open Project…") {
                    store.chooseWorkspace()
                }
                .keyboardShortcut(keybindings.shortcut(for: "openProject"))
            }

            CommandMenu("Workspace") {
                Button("Refresh Chats") {
                    store.refreshThreads()
                }
                .keyboardShortcut(keybindings.shortcut(for: "refresh"))

                Button("Reveal Project in Finder") {
                    store.revealWorkspace()
                }
                .disabled(!store.hasExplicitWorkspace)

                Button("Open Terminal Here") {
                    store.openTerminal()
                }
                .disabled(!store.hasExplicitWorkspace)

                Divider()

                Button("Save Prompt for Later") { store.stashPrompt() }
                    .keyboardShortcut(keybindings.shortcut(for: "stash"))
                    .disabled(store.draft.isEmpty && store.attachments.isEmpty)

                Button("Stop Turn") {
                    store.stopTurn()
                }
                .keyboardShortcut(keybindings.shortcut(for: "stop"))
                .disabled(!store.isRunningTurn)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    navigation.showSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(keybindings.shortcut(for: "settings"))

                Button("Manage Permissions…") {
                    permissionsPanel.show(
                        notifications: notifications, audio: store.realtimeAudio, colorScheme: preferredColorScheme
                    )
                }
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateService.checkForUpdates(userInitiated: true)
                    navigation.showSettings(.updates)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .disabled(updateService.isBusy)
            }
        }
    }
}
