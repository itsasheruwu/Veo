// FILE: DesktopCodexModels.swift
// Purpose: Defines the small, macOS-native view model surface used by the local Codex workspace.
// Layer: Desktop app model
// Depends on: Foundation and the Codex app-server v2 JSON contract

import Foundation

enum DesktopRuntimeState: Equatable {
    case starting
    case ready
    case unavailable(String)

    var title: String {
        switch self {
        case .starting:
            return "Starting Codex"
        case .ready:
            return "Local runtime ready"
        case .unavailable:
            return "Codex unavailable"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum DesktopAccessMode: String, CaseIterable, Identifiable, Codable, Hashable {
    case readOnly
    case workspace
    case fullAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readOnly: return "Read only"
        case .workspace: return "Workspace"
        case .fullAccess: return "Full access"
        }
    }

    var shortTitle: String {
        switch self {
        case .readOnly: return "Read"
        case .workspace: return "Workspace"
        case .fullAccess: return "Full"
        }
    }

    var detail: String {
        switch self {
        case .readOnly:
            return "Inspect the project without changing files."
        case .workspace:
            return "Read and edit inside the selected project."
        case .fullAccess:
            return "Allow Codex to work anywhere on this Mac."
        }
    }

    var sandboxValue: String {
        switch self {
        case .readOnly: return "read-only"
        case .workspace: return "workspace-write"
        case .fullAccess: return "danger-full-access"
        }
    }

    func sandboxPolicy(workspacePath: String) -> [String: Any] {
        switch self {
        case .readOnly:
            return [
                "type": "readOnly",
                "networkAccess": false,
            ]
        case .workspace:
            return [
                "type": "workspaceWrite",
                "writableRoots": [workspacePath],
                "networkAccess": false,
            ]
        case .fullAccess:
            return ["type": "dangerFullAccess"]
        }
    }

    // Requests that exceed the selected sandbox are routed into Veo's per-thread queue.
    // The sandbox remains the hard boundary; approvals are explicit and user-scoped.
    var approvalPolicyValue: String { "on-request" }

    var symbolName: String {
        switch self {
        case .readOnly: return "eye"
        case .workspace: return "folder.badge.gearshape"
        case .fullAccess: return "lock.open"
        }
    }
}

enum DesktopFollowUpBehavior: String, CaseIterable, Identifiable, Codable {
    case steer
    case queue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steer: return "Steer current turn"
        case .queue: return "Queue next message"
        }
    }

    var shortTitle: String {
        switch self {
        case .steer: return "Steer"
        case .queue: return "Queue"
        }
    }

    var systemImage: String {
        switch self {
        case .steer: return "arrow.trianglehead.branch"
        case .queue: return "text.line.last.and.arrowtriangle.forward"
        }
    }
}

struct DesktopComposerAttachment: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case localImage
        case image
        case localAudio
        case audio
        case fileMention
        case skill
    }

    let id: String
    let kind: Kind
    let source: String
    let name: String

    init(
        id: String = UUID().uuidString,
        kind: Kind,
        source: String,
        name: String
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.name = name
    }

    var protocolObject: [String: Any]? {
        switch kind {
        case .localImage:
            return ["type": "localImage", "path": source]
        case .image:
            return ["type": "image", "url": source]
        case .localAudio:
            return ["type": "localAudio", "path": source]
        case .audio:
            return ["type": "audio", "url": source]
        case .fileMention:
            return ["type": "mention", "name": name, "path": source]
        case .skill:
            return ["type": "skill", "name": name, "path": source]
        }
    }

    static func parse(_ input: [String: Any]) -> DesktopComposerAttachment? {
        switch input.string("type") {
        case "localImage":
            guard let path = input.string("path") else { return nil }
            return .init(kind: .localImage, source: path, name: URL(fileURLWithPath: path).lastPathComponent)
        case "image":
            guard let url = input.string("url") else { return nil }
            return .init(kind: .image, source: url, name: "Image")
        case "localAudio":
            guard let path = input.string("path") else { return nil }
            return .init(kind: .localAudio, source: path, name: URL(fileURLWithPath: path).lastPathComponent)
        case "audio":
            guard let url = input.string("url") else { return nil }
            return .init(kind: .audio, source: url, name: "Audio")
        case "mention":
            guard let path = input.string("path") else { return nil }
            return .init(kind: .fileMention, source: path, name: input.string("name") ?? URL(fileURLWithPath: path).lastPathComponent)
        case "skill":
            guard let path = input.string("path") else { return nil }
            return .init(kind: .skill, source: path, name: input.string("name") ?? URL(fileURLWithPath: path).lastPathComponent)
        default:
            return nil
        }
    }
}

struct DesktopComposerSuggestion: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case file
        case skill
        case command
        case model
        case reasoning
        case accessMode
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let source: String

    var id: String { "\(kind.rawValue):\(source)" }
}

struct DesktopComposerPayload: Identifiable, Codable, Hashable {
    let id: String
    var text: String
    let createdAt: Date
    var attachments: [DesktopComposerAttachment]
    let accessMode: DesktopAccessMode?
    let model: String?
    let reasoningEffort: String?
    let serviceTier: String?
    let isPlanMode: Bool

