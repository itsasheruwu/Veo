// FILE: DesktopNotificationPreferences.swift
// Purpose: Persisted preferences for turn alerts, menu bar presence, and completion sounds.
// Layer: Desktop app model

import AppKit
import Foundation

enum DesktopNotificationPreferences {
    static let systemAlertsKey = "VeoDesktop.notificationsSystemAlerts"
    static let inAppWarningsKey = "VeoDesktop.notificationsInAppWarnings"
    static let menuBarIconKey = "VeoDesktop.notificationsMenuBarIcon"
    static let completionSoundKey = "VeoDesktop.notificationsCompletionSound"
    static let customSoundPathKey = "VeoDesktop.notificationsCustomSoundPath"
    static let customSoundNameKey = "VeoDesktop.notificationsCustomSoundName"

    /// Sound used when no custom file is chosen.
    static let defaultSoundName = "Submarine"

    private static let defaults = UserDefaults.standard

    /// Alerts and the menu bar item are on by default; sound stays opt-in so Veo
    /// does not make noise on a machine the user never configured.
    static func registerDefaults(_ store: UserDefaults = .standard) {
        store.register(defaults: [
            systemAlertsKey: true,
            inAppWarningsKey: true,
            menuBarIconKey: true,
            completionSoundKey: false,
        ])
    }

    static var systemAlertsEnabled: Bool { defaults.bool(forKey: systemAlertsKey) }
    static var inAppWarningsEnabled: Bool { defaults.bool(forKey: inAppWarningsKey) }
    static var completionSoundEnabled: Bool { defaults.bool(forKey: completionSoundKey) }

    static var customSoundPath: String? {
        defaults.string(forKey: customSoundPathKey)?.nilIfBlank
    }

    static var customSoundName: String? {
        defaults.string(forKey: customSoundNameKey)?.nilIfBlank
    }

    static func setCustomSoundPath(_ path: String?, displayName: String? = nil) {
        if let path, !path.isEmpty {
            defaults.set(path, forKey: customSoundPathKey)
            if let displayName, !displayName.isEmpty {
                defaults.set(displayName, forKey: customSoundNameKey)
            }
        } else {
            defaults.removeObject(forKey: customSoundPathKey)
            defaults.removeObject(forKey: customSoundNameKey)
        }
    }

    /// Copies a chosen sound into Veo's Application Support folder so it remains
    /// available after the original file is moved, renamed, or disconnected.
    @discardableResult
    static func importCustomSound(from sourceURL: URL) throws -> URL {
        let manager = FileManager.default
        let supportURL = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let soundsURL = supportURL
            .appendingPathComponent("com.ash.Veo", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        try manager.createDirectory(at: soundsURL, withIntermediateDirectories: true)

        let fileExtension = sourceURL.pathExtension.isEmpty ? "aiff" : sourceURL.pathExtension
        let destinationURL = soundsURL
            .appendingPathComponent("Notification-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try manager.copyItem(at: sourceURL, to: destinationURL)

        let previousURL = customSoundPath.map(URL.init(fileURLWithPath:))
        setCustomSoundPath(
            destinationURL.path,
            displayName: sourceURL.deletingPathExtension().lastPathComponent
        )
        if let previousURL,
           previousURL.deletingLastPathComponent().standardizedFileURL == soundsURL.standardizedFileURL {
            try? manager.removeItem(at: previousURL)
        }
        return destinationURL
    }

    static func clearCustomSound() {
        let previousURL = customSoundPath.map(URL.init(fileURLWithPath:))
        setCustomSoundPath(nil)
        guard let previousURL else { return }
        let manager = FileManager.default
        guard let supportURL = try? manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        let soundsURL = supportURL
            .appendingPathComponent("com.ash.Veo", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        if previousURL.deletingLastPathComponent().standardizedFileURL == soundsURL.standardizedFileURL {
            try? manager.removeItem(at: previousURL)
        }
    }

    /// Resolves the configured sound, falling back to the system default when a
    /// custom file has been moved or deleted since it was chosen.
    static func resolvedSound() -> NSSound? {
        if let path = customSoundPath, FileManager.default.fileExists(atPath: path) {
            return NSSound(contentsOfFile: path, byReference: true)
        }
        return NSSound(named: defaultSoundName)
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
