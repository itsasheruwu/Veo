import SwiftUI
import Observation

struct DesktopKeyBinding: Codable, Equatable {
    var key: String
    var modifiers: String
    var shortcut: KeyboardShortcut? {
        guard let character = key.first, key.count == 1 else { return nil }
        var flags: EventModifiers = []
        if modifiers.contains("command") { flags.insert(.command) }
        if modifiers.contains("shift") { flags.insert(.shift) }
        if modifiers.contains("option") { flags.insert(.option) }
        if modifiers.contains("control") { flags.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: flags)
    }
}

@MainActor @Observable
final class DesktopKeyboardPreferences {
    static let shared = DesktopKeyboardPreferences()
    static let commands: [(id: String, title: String, binding: DesktopKeyBinding)] = [
        ("newChat", "New chat", .init(key: "n", modifiers: "command")),
        ("openProject", "Open project", .init(key: "o", modifiers: "command")),
        ("refresh", "Refresh chats", .init(key: "r", modifiers: "command shift")),
        ("stop", "Stop turn", .init(key: ".", modifiers: "command")),
        ("settings", "Settings", .init(key: ",", modifiers: "command")),
        ("terminal", "Toggle terminal", .init(key: "`", modifiers: "control")),
        ("stash", "Save prompt", .init(key: "s", modifiers: "command shift")),
        ("worktrees", "Project worktrees", .init(key: "w", modifiers: "command option shift"))
    ]
    private(set) var overrides: [String: DesktopKeyBinding]
    private let defaults: UserDefaults
    private let storageKey = "VeoDesktop.keyBindings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: DesktopKeyBinding].self, from: $0) } ?? [:]
    }
    func binding(for id: String) -> DesktopKeyBinding {
        overrides[id] ?? Self.commands.first { $0.id == id }?.binding ?? .init(key: "", modifiers: "command shift")
    }
    func shortcut(for id: String) -> KeyboardShortcut? { binding(for: id).shortcut }

    func set(_ value: DesktopKeyBinding, for id: String) -> String? {
        let key = value.key.lowercased()
        if !key.isEmpty {
            guard key.count == 1, key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { return "Use one letter, number, or punctuation key." }
            guard value.modifiers.contains("command") || value.modifiers == "control" && key == "`" else { return "Use Command to avoid intercepting typing or terminal input." }
            let reserved: [String: Set<String>] = [
                "command": Set("acvxzqwfhmds".map(String.init)),
                "command shift": ["w", "z", "s", "g", "c", "v"],
                "command option": ["i", "w", "h", "m", "d", "f"]
            ]
            let isOwnDefault = Self.commands.first(where: { $0.id == id })?.binding == value
            if reserved[value.modifiers]?.contains(key) == true && !isOwnDefault { return "That shortcut is reserved for editing, windows, or the terminal." }
            let ids = Set(Self.commands.map(\.id)).union(overrides.keys)
            if ids.contains(where: { $0 != id && binding(for: $0) == DesktopKeyBinding(key: key, modifiers: value.modifiers) }) {
                return "That shortcut is already assigned. Clear the other binding first."
            }
        }
        overrides[id] = .init(key: key, modifiers: value.modifiers)
        persist()
        return nil
    }
    func reset() { overrides = [:]; persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(overrides) { defaults.set(data, forKey: storageKey) }
    }
}