    init(
        id: String = UUID().uuidString,
        text: String,
        attachments: [DesktopComposerAttachment] = [],
        accessMode: DesktopAccessMode? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        isPlanMode: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.accessMode = accessMode
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.isPlanMode = isPlanMode
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case createdAt
        case attachments
        case accessMode
        case model
        case reasoningEffort
        case serviceTier
        case isPlanMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        attachments = try container.decodeIfPresent(
            [DesktopComposerAttachment].self,
            forKey: .attachments
        ) ?? []
        accessMode = try container.decodeIfPresent(DesktopAccessMode.self, forKey: .accessMode)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
        isPlanMode = try container.decodeIfPresent(Bool.self, forKey: .isPlanMode) ?? false
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var protocolInput: [[String: Any]] {
        var input: [[String: Any]] = []
        if !trimmedText.isEmpty {
            input.append(["type": "text", "text": trimmedText])
        }
        input.append(contentsOf: attachments.compactMap(\.protocolObject))
        return input
    }
}

struct DesktopInteractionSnapshot: Codable {
    var draftsByContextID: [String: String] = [:]
    var attachmentsByContextID: [String: [DesktopComposerAttachment]] = [:]
    var queuedDraftsByThreadID: [String: [DesktopComposerPayload]] = [:]

    private enum CodingKeys: String, CodingKey {
        case draftsByContextID
        case attachmentsByContextID
        case queuedDraftsByThreadID
    }

    init(
        draftsByContextID: [String: String] = [:],
        attachmentsByContextID: [String: [DesktopComposerAttachment]] = [:],
        queuedDraftsByThreadID: [String: [DesktopComposerPayload]] = [:]
    ) {
        self.draftsByContextID = draftsByContextID
        self.attachmentsByContextID = attachmentsByContextID
        self.queuedDraftsByThreadID = queuedDraftsByThreadID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        draftsByContextID = try container.decodeIfPresent(
            [String: String].self,
            forKey: .draftsByContextID
        ) ?? [:]
        attachmentsByContextID = try container.decodeIfPresent(
            [String: [DesktopComposerAttachment]].self,
            forKey: .attachmentsByContextID
        ) ?? [:]
        queuedDraftsByThreadID = try container.decodeIfPresent(
            [String: [DesktopComposerPayload]].self,
            forKey: .queuedDraftsByThreadID
        ) ?? [:]
    }
}

struct DesktopReasoningOption: Identifiable, Hashable {
    let id: String
    let description: String

