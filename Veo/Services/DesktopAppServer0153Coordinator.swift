// FILE: DesktopAppServer0153Coordinator.swift
// Purpose: Owns optional app-server 0.153 protocol workflows and truthful fallback state.
// Layer: Desktop app service

import Foundation
import Observation

@MainActor
@Observable
final class DesktopAppServer0153Coordinator {
    private(set) var liveSettingsState: DesktopLiveTurnSettingsState = .idle
    private(set) var backgroundTerminals: [DesktopBackgroundTerminal] = []
    private(set) var backgroundTerminalState: DesktopAsyncCollectionState = .idle
    private(set) var approvalReviewsByThreadID: [String: [DesktopApprovalReview]] = [:]
    private(set) var realtimeItemsByThreadID: [String: [DesktopRealtimeTranscriptItem]] = [:]
    private(set) var serverQueueLinksByThreadID: [String: [DesktopServerQueueLink]] = [:]
    private(set) var memoryUpdatesInFlight = Set<String>()
    private(set) var memoryModeByThreadID: [String: DesktopThreadMemoryMode] = [:]
    private(set) var modelProviderCapabilities = DesktopModelProviderCapabilities()
    private(set) var marketplaces: [DesktopMarketplaceRecord] = []
    private(set) var pluginSearchResults: [DesktopPluginSearchRecord] = []
    private(set) var externalImportItems: [DesktopExternalAgentImportItem] = []
    private(set) var externalImportProgress: DesktopExternalAgentImportProgress?
    private(set) var integrationState: DesktopAsyncCollectionState = .idle
    private(set) var integrationMessage: String?
    private(set) var isIntegrationMutating = false
    private var queueGenerationByThreadID: [String: Int] = [:]

    let dynamicToolNames = ["veo_workspace_context", "veo_background_terminals"]
    private(set) var dynamicToolEnabledThreadIDs: Set<String> = []
    private let client: CodexAppServerClient
    @ObservationIgnored private var liveSettingsTask: Task<Void, Never>?
    private var liveSettingsGeneration = 0
    private var terminalGeneration = 0
    private var importPending = false
    private var earlyImportEvents: [String: DesktopExternalAgentImportProgress] = [:]
    private var integrationGeneration = 0
    private var integrationCWD: String?
    private(set) var selectedRuntimeThreadID: String?

    init(client: CodexAppServerClient) {
        self.client = client
        if let data = UserDefaults.standard.data(forKey: "VeoDesktop.approvalReviews"),
           let saved = try? JSONDecoder().decode([String: [DesktopApprovalReview]].self, from: data) {
            approvalReviewsByThreadID = saved.mapValues { reviews in
                reviews.map { review in var clean = review; clean.serializedAssessment = nil; return clean }
            }
        }
        dynamicToolEnabledThreadIDs = Set(UserDefaults.standard.stringArray(forKey: "VeoDesktop.dynamicToolThreads") ?? [])
        if let data = UserDefaults.standard.data(forKey: "VeoDesktop.serverQueueLinks"),
           let links = try? JSONDecoder().decode([String: [DesktopServerQueueLink]].self, from: data) {
            serverQueueLinksByThreadID = links
        }
        if let data = UserDefaults.standard.data(forKey: "VeoDesktop.threadMemoryModes"),
           let modes = try? JSONDecoder().decode([String: DesktopThreadMemoryMode].self, from: data) {
            memoryModeByThreadID = modes
        }
    }

    var dynamicToolSpecs: [[String: Any]] {
        [
            [
                "type": "function",
                "name": "veo_workspace_context",
                "description": "Read the originating Veo thread's workspace path and access boundary.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
            ],
            [
                "type": "function",
                "name": "veo_background_terminals",
                "description": "List background agent terminals for the originating Codex thread. Read-only.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
            ],
        ]
    }

    func markDynamicToolsEnabled(uiThreadID: String) {
        dynamicToolEnabledThreadIDs.insert(uiThreadID)
        UserDefaults.standard.set(Array(dynamicToolEnabledThreadIDs).sorted(), forKey: "VeoDesktop.dynamicToolThreads")
    }

