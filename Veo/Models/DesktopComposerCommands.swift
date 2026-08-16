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
    case temporaryChat
    case compact
    case review
    case rename
    case archive
    case fork
    case agentic
    case plan
    case debug
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
    case review
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
    var systemImage = "command"
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
        .init(name: "model", description: "Choose a model in the command palette", action: .model, systemImage: "cube"),
        .init(name: "reasoning", description: "Choose reasoning effort in the command palette", action: .reasoning, systemImage: "brain"),
        .init(name: "permissions", description: "Choose workspace access in the command palette", action: .permissions, systemImage: "shield"),
        .init(name: "review", description: "Review current changes and find issues", action: .review, systemImage: "doc.text.magnifyingglass", supportsInlineArguments: true),
        .init(name: "rename", description: "Rename the current chat in Veo", action: .rename, systemImage: "pencil", supportsInlineArguments: true),
        .init(name: "new", description: "Start a new chat", action: .newChat, systemImage: "square.and.pencil", supportsInlineArguments: true),
        .init(name: "temporary", description: "Make this unused projectless chat temporary", action: .temporaryChat, systemImage: "timer"),
        .init(name: "archive", description: "Archive the current Veo chat", action: .archive, systemImage: "archivebox"),
        .init(name: "delete", description: "Delete the current Veo chat with confirmation", action: .delete, systemImage: "trash"),
        .init(name: "fork", description: "Fork the current chat at a chosen point", action: .fork, systemImage: "arrow.triangle.branch"),
        .init(name: "init", description: "Create an AGENTS.md for this project", action: .initAgents, systemImage: "doc.badge.plus"),
        .init(name: "compact", description: "Summarize history and free context", action: .compact, systemImage: "arrow.down.right.and.arrow.up.left"),
        .init(name: "agentic", description: "Switch to Agentic mode", action: .agentic, systemImage: "sparkles"),
        .init(name: "plan", description: "Switch to Plan mode", action: .plan, systemImage: "list.bullet.clipboard", supportsInlineArguments: true),
        .init(name: "debug", description: "Switch to evidence-first Debug mode", action: .debug, systemImage: "ladybug", supportsInlineArguments: true),
        .init(name: "goal", description: "Set or view a long-running goal", action: .goal, systemImage: "target", supportsInlineArguments: true),
        .init(name: "copy", description: "Copy the last response as Markdown", action: .copyLastResponse, systemImage: "doc.on.doc"),
        .init(name: "diff", description: "Open Veo's Changes view", action: .changes, systemImage: "arrow.left.arrow.right"),
        .init(name: "mention", description: "Mention a project file", action: .mention, systemImage: "at"),
        .init(name: "status", description: "Open Veo's runtime settings", action: .status, systemImage: "bolt.horizontal.circle"),
        .init(name: "usage", description: "Open Veo's account usage and limits", action: .usage, systemImage: "gauge.with.dots.needle.50percent"),
        .init(name: "skills", description: "Open Veo's skills and integrations", action: .integrations, systemImage: "bolt.badge.checkmark"),
        .init(name: "mcp", description: "Open Veo's MCP integrations", action: .integrations, systemImage: "server.rack"),
        .init(name: "apps", description: "Open Veo's connected apps", action: .integrations, systemImage: "square.grid.2x2"),
        .init(name: "plugins", description: "Open Veo's plugin manager", action: .integrations, systemImage: "puzzlepiece.extension"),
        .init(name: "appearance", description: "Open Veo's appearance settings", action: .settings(.appearance), systemImage: "paintbrush"),
        .init(name: "browser", description: "Open Veo's browser settings", action: .settings(.browser), systemImage: "globe"),
        .init(name: "terminal", description: "Open Veo's docked terminal", action: .terminal, systemImage: "apple.terminal"),
        .init(name: "runtime", description: "Open Veo's local runtime settings", action: .settings(.runtime), systemImage: "bolt.horizontal.circle"),
        .init(name: "reconnect", description: "Reconnect Veo to the local Codex runtime", action: .reconnect, systemImage: "arrow.clockwise"),
        .init(name: "reveal", description: "Reveal the current project in Finder", action: .revealProject, systemImage: "folder"),
        .init(name: "refresh", description: "Refresh Veo's chat list", action: .refreshChats, systemImage: "arrow.clockwise"),
        .init(name: "stop", description: "Stop the active turn", action: .stop, systemImage: "stop.circle"),
        .init(name: "clear", description: "Clear the composer and start a new Veo chat", action: .newChat, systemImage: "eraser"),
    ]
}