    var title: String {
        switch id.lowercased() {
        case "none": return "None"
        case "minimal": return "Minimal"
        case "low": return "Light"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct DesktopModelServiceTier: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
}

struct DesktopModelOption: Identifiable, Hashable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [DesktopReasoningOption]
    let serviceTiers: [DesktopModelServiceTier]
    let defaultServiceTier: String?

    static func parse(_ object: [String: Any]) -> DesktopModelOption? {
        guard let id = object.string("id"),
              let model = object.string("model") else { return nil }

        let reasoning = (object["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { row -> DesktopReasoningOption? in
            guard let effort = row.string("reasoningEffort") else { return nil }
            return DesktopReasoningOption(id: effort, description: row.string("description") ?? "")
        }
        let tiers = (object["serviceTiers"] as? [[String: Any]] ?? []).compactMap { row -> DesktopModelServiceTier? in
            guard let tierID = row.string("id") else { return nil }
            return DesktopModelServiceTier(
                id: tierID,
                name: row.string("name") ?? tierID.capitalized,
                description: row.string("description") ?? ""
            )
        }

        return DesktopModelOption(
            id: id,
            model: model,
            displayName: object.string("displayName") ?? model,
            description: object.string("description") ?? "",
            isDefault: object.bool("isDefault") ?? false,
            defaultReasoningEffort: object.string("defaultReasoningEffort") ?? reasoning.first?.id ?? "medium",
            supportedReasoningEfforts: reasoning,
            serviceTiers: tiers,
            defaultServiceTier: object.string("defaultServiceTier")
        )
    }
}

enum DesktopThreadOrigin: String, Codable, Hashable {
    case veo
    case codex
}

enum DesktopWorkspaceKind: String, Codable, Hashable {
    case project
    case projectless
    case temporary

    var isAppManaged: Bool { self != .project }
}

/// Stable UI selection key for Veo-owned chats vs Codex history chats.
enum DesktopThreadSelection: Hashable, Codable {
    case veo(String)
    case codex(String)

    var storageKey: String {
        switch self {
        case .veo(let id): return "veo:\(id)"
        case .codex(let id): return "codex:\(id)"
        }
    }

    var origin: DesktopThreadOrigin {
        switch self {
        case .veo: return .veo
        case .codex: return .codex
        }
    }

    /// Bare id without the `veo:` / `codex:` prefix.
    var bareID: String {
        switch self {
        case .veo(let id), .codex(let id): return id
        }
    }

    static func parse(_ key: String) -> DesktopThreadSelection {
        if key.hasPrefix("veo:") {
            return .veo(String(key.dropFirst(4)))
        }
        if key.hasPrefix("codex:") {
            return .codex(String(key.dropFirst(6)))
        }
        // Legacy selectedThreadID values were bare Codex ids.
        return .codex(key)
    }
}

struct DesktopThread: Identifiable, Hashable {
    let id: String
    let sessionID: String?
    let title: String
    let preview: String
    let cwd: String
    let updatedAt: Date
    var status: String
    let isPinned: Bool
    let parentThreadID: String?
    let agentNickname: String?
    let agentRole: String?
    let canAcceptDirectInput: Bool?
    var activeFlags: [String]
    let agentDepth: Int?
    var origin: DesktopThreadOrigin
    var workspaceKind: DesktopWorkspaceKind
    /// Codex app-server thread id used for RPC. For Codex-origin rows this is the bare Codex id.
    var codexThreadId: String?

    var workspaceName: String {
        if workspaceKind == .temporary { return "Temporary Chat" }
        if workspaceKind == .projectless { return "Projectless Chat" }
        return URL(fileURLWithPath: cwd).lastPathComponent.nilIfEmpty ?? "General"
    }

    var selection: DesktopThreadSelection {
        DesktopThreadSelection.parse(id)
    }

    /// Thread id to pass to Codex app-server methods, when a runtime binding exists.
    var runtimeThreadID: String? {
        switch origin {
        case .veo:
            return codexThreadId
        case .codex:
            return codexThreadId ?? selection.bareID
        }
    }

    var isRunning: Bool {
        let normalized = status.lowercased()
        return normalized.contains("active") || normalized.contains("running") || normalized.contains("progress")
    }

    var isSubagent: Bool { parentThreadID != nil }

    var agentStatus: String {
        if activeFlags.contains("waitingOnApproval") { return "Waiting for approval" }
        if activeFlags.contains("waitingOnUserInput") { return "Waiting for input" }
        if isRunning { return "Running" }
        switch status.lowercased() {
        case "systemerror": return "Error"
        case "notloaded": return "Saved"
        case "idle": return "Idle"
        default:
            return status
                .replacingOccurrences(
                    of: "([a-z0-9])([A-Z])",
                    with: "$1 $2",
                    options: .regularExpression
                )
                .capitalized
        }
    }

    static func parse(_ object: [String: Any], origin: DesktopThreadOrigin = .codex) -> DesktopThread? {
        guard let rawID = object.string("id") else { return nil }

        let preview = object.string("preview")?.trimmed ?? ""
        let explicitName = object.string("name")?.trimmed.nilIfEmpty
        let fallbackTitle = preview.firstNonemptyLine?.truncated(to: 68) ?? "New chat"
        let seconds = object.number("recencyAt")
            ?? object.number("updatedAt")
            ?? object.number("createdAt")
            ?? 0

        let statusObject = object["status"] as? [String: Any]
        let source = object["source"] as? [String: Any]
        let subAgent = source?["subAgent"]
        let spawn = (subAgent as? [String: Any])?["thread_spawn"] as? [String: Any]
        let parentRaw = object.string("parentThreadId") ?? spawn?.string("parent_thread_id")
        let uiID: String
        let parentUI: String?
        switch origin {
        case .veo:
            uiID = DesktopThreadSelection.veo(rawID).storageKey
            parentUI = parentRaw.map { DesktopThreadSelection.veo($0).storageKey }
        case .codex:
            uiID = DesktopThreadSelection.codex(rawID).storageKey
            parentUI = parentRaw.map { DesktopThreadSelection.codex($0).storageKey }
        }

        return DesktopThread(
            id: uiID,
            sessionID: object.string("sessionId"),
            title: explicitName ?? fallbackTitle,
            preview: preview,
            cwd: object.string("cwd") ?? FileManager.default.homeDirectoryForCurrentUser.path,
            updatedAt: Date(timeIntervalSince1970: seconds),
            status: object.displayString("status") ?? "idle",
            isPinned: object.bool("isPinned") ?? false,
            parentThreadID: parentUI,
            agentNickname: object.string("agentNickname") ?? spawn?.string("agent_nickname"),
            agentRole: object.string("agentRole") ?? spawn?.string("agent_role"),
            canAcceptDirectInput: object.bool("canAcceptDirectInput"),
            activeFlags: statusObject?.stringArray("activeFlags") ?? [],
            agentDepth: spawn?.number("depth").map(Int.init),
            origin: origin,
            workspaceKind: .project,
            codexThreadId: origin == .codex ? rawID : object.string("codexThreadId")
        )
    }

    static func makeVeo(
        id: String = UUID().uuidString,
        title: String = "New chat",
        preview: String = "",
        cwd: String,
        updatedAt: Date = Date(),
        status: String = "idle",
        isPinned: Bool = false,
        codexThreadId: String? = nil,
        parentThreadID: String? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        canAcceptDirectInput: Bool? = nil,
        activeFlags: [String] = [],
        agentDepth: Int? = nil,
        sessionID: String? = nil,
        workspaceKind: DesktopWorkspaceKind = .project
    ) -> DesktopThread {
        return DesktopThread(
            id: DesktopThreadSelection.veo(id).storageKey,
            sessionID: sessionID,
            title: title,
            preview: preview,
            cwd: cwd,
            updatedAt: updatedAt,
            status: status,
            isPinned: isPinned,
            parentThreadID: parentThreadID.map { id in
                id.hasPrefix("veo:") ? id : DesktopThreadSelection.veo(id).storageKey
            },
            agentNickname: agentNickname,
            agentRole: agentRole,
            canAcceptDirectInput: canAcceptDirectInput,
            activeFlags: activeFlags,
            agentDepth: agentDepth,
            origin: .veo,
            workspaceKind: workspaceKind,
            codexThreadId: codexThreadId
        )
    }
}

struct DesktopThreadSearchOccurrence: Identifiable, Hashable {
    let itemID: String
    let turnID: String
    let turnCursor: String
    let snippet: String
    let matchStart: Int
    let matchEnd: Int

    var id: String { "\(turnID):\(itemID):\(matchStart)" }

    static func parse(_ object: [String: Any]) -> DesktopThreadSearchOccurrence? {
        guard let itemID = object.string("itemId"),
              let turnID = object.string("turnId"),
              let turnCursor = object.string("turnCursor"),
              let snippet = object.string("snippet"),
              let range = object["snippetMatchRange"] as? [String: Any] else { return nil }
        guard let startValue = range.number("start"),
              let endValue = range.number("end") else { return nil }
        let start = Int(startValue)
        let end = Int(endValue)
        guard start >= 0, end >= start, end <= (snippet as NSString).length else { return nil }
        return DesktopThreadSearchOccurrence(
            itemID: itemID,
            turnID: turnID,
            turnCursor: turnCursor,
            snippet: snippet,
            matchStart: start,
            matchEnd: end
        )
    }
}

struct DesktopTurnBoundary: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
    let startedAt: Date?

    static func parse(_ turn: [String: Any], index: Int) -> DesktopTurnBoundary? {
        guard let id = turn.string("id") else { return nil }
        let items = turn["items"] as? [[String: Any]] ?? []
        let userItem = items.first(where: { $0.string("type") == "userMessage" })
        let content = userItem?["content"] as? [[String: Any]] ?? []
        let prompt = content
            .first(where: { $0.string("type") == "text" || $0.string("type") == "input_text" })?
            .string("text")
            .flatMap(visibleUserPromptText)
        let seconds = turn.number("startedAt")
        return DesktopTurnBoundary(
            id: id,
            title: prompt?.firstNonemptyLine?.truncated(to: 72) ?? "Turn \(index + 1)",
            status: turn.displayString("status") ?? "unknown",
            startedAt: seconds.map(Date.init(timeIntervalSince1970:))
        )
    }
}

struct DesktopTokenUsage: Equatable {
    /// Lifetime usage accumulated across the whole thread. This is useful for
    /// accounting, but it is not the amount currently occupying the context window.
    let cumulativeTokens: Int
    /// The app-server's `last` usage snapshot. Codex uses this as the current
    /// context signal; unlike `total`, it drops after compaction.
    let currentContextTokens: Int
    let contextWindow: Int?

