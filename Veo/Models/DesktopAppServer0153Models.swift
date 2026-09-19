// FILE: DesktopAppServer0153Models.swift
// Purpose: Typed UI state for optional Codex app-server 0.153 workflows.
// Layer: Desktop app model

import Foundation

enum DesktopLiveTurnSettingsState: Equatable {
    case idle
    case applying
    case applied
    case nextTurnOnly(String)
    case failed(String)

    var label: String? {
        switch self {
        case .idle: return nil
        case .applying: return "Applying to current turn…"
        case .applied: return "Applied to current turn"
        case .nextTurnOnly(let reason): return "Next turn only · \(reason)"
        case .failed(let message): return "Live update failed · \(message)"
        }
    }
}

struct DesktopBackgroundTerminal: Identifiable, Hashable {
    let itemID: String
    let processID: String
    let command: String
    let cwd: String
    let osPID: Int?
    let cpuPercent: Double?
    let rssKB: Int64?

    var id: String { processID }

    static func parse(_ object: [String: Any]) -> Self? {
        guard let itemID = object.string("itemId"),
              let processID = object.string("processId"),
              let command = object.string("command"),
              let cwd = object.string("cwd") else { return nil }
        return Self(
            itemID: itemID,
            processID: processID,
            command: command,
            cwd: cwd,
            osPID: object.number("osPid").map(Int.init),
            cpuPercent: object.number("cpuPercent"),
            rssKB: object.number("rssKb").map(Int64.init)
        )
    }
}

enum DesktopAsyncCollectionState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

struct DesktopApprovalReview: Identifiable, Hashable, Codable {
    enum Phase: String, Hashable, Codable { case reviewing, completed, strictReviewRequired }
    let id: String
    let threadID: String
    let turnID: String
    let targetItemID: String?
    var phase: Phase
    var status: String
    var riskLevel: String?
    var rationale: String?
    var actionSummary: String
    var decisionSource: String?
    var serializedAssessment: Data?
    var startedAt: Date
    var completedAt: Date?

    var canApproveDeniedAction: Bool {
        phase == .completed && status.lowercased().contains("den") && serializedAssessment != nil
    }
}

struct DesktopServerQueueLink: Hashable, Codable {
    let clientUserMessageID: String
    let queuedSubmissionID: String
    var inputData: Data? = nil

    var input: [[String: Any]] {
        guard let inputData else { return [] }
        return (try? JSONSerialization.jsonObject(with: inputData)) as? [[String: Any]] ?? []
    }
}

enum DesktopRealtimeProtocolChoice: String, CaseIterable, Identifiable {
    case automatic
    case timelineV3
    case legacyV2
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .timelineV3: return "Timeline v3"
        case .legacyV2: return "Legacy v2"
        }
    }
}

struct DesktopRealtimeTranscriptItem: Identifiable, Hashable {
    let id: String
    let sessionID: String
    let role: String
    var text: String
    var isComplete: Bool
    let position: Int?
}

enum DesktopThreadMemoryMode: String, CaseIterable, Identifiable, Codable {
    case enabled
    case disabled
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct DesktopModelProviderCapabilities: Equatable {
    var namespaceTools = false
    var imageGeneration = false
    var webSearch = false
    var isAvailable = false
}

struct DesktopMarketplaceRecord: Identifiable, Hashable {
    let name: String
    let path: String?
    let description: String?
    let pluginCount: Int
    var id: String { name }
}

struct DesktopPluginSearchRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let marketplaceName: String
    let marketplacePath: String?
}

struct DesktopExternalAgentImportItem: Identifiable, Hashable {
    let id: String
    let itemType: String
    let description: String
    let cwd: String?
    let preview: String
    let protocolJSON: Data
}

struct DesktopExternalAgentImportProgress: Equatable {
    let importID: String
    var summary: String
    var isComplete: Bool
}

extension Dictionary where Key == String, Value == Any {
    func protocolJSONData() -> Data? {
        try? JSONSerialization.data(withJSONObject: self, options: [.sortedKeys])
    }
}
