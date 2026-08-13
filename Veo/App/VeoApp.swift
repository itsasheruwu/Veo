// FILE: VeoApp.swift
// Purpose: Entry point for the native Veo macOS workspace and its quick-access menu.
// Layer: Desktop app
// Exports: VeoApp
// Depends on: SwiftUI, DesktopCodexStore, DesktopWorkspaceView

import SwiftUI

@main
struct VeoApp: App {
    @StateObject private var store = DesktopCodexStore()
    @StateObject private var navigation = DesktopNavigationState()
    @StateObject private var updateService = DesktopUpdateService()
    @StateObject private var notifications = DesktopNotificationService()
    @StateObject private var menuBarController = DesktopMenuBarController()
    @AppStorage(DesktopAppearancePreferences.appearanceModeKey) private var appearanceModeRaw =
        DesktopAppearanceMode.dark.rawValue

    init() {
        DesktopNotificationPreferences.registerDefaults()
        DesktopBrowserPreferences.registerDefaults()
    }

    private var preferredColorScheme: ColorScheme? {
        (DesktopAppearanceMode(rawValue: appearanceModeRaw) ?? .dark).preferredColorScheme
    }

    var body: some Scene {
        WindowGroup("Veo", id: "workspace") {
            DesktopWorkspaceView(store: store, navigation: navigation)
                .environmentObject(updateService)
                .environmentObject(notifications)
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
                .keyboardShortcut("n", modifiers: .command)

                Button("Open Project…") {
                    store.chooseWorkspace()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Workspace") {
                Button("Refresh Chats") {
                    store.refreshThreads()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Reveal Project in Finder") {
                    store.revealWorkspace()
                }
                .disabled(!store.hasExplicitWorkspace)

                Button("Open Terminal Here") {
                    store.openTerminal()
                }
                .disabled(!store.hasExplicitWorkspace)

                Divider()

                Button("Stop Turn") {
                    store.stopTurn()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!store.isRunningTurn)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    navigation.showSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
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