    var fractionUsed: Double? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        return min(max(Double(currentContextTokens) / Double(contextWindow), 0), 1)
    }

    var warningLevel: Int {
        guard let fractionUsed else { return 0 }
        if fractionUsed >= 0.9 { return 2 }
        if fractionUsed >= 0.75 { return 1 }
        return 0
    }

    static func parse(_ object: [String: Any]) -> DesktopTokenUsage? {
        guard let total = object["total"] as? [String: Any],
              let last = object["last"] as? [String: Any] else { return nil }
        return DesktopTokenUsage(
            cumulativeTokens: Int(total.number("totalTokens") ?? 0),
            currentContextTokens: Int(last.number("totalTokens") ?? 0),
            contextWindow: object.number("modelContextWindow").map(Int.init)
        )
    }
}

struct DesktopFilePatch: Identifiable, Hashable {
    let path: String
    let diff: String
    let kind: String

    var id: String { path }

    static func parse(_ object: [String: Any]) -> DesktopFilePatch? {
        guard let path = object.string("path"),
              let diff = object.string("diff") else { return nil }
        let change = object["kind"] as? [String: Any]
        return DesktopFilePatch(
            path: path,
            diff: diff,
            kind: change?.string("type") ?? "update"
        )
    }
}

struct DesktopTurnDiff: Equatable {
    var turnID: String?
    var unifiedDiff: String = ""
    var files: [DesktopFilePatch] = []

    var isEmpty: Bool {
        unifiedDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty
    }
}

struct DesktopAccountOverview: Equatable {
    var accountType = "Signed out"
    var email: String?
    var plan: String?
    var requiresOpenAIAuth = false
    var primaryUsedPercent: Int?
    var secondaryUsedPercent: Int?
    var primaryResetsAt: Date?
    var lifetimeTokens: Int?
}

struct DesktopResourceOverview: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Hashable {
        case skill = "Skills"
        case plugin = "Plugins"
        case app = "Apps"
        case mcp = "MCP Servers"

        var systemImage: String {
            switch self {
            case .skill: return "bolt.badge.checkmark"
            case .plugin: return "puzzlepiece.extension"
            case .app: return "app.connected.to.app.below.fill"
            case .mcp: return "server.rack"
            }
        }
    }

    let id: String
    let kind: Kind
    let name: String
    let detail: String
    let status: String

    init(
        id: String? = nil,
        kind: Kind,
        name: String,
        detail: String,
        status: String
    ) {
        self.id = id ?? "\(kind.rawValue):\(name)"
        self.kind = kind
        self.name = name
        self.detail = detail
        self.status = status
    }
}

struct DesktopAgentState: Hashable {
    let status: String
    let message: String?

    static func parse(_ object: [String: Any]) -> DesktopAgentState? {
        guard let status = object.string("status") else { return nil }
        return DesktopAgentState(status: status, message: object.string("message"))
    }

    var displayStatus: String {
        switch status {
        case "pendingInit": return "Starting"
        case "running": return "Running"
        case "interrupted": return "Interrupted"
        case "completed": return "Completed"
        case "errored": return "Error"
        case "shutdown": return "Stopped"
        case "notFound": return "Unavailable"
        default: return status.capitalized
        }
    }

