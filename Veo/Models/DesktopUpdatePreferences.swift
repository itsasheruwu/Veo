// FILE: DesktopUpdatePreferences.swift
// Purpose: Stores the user's update-check and auto-install choices.
// Layer: Desktop app model
// Depends on: Foundation

import Foundation

enum DesktopUpdatePreferences {
    static let automaticChecksKey = "VeoDesktop.updates.automaticChecks"
    static let automaticInstallKey = "VeoDesktop.updates.automaticInstall"
    static let lastCheckKey = "VeoDesktop.updates.lastCheck"
    static let skippedVersionKey = "VeoDesktop.updates.skippedVersion"

    /// Checking is on by default; installing without asking stays opt-in.
    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            automaticChecksKey: true,
            automaticInstallKey: false
        ])
    }
}
