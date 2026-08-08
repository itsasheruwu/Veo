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

    var body: some Scene {
        WindowGroup("Veo", id: "workspace") {
            DesktopWorkspaceView(store: store, navigation: navigation)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
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
        }

        MenuBarExtra {
            DesktopMenuBarView(store: store)
        } label: {
            Image(systemName: store.isRunningTurn ? "waveform" : "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}