    var isActive: Bool { status == "pendingInit" || status == "running" }
}

struct DesktopTimelineItem: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case user
        case assistant
        case reasoning
        case command
        case fileChange
        case plan
        case activity
        case error
    }

    let id: String
    let turnID: String?
    var clientID: String? = nil
    var kind: Kind
    var title: String
    var body: String
    var detail: String? = nil
    var attachments: [DesktopComposerAttachment] = []
    var status: String?
    var agentStates: [String: DesktopAgentState] = [:]
    var toolMetadata: DesktopToolMetadata?
    var artifacts: [DesktopToolArtifact] = []
    var citations: [DesktopCitationEntry] = []
    var terminalInteractions: [String] = []

    static func parse(_ object: [String: Any], turnID: String?) -> DesktopTimelineItem? {
        let type = object.string("type") ?? ""
        let id = object.string("id") ?? "\(type)-\(UUID().uuidString)"
        let status = object.displayString("status")

        switch type {
        case "userMessage":
            let content = (object["content"] as? [[String: Any]]) ?? []
            let attachments = content.compactMap(DesktopComposerAttachment.parse)
            let body = content.compactMap { input -> String? in
                switch input.string("type") {
                case "text", "input_text":
                    return input.string("text").flatMap(visibleUserPromptText)
                default:
                    return nil
                }
            }.joined(separator: "\n")
            guard !body.isEmpty || !attachments.isEmpty else { return nil }
            return DesktopTimelineItem(
                id: id,
                turnID: turnID,
                clientID: object.string("clientId"),
                kind: .user,
                title: "You",
                body: body,
                attachments: attachments,
                status: status
            )

        case "agentMessage":
            let citation = (object["memoryCitation"] as? [String: Any])
                .flatMap { DesktopMemoryCitation.parse($0, itemID: id) }
            return DesktopTimelineItem(
                id: id,
                turnID: turnID,
                kind: .assistant,
                title: "Codex",
                body: object.string("text") ?? "",
                status: status,
                citations: citation?.entries ?? []
            )

        case "reasoning":
            let summary = object.stringArray("summary").joined(separator: "\n")
            let content = object.stringArray("content").joined(separator: "\n")
            let body = summary.nilIfEmpty ?? content
            guard !body.isEmpty else { return nil }
            return DesktopTimelineItem(id: id, turnID: turnID, kind: .reasoning, title: "Thinking", body: body, status: status)

        case "commandExecution":
            let command = object.string("command") ?? "Command"
            let output = object.string("aggregatedOutput")?.trimmed.nilIfEmpty
            let metadata = DesktopToolMetadata.parse(object)
            return DesktopTimelineItem(
                id: id,
                turnID: turnID,
                kind: .command,
                title: command,
                body: output ?? "Running in \(object.string("cwd") ?? "the workspace")",
                detail: object.string("cwd"),
                status: status,
                toolMetadata: metadata
            )

        case "fileChange":
            let changes = (object["changes"] as? [[String: Any]]) ?? []
            let paths = changes.compactMap { change in
                change.string("path") ?? change.string("filePath")
            }
            let body = paths.isEmpty ? "Updated project files" : paths.joined(separator: "\n")
            return DesktopTimelineItem(
                id: id,
                turnID: turnID,
                kind: .fileChange,
                title: "File changes",
                body: body,
                status: status,
                toolMetadata: DesktopToolMetadata.parse(object)
            )

        case "plan":
            return DesktopTimelineItem(id: id, turnID: turnID, kind: .plan, title: "Plan", body: object.string("text") ?? "", status: status)

        case "mcpToolCall":
            let server = object.string("server") ?? "MCP"
            let tool = object.string("tool") ?? "tool"
            let result = Self.prettyJSON(object["result"])
            let error = (object["error"] as? [String: Any])?.string("message")
                ?? object.string("error")
            let content = ((object["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? [])
            let artifacts = content.enumerated().compactMap {
                DesktopToolArtifact.parseContentItem($0.element, parentID: id, index: $0.offset)
            }
            return DesktopTimelineItem(
                id: id,
                turnID: turnID,
                kind: .activity,
                title: "\(server) · \(tool)",
                body: error ?? result ?? status?.capitalized ?? "Working",
                status: status,
                toolMetadata: DesktopToolMetadata.parse(object),
                artifacts: artifacts
            )

        case "dynamicToolCall":
            let tool = object.string("tool") ?? "Tool"
            let content = object["contentItems"] as? [[String: Any]] ?? []
            let artifacts = content.enumerated().compactMap {
                DesktopToolArtifact.parseContentItem($0.element, parentID: id, index: $0.offset)
            }
            let output = artifacts.first(where: { $0.kind == .text })?.source
            return DesktopTimelineItem(
                id: id,
                turnID: turnID,
                kind: .activity,
                title: tool,
                body: output ?? status?.capitalized ?? "Working",
                status: status,
                toolMetadata: DesktopToolMetadata.parse(object),
                artifacts: artifacts
            )

        case "collabAgentToolCall":
            let tool = object.string("tool") ?? "Subagent"
            let targets = (object["receiverThreadIds"] as? [String])?.count ?? 0
            let states = (object["agentsStates"] as? [String: Any] ?? [:]).reduce(into: [String: DesktopAgentState]()) { result, entry in
                guard let value = entry.value as? [String: Any],
                      let state = DesktopAgentState.parse(value) else { return }
                result[entry.key] = state
            }
            let stateSummary = Dictionary(grouping: states.values, by: \.displayStatus)
                .map { "\($0.value.count) \($0.key.lowercased())" }
                .sorted()
                .joined(separator: " · ")
            let body = stateSummary.nilIfEmpty
                ?? (targets > 0 ? "\(targets) agent\(targets == 1 ? "" : "s")" : (status?.capitalized ?? "Working"))
            return DesktopTimelineItem(
                id: id,
                turnID: turnID,
                kind: .activity,
                title: tool,
                body: body,
                status: status,
                agentStates: states,
                toolMetadata: DesktopToolMetadata.parse(object)
            )

        case "subAgentActivity":
            let activity = object.string("kind") ?? "interacted"
            let agentPath = object.string("agentPath")?.nilIfEmpty
            return DesktopTimelineItem(
                id: id,
                turnID: turnID,
                kind: .activity,
                title: "Subagent \(activity)",
                body: agentPath ?? object.string("agentThreadId") ?? "Agent activity",
                status: activity
            )

        case "webSearch":
            return DesktopTimelineItem(id: id, turnID: turnID, kind: .activity, title: "Web search", body: object.string("query") ?? "Searching", status: status)

        case "imageView":
            let path = object.string("path") ?? "Image"
            return DesktopTimelineItem(
                id: id,
                turnID: turnID,
                kind: .activity,
                title: "Viewed image",
                body: path,
                status: status,
                artifacts: DesktopToolArtifact.parseKnownItem(object).map { [$0] } ?? []
            )

        case "imageGeneration":
            return DesktopTimelineItem(
                id: id,
                turnID: turnID,
                kind: .activity,
                title: "Generated image",
                body: object.string("result") ?? "Complete",
                status: status,
                artifacts: DesktopToolArtifact.parseKnownItem(object).map { [$0] } ?? []
            )

        case "enteredReviewMode":
            return DesktopTimelineItem(
                id: id,
                turnID: turnID,
                kind: .activity,
                title: "Review started",
                body: object.string("review") ?? "Reviewing changes",
                status: "inProgress"
            )

        case "exitedReviewMode":
            return DesktopTimelineItem(
                id: id,
                turnID: turnID,
                kind: .assistant,
                title: "Review",
                body: object.string("review") ?? "Review completed",
                status: "completed"
            )

        default:
            return nil
        }
    }

    private static func prettyJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string.trimmed.nilIfEmpty }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmed.nilIfEmpty
    }
}

