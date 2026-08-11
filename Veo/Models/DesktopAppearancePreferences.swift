// FILE: DesktopAppearancePreferences.swift
// Purpose: Persisted appearance preferences for theme, accent, and workspace chrome.
// Layer: Desktop app model

import AppKit
import SwiftUI

enum DesktopAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: return "Sync"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` follows the macOS appearance setting.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum DesktopChromeMaterial: String, CaseIterable, Identifiable {
    case solid
    case mica
    case liquidGlass

    var id: Self { self }

    var title: String {
        switch self {
        case .solid: return "Solid"
        case .mica: return "Mica"
        case .liquidGlass: return "Liquid Glass"
        }
    }
}

typealias DesktopSidebarMaterial = DesktopChromeMaterial
typealias DesktopComposerMaterial = DesktopChromeMaterial
typealias DesktopMinimapMaterial = DesktopChromeMaterial
typealias DesktopWindowMaterial = DesktopChromeMaterial

private struct VeoAccentKey: EnvironmentKey {
    static let defaultValue = Color(red: 0.18, green: 0.55, blue: 0.98)
}

extension EnvironmentValues {
    /// App accent from Appearance settings (not the macOS system accent).
    var veoAccent: Color {
        get { self[VeoAccentKey.self] }
        set { self[VeoAccentKey.self] = newValue }
    }
}

enum DesktopAppearancePreferences {
    static let appearanceModeKey = "VeoDesktop.appearanceMode"
    static let accentColorKey = "VeoDesktop.accentColor"
    static let sidebarMaterialKey = "VeoDesktop.sidebarMaterial"
    static let composerMaterialKey = "VeoDesktop.composerMaterial"
    static let windowMaterialKey = "VeoDesktop.windowMaterial"
    static let threadMinimapVisibleKey = "VeoDesktop.threadMinimapVisible"
    static let threadMinimapMaterialKey = "VeoDesktop.threadMinimapMaterial"

    /// Default Veo accent (matches prior hard-coded `DesktopTheme.accent`).
    static let defaultAccentHex = "#2E8CFA"

    private static let defaults = UserDefaults.standard

    static var appearanceMode: DesktopAppearanceMode {
        let raw = defaults.string(forKey: appearanceModeKey) ?? DesktopAppearanceMode.dark.rawValue
        return DesktopAppearanceMode(rawValue: raw) ?? .dark
    }

    static var sidebarMaterial: DesktopSidebarMaterial {
        let raw = defaults.string(forKey: sidebarMaterialKey) ?? DesktopSidebarMaterial.solid.rawValue
        return DesktopSidebarMaterial(rawValue: raw) ?? .solid
    }

    /// Material behind the main window canvas (conversation and settings panes).
    static var windowMaterial: DesktopWindowMaterial {
        let raw = defaults.string(forKey: windowMaterialKey) ?? DesktopWindowMaterial.solid.rawValue
        return DesktopWindowMaterial(rawValue: raw) ?? .solid
    }

    static var composerMaterial: DesktopComposerMaterial {
        let raw = defaults.string(forKey: composerMaterialKey) ?? DesktopComposerMaterial.liquidGlass.rawValue
        return DesktopComposerMaterial(rawValue: raw) ?? .liquidGlass
    }

    static var isThreadMinimapVisible: Bool {
        defaults.object(forKey: threadMinimapVisibleKey) as? Bool ?? true
    }

    static var threadMinimapMaterial: DesktopMinimapMaterial {
        let raw = defaults.string(forKey: threadMinimapMaterialKey) ?? DesktopMinimapMaterial.liquidGlass.rawValue
        return DesktopMinimapMaterial(rawValue: raw) ?? .liquidGlass
    }

    static var accentColor: Color {
        color(fromHex: defaults.string(forKey: accentColorKey) ?? defaultAccentHex) ?? Color(red: 0.18, green: 0.55, blue: 0.98)
    }

    static func hex(from color: Color) -> String {
        let ns = NSColor(color)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return defaultAccentHex }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func color(fromHex hex: String) -> Color? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt32(value, radix: 16) else { return nil }
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}
