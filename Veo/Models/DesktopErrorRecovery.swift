// FILE: DesktopErrorRecovery.swift
// Purpose: Describes explicit, context-bound recovery actions for desktop errors.
// Layer: Desktop app model

import Foundation

enum DesktopErrorRecoveryAction: Hashable {
    case retryQueuedMessage(threadID: String, payloadID: String)
    case restoreMessage(threadID: String, errorItemID: String)
    case reloadConversation(threadID: String)
    case reloadModels
    case reconnect
    case settings(DesktopSettingsCategory)
    case dismiss

    var title: String {
        switch self {
        case .retryQueuedMessage: return "Retry message"
        case .restoreMessage: return "Restore message"
        case .reloadConversation: return "Reload chat"
        case .reloadModels: return "Reload models"
        case .reconnect: return "Reconnect"
        case .settings(let category): return "\(category.title) settings"
        case .dismiss: return "Dismiss"
        }
    }

    var progressTitle: String {
        switch self {
        case .retryQueuedMessage: return "Retrying…"
        case .reloadConversation, .reloadModels: return "Reloading…"
        case .reconnect: return "Reconnecting…"
        case .restoreMessage, .settings, .dismiss: return title
        }
    }

    var help: String {
        switch self {
        case .retryQueuedMessage:
            return "Retry this queued message in its original chat, using its saved access and model settings. Your current draft stays untouched."
        case .restoreMessage:
            return "Restore the failed message and its attachments to an empty composer. Review it before sending again."
        case .reloadConversation:
            return "Reload this chat without clearing its draft or changing its workspace."
        case .reloadModels:
            return "Ask the connected Codex runtime for its model list again."
        case .reconnect:
            return "Reconnect the local Codex runtime. Available when no chats are running."
        case .settings(let category):
            return "Open \(category.title.lowercased()) settings to resolve this error."
        case .dismiss:
            return "Dismiss this notice without changing your message or workspace."
        }
    }

    static func isCurrentError(_ itemID: String, in timeline: [DesktopTimelineItem]) -> Bool {
        guard let index = timeline.lastIndex(where: { $0.kind == .error }),
              timeline[index].id == itemID else { return false }
        return !timeline.dropFirst(index + 1).contains {
            $0.kind == .user || $0.kind == .assistant || $0.kind == .plan
        }
    }

    static func originalMessage(
        for itemID: String,
        in timeline: [DesktopTimelineItem],
        originalClientID: String? = nil
    ) -> DesktopTimelineItem? {
        guard let index = timeline.firstIndex(where: { $0.id == itemID && $0.kind == .error }) else { return nil }
        let error = timeline[index]
        let clientID = error.clientID ?? originalClientID
        let original = timeline[..<index].last { candidate in
            guard candidate.kind == .user, !candidate.body.isEmpty || !candidate.attachments.isEmpty else { return false }
            if let clientID { return candidate.clientID == clientID }
            if let turnID = error.turnID { return candidate.turnID == turnID }
            return false
        }
        // A late error must never recover a newer message just because it
        // appeared immediately before the error row.
        guard let original, original.id == timeline.last(where: { $0.kind == .user })?.id else { return nil }
        return original
    }

    /// Opaque runtime messages can suggest a settings destination. This never
    /// authorizes a retry or changes access; operation-specific recovery stays in the store.
    static func suggestedSettings(for message: String) -> DesktopSettingsCategory? {
        let text = message.lowercased()
        if ["mcp authorization", "mcp server", "plugin could not", "skill could not"].contains(where: text.contains) {
            return .integrations
        }
        if ["unauthorized", "not authenticated", "authentication", "sign in", "sign-in",
            "api key", "expired token", "token expired"].contains(where: text.contains) {
            return .account
        }
        if ["utility model", "cannot analyze images"].contains(where: text.contains) {
            return .general
        }
        return nil
    }
}