enum DesktopRPCRequestID: Hashable {
    case number(Int)
    case string(String)

    init?(_ value: Any?) {
        if let number = value as? NSNumber {
            self = .number(number.intValue)
        } else if let string = value as? String {
            self = .string(string)
        } else {
            return nil
        }
    }

    var rawValue: Any {
        switch self {
        case .number(let value): return value
        case .string(let value): return value
        }
    }

    var stringValue: String {
        switch self {
        case .number(let value): return String(value)
        case .string(let value): return value
        }
    }
}

struct DesktopRequestQuestion: Identifiable {
    struct Option: Identifiable {
        let id = UUID()
        let label: String
        let description: String
    }

    let id: String
    let header: String
    let prompt: String
    let options: [Option]
    let allowsOther: Bool
    let isSecret: Bool
}

struct DesktopMCPFormField: Identifiable {
    enum ValueKind: String {
        case string
        case number
        case integer
        case boolean
        case stringArray
    }

    let id: String
    let title: String
    let detail: String
    let valueKind: ValueKind
    let options: [String]
    let isRequired: Bool
    let isSecret: Bool
    let defaultValue: String
}

struct DesktopApprovalDecision: Identifiable {
    enum Intent: Equatable {
        case approve
        case deny
    }

    let id: String
    let title: String
    let intent: Intent
    let rpcValue: Any

    var isDestructive: Bool { intent == .deny }

    static func parse(_ value: Any, index: Int) -> DesktopApprovalDecision? {
        if let value = value as? String {
            let title: String
            let intent: Intent
            switch value {
            case "accept":
                title = "Allow Once"
                intent = .approve
            case "acceptForSession":
                title = "Allow for Session"
                intent = .approve
            case "decline":
                title = "Decline"
                intent = .deny
            case "cancel":
                title = "Cancel Turn"
                intent = .deny
            default:
                return nil
            }
            return DesktopApprovalDecision(
                id: "\(index):\(value)",
                title: title,
                intent: intent,
                rpcValue: value
            )
        }

        guard let value = value as? [String: Any] else { return nil }
        if value["acceptWithExecpolicyAmendment"] != nil {
            return DesktopApprovalDecision(
                id: "\(index):execpolicy",
                title: "Allow & Save Command Rule",
                intent: .approve,
                rpcValue: value
            )
        }
        if value["applyNetworkPolicyAmendment"] != nil {
            let amendment = value["applyNetworkPolicyAmendment"] as? [String: Any]
            let policy = amendment?["network_policy_amendment"] as? [String: Any]
            let action = policy?.string("action") ?? policy?.string("decision")
            return DesktopApprovalDecision(
                id: "\(index):network:\(action ?? "rule")",
                title: action?.lowercased() == "deny" ? "Save Network Deny Rule" : "Apply Network Rule",
                intent: action?.lowercased() == "deny" ? .deny : .approve,
                rpcValue: value
            )
        }
        return nil
    }