    func enabledDynamicToolNames(uiThreadID: String?) -> [String] {
        guard let uiThreadID, dynamicToolEnabledThreadIDs.contains(uiThreadID) else { return [] }
        return dynamicToolNames
    }

    func selectRuntimeThread(_ runtimeID: String?) {
        guard selectedRuntimeThreadID != runtimeID else { return }
        liveSettingsGeneration += 1
        liveSettingsState = .idle
        terminalGeneration += 1
        selectedRuntimeThreadID = runtimeID
        backgroundTerminals = []
        backgroundTerminalState = .idle
    }

    func noteNextTurnOnly(_ reason: String) {
        liveSettingsGeneration += 1
        liveSettingsState = .nextTurnOnly(reason)
    }

    func scheduleLiveSettings(
        uiThreadID: String,
        runtimeThreadID: String,
        resolveTurnID: @escaping () async throws -> String?,
        model: String?, modelProvider: String?, effort: String?, serviceTier: String?,
        supported: Bool
    ) {
        liveSettingsGeneration += 1
        let generation = liveSettingsGeneration
        guard supported else {
            liveSettingsState = .nextTurnOnly("this Codex runtime does not support live turn settings")
            return
        }
        liveSettingsState = .applying
        let predecessor = liveSettingsTask
        liveSettingsTask = Task { @MainActor [weak self] in
            await predecessor?.value
            do {
                try await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, generation == self.liveSettingsGeneration else { return }
                guard let turnID = try await resolveTurnID() else {
                    self.liveSettingsState = .nextTurnOnly("no running turn")
                    return
                }
                guard generation == self.liveSettingsGeneration else { return }
                var params: [String: Any] = ["threadId": runtimeThreadID, "turnId": turnID]
                if let model { params["model"] = model }
                if let modelProvider { params["modelProvider"] = modelProvider }
                if let effort { params["effort"] = effort }
                params["serviceTier"] = serviceTier ?? NSNull()
                let response = try await self.client.request(
                    method: "turn/settings/update",
                    params: params,
                    maturity: .experimental
                )
                guard generation == self.liveSettingsGeneration else { return }
                switch response.string("status") {
                case "applied": self.liveSettingsState = .applied
                case "targetUnavailable": self.liveSettingsState = .nextTurnOnly("the active turn no longer accepts changes")
                default: throw CodexAppServerClientError.malformedResponse("turn/settings/update")
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.liveSettingsGeneration else { return }
                if case CodexAppServerClientError.unsupportedCapability = error {
                    self.liveSettingsState = .nextTurnOnly("unsupported by this Codex runtime")
                } else if case CodexAppServerClientError.rpc(let code, _) = error, code == -32601 {
                    self.liveSettingsState = .nextTurnOnly("unsupported by this Codex runtime")
                } else {
                    self.liveSettingsState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func refreshBackgroundTerminals(runtimeThreadID: String) async {
        guard selectedRuntimeThreadID == runtimeThreadID else { return }
        terminalGeneration += 1
        let generation = terminalGeneration
        backgroundTerminalState = .loading
        do {
            let rows = try await listBackgroundTerminals(runtimeThreadID: runtimeThreadID)
            guard selectedRuntimeThreadID == runtimeThreadID, generation == terminalGeneration else { return }
            backgroundTerminals = rows
            backgroundTerminalState = .loaded
        } catch {
            guard selectedRuntimeThreadID == runtimeThreadID, generation == terminalGeneration else { return }
            backgroundTerminalState = .failed(error.localizedDescription)
        }
    }

    private func listBackgroundTerminals(runtimeThreadID: String) async throws -> [DesktopBackgroundTerminal] {
        var cursor: String?
        var result: [DesktopBackgroundTerminal] = []
        repeat {
            var params: [String: Any] = ["threadId": runtimeThreadID, "limit": 100]
            if let cursor { params["cursor"] = cursor }
            let response = try await client.request(
                method: "thread/backgroundTerminals/list", params: params, maturity: .experimental
            )
            result += (response["data"] as? [[String: Any]] ?? []).compactMap(DesktopBackgroundTerminal.parse)
            cursor = response.string("nextCursor")
        } while cursor != nil
        return result
    }

    func terminateBackgroundTerminal(_ processID: String, runtimeThreadID: String) async {
        do {
            _ = try await client.request(
                method: "thread/backgroundTerminals/terminate",
                params: ["threadId": runtimeThreadID, "processId": processID], maturity: .experimental
            )
            await refreshBackgroundTerminals(runtimeThreadID: runtimeThreadID)
        } catch {
            if selectedRuntimeThreadID == runtimeThreadID { backgroundTerminalState = .failed(error.localizedDescription) }
        }
    }

    func cleanBackgroundTerminals(runtimeThreadID: String) async {
        do {
            _ = try await client.request(
                method: "thread/backgroundTerminals/clean",
                params: ["threadId": runtimeThreadID], maturity: .experimental
            )
            await refreshBackgroundTerminals(runtimeThreadID: runtimeThreadID)
        } catch {
            if selectedRuntimeThreadID == runtimeThreadID { backgroundTerminalState = .failed(error.localizedDescription) }
        }
    }

    func handleApprovalEvent(method: String, params: [String: Any], uiThreadID: String) {
        guard let runtimeThreadID = params.string("threadId"), let turnID = params.string("turnId") else { return }
        if method == "autoApprovalReview/strictReviewRequired" {
            let started = Date(timeIntervalSince1970: (params.number("startedAtMs") ?? 0) / 1_000)
            upsertReview(DesktopApprovalReview(
                id: "strict-\(turnID)-\(Int(started.timeIntervalSince1970 * 1_000))",
                threadID: runtimeThreadID, turnID: turnID, targetItemID: nil,
                phase: .strictReviewRequired, status: "Manual review required", riskLevel: nil,
                rationale: "Automatic approval stopped. Review the pending request yourself.",
                actionSummary: "Strict review", decisionSource: nil, serializedAssessment: nil,
                startedAt: started, completedAt: nil
            ), uiThreadID: uiThreadID)
            return
        }
        guard let reviewID = params.string("reviewId"),
              let review = params["review"] as? [String: Any],
              let action = params["action"] as? [String: Any] else { return }
        let phase: DesktopApprovalReview.Phase = method.hasSuffix("completed") ? .completed : .reviewing
        // The notification is not a GuardianAssessmentEvent. Never manufacture an executable approval.
        let serialized: Data? = nil
        let item = DesktopApprovalReview(
            id: reviewID, threadID: runtimeThreadID, turnID: turnID,
            targetItemID: params.string("targetItemId"), phase: phase,
            status: review.displayString("status") ?? (phase == .reviewing ? "Reviewing" : "Completed"),
            riskLevel: review.string("riskLevel"), rationale: review.string("rationale"),
            actionSummary: Self.guardianActionSummary(action) + (action.string("cwd").map { "\nWorkspace: " + $0 } ?? ""),
            decisionSource: params.string("decisionSource"), serializedAssessment: serialized,
            startedAt: Date(timeIntervalSince1970: (params.number("startedAtMs") ?? 0) / 1_000),
            completedAt: params.number("completedAtMs").map { Date(timeIntervalSince1970: $0 / 1_000) }
        )
        upsertReview(item, uiThreadID: uiThreadID)
    }

    private func upsertReview(_ review: DesktopApprovalReview, uiThreadID: String) {
        var reviews = approvalReviewsByThreadID[uiThreadID] ?? []
        if let index = reviews.firstIndex(where: { $0.id == review.id }) { reviews[index] = review }
        else { reviews.append(review) }
        approvalReviewsByThreadID[uiThreadID] = reviews
        if let data = try? JSONEncoder().encode(approvalReviewsByThreadID) {
            UserDefaults.standard.set(data, forKey: "VeoDesktop.approvalReviews")
        }
    }

    func approveGuardianDeniedAction(_ review: DesktopApprovalReview, runtimeThreadID: String) async throws {
        guard review.canApproveDeniedAction, let data = review.serializedAssessment,
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAppServerClientError.invalidInput("This review does not contain a denied assessment that can be retried.")
        }
        _ = try await client.request(
            method: "thread/approveGuardianDeniedAction",
            params: ["threadId": runtimeThreadID, "event": event]
        )
    }

    func reconcileServerQueue(runtimeThreadID: String, uiThreadID: String) async throws -> [DesktopServerQueueLink] {
        queueGenerationByThreadID[uiThreadID, default: 0] += 1
        let generation = queueGenerationByThreadID[uiThreadID]
        var seen = Set<String>()
        var cursor: String?
        var links: [DesktopServerQueueLink] = []
        repeat {
            var params: [String: Any] = ["threadId": runtimeThreadID, "limit": 100]
            if let cursor { params["cursor"] = cursor }
            let response = try await client.request(method: "thread/queue/list", params: params, maturity: .experimental)
            guard generation == queueGenerationByThreadID[uiThreadID] else { return serverQueueLinksByThreadID[uiThreadID] ?? [] }
            for row in response["data"] as? [[String: Any]] ?? [] {
                if let id = row.string("id"), let clientID = row.string("clientUserMessageId") ?? row.string("id").map({ "server-" + $0 }) {
                    links.append(.init(clientUserMessageID: clientID, queuedSubmissionID: id, inputData: (row["input"] as? [[String: Any]]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }))
                }
            }
            cursor = response.string("nextCursor")
            if let cursor, !seen.insert(cursor).inserted { throw CodexAppServerClientError.malformedResponse("Repeated queue cursor") }
        } while cursor != nil
        serverQueueLinksByThreadID[uiThreadID] = links
        persistServerQueueLinks()
        return links
    }

    func addServerQueue(_ payload: DesktopComposerPayload, runtimeThreadID: String, uiThreadID: String) async throws -> String {
        queueGenerationByThreadID[uiThreadID, default: 0] += 1
        let response = try await client.request(
            method: "thread/queue/add",
            params: ["threadId": runtimeThreadID, "input": payload.protocolInput, "clientUserMessageId": payload.id],
            maturity: .experimental
        )
        guard let queued = response["queuedSubmission"] as? [String: Any], let id = queued.string("id") else {
            throw CodexAppServerClientError.malformedResponse("thread/queue/add")
        }
        queueGenerationByThreadID[uiThreadID, default: 0] += 1
        var links = serverQueueLinksByThreadID[uiThreadID] ?? []
        links.removeAll { $0.clientUserMessageID == payload.id }
        links.append(.init(clientUserMessageID: payload.id, queuedSubmissionID: id, inputData: try? JSONSerialization.data(withJSONObject: payload.protocolInput)))
        serverQueueLinksByThreadID[uiThreadID] = links
        persistServerQueueLinks()
        return id
    }

    func updateServerQueue(_ payload: DesktopComposerPayload, runtimeThreadID: String, uiThreadID: String) async throws {
        queueGenerationByThreadID[uiThreadID, default: 0] += 1
        defer { queueGenerationByThreadID[uiThreadID, default: 0] += 1 }
        guard let id = serverQueueID(clientID: payload.id, uiThreadID: uiThreadID) else { throw CodexAppServerClientError.invalidInput("Queued submission is no longer available.") }
        _ = try await client.request(method: "thread/queue/update", params: [
            "threadId": runtimeThreadID, "queuedSubmissionId": id, "input": payload.protocolInput,
        ], maturity: .experimental)
    }

    func deleteServerQueue(clientID: String, runtimeThreadID: String, uiThreadID: String) async throws {
        queueGenerationByThreadID[uiThreadID, default: 0] += 1
        defer { queueGenerationByThreadID[uiThreadID, default: 0] += 1 }
        guard let id = serverQueueID(clientID: clientID, uiThreadID: uiThreadID) else { throw CodexAppServerClientError.invalidInput("Queued submission is no longer available.") }
        _ = try await client.request(method: "thread/queue/delete", params: [
            "threadId": runtimeThreadID, "queuedSubmissionId": id,
        ], maturity: .experimental)
        serverQueueLinksByThreadID[uiThreadID]?.removeAll { $0.clientUserMessageID == clientID }
        persistServerQueueLinks()
    }

    func reorderServerQueue(clientIDs: [String], runtimeThreadID: String, uiThreadID: String) async throws {
        queueGenerationByThreadID[uiThreadID, default: 0] += 1
        defer { queueGenerationByThreadID[uiThreadID, default: 0] += 1 }
        let ids = clientIDs.compactMap { serverQueueID(clientID: $0, uiThreadID: uiThreadID) }
        guard ids.count == clientIDs.count else { throw CodexAppServerClientError.invalidInput("Server queue is not reconciled.") }
        _ = try await client.request(method: "thread/queue/reorder", params: [
            "threadId": runtimeThreadID, "queuedSubmissionIds": ids,
        ], maturity: .experimental)
    }

    func startServerQueue(clientID: String?, runtimeThreadID: String, uiThreadID: String) async throws {
        queueGenerationByThreadID[uiThreadID, default: 0] += 1
        defer { queueGenerationByThreadID[uiThreadID, default: 0] += 1 }
        var params: [String: Any] = ["threadId": runtimeThreadID]
        if let clientID {
            guard let id = serverQueueID(clientID: clientID, uiThreadID: uiThreadID) else {
                throw CodexAppServerClientError.invalidInput("The selected submission is no longer in the server queue. Refresh the queue before retrying.")
            }
            params["queuedSubmissionId"] = id
        }
        _ = try await client.request(method: "thread/queue/start", params: params, maturity: .experimental)
    }

    func serverQueueID(clientID: String, uiThreadID: String) -> String? {
        serverQueueLinksByThreadID[uiThreadID]?.first { $0.clientUserMessageID == clientID }?.queuedSubmissionID
    }

    func handleRealtimeEvent(method: String, params: [String: Any], uiThreadID: String) {
        guard method == "thread/realtime/item/started" || method == "thread/realtime/item/completed"
                || method == "thread/realtime/item/transcript/delta" else { return }
        var items = realtimeItemsByThreadID[uiThreadID] ?? []
        if method == "thread/realtime/item/transcript/delta", let id = params.string("itemId") {
            if let index = items.firstIndex(where: { $0.id == id }), !items[index].isComplete { items[index].text += params.string("delta") ?? "" }
            realtimeItemsByThreadID[uiThreadID] = items
            return
        }
        guard let item = params["item"] as? [String: Any], item.string("type") == "transcriptSegment",
              let id = item.string("id"), let sessionID = item.string("realtimeSessionId") else { return }
        let parsed = DesktopRealtimeTranscriptItem(
            id: id, sessionID: sessionID, role: item.string("role") ?? "assistant",
            text: item.string("text") ?? "", isComplete: method.hasSuffix("completed"), position: nil
        )
        if let index = items.firstIndex(where: { $0.id == id && $0.sessionID == sessionID }) {
            if !items[index].isComplete || parsed.isComplete { items[index] = parsed }
        } else { items.append(parsed) }
        realtimeItemsByThreadID[uiThreadID] = items
    }

    func loadTimelinePage(runtimeThreadID: String, cursor: String? = nil) async throws -> (items: [(Int, String?, [String: Any])], realtime: [DesktopRealtimeTranscriptItem], next: String?) {
        var params: [String: Any] = ["threadId": runtimeThreadID, "limit": 100]
        if let cursor { params["cursor"] = cursor }
        let response = try await client.request(method: "thread/timeline/list", params: params, maturity: .experimental)
        var ordinary: [(Int, String?, [String: Any])] = []
        var realtime: [DesktopRealtimeTranscriptItem] = []
        for row in response["data"] as? [[String: Any]] ?? [] {
            let position = row.number("position").map(Int.init) ?? 0
            if row.string("type") == "item", let item = row["item"] as? [String: Any] {
                ordinary.append((position, row.string("turnId"), item))
            } else if row.string("type") == "realtime", let item = row["item"] as? [String: Any],
                      item.string("type") == "transcriptSegment", let id = item.string("id"),
                      let session = item.string("realtimeSessionId") {
                realtime.append(.init(id: id, sessionID: session, role: item.string("role") ?? "assistant",
                                      text: item.string("text") ?? "", isComplete: true, position: position))
            }
        }
        return (ordinary, realtime, response.string("nextCursor"))
    }

    func setMemoryMode(_ mode: DesktopThreadMemoryMode, runtimeThreadID: String, uiThreadID: String) async throws {
        guard memoryUpdatesInFlight.insert(uiThreadID).inserted else { return }
        defer { memoryUpdatesInFlight.remove(uiThreadID) }
        _ = try await client.request(method: "thread/memoryMode/set", params: [
            "threadId": runtimeThreadID, "mode": mode.rawValue,
        ], maturity: .experimental)
        memoryModeByThreadID[uiThreadID] = mode
        if let data = try? JSONEncoder().encode(memoryModeByThreadID) {
            UserDefaults.standard.set(data, forKey: "VeoDesktop.threadMemoryModes")
        }
    }

    func readModelProviderCapabilities() async {
        do {
            let response = try await client.request(method: "modelProvider/capabilities/read", params: [:])
            modelProviderCapabilities = .init(
                namespaceTools: response.bool("namespaceTools") ?? false,
                imageGeneration: response.bool("imageGeneration") ?? false,
                webSearch: response.bool("webSearch") ?? false,
                isAvailable: true
            )
        } catch { modelProviderCapabilities = .init() }
    }

    private func selectIntegrationWorkspace(_ cwd: String) {
        guard integrationCWD != cwd else { return }
        integrationCWD = cwd
        externalImportItems = []
        pluginSearchResults = []
        integrationMessage = nil
    }

    func detectExternalAgentConfiguration(cwd: String) async {
        selectIntegrationWorkspace(cwd)
        integrationGeneration += 1
        let generation = integrationGeneration
        integrationState = .loading
        do {
            let response = try await client.request(method: "externalAgentConfig/detect", params: [
                "includeHome": false, "cwds": [cwd],
            ])
            guard generation == integrationGeneration else { return }
            externalImportItems = (response["items"] as? [[String: Any]] ?? []).compactMap { row in
                guard let type = row.string("itemType"), let data = row.protocolJSONData() else { return nil }
                let preview = (row["details"] as? [String: Any]).map(Self.compactJSON) ?? "No additional preview"
                return DesktopExternalAgentImportItem(
                    id: "\(type)|\(row.string("cwd") ?? "home")|\(row.string("description") ?? "")",
                    itemType: type, description: row.string("description") ?? type,
                    cwd: row.string("cwd"), preview: preview, protocolJSON: data
                )
            }
            integrationState = .loaded
            integrationMessage = externalImportItems.isEmpty ? "No importable artifacts were detected in this project." : nil
        } catch { if generation == integrationGeneration { integrationState = .failed(error.localizedDescription) } }
    }

    func importExternalAgentConfiguration(ids: Set<String>) async throws {
        guard !isIntegrationMutating else { throw CodexAppServerClientError.invalidInput("Another setup change is in progress.") }
        isIntegrationMutating = true
        defer { isIntegrationMutating = false }
        let selected = externalImportItems.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { throw CodexAppServerClientError.invalidInput("Choose at least one artifact to import.") }
        guard !importPending, externalImportProgress?.isComplete != false else { throw CodexAppServerClientError.invalidInput("An import is already starting.") }
        importPending = true
        earlyImportEvents = [:]
        defer { importPending = false; earlyImportEvents = [:] }
        let rows = try selected.map { try JSONSerialization.jsonObject(with: $0.protocolJSON) }
        let response = try await client.request(method: "externalAgentConfig/import", params: [
            "migrationItems": rows, "source": "veo-macos",
        ])
        guard let importID = response.string("importId") else { throw CodexAppServerClientError.malformedResponse("externalAgentConfig/import") }
        externalImportProgress = earlyImportEvents[importID] ?? .init(importID: importID, summary: "Import started…", isComplete: false)
    }

    func handleIntegrationNotification(method: String, params: [String: Any]) {
        guard let importID = params.string("importId") else { return }
        let results = params["itemTypeResults"] as? [[String: Any]] ?? []
        let successes = results.reduce(0) { $0 + (($1["successes"] as? [Any])?.count ?? 0) }
        let failures = results.reduce(0) { $0 + (($1["failures"] as? [Any])?.count ?? 0) }
        let details = results.flatMap { $0["failures"] as? [[String: Any]] ?? [] }.compactMap { failure -> String? in
            guard let message = failure.string("message") else { return nil }
            return "\(failure.string("itemType") ?? "Artifact"): \(message)"
        }.joined(separator: "\n")
        let progress = DesktopExternalAgentImportProgress(
            importID: importID, summary: "\(successes) imported, \(failures) failed" + (details.isEmpty ? "" : "\n" + details),
            isComplete: method.hasSuffix("completed")
        )
        if importPending {
            if earlyImportEvents[importID]?.isComplete != true { earlyImportEvents[importID] = progress }
        }
        if externalImportProgress?.importID == importID, externalImportProgress?.isComplete != true { externalImportProgress = progress }
    }

    func reportIntegrationError(_ error: Error) {
        integrationState = .failed(error.localizedDescription)
    }

    func searchPlugins(_ term: String, cwd: String) async {
        selectIntegrationWorkspace(cwd)
        integrationGeneration += 1
        let generation = integrationGeneration
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { pluginSearchResults = []; return }
        integrationState = .loading
        do {
            var cursor: String?
            var seen = Set<String>()
            var results: [DesktopPluginSearchRecord] = []
            repeat {
                var params: [String: Any] = ["searchTerm": term, "scope": "workspace", "cwds": [cwd], "limit": 50]
                if let cursor { params["cursor"] = cursor }
                let response = try await client.request(method: "plugin/search", params: params, maturity: .experimental)
                guard generation == integrationGeneration else { return }
                results += (response["data"] as? [[String: Any]] ?? []).compactMap { row in
                    guard let plugin = row["plugin"] as? [String: Any], let id = plugin.string("id") else { return nil }
                    let interface = plugin["interface"] as? [String: Any]
                    let market = row.string("marketplaceName") ?? "Marketplace"
                    return .init(id: "\(row.string("marketplacePath") ?? market)|\(id)",
                                 name: interface?.string("displayName") ?? plugin.string("name") ?? id,
                                 description: interface?.string("shortDescription") ?? "",
                                 marketplaceName: market, marketplacePath: row.string("marketplacePath"))
                }
                cursor = response.string("nextCursor")
                if let cursor, !seen.insert(cursor).inserted {
                    throw CodexAppServerClientError.malformedResponse("Repeated plugin search cursor")
                }
            } while cursor != nil
            pluginSearchResults = results
            integrationState = .loaded
        } catch { if generation == integrationGeneration { integrationState = .failed(error.localizedDescription) } }
    }

    func refreshIntegrationSetup(cwd: String) async {
        selectIntegrationWorkspace(cwd)
        integrationGeneration += 1
        let generation = integrationGeneration
        integrationState = .loading
        do {
            let response = try await client.request(method: "plugin/list", params: [
                "cwds": [cwd], "forceRefetch": false,
            ])
            guard generation == integrationGeneration else { return }
            marketplaces = (response["marketplaces"] as? [[String: Any]] ?? []).compactMap { row in
                guard let name = row.string("name") else { return nil }
                return .init(
                    name: name, path: row.string("path"),
                    description: (row["interface"] as? [String: Any])?.string("displayName"),
                    pluginCount: (row["plugins"] as? [Any])?.count ?? 0
                )
            }
            let errors = response["marketplaceLoadErrors"] as? [Any] ?? []
            integrationMessage = errors.isEmpty ? nil : "\(errors.count) marketplace(s) could not be loaded."
            integrationState = .loaded
        } catch { if generation == integrationGeneration { integrationState = .failed(error.localizedDescription) } }
    }

    func addMarketplace(source: String) async throws {
        guard !isIntegrationMutating else { throw CodexAppServerClientError.invalidInput("Another setup change is in progress.") }
        isIntegrationMutating = true
        defer { isIntegrationMutating = false }
        let response = try await client.request(method: "marketplace/add", params: ["source": source])
        integrationMessage = response.bool("alreadyAdded") == true
            ? "\(response.string("marketplaceName") ?? "Marketplace") was already added."
            : "Added \(response.string("marketplaceName") ?? "marketplace")."
    }

    func removeMarketplace(name: String) async throws {
        guard !isIntegrationMutating else { throw CodexAppServerClientError.invalidInput("Another setup change is in progress.") }
        isIntegrationMutating = true
        defer { isIntegrationMutating = false }
        _ = try await client.request(method: "marketplace/remove", params: ["marketplaceName": name])
        marketplaces.removeAll { $0.name == name }
        integrationMessage = "Removed \(name)."
    }

    func upgradeMarketplace(name: String?) async throws {
        guard !isIntegrationMutating else { throw CodexAppServerClientError.invalidInput("Another setup change is in progress.") }
        isIntegrationMutating = true
        defer { isIntegrationMutating = false }
        var params: [String: Any] = [:]
        if let name { params["marketplaceName"] = name }
        let response = try await client.request(method: "marketplace/upgrade", params: params)
        let errors = response["errors"] as? [Any] ?? []
        integrationMessage = errors.isEmpty ? "Marketplace update completed." : "Marketplace update completed with \(errors.count) error(s)."
    }

    func handleDynamicToolRequest(
        _ request: [String: Any], route: CodexAppServerRoute,
        resolveContext: (String) -> (cwd: String, access: String)?
    ) -> Bool {
        guard route.method == "item/tool/call", let rpcID = route.rpcID,
              let params = request["params"] as? [String: Any],
              let runtimeID = params.string("threadId"), let tool = params.string("tool") else { return false }
        guard resolveContext(runtimeID) != nil,
              params["namespace"] == nil || params["namespace"] is NSNull || params.string("namespace") == "",
              let arguments = params["arguments"] as? [String: Any], arguments.isEmpty else {
            try? client.respond(to: rpcID, result: Self.toolFailure("Unknown originating thread, namespace, or unsupported arguments."))
            return true
        }
        let response: [String: Any]
        if tool == "veo_workspace_context", let context = resolveContext(runtimeID) {
            response = Self.toolSuccess(["cwd": context.cwd, "accessBoundary": context.access,
                                         "threadId": runtimeID, "readOnly": true])
        } else if tool == "veo_background_terminals" {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let rows = try await self.listBackgroundTerminals(runtimeThreadID: runtimeID)
                    let value: [[String: Any]] = rows.map { ["processId": $0.processID, "command": $0.command, "cwd": $0.cwd] }
                    try self.client.respond(to: rpcID, result: Self.toolSuccess(value))
                } catch {
                    try? self.client.respond(to: rpcID, result: Self.toolFailure(error.localizedDescription))
                }
            }
            return true
        } else {
            response = Self.toolFailure("Veo does not advertise or implement \(tool).")
        }
        try? client.respond(to: rpcID, result: response)
        return true
    }

    private static func toolSuccess(_ value: Any) -> [String: Any] {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ["contentItems": [["type": "inputText", "text": text]], "success": true]
    }

    private static func toolFailure(_ message: String) -> [String: Any] {
        ["contentItems": [["type": "inputText", "text": message]], "success": false]
    }

    private static func guardianActionSummary(_ action: [String: Any]) -> String {
        switch action.string("type") {
        case "command": return action.string("command") ?? "Command"
        case "execve": return ([action.string("program")] + (action["argv"] as? [String] ?? []).map(Optional.some)).compactMap { $0 }.joined(separator: " ")
        case "writeStdin": return "Write input to process \(action.string("processId") ?? "")"
        case "applyPatch": return "Apply changes to \((action["files"] as? [String] ?? []).count) file(s)"
        case "networkAccess": return "Connect to \(action.string("host") ?? action.string("target") ?? "network target")"
        case "mcpToolCall": return "\(action.string("server") ?? "MCP") · \(action.string("toolName") ?? "tool")"
        case "requestPermissions": return action.string("reason") ?? "Request additional permissions"
        default: return "Approval action"
        }
    }

    private func persistServerQueueLinks() {
        if let data = try? JSONEncoder().encode(serverQueueLinksByThreadID) {
            UserDefaults.standard.set(data, forKey: "VeoDesktop.serverQueueLinks")
        }
    }

    private static func compactJSON(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return text.count > 2_000 ? String(text.prefix(1_999)) + "…" : text
    }
}
