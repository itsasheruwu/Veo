// FILE: DesktopComposerCommands.swift
// Purpose: Catalogs Codex slash commands and their Veo execution routes.
// Layer: Desktop app model

import Foundation

enum DesktopComposerPaletteContext: Hashable {
    case models
    case reasoning
    case accessModes
}

enum DesktopComposerCommandAction: Hashable {
    case model
    case reasoning
    case permissions
    case newChat
    case compact
    case review
    case rename
    case archive
    case fork
    case plan
    case goal
    case mention
    case status
    case usage
    case integrations
    case changes
    case stop
    case copyLastResponse
    case initAgents
    case settings(DesktopSettingsCategory)
    case terminal
    case reconnect
    case revealProject
    case refreshChats
    case delete
}

enum DesktopComposerCommandDestination: Hashable {
    case inspector
    case settings(DesktopSettingsCategory)
    case changes
    case terminal
    case rename
    case fork
    case delete
}

struct DesktopComposerCommand: Identifiable, Hashable {
    let name: String
    let description: String
    let action: DesktopComposerCommandAction
    var supportsInlineArguments = false

    var id: String { name }
    var invocation: String { "/\(name)" }
    static func named(_ invocation: String) -> DesktopComposerCommand? {
        let name = invocation.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return all.first(where: { $0.name == name })
    }

    // Veo's native command catalog. Every entry maps to a real in-app action or destination;
    // terminal-only presentation commands intentionally stay in the docked Codex CLI.
    static let all: [DesktopComposerCommand] = [
        .init(name: "model", description: "Choose a model in the command palette", action: .model),
        .init(name: "reasoning", description: "Choose reasoning effort in the command palette", action: .reasoning),
        .init(name: "permissions", description: "Choose workspace access in the command palette", action: .permissions),
        .init(name: "review", description: "Review current changes and find issues", action: .review, supportsInlineArguments: true),
        .init(name: "rename", description: "Rename the current chat in Veo", action: .rename, supportsInlineArguments: true),
        .init(name: "new", description: "Start a new chat", action: .newChat, supportsInlineArguments: true),
        .init(name: "archive", description: "Archive the current Veo chat", action: .archive),
        .init(name: "delete", description: "Delete the current Veo chat with confirmation", action: .delete),
        .init(name: "fork", description: "Fork the current chat at a chosen point", action: .fork),
        .init(name: "init", description: "Create an AGENTS.md for this project", action: .initAgents),
        .init(name: "compact", description: "Summarize history and free context", action: .compact),
        .init(name: "plan", description: "Switch to Plan mode", action: .plan, supportsInlineArguments: true),
        .init(name: "goal", description: "Set or view a long-running goal", action: .goal, supportsInlineArguments: true),
        .init(name: "copy", description: "Copy the last response as Markdown", action: .copyLastResponse),
        .init(name: "diff", description: "Open Veo's Changes view", action: .changes),
        .init(name: "mention", description: "Mention a project file", action: .mention),
        .init(name: "status", description: "Open Veo's task inspector", action: .status),
        .init(name: "usage", description: "Open Veo's account usage and limits", action: .usage),
        .init(name: "skills", description: "Open Veo's skills and integrations", action: .integrations),
        .init(name: "mcp", description: "Open Veo's MCP integrations", action: .integrations),
        .init(name: "apps", description: "Open Veo's connected apps", action: .integrations),
        .init(name: "plugins", description: "Open Veo's plugin manager", action: .integrations),
        .init(name: "appearance", description: "Open Veo's appearance settings", action: .settings(.appearance)),
        .init(name: "terminal", description: "Open Veo's docked terminal", action: .terminal),
        .init(name: "runtime", description: "Open Veo's local runtime settings", action: .settings(.runtime)),
        .init(name: "reconnect", description: "Reconnect Veo to the local Codex runtime", action: .reconnect),
        .init(name: "reveal", description: "Reveal the current project in Finder", action: .revealProject),
        .init(name: "refresh", description: "Refresh Veo's chat list", action: .refreshChats),
        .init(name: "stop", description: "Stop the active turn", action: .stop),
        .init(name: "clear", description: "Clear the composer and start a new Veo chat", action: .newChat),
    ]
}