    static func defaults(includeSession: Bool) -> [DesktopApprovalDecision] {
        let values = includeSession
            ? ["decline", "acceptForSession", "accept"]
            : ["decline", "accept"]
        return values.enumerated().compactMap { parse($0.element, index: $0.offset) }
    }
}

struct DesktopPendingRequest: Identifiable {
    enum Kind: Equatable {
        case userInput
        case commandApproval
        case fileApproval
        case permissionApproval
        case mcpElicitation
    }

    let rpcID: DesktopRPCRequestID
    let threadID: String?
    let turnID: String?
    let kind: Kind
    let title: String
    let message: String
    let detail: String?
    let questions: [DesktopRequestQuestion]
    let requestedPermissions: [String: Any]?
    var approvalDecisions: [DesktopApprovalDecision] = []
    var mcpFields: [DesktopMCPFormField] = []
    var mcpMode: String? = nil

    var id: String {
        "\(threadID ?? "global"):\(rpcID.stringValue)"
    }

    static func parse(
        _ object: [String: Any],
        route: CodexAppServerRoute? = nil
    ) -> DesktopPendingRequest? {
        guard let rpcID = DesktopRPCRequestID(object["id"]),
              let method = object.string("method"),
              let params = object["params"] as? [String: Any] else { return nil }

        switch method {
        case "item/tool/requestUserInput":
            let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap { question -> DesktopRequestQuestion? in
                guard let id = question.string("id"),
                      let prompt = question.string("question") else { return nil }
                let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> DesktopRequestQuestion.Option? in
                    guard let label = option.string("label") else { return nil }
                    return .init(label: label, description: option.string("description") ?? "")
                }
                return DesktopRequestQuestion(
                    id: id,
                    header: question.string("header") ?? "Question",
                    prompt: prompt,
                    options: options,
                    allowsOther: question.bool("isOther") ?? options.isEmpty,
                    isSecret: question.bool("isSecret") ?? false
                )
            }
            return DesktopPendingRequest(
                rpcID: rpcID,
                threadID: route?.threadID ?? params.string("threadId"),
                turnID: params.string("turnId"),
                kind: .userInput,
                title: "Codex needs your input",
                message: "Answer to continue this turn.",
                detail: nil,
                questions: questions,
                requestedPermissions: nil
            )

        case "item/commandExecution/requestApproval":
            let rawAvailableDecisions = params["availableDecisions"] as? [Any]
            let availableDecisions = (rawAvailableDecisions ?? [])
                .enumerated()
                .compactMap { DesktopApprovalDecision.parse($0.element, index: $0.offset) }
            return DesktopPendingRequest(
                rpcID: rpcID,
                threadID: route?.threadID ?? params.string("threadId"),
                turnID: params.string("turnId"),
                kind: .commandApproval,
                title: "Allow this command?",
                message: params.string("reason") ?? "Codex wants to run a command outside the current automatic policy.",
                detail: approvalDetail(
                    params,
                    keys: [
                        "command", "cwd", "commandActions", "networkApprovalContext",
                        "additionalPermissions", "proposedExecpolicyAmendment",
                        "proposedNetworkPolicyAmendments", "availableDecisions",
                    ]
                ),
                questions: [],
                requestedPermissions: nil,
                approvalDecisions: rawAvailableDecisions == nil
                    ? DesktopApprovalDecision.defaults(includeSession: true)
                    : availableDecisions
            )

        case "item/fileChange/requestApproval":
            let rawAvailableDecisions = params["availableDecisions"] as? [Any]
            let availableDecisions = (rawAvailableDecisions ?? [])
                .enumerated()
                .compactMap { DesktopApprovalDecision.parse($0.element, index: $0.offset) }
            return DesktopPendingRequest(
                rpcID: rpcID,
                threadID: route?.threadID ?? params.string("threadId"),
                turnID: params.string("turnId"),
                kind: .fileApproval,
                title: "Allow these file changes?",
                message: params.string("reason") ?? "Codex needs confirmation before changing files.",
                detail: approvalDetail(params, keys: ["grantRoot", "cwd"]),
                questions: [],
                requestedPermissions: nil,
                approvalDecisions: rawAvailableDecisions == nil
                    ? DesktopApprovalDecision.defaults(includeSession: true)
                    : availableDecisions
            )

        case "item/permissions/requestApproval":
            return DesktopPendingRequest(
                rpcID: rpcID,
                threadID: route?.threadID ?? params.string("threadId"),
                turnID: params.string("turnId"),
                kind: .permissionApproval,
                title: "Allow more access?",
                message: params.string("reason") ?? "Codex requested access beyond the current workspace policy.",
                detail: approvalDetail(params, keys: ["cwd", "permissions"]),
                questions: [],
                requestedPermissions: params["permissions"] as? [String: Any]
            )

        case "mcpServer/elicitation/request":
            let mode = params.string("mode")
            let fields = parseMCPFields(params["requestedSchema"] as? [String: Any])
            return DesktopPendingRequest(
                rpcID: rpcID,
                threadID: route?.threadID ?? params.string("threadId"),
                turnID: params.string("turnId"),
                kind: .mcpElicitation,
                title: "Tool input requested",
                message: params.string("message")
                    ?? "\(params.string("serverName") ?? "A connected tool") requested information.",
                detail: mode == "url" ? params.string("url") : nil,
                questions: [],
                requestedPermissions: nil,
                mcpFields: fields,
                mcpMode: mode
            )

        default:
            return nil
        }
    }

    private static func approvalDetail(
        _ params: [String: Any],
        keys: [String]
    ) -> String? {
        let sections = keys.compactMap { key -> String? in
            guard let value = params[key], !(value is NSNull) else { return nil }
            let rendered: String
            if let string = value as? String {
                rendered = string
            } else if JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(
                        withJSONObject: value,
                        options: [.prettyPrinted, .sortedKeys]
                      ),
                      let string = String(data: data, encoding: .utf8) {
                rendered = string
            } else {
                rendered = String(describing: value)
            }
            return "\(key)\n\(rendered)"
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    private static func parseMCPFields(_ schema: [String: Any]?) -> [DesktopMCPFormField] {
        guard let schema,
              let properties = schema["properties"] as? [String: Any] else { return [] }
        let required = Set(schema["required"] as? [String] ?? [])

        return properties.keys.sorted().compactMap { name in
            guard let property = properties[name] as? [String: Any] else { return nil }
            let rawType = property.string("type")
                ?? (property["type"] as? [String])?.first(where: { $0 != "null" })
                ?? "string"
            let kind: DesktopMCPFormField.ValueKind
            switch rawType {
            case "boolean": kind = .boolean
            case "number": kind = .number
            case "integer": kind = .integer
            case "array": kind = .stringArray
            default: kind = .string
            }
            let items = property["items"] as? [String: Any]
            let titledOptions = ((property["oneOf"] as? [[String: Any]])
                ?? (items?["anyOf"] as? [[String: Any]]))
                .map { choices in
                    choices.compactMap { $0.string("const") }
                } ?? []
            var options = property["enum"] as? [String]
                ?? items?["enum"] as? [String]
                ?? titledOptions
            if options.isEmpty, kind == .boolean {
                options = ["true", "false"]
            }

            let defaultValue: String
            if let value = property["default"] as? String {
                defaultValue = value
            } else if let values = property["default"] as? [String] {
                defaultValue = values.joined(separator: ", ")
            } else if let value = property["default"] as? NSNumber {
                defaultValue = kind == .boolean
                    ? (value.boolValue ? "true" : "false")
                    : value.stringValue
            } else {
                defaultValue = ""
            }

            return DesktopMCPFormField(
                id: name,
                title: property.string("title") ?? name,
                detail: property.string("description") ?? "",
                valueKind: kind,
                options: options,
                isRequired: required.contains(name),
                isSecret: property.string("format") == "password",
                defaultValue: defaultValue
            )
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let value = self[key] as? String { return value }
        if let value = self[key] as? NSNumber { return value.stringValue }
        return nil
    }

    func number(_ key: String) -> TimeInterval? {
        if let value = self[key] as? NSNumber { return value.doubleValue }
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? Int { return TimeInterval(value) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        return (self[key] as? NSNumber)?.boolValue
    }

    func stringArray(_ key: String) -> [String] {
        self[key] as? [String] ?? []
    }

    func displayString(_ key: String) -> String? {
        if let value = string(key) { return value }
        if let object = self[key] as? [String: Any] {
            return object.string("type") ?? object.string("status")
        }
        return nil
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var firstNonemptyLine: String? {
        split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .map(\.trimmed)
            .first(where: { !$0.isEmpty })
    }

    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(max(1, limit - 1))) + "…"
    }
}

private func visibleUserPromptText(_ source: String) -> String? {
    var text = source
        .replacingOccurrences(of: #"<image>\s*</image>"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    let markerPairs = [
        ("<environment_context>", "</environment_context>"),
        ("<skill>", "</skill>"),
        ("<user_shell_command>", "</user_shell_command>"),
        ("<turn_aborted>", "</turn_aborted>"),
        ("<subagent_notification>", "</subagent_notification>"),
        ("<recommended_plugins>", "</recommended_plugins>"),
        ("<goal_context>", "</goal_context>"),
        ("<user_action>", "</user_action>"),
    ]

    while !text.isEmpty {
        let lower = text.lowercased()
        var consumed = false

        for (start, end) in markerPairs where lower.hasPrefix(start) {
            guard let range = text.range(of: end, options: .caseInsensitive) else { return text }
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            consumed = true
            break
        }
        if consumed { continue }

        if lower.hasPrefix("# agents.md instructions") {
            guard let range = text.range(of: "</instructions>", options: .caseInsensitive) else { return text }
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            while text.lowercased().hasPrefix("<instructions>"),
                  let nextRange = text.range(of: "</instructions>", options: .caseInsensitive) {
                text = String(text[nextRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            continue
        }

        let internalPatterns = [
            #"^<codex_internal_context\s+source=(?:\"[a-z][a-z0-9_]*\"|'[a-z][a-z0-9_]*')>[\s\S]*?</codex_internal_context>"#,
            #"^<external_([a-z0-9_-]+)>[\s\S]*?</external_\1>"#,
        ]
        var removedInternalContext = false
        for pattern in internalPatterns {
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive, .anchored]) {
                text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                removedInternalContext = true
                break
            }
        }
        if removedInternalContext { continue }
        break
    }

    let requestMarker = "## My request for Codex:"
    if let range = text.range(of: requestMarker, options: .backwards) {
        let request = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !request.isEmpty { return request }
    }
    return text.isEmpty ? nil : text
}
