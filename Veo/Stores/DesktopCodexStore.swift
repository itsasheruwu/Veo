// FILE: DesktopCodexStore.swift
// Purpose: Coordinates the local Codex runtime, desktop thread list, selection, and live timeline.
// Layer: Desktop app state
// Depends on: CodexAppServerClient, DesktopCodexModels, AppKit

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct DesktopAccountSnapshot {
    var overview = DesktopAccountOverview()
    var workspaceMessages: [DesktopWorkspaceMessage] = []
    var resetCreditCount = 0
    var resetCreditID: String?
    var failures: [String] = []
}

@MainActor
final class DesktopCodexStore: ObservableObject {
    @Published var runtimeState: DesktopRuntimeState = .starting
    /// Veo-owned chats (active).
    @Published var threads: [DesktopThread] = []
    /// Veo-owned chats (archived).
    @Published private(set) var archivedThreads: [DesktopThread] = []
    /// Codex CLI history chats (active). Populated only when `showCodexThreads` is true.
    @Published private(set) var codexThreads: [DesktopThread] = []
    /// Codex CLI history chats (archived).
    @Published private(set) var archivedCodexThreads: [DesktopThread] = []
    /// Codex search results (origin `.codex`). Not used for Veo sidebar filtering.
    @Published private(set) var searchedThreads: [DesktopThread]?
    @Published var isBrowsingArchivedThreads = false
    @Published var showCodexThreads = false
    /// True while Codex CLI history is first loading after turning the sidebar option on.
    @Published private(set) var isLoadingCodexThreads = false
    @Published var selectedThreadID: String?
    @Published var timeline: [DesktopTimelineItem] = []
    @Published var draft = "" {
        didSet { persistCurrentDraft() }
    }
    @Published var attachments: [DesktopComposerAttachment] = [] {
        didSet { persistCurrentAttachments() }
    }
    @Published var searchText = "" {
        didSet { scheduleThreadSearch() }
    }
    @Published var searchesMessageContent = false {
        didSet {
            defaults.set(searchesMessageContent, forKey: "VeoDesktop.searchesMessageContent")
            searchOccurrencesByThreadID = [:]
            searchSnippetByThreadID = [:]
            scheduleThreadSearch()
        }
    }
    @Published var accessMode: DesktopAccessMode = .workspace
    @Published var workspaceURL: URL?
    @Published var isLoadingTimeline = false
    @Published var isSubmittingTurn = false
    @Published var isRunningTurn = false
    @Published var activeTurnID: String?
    @Published var transientError: String?
    @Published var pendingRequest: DesktopPendingRequest?
    @Published private(set) var pendingRequestCountsByThreadID: [String: Int] = [:]
    @Published var followUpBehavior: DesktopFollowUpBehavior = .steer
    @Published private(set) var queuedDraftsByThreadID: [String: [DesktopComposerPayload]] = [:]
    @Published private(set) var composerSuggestions: [DesktopComposerSuggestion] = [] {
        didSet {
            if !composerSuggestions.contains(where: { $0.id == selectedComposerSuggestionID }) {
                selectedComposerSuggestionID = composerSuggestions.first?.id
            }
        }
    }
    @Published private(set) var selectedComposerSuggestionID: String?
    @Published private(set) var composerCommandDestinationRequest: DesktopComposerCommandDestination?
    @Published private(set) var composerPaletteContext: DesktopComposerPaletteContext?
    @Published private(set) var tokenUsageByThreadID: [String: DesktopTokenUsage] = [:]
    @Published private(set) var compactingThreadIDs: Set<String> = []
    @Published private(set) var turnDiffByThreadID: [String: DesktopTurnDiff] = [:]
    @Published private(set) var searchOccurrencesByThreadID: [String: [DesktopThreadSearchOccurrence]] = [:]
    @Published private(set) var searchSnippetByThreadID: [String: String] = [:]
    @Published private(set) var agentStateByThreadID: [String: DesktopAgentState] = [:]
    @Published private(set) var timelineNavigationItemID: String?
    @Published private(set) var accountOverview = DesktopAccountOverview()
    @Published private(set) var resourceOverviews: [DesktopResourceOverview] = []
    @Published private(set) var skillRecords: [DesktopSkillRecord] = []
    @Published private(set) var pluginRecords: [DesktopPluginRecord] = []
    @Published private(set) var appRecords: [DesktopAppRecord] = []
    @Published private(set) var mcpServerStatuses: [DesktopMCPServerStatus] = []
    @Published private(set) var accountLoginSession: DesktopAccountLoginSession?
    @Published private(set) var interactiveTerminal: DesktopInteractiveTerminalState?
    @Published private(set) var gitRepository: DesktopGitRepositorySnapshot?
    @Published private(set) var gitReviewSnapshot: DesktopGitReviewSnapshot?
    @Published private(set) var isRefreshingGit = false
    @Published private(set) var isRefreshingGitReview = false
    @Published private(set) var isMutatingGit = false
    @Published private(set) var gitMessage: String?
    @Published var realtimeVoiceEnabled = false {
        didSet { defaults.set(realtimeVoiceEnabled, forKey: "VeoDesktop.realtimeVoiceEnabled") }
    }
    @Published private(set) var realtimeVoices: [DesktopVoiceOption] = []
    @Published var selectedRealtimeVoiceID: String?
    @Published private(set) var realtimeSession: DesktopRealtimeSessionState?
    @Published private(set) var realtimeTranscript = ""
    @Published private(set) var isLoadingAccountOverview = false
    @Published private(set) var isLoadingAccountResources = false
    @Published private(set) var integrationMutationID: String?
    @Published private(set) var accountOverviewMessage: String?
    @Published private(set) var accountResourcesMessage: String?
    @Published var models: [DesktopModelOption] = []
    @Published var selectedModelID: String?
    @Published var selectedReasoningEffort: String?
    @Published var selectedServiceTier: String?
    @Published private(set) var supportsPlanMode = false
    @Published private(set) var capabilities = CodexAppServerCapabilities.unavailable
    @Published var isPlanModeEnabled = false
    @Published var isGoalModeEnabled = false
    @Published private(set) var activeGoalObjective: String?
    @Published private(set) var threadMinimapTopicStartIDs: Set<String>?
    @Published private(set) var utilityModelPreferenceRevision = 0
    @Published private(set) var runtimeNotices: [DesktopRuntimeNotice] = []
    @Published private(set) var permissionProfiles: [DesktopPermissionProfile] = []
    @Published private(set) var managedRequirements = DesktopManagedRequirements()
    @Published private(set) var experimentalFeatures: [DesktopExperimentalFeature] = []
    @Published private(set) var hookRecords: [DesktopHookRecord] = []
    @Published private(set) var codexConfigDetails: [String] = []
    @Published private(set) var isLoadingRuntimeConfiguration = false
    @Published private(set) var runtimeConfigurationMessage: String?
    @Published private(set) var workspaceMessages: [DesktopWorkspaceMessage] = []
    @Published private(set) var availableRateLimitResetCredits = 0
    @Published private(set) var availableRateLimitResetCreditID: String?

    private let client: CodexAppServerClient
    private let utilityInference: DesktopUtilityInferenceCoordinator
    private let gitService: LocalGitService
    private let realtimeAudio: RealtimeAudioCoordinator
    private let defaults: UserDefaults
    private let threadStore = VeoThreadStore()
    private let temporaryWorkspaceService: DesktopTemporaryWorkspaceService
    private var hasStarted = false
    private var connectionTask: Task<Void, Never>?
    private var planModeThreadIDs = Set<String>()
    private var planModeReasoningEffort: String?
    private var draftsByContextID: [String: String] = [:]
    private var attachmentsByContextID: [String: [DesktopComposerAttachment]] = [:]
    /// Active turn ids keyed by UI thread id (`veo:…` / `codex:…`).
    private var activeTurnIDByThread: [String: String] = [:]
    private var queuedDispatchingThreadIDs = Set<String>()
    private var queuedDeliveryInFlightIDs = Set<String>()
    private var availableSkillSuggestions: [DesktopComposerSuggestion] = []
    private var autocompleteTask: Task<Void, Never>?
    private var autocompleteToken: String?
    private var threadSearchTask: Task<Void, Never>?
    private var searchOccurrencesTask: Task<Void, Never>?
    private var codexThreadsLoadGeneration = 0
    private var codexCatalogRequestGeneration = 0
    private var pendingRequestQueues: [String: [DesktopPendingRequest]] = [:]
    private var pendingRequestOrder: [String] = []
    private weak var notifications: DesktopNotificationService?
    private var newChatGenerationID = UUID()
    private var skillPathsByWorkspacePath: [String: Set<String>] = [:]
    private var pendingRealtimeAudioChunks: [RealtimeAudioCoordinator.PCMChunk] = []
    private var isSendingRealtimeAudio = false
    private var realtimeAudioGeneration = UUID()
    private var realtimeStartTask: Task<Void, Never>?
    private var accountOverviewLoadGeneration = UUID()
    private var accountResourcesLoadGeneration = UUID()
    private var interactiveTerminalPendingOutput = Data()
    private var interactiveTerminalPendingProcessID: String?
    private var gitContextGeneration = UUID()
    private var gitRefreshRequested = false
    var prepareForWorkspaceChange: (() -> Bool)?
    /// Opens an HTTPS (or loopback) URL in Veo's embedded browser, sharing ChatGPT cookies.
    var openInEmbeddedBrowser: ((URL, Bool) -> Void)?
    private var pendingEmbeddedBrowserURL: URL?
    private var pendingEmbeddedBrowserIsAccountLogin = false
    private var timelineLoadGeneration = UUID()
    /// Runtime (Codex) thread id → Veo UI storage key.
    private var veoIDByCodexThreadID: [String: String] = [:]
    /// Veo UI storage key → runtime (Codex) thread id.
    private var codexThreadIDByVeoID: [String: String] = [:]
    private var threadMinimapAnalysisTask: Task<Void, Never>?
    private var threadMinimapAnalysisKey: String?
    private var autoTitleTasksByThreadID: [String: Task<Void, Never>] = [:]

    init(
        client: CodexAppServerClient? = nil,
        gitService: LocalGitService? = nil,
        temporaryWorkspaceService: DesktopTemporaryWorkspaceService = DesktopTemporaryWorkspaceService(),
        defaults: UserDefaults = .standard
    ) {
        let resolvedClient = client ?? CodexAppServerClient()
        let resolvedRealtimeAudio = RealtimeAudioCoordinator()
        self.client = resolvedClient
        self.utilityInference = DesktopUtilityInferenceCoordinator(client: resolvedClient)
        self.gitService = gitService ?? LocalGitService()
        self.realtimeAudio = resolvedRealtimeAudio
        self.temporaryWorkspaceService = temporaryWorkspaceService
        self.defaults = defaults

        if let savedPath = defaults.string(forKey: "VeoDesktop.workspacePath"),
           FileManager.default.fileExists(atPath: savedPath) {
            workspaceURL = URL(fileURLWithPath: savedPath, isDirectory: true)
        }
        if let rawMode = defaults.string(forKey: "VeoDesktop.accessMode"),
           let mode = DesktopAccessMode(rawValue: rawMode) {
            accessMode = mode
        }
        if let savedSelection = defaults.string(forKey: "VeoDesktop.selectedThreadID") {
            selectedThreadID = DesktopThreadSelection.parse(savedSelection).storageKey
        }
        selectedModelID = defaults.string(forKey: "VeoDesktop.modelID")
        selectedReasoningEffort = defaults.string(forKey: "VeoDesktop.reasoningEffort")
        selectedServiceTier = defaults.string(forKey: "VeoDesktop.serviceTier")
        realtimeVoiceEnabled = defaults.bool(forKey: "VeoDesktop.realtimeVoiceEnabled")
        selectedRealtimeVoiceID = defaults.string(forKey: "VeoDesktop.realtimeVoice")
        searchesMessageContent = defaults.bool(forKey: "VeoDesktop.searchesMessageContent")
        showCodexThreads = defaults.bool(forKey: "VeoDesktop.showCodexThreads")
        isLoadingCodexThreads = showCodexThreads
        planModeThreadIDs = Set(defaults.stringArray(forKey: "VeoDesktop.planModeThreadIDs") ?? [])
        if let rawBehavior = defaults.string(forKey: "VeoDesktop.followUpBehavior"),
           let behavior = DesktopFollowUpBehavior(rawValue: rawBehavior) {
            followUpBehavior = behavior
        }
        if let snapshotData = defaults.data(forKey: "VeoDesktop.interactionSnapshot"),
           let snapshot = try? JSONDecoder().decode(DesktopInteractionSnapshot.self, from: snapshotData) {
            draftsByContextID = snapshot.draftsByContextID
            attachmentsByContextID = snapshot.attachmentsByContextID
            queuedDraftsByThreadID = snapshot.queuedDraftsByThreadID
        }
        draft = draftsByContextID[currentDraftContextID] ?? ""
        attachments = attachmentsByContextID[currentDraftContextID] ?? []

        Task { await loadVeoThreadsFromStore() }

        resolvedClient.eventHandler = { [weak self] event, route in
            if self?.utilityInference.handle(event, route: route) == true { return }
            self?.handle(event, route: route)
        }
        resolvedClient.serverRequestHandler = { [weak self] request, route in
            if self?.utilityInference.handleServerRequest(request, route: route) == true { return true }
            return self?.captureServerRequest(request, route: route) ?? false
        }
        resolvedClient.capabilitiesHandler = { [weak self] capabilities in
            self?.capabilities = capabilities
            if !capabilities.supports(.threadSearch) {
                self?.searchesMessageContent = false
            }
        }
        resolvedClient.terminationHandler = { [weak self] message in
            guard let self else { return }
            self.runtimeState = .unavailable(message ?? "The local Codex runtime stopped.")
            self.isSubmittingTurn = false
            self.isRunningTurn = false
            self.activeTurnID = nil
            self.pendingRequest = nil
            self.pendingRequestQueues.removeAll()
            self.pendingRequestOrder.removeAll()
            self.pendingRequestCountsByThreadID = [:]
            self.utilityInference.cancelAll()
            self.threadMinimapAnalysisTask?.cancel()
            self.threadMinimapAnalysisTask = nil
            self.autoTitleTasksByThreadID.values.forEach { $0.cancel() }
            self.autoTitleTasksByThreadID = [:]
            if var terminal = self.interactiveTerminal, terminal.isRunning {
                self.flushInteractiveTerminalOutput(processID: terminal.id)
                terminal.isRunning = false
                terminal.isTerminating = false
                terminal.errorMessage = "The local Codex runtime stopped."
                self.interactiveTerminal = terminal
            }
            self.autocompleteTask?.cancel()
            self.threadSearchTask?.cancel()
            self.searchOccurrencesTask?.cancel()
            self.composerSuggestions = []
            self.tokenUsageByThreadID = [:]
            self.compactingThreadIDs = []
            self.turnDiffByThreadID = [:]
            self.agentStateByThreadID = [:]
            self.capabilities = .unavailable
            self.invalidateAccountResourceContext()
            self.pendingRealtimeAudioChunks = []
            self.isSendingRealtimeAudio = false
            self.realtimeAudioGeneration = UUID()
            self.realtimeStartTask?.cancel()
            self.realtimeStartTask = nil
            self.realtimeSession = nil
            self.realtimeTranscript = ""
            self.realtimeAudio.stop()
        }
        resolvedRealtimeAudio.captureHandler = { [weak self] chunk in
            self?.enqueueRealtimeAudio(chunk)
        }
        resolvedRealtimeAudio.errorHandler = { [weak self] message in
            guard let self else { return }
            if self.realtimeSession != nil {
                self.stopRealtimeVoice(preservingError: message)
            } else {
                self.transientError = message
                self.realtimeAudio.stop()
            }
        }
    }

    var filteredThreads: [DesktopThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sidebarThreads }
        return sidebarThreads.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.preview.localizedCaseInsensitiveContains(query)
                || $0.cwd.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredCodexThreads: [DesktopThread] {
        guard showCodexThreads else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, let searchedThreads {
            return searchedThreads
        }
        let base = isBrowsingArchivedThreads ? archivedCodexThreads : codexThreads
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.preview.localizedCaseInsensitiveContains(query)
                || $0.cwd.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedThread: DesktopThread? {
        guard let selectedThreadID else { return nil }
        return findThread(selectedThreadID)
    }

    var sidebarThreads: [DesktopThread] {
        isBrowsingArchivedThreads ? archivedThreads : threads
    }

    private var allKnownThreads: [DesktopThread] {
        threads + archivedThreads + codexThreads + archivedCodexThreads + (searchedThreads ?? [])
    }

    private func findThread(_ id: String) -> DesktopThread? {
        allKnownThreads.first(where: { $0.id == id })
    }

    private static func workspaceExists(for thread: DesktopThread) -> Bool {
        workspaceExists(atPath: thread.cwd)
    }

    private static func workspaceExists(atPath path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func threadsWithExistingWorkspaces(_ candidates: [DesktopThread]) -> [DesktopThread] {
        var existenceByPath: [String: Bool] = [:]
        return candidates.filter { thread in
            if let exists = existenceByPath[thread.cwd] { return exists }
            let exists = workspaceExists(for: thread)
            existenceByPath[thread.cwd] = exists
            return exists
        }
    }

    private func clearMissingSelectionIfNeeded(origin: DesktopThreadOrigin) {
        guard let selectedThreadID,
              DesktopThreadSelection.parse(selectedThreadID).origin == origin else { return }
        if let thread = findThread(selectedThreadID), Self.workspaceExists(for: thread) {
            return
        }
        beginNewChat()
    }

    private func clearMissingWorkspaceIfNeeded() {
        guard let workspaceURL,
              !Self.workspaceExists(atPath: workspaceURL.path) else { return }
        self.workspaceURL = nil
        defaults.removeObject(forKey: "VeoDesktop.workspacePath")
    }

    private func discardThreadFromLoadedCatalog(_ threadID: String) {
        if selectedThreadID == threadID {
            beginNewChat()
        }
        threads.removeAll(where: { $0.id == threadID })
        archivedThreads.removeAll(where: { $0.id == threadID })
        codexThreads.removeAll(where: { $0.id == threadID })
        archivedCodexThreads.removeAll(where: { $0.id == threadID })
        searchedThreads?.removeAll(where: { $0.id == threadID })
        searchSnippetByThreadID.removeValue(forKey: threadID)
        rebuildCodexMappings()
    }

    private func uiThreadID(forRuntimeThreadID runtimeID: String) -> String {
        if let veoID = veoIDByCodexThreadID[runtimeID] {
            return veoID
        }
        return DesktopThreadSelection.codex(runtimeID).storageKey
    }

    private func runtimeThreadID(forUIThreadID uiID: String) -> String? {
        findThread(uiID)?.runtimeThreadID
    }

    private func runtimeThreadID(for thread: DesktopThread) -> String? {
        thread.runtimeThreadID
    }

    private func rebuildCodexMappings() {
        var forward: [String: String] = [:]
        var reverse: [String: String] = [:]
        for thread in threads + archivedThreads where thread.origin == .veo {
            if let codexID = thread.codexThreadId, !codexID.isEmpty {
                forward[codexID] = thread.id
                reverse[thread.id] = codexID
            }
        }
        veoIDByCodexThreadID = forward
        codexThreadIDByVeoID = reverse
    }

    private func persistVeoThread(_ thread: DesktopThread, isArchived: Bool = false) {
        guard thread.origin == .veo else { return }
        Task {
            do {
                try await threadStore.upsertThread(thread, isArchived: isArchived)
            } catch {
                await MainActor.run {
                    transientError = "Could not save chat: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadVeoThreadsFromStore(archived: Bool? = nil) async {
        do {
            let storedActive = try await threadStore.listThreads(archived: false)
            let storedArchived = try await threadStore.listThreads(archived: true)
            let storedThreads = storedActive + storedArchived
            var unavailableTemporaryThreadIDs = Set<String>()
            var temporaryRestoreError: Error?
            for thread in storedThreads where thread.workspaceKind.isAppManaged {
                do {
                    try temporaryWorkspaceService.ensureWorkspace(for: thread)
                } catch {
                    unavailableTemporaryThreadIDs.insert(thread.id)
                    temporaryRestoreError = error
                }
            }
            try? temporaryWorkspaceService.removeOrphanedWorkspaces(
                keeping: Set(storedThreads.filter {
                    $0.workspaceKind.isAppManaged && !unavailableTemporaryThreadIDs.contains($0.id)
                }.map(\.cwd))
            )
            let active = Self.threadsWithExistingWorkspaces(
                storedActive.filter { !unavailableTemporaryThreadIDs.contains($0.id) }
            )
            let archivedRows = Self.threadsWithExistingWorkspaces(
                storedArchived.filter { !unavailableTemporaryThreadIDs.contains($0.id) }
            )
            threads = active.sorted { $0.updatedAt > $1.updatedAt }
            archivedThreads = archivedRows.sorted { $0.updatedAt > $1.updatedAt }
            rebuildCodexMappings()
            clearMissingSelectionIfNeeded(origin: .veo)
            clearMissingWorkspaceIfNeeded()
            if let temporaryRestoreError {
                transientError = "A temporary chat workspace could not be restored: \(temporaryRestoreError.localizedDescription)"
            }
            if let archived, archived != isBrowsingArchivedThreads {
                return
            }
        } catch {
            transientError = "Could not load Veo chats: \(error.localizedDescription)"
        }
    }

    func setShowCodexThreads(_ enabled: Bool) {
        guard showCodexThreads != enabled else { return }
        showCodexThreads = enabled
        defaults.set(enabled, forKey: "VeoDesktop.showCodexThreads")
        codexThreadsLoadGeneration += 1
        let generation = codexThreadsLoadGeneration
        if enabled {
            // Only show the loading bar when turning the option on from off —
            // not when the preference was already restored on launch.
            isLoadingCodexThreads = true
            guard runtimeState.isReady else { return }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchTerm = query.isEmpty ? nil : query
            Task {
                await loadThreads(archived: isBrowsingArchivedThreads, searchTerm: searchTerm)
                finishCodexThreadsLoading(generation: generation)
            }
        } else {
            isLoadingCodexThreads = false
            codexThreads = []
            archivedCodexThreads = []
            searchedThreads = nil
            searchSnippetByThreadID = [:]
            if let selectedThreadID,
               DesktopThreadSelection.parse(selectedThreadID).origin == .codex {
                beginNewChat()
            }
        }
    }

    private func finishCodexThreadsLoading(generation: Int) {
        guard generation == codexThreadsLoadGeneration else { return }
        isLoadingCodexThreads = false
    }

    var selectedModel: DesktopModelOption? {
        models.first(where: { $0.id == selectedModelID })
    }

    var modelDisplayName: String {
        selectedModel?.displayName ?? "Auto"
    }

    var utilityModelSelectionID: String {
        resolvedUtilityModel?.id
            ?? defaults.string(forKey: DesktopUtilityModelPreferences.modelIDKey)
            ?? DesktopUtilityModelPreferences.defaultModelName
    }

    var utilityModelDisplayName: String {
        resolvedUtilityModel?.displayName ?? "GPT-5.6 Luna"
    }

    var utilityModelOptions: [DesktopModelOption] {
        models.filter { model in
            model.supportedReasoningEfforts.contains(where: {
                $0.id.caseInsensitiveCompare(DesktopUtilityModelPreferences.reasoningEffort) == .orderedSame
            })
        }
    }

    func setUtilityModel(_ modelID: String) {
        guard utilityModelOptions.contains(where: { $0.id == modelID }) else { return }
        defaults.set(modelID, forKey: DesktopUtilityModelPreferences.modelIDKey)
        utilityModelPreferenceRevision += 1
        threadMinimapAnalysisTask?.cancel()
        threadMinimapAnalysisTask = nil
        threadMinimapAnalysisKey = nil
        threadMinimapTopicStartIDs = nil
        autoTitleTasksByThreadID.values.forEach { $0.cancel() }
        autoTitleTasksByThreadID = [:]
        refreshSelectedVeoThreadMetadata()
    }

    private var resolvedUtilityModel: DesktopModelOption? {
        if let savedID = defaults.string(forKey: DesktopUtilityModelPreferences.modelIDKey),
           let saved = utilityModelOptions.first(where: { $0.id == savedID }) {
            return saved
        }
        let canonical = DesktopUtilityModelPreferences.defaultModelName
        return utilityModelOptions.first(where: {
            [$0.id, $0.model, $0.displayName]
                .map(Self.normalizedModelName)
                .contains(canonical)
        }) ?? utilityModelOptions.first(where: {
            [$0.id, $0.model, $0.displayName]
                .map(Self.normalizedModelName)
                .contains(where: { $0.contains(canonical) })
        })
    }

    private static func normalizedModelName(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    var reasoningDisplayName: String {
        guard let selectedReasoningEffort else { return "Default" }
        return selectedModel?.supportedReasoningEfforts
            .first(where: { $0.id == selectedReasoningEffort })?.title
            ?? DesktopReasoningOption(id: selectedReasoningEffort, description: "").title
    }

    var effectiveWorkspaceURL: URL {
        if let selectedThread {
            return URL(fileURLWithPath: selectedThread.cwd, isDirectory: true)
        }
        return workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser
    }

    var hasExplicitWorkspace: Bool {
        selectedThread != nil || workspaceURL != nil
    }

    var currentWorkspaceKind: DesktopWorkspaceKind? {
        if let selectedThread { return selectedThread.workspaceKind }
        return workspaceURL == nil ? nil : .project
    }

    var isProjectlessWorkspace: Bool {
        currentWorkspaceKind?.isAppManaged == true
    }

    var canToggleTemporaryChat: Bool {
        guard let thread = selectedThread else { return false }
        return thread.origin == .veo
            && thread.workspaceKind.isAppManaged
            && thread.runtimeThreadID == nil
            && !isBusyTurn
    }

    var isTemporaryChat: Bool {
        selectedThread?.workspaceKind == .temporary
    }

    var canUseProjectChanges: Bool {
        currentWorkspaceKind == .project || gitRepository != nil || selectedTurnDiff?.isEmpty == false
    }

    var canSend: Bool {
        guard runtimeState.isReady,
              (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty),
              hasExplicitWorkspace else { return false }
        if selectedThreadID != nil, !selectedThreadAcceptsDirectInput { return false }
        guard isBusyTurn else { return true }
        guard selectedThreadID != nil else { return false }
        return followUpBehavior == .queue || capabilities.supports(.turnSteering)
    }

    var isBusyTurn: Bool {
        isSubmittingTurn || isRunningTurn
    }

    private var selectedThreadAcceptsDirectInput: Bool {
        guard !isLoadingTimeline, let selectedThread else { return false }
        if selectedThread.isSubagent {
            return selectedThread.canAcceptDirectInput == true
        }
        return selectedThread.canAcceptDirectInput != false
    }

    var selectedQueuedDrafts: [DesktopComposerPayload] {
        // Hide drafts already being delivered so ordinary sends don't flash "Queued".
        (queuedDraftsByThreadID[currentQueueContextID] ?? [])
            .filter { !queuedDeliveryInFlightIDs.contains($0.id) }
    }

    var selectedTokenUsage: DesktopTokenUsage? {
        guard let selectedThreadID else { return nil }
        return tokenUsageByThreadID[selectedThreadID]
    }

    var isSelectedThreadCompacting: Bool {
        guard let selectedThreadID else { return false }
        return compactingThreadIDs.contains(selectedThreadID)
    }

    var selectedTurnDiff: DesktopTurnDiff? {
        guard let selectedThreadID else { return nil }
        return turnDiffByThreadID[selectedThreadID]
    }

    var selectedSearchOccurrences: [DesktopThreadSearchOccurrence] {
        guard let selectedThreadID else { return [] }
        return searchOccurrencesByThreadID[selectedThreadID] ?? []
    }

    func agentState(for threadID: String) -> DesktopAgentState? {
        agentStateByThreadID[threadID]
    }

    /// True while this chat has an in-flight or active turn (selected busy state, tracked turn, or running status).
    func isThreadTurnActive(_ threadID: String) -> Bool {
        if selectedThreadID == threadID, isBusyTurn { return true }
        if activeTurnIDByThread[threadID] != nil { return true }
        if findThread(threadID)?.isRunning == true { return true }
        return agentStateByThreadID[threadID]?.isActive == true
    }

    var canSearchMessageContent: Bool {
        capabilities.supports(.threadSearch) && capabilities.supports(.threadContentSearch)
    }

    func searchSnippet(for threadID: String) -> String? {
        guard searchesMessageContent else { return nil }
        return searchSnippetByThreadID[threadID]
    }

    func pendingRequestCount(for threadID: String) -> Int {
        pendingRequestCountsByThreadID[threadID] ?? 0
    }

    func attachNotifications(_ service: DesktopNotificationService) {
        notifications = service
    }

    /// Announces background work. The originating chat is "foreground" only when it
    /// is the selected one, so alerts stay quiet for what the user is watching.
    private func notify(_ alert: DesktopNotificationService.Alert, threadID: String?) {
        notifications?.post(alert, isForegroundThread: threadID == selectedThreadID)
    }

    private func threadTitle(_ threadID: String?) -> String {
        threadID.flatMap { findThread($0)?.title } ?? "Veo"
    }

    /// Both the selected-thread and background event paths funnel here so a
    /// completed turn is announced exactly once, wherever it was observed.
    private func announceTurnCompletion(turn: [String: Any]?, threadID: String?) {
        let title = threadTitle(threadID)
        if let turnError = turn?["error"] as? [String: Any],
           let message = turnError.string("message") {
            notify(.turnFailed(threadTitle: title, message: message), threadID: threadID)
        } else {
            notify(.turnCompleted(threadTitle: title), threadID: threadID)
        }
    }

    func contextDescription(for request: DesktopPendingRequest) -> String? {
        guard let threadID = request.threadID else { return nil }
        let uiID = uiThreadID(forRuntimeThreadID: threadID)
        guard let thread = findThread(uiID) ?? findThread(threadID) else {
            return "Chat \(DesktopThreadSelection.parse(threadID).bareID.prefix(8))"
        }
        return "\(thread.title) · \(thread.workspaceName)"
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        scheduleConnection()
    }

    func reconnect() {
        guard !isBusyTurn else { return }
        scheduleConnection()
    }

    func refreshAccountResources() {
        guard runtimeState.isReady, !isLoadingAccountResources else { return }
        Task { await loadAccountResources() }
    }

    func refreshAccountOverview() {
        guard runtimeState.isReady, !isLoadingAccountOverview else { return }
        Task { await loadAccountOverview() }
    }

    func refreshRuntimeConfiguration() {
        guard runtimeState.isReady, !isLoadingRuntimeConfiguration else { return }
        Task { await loadRuntimeConfiguration() }
    }

    func unloadInactiveRuntimeThreads() {
        guard runtimeState.isReady,
              capabilities.supports(.threadSubscriptions),
              integrationMutationID == nil else { return }
        integrationMutationID = "thread-unload"
        Task {
            defer { integrationMutationID = nil }
            do {
                var loadedRuntimeIDs: [String] = []
                var cursor: String?
                var seenCursors = Set<String>()
                repeat {
                    var params: [String: Any] = ["limit": 100]
                    if let cursor { params["cursor"] = cursor }
                    let response = try await client.request(
                        method: "thread/loaded/list",
                        params: params,
                        requiring: .threadSubscriptions
                    )
                    loadedRuntimeIDs.append(contentsOf: response.stringArray("data"))
                    let next = response.string("nextCursor")
                    cursor = next?.isEmpty == false ? next : nil
                    if let cursor, !seenCursors.insert(cursor).inserted {
                        throw CodexAppServerClientError.malformedResponse("thread/loaded/list pagination")
                    }
                } while cursor != nil

                var protectedRuntimeIDs = Set<String>()
                if let selectedThreadID,
                   let selectedRuntimeID = runtimeThreadID(forUIThreadID: selectedThreadID) {
                    protectedRuntimeIDs.insert(selectedRuntimeID)
                }
                for (uiThreadID, _) in activeTurnIDByThread {
                    if let runtimeID = runtimeThreadID(forUIThreadID: uiThreadID) {
                        protectedRuntimeIDs.insert(runtimeID)
                    }
                }

                let inactiveRuntimeIDs = Set(loadedRuntimeIDs).subtracting(protectedRuntimeIDs)
                for runtimeID in inactiveRuntimeIDs {
                    _ = try await client.request(
                        method: "thread/unsubscribe",
                        params: ["threadId": runtimeID],
                        requiring: .threadSubscriptions
                    )
                }
                recordRuntimeNotice(
                    method: "thread/unsubscribe",
                    severity: .info,
                    title: "Inactive runtimes unloaded",
                    detail: inactiveRuntimeIDs.isEmpty
                        ? "No inactive Codex sessions were loaded."
                        : "Released \(inactiveRuntimeIDs.count) inactive Codex session\(inactiveRuntimeIDs.count == 1 ? "" : "s") from memory."
                )
            } catch {
                transientError = "Inactive runtimes could not be unloaded: \(error.localizedDescription)"
            }
        }
    }

    func isAccessModeAllowed(_ mode: DesktopAccessMode) -> Bool {
        guard !managedRequirements.allowedSandboxModes.isEmpty else { return true }
        let accepted: Set<String>
        switch mode {
        case .readOnly: accepted = ["readOnly", "read-only"]
        case .workspace: accepted = ["workspaceWrite", "workspace-write"]
        case .fullAccess: accepted = ["dangerFullAccess", "danger-full-access"]
        }
        return !accepted.isDisjoint(with: Set(managedRequirements.allowedSandboxModes))
    }

    func setExperimentalFeature(_ feature: DesktopExperimentalFeature, enabled: Bool) {
        guard capabilities.supports(.experimentalFeatures), integrationMutationID == nil else { return }
        integrationMutationID = "feature:\(feature.id)"
        Task {
            defer { integrationMutationID = nil }
            do {
                _ = try await client.request(
                    method: "experimentalFeature/enablement/set",
                    params: ["enablement": [feature.id: enabled]],
                    requiring: .experimentalFeatures
                )
                await loadRuntimeConfiguration()
            } catch {
                transientError = "Feature could not be updated: \(error.localizedDescription)"
            }
        }
    }

    func setRealtimeVoiceEnabled(_ enabled: Bool) {
        realtimeVoiceEnabled = enabled
        if enabled {
            Task { await loadRealtimeVoices() }
        } else if realtimeSession != nil {
            stopRealtimeVoice()
        }
    }

    func selectRealtimeVoice(_ id: String) {
        guard realtimeVoices.contains(where: { $0.id == id }) else { return }
        selectedRealtimeVoiceID = id
        defaults.set(id, forKey: "VeoDesktop.realtimeVoice")
    }

    var isRealtimeVoiceActive: Bool {
        guard let session = realtimeSession else { return false }
        switch session.connectionState {
        case .starting, .active, .stopping: return true
        case .closed, .failed: return false
        }
    }

    func startRealtimeVoice() {
        guard realtimeVoiceEnabled,
              capabilities.supports(.realtimeVoice),
              let threadID = selectedThreadID,
              let runtimeID = runtimeThreadID(forUIThreadID: threadID),
              selectedThreadAcceptsDirectInput,
              !isRealtimeVoiceActive else { return }

        let voice = selectedRealtimeVoiceID ?? realtimeVoices.first?.id
        realtimeTranscript = ""
        let generation = UUID()
        realtimeAudioGeneration = generation
        realtimeSession = .starting(
            threadID: threadID,
            outputModality: "audio",
            voice: voice
        )

        realtimeStartTask = Task {
            defer {
                if realtimeAudioGeneration == generation {
                    realtimeStartTask = nil
                }
            }
            guard await realtimeAudio.requestMicrophonePermission() else {
                guard !Task.isCancelled,
                      realtimeAudioGeneration == generation,
                      realtimeVoiceEnabled,
                      selectedThreadID == threadID,
                      var session = realtimeSession,
                      session.threadID == threadID else { return }
                if session.threadID == threadID {
                    session.connectionState = .failed("Microphone access was not granted.")
                    realtimeSession = session
                }
                transientError = "Microphone access is required for realtime voice."
                return
            }

            guard !Task.isCancelled,
                  realtimeAudioGeneration == generation,
                  realtimeVoiceEnabled,
                  selectedThreadID == threadID,
                  realtimeSession?.threadID == threadID else { return }

            do {
                var params: [String: Any] = [
                    "threadId": runtimeID,
                    "outputModality": "audio",
                    "version": "v2",
                    "includeStartupContext": true,
                    "transport": ["type": "websocket"],
                ]
                if let voice { params["voice"] = voice }
                _ = try await client.request(
                    method: "thread/realtime/start",
                    params: params,
                    requiring: .realtimeVoice
                )
                // A stop waits for this start task before sending its server stop,
                // so a stop can never race ahead of an in-flight server start.
                guard !Task.isCancelled,
                      realtimeAudioGeneration == generation,
                      realtimeVoiceEnabled,
                      selectedThreadID == threadID,
                      realtimeSession?.threadID == threadID else { return }
                guard await realtimeAudio.startCapture() else {
                    if realtimeAudioGeneration == generation {
                        _ = try? await client.request(
                            method: "thread/realtime/stop",
                            params: ["threadId": runtimeID],
                            requiring: .realtimeVoice
                        )
                    }
                    return
                }
                guard !Task.isCancelled,
                      realtimeAudioGeneration == generation,
                      realtimeVoiceEnabled,
                      selectedThreadID == threadID,
                      realtimeSession?.threadID == threadID else {
                    realtimeAudio.stopCapture()
                    return
                }
            } catch {
                guard !Task.isCancelled,
                      realtimeAudioGeneration == generation,
                      realtimeSession?.threadID == threadID else { return }
                capabilities = client.capabilities
                realtimeAudio.stop()
                if var session = realtimeSession, session.threadID == threadID {
                    session.connectionState = .failed(error.localizedDescription)
                    realtimeSession = session
                }
                transientError = "Realtime voice could not start: \(error.localizedDescription)"
            }
        }
    }

    func stopRealtimeVoice(preservingError: String? = nil) {
        if let preservingError { transientError = preservingError }
        guard let session = realtimeSession else {
            realtimeAudioGeneration = UUID()
            realtimeStartTask?.cancel()
            realtimeStartTask = nil
            realtimeAudio.stop()
            realtimeTranscript = ""
            return
        }
        let threadID = session.threadID
        let pendingStartTask = realtimeStartTask
        let stopGeneration = UUID()
        var stopping = session
        stopping.connectionState = .stopping
        realtimeSession = stopping
        pendingRealtimeAudioChunks = []
        realtimeAudioGeneration = stopGeneration
        realtimeAudio.stop()
        Task {
            // If start is already inside the RPC, wait for it to finish before
            // issuing stop. This preserves server ordering and prevents an
            // abandoned realtime session after a quick disable/thread switch.
            await pendingStartTask?.value
            guard realtimeAudioGeneration == stopGeneration else { return }
            realtimeStartTask = nil
            if let runtimeID = runtimeThreadID(forUIThreadID: threadID) {
                do {
                    _ = try await client.request(
                        method: "thread/realtime/stop",
                        params: ["threadId": runtimeID],
                        requiring: .realtimeVoice
                    )
                } catch {
                    capabilities = client.capabilities
                    if preservingError == nil {
                        transientError = "Realtime voice could not stop cleanly: \(error.localizedDescription)"
                    }
                }
            }
            if realtimeAudioGeneration == stopGeneration,
               realtimeSession?.threadID == threadID {
                realtimeSession = nil
                realtimeTranscript = ""
            }
            if let preservingError { transientError = preservingError }
        }
    }

    private func enqueueRealtimeAudio(_ chunk: RealtimeAudioCoordinator.PCMChunk) {
        guard isRealtimeVoiceActive else { return }
        if pendingRealtimeAudioChunks.count >= 8 {
            pendingRealtimeAudioChunks.removeFirst()
        }
        pendingRealtimeAudioChunks.append(chunk)
        drainRealtimeAudioQueue()
    }

    private func drainRealtimeAudioQueue() {
        guard !isSendingRealtimeAudio,
              isRealtimeVoiceActive,
              let threadID = realtimeSession?.threadID,
              let runtimeID = runtimeThreadID(forUIThreadID: threadID) else { return }
        let generation = realtimeAudioGeneration
        isSendingRealtimeAudio = true
        Task {
            defer {
                isSendingRealtimeAudio = false
                if generation == realtimeAudioGeneration,
                   !pendingRealtimeAudioChunks.isEmpty {
                    drainRealtimeAudioQueue()
                }
            }
            while isRealtimeVoiceActive,
                  generation == realtimeAudioGeneration,
                  realtimeSession?.threadID == threadID,
                  !pendingRealtimeAudioChunks.isEmpty {
                let chunk = pendingRealtimeAudioChunks.removeFirst()
                do {
                    _ = try await client.request(
                        method: "thread/realtime/appendAudio",
                        params: [
                            "threadId": runtimeID,
                            "audio": [
                                "data": chunk.data,
                                "sampleRate": chunk.sampleRate,
                                "numChannels": chunk.numChannels,
                                "samplesPerChannel": chunk.samplesPerChannel,
                            ],
                        ],
                        requiring: .realtimeVoice
                    )
                } catch {
                    guard generation == realtimeAudioGeneration else { break }
                    capabilities = client.capabilities
                    let message = "Realtime microphone audio stopped: \(error.localizedDescription)"
                    stopRealtimeVoice(preservingError: message)
                    break
                }
            }
        }
    }

    func refreshGitRepository() {
        guard hasExplicitWorkspace else {
            gitRefreshRequested = false
            gitRepository = nil
            gitReviewSnapshot = nil
            gitMessage = "Open a project inside a Git repository."
            return
        }
        guard !isRefreshingGit, !isMutatingGit else {
            gitRefreshRequested = true
            return
        }
        guard let workspace = currentCanonicalGitWorkspaceURL else {
            gitRefreshRequested = false
            gitRepository = nil
            gitReviewSnapshot = nil
            gitMessage = "Open a project inside a Git repository."
            return
        }
        let generation = gitContextGeneration
        gitRefreshRequested = false
        isRefreshingGit = true
        Task {
            defer {
                isRefreshingGit = false
                if gitRefreshRequested { refreshGitRepository() }
            }
            do {
                let snapshot = try await gitService.repositorySnapshot(for: workspace)
                guard gitContextGeneration == generation,
                      currentCanonicalGitWorkspaceURL?.path == workspace.path else {
                    gitRefreshRequested = true
                    return
                }
                gitRepository = snapshot
                gitMessage = snapshot.mutationBlocker
                await refreshGitReviewSnapshot(for: snapshot, generation: generation)
            } catch {
                guard gitContextGeneration == generation,
                      currentCanonicalGitWorkspaceURL?.path == workspace.path else {
                    gitRefreshRequested = true
                    return
                }
                gitRepository = nil
                gitReviewSnapshot = nil
                gitMessage = error.localizedDescription
            }
        }
    }

    private func refreshGitReviewSnapshot(
        for snapshot: DesktopGitRepositorySnapshot,
        generation: UUID
    ) async {
        isRefreshingGitReview = true
        defer { isRefreshingGitReview = false }
        do {
            let review = try await gitService.reviewSnapshot(for: snapshot)
            guard generation == gitContextGeneration,
                  gitRepository?.id == snapshot.id else { return }
            gitReviewSnapshot = review
        } catch {
            guard generation == gitContextGeneration else { return }
            gitReviewSnapshot = nil
            if gitMessage == nil { gitMessage = error.localizedDescription }
        }
    }

    private var currentCanonicalGitWorkspaceURL: URL? {
        guard hasExplicitWorkspace else { return nil }
        return effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func gitSnapshotMatchesCurrentContext(_ snapshot: DesktopGitRepositorySnapshot) -> Bool {
        currentCanonicalGitWorkspaceURL?.path == snapshot.workspacePath
    }

    private func invalidateGitContext() {
        let shouldRefresh = gitRepository != nil || isRefreshingGit || isMutatingGit
        gitContextGeneration = UUID()
        gitRepository = nil
        gitReviewSnapshot = nil
        gitMessage = nil
        gitRefreshRequested = gitRefreshRequested || shouldRefresh
    }

    private func refreshInvalidatedGitContextIfNeeded() {
        guard gitRefreshRequested else { return }
        refreshGitRepository()
    }

    func stageGitFiles(_ fileIDs: [DesktopGitFileID]) {
        guard let snapshot = gitRepository,
              gitSnapshotMatchesCurrentContext(snapshot),
              !fileIDs.isEmpty else { return }
        performGitMutation(snapshot: snapshot) {
            let result = try await self.gitService.stage(fileIDs, in: snapshot)
            return (result.repository, nil)
        }
    }

    func applyGitHunk(_ selection: DesktopGitHunkSelection) {
        guard let snapshot = gitRepository,
              gitSnapshotMatchesCurrentContext(snapshot) else { return }
        performGitMutation(snapshot: snapshot) {
            let result = try await self.gitService.applyHunk(selection, in: snapshot)
            return (
                result.repository,
                selection.fileDiffID.side == .staged ? "Hunk unstaged." : "Hunk staged."
            )
        }
    }

    func unstageGitFiles(_ fileIDs: [DesktopGitFileID]) {
        guard let snapshot = gitRepository,
              gitSnapshotMatchesCurrentContext(snapshot),
              !fileIDs.isEmpty else { return }
        performGitMutation(snapshot: snapshot) {
            let result = try await self.gitService.unstage(fileIDs, in: snapshot)
            return (result.repository, nil)
        }
    }

    func discardGitFile(_ fileID: DesktopGitFileID, mode: DesktopGitDiscardMode) {
        guard let snapshot = gitRepository,
              gitSnapshotMatchesCurrentContext(snapshot) else { return }
        performGitMutation(snapshot: snapshot) {
            let result = try await self.gitService.discard([fileID], mode: mode, in: snapshot)
            return (
                result.repository,
                result.recovery.map { "Recovery saved at \($0.bundlePath)" }
            )
        }
    }

    func commitGitFiles(message: String, fileIDs: [DesktopGitFileID]) {
        guard let snapshot = gitRepository,
              gitSnapshotMatchesCurrentContext(snapshot),
              !fileIDs.isEmpty else { return }
        performGitMutation(snapshot: snapshot) {
            let result = try await self.gitService.commit(
                message: message,
                fileIDs: fileIDs,
                in: snapshot
            )
            return (result.repository, "Created commit \(result.commitObjectID.prefix(12))")
        }
    }

    func createGitBranch(named name: String) {
        guard let snapshot = gitRepository,
              gitSnapshotMatchesCurrentContext(snapshot) else { return }
        performGitMutation(snapshot: snapshot) {
            let result = try await self.gitService.createAndSwitchBranch(named: name, in: snapshot)
            return (result.repository, "Switched to \(result.branchName)")
        }
    }

    private func performGitMutation(
        snapshot: DesktopGitRepositorySnapshot,
        _ operation: @escaping @MainActor () async throws -> (
            repository: DesktopGitRepositorySnapshot,
            message: String?
        )
    ) {
        guard gitSnapshotMatchesCurrentContext(snapshot),
              !isMutatingGit,
              !isRefreshingGit else { return }
        let generation = gitContextGeneration
        let workspacePath = snapshot.workspacePath
        isMutatingGit = true
        gitMessage = nil
        Task {
            defer {
                isMutatingGit = false
                if generation != gitContextGeneration
                    || currentCanonicalGitWorkspaceURL?.path != workspacePath {
                    gitRefreshRequested = true
                }
                if gitRefreshRequested { refreshGitRepository() }
            }
            do {
                let result = try await operation()
                guard generation == gitContextGeneration,
                      currentCanonicalGitWorkspaceURL?.path == workspacePath else {
                    gitRefreshRequested = true
                    return
                }
                gitRepository = result.repository
                gitMessage = result.message ?? "Repository updated safely."
                await refreshGitReviewSnapshot(for: result.repository, generation: generation)
            } catch {
                guard generation == gitContextGeneration,
                      currentCanonicalGitWorkspaceURL?.path == workspacePath else {
                    gitRefreshRequested = true
                    return
                }
                gitMessage = error.localizedDescription
                if case DesktopGitError.staleSnapshot = error {
                    refreshGitRepository()
                }
            }
        }
    }

    func startChatGPTLogin() {
        guard capabilities.supports(.accountLogin), integrationMutationID == nil else { return }
        integrationMutationID = "account-login"
        Task {
            defer { integrationMutationID = nil }
            do {
                let session = try await startChatGPTBrowserLogin()
                accountLoginSession = session
                if let url = session.authorizationURL {
                    presentAccountLoginURL(url)
                }
            } catch {
                transientError = "Sign in could not start: \(error.localizedDescription)"
            }
        }
    }

    func startChatGPTDeviceCodeLogin() {
        guard capabilities.supports(.accountLogin), integrationMutationID == nil else { return }
        integrationMutationID = "account-login"
        Task {
            defer { integrationMutationID = nil }
            do {
                let response = try await client.request(
                    method: "account/login/start",
                    params: ["type": "chatgptDeviceCode"],
                    requiring: .accountLogin
                )
                guard let session = DesktopAccountLoginSession.parse(response) else {
                    throw CodexAppServerClientError.malformedResponse("account/login/start")
                }
                accountLoginSession = session
                if let url = session.authorizationURL {
                    presentAccountLoginURL(url)
                }
            } catch {
                transientError = "Device sign in could not start: \(error.localizedDescription)"
            }
        }
    }

    private func startChatGPTBrowserLogin() async throws -> DesktopAccountLoginSession {
        try await startAccountLogin(params: [
            "type": "chatgpt",
            "codexStreamlinedLogin": true,
        ])
    }

    private func startAccountLogin(params: [String: Any]) async throws -> DesktopAccountLoginSession {
        let response = try await client.request(
            method: "account/login/start",
            params: params,
            requiring: .accountLogin
        )
        guard let session = DesktopAccountLoginSession.parse(response) else {
            throw CodexAppServerClientError.malformedResponse("account/login/start")
        }
        return session
    }

    private func presentAccountLoginURL(_ url: URL, accountLogin: Bool = true) {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let isLoopbackHTTP = scheme == "http" && ["127.0.0.1", "localhost", "[::1]"].contains(host)
        guard scheme == "https" || isLoopbackHTTP else {
            transientError = "Sign in returned an address Veo could not open securely."
            return
        }
        if let openInEmbeddedBrowser {
            openInEmbeddedBrowser(url, accountLogin)
        } else {
            pendingEmbeddedBrowserURL = url
            pendingEmbeddedBrowserIsAccountLogin = accountLogin
        }
    }

    func takePendingEmbeddedBrowserURL() -> (url: URL, accountLogin: Bool)? {
        guard let url = pendingEmbeddedBrowserURL else { return nil }
        let accountLogin = pendingEmbeddedBrowserIsAccountLogin
        pendingEmbeddedBrowserURL = nil
        pendingEmbeddedBrowserIsAccountLogin = false
        return (url, accountLogin)
    }

    func consumeRateLimitResetCredit() {
        guard availableRateLimitResetCredits > 0,
              capabilities.supports(method: "account/rateLimitResetCredit/consume"),
              integrationMutationID == nil else { return }
        integrationMutationID = "rate-limit-reset"
        Task {
            defer { integrationMutationID = nil }
            do {
                var params: [String: Any] = ["idempotencyKey": UUID().uuidString]
                if let availableRateLimitResetCreditID { params["creditId"] = availableRateLimitResetCreditID }
                _ = try await client.request(method: "account/rateLimitResetCredit/consume", params: params)
                await loadAccountResources()
            } catch {
                transientError = "Rate-limit reset could not be used: \(error.localizedDescription)"
            }
        }
    }

    func sendCreditsNudgeEmail(usageLimit: Bool = false) {
        guard capabilities.supports(method: "account/sendAddCreditsNudgeEmail"),
              integrationMutationID == nil else { return }
        integrationMutationID = "credits-nudge"
        Task {
            defer { integrationMutationID = nil }
            do {
                _ = try await client.request(
                    method: "account/sendAddCreditsNudgeEmail",
                    params: ["creditType": usageLimit ? "usage_limit" : "credits"]
                )
                recordRuntimeNotice(
                    method: "account/sendAddCreditsNudgeEmail",
                    severity: .info,
                    title: "Workspace owner notified",
                    detail: "Codex asked the workspace owner to review available credits."
                )
            } catch {
                transientError = "Workspace owner could not be notified: \(error.localizedDescription)"
            }
        }
    }

    /// The key is intentionally kept only in the caller's transient SwiftUI state and
    /// this request dictionary. It is never assigned to store state or UserDefaults.
    func loginWithAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              capabilities.supports(method: "account/login/start"),
              integrationMutationID == nil else { return }
        integrationMutationID = "account-login"
        Task {
            defer { integrationMutationID = nil }
            do {
                _ = try await client.request(
                    method: "account/login/start",
                    params: ["type": "apiKey", "apiKey": trimmed]
                )
                accountLoginSession = nil
                await loadAccountResources()
            } catch {
                transientError = "API key sign in failed. Veo did not save the key; verify it and try again."
            }
        }
    }

    func cancelAccountLogin() {
        guard let session = accountLoginSession,
              capabilities.supports(method: "account/login/cancel"),
              integrationMutationID == nil else { return }
        integrationMutationID = "account-login"
        Task {
            defer { integrationMutationID = nil }
            do {
                _ = try await client.request(
                    method: "account/login/cancel",
                    params: ["loginId": session.id]
                )
                accountLoginSession = nil
            } catch {
                transientError = "Sign in could not be canceled: \(error.localizedDescription)"
            }
        }
    }

    func logoutAccount() {
        guard capabilities.supports(.accountLogout), integrationMutationID == nil else { return }
        integrationMutationID = "account-logout"
        Task {
            defer { integrationMutationID = nil }
            do {
                _ = try await client.request(method: "account/logout", requiring: .accountLogout)
                accountLoginSession = nil
                await loadAccountResources()
            } catch {
                transientError = "Sign out failed: \(error.localizedDescription)"
            }
        }
    }

    func setSkillEnabled(_ skill: DesktopSkillRecord, enabled: Bool) {
        guard capabilities.supports(method: "skills/config/write"),
              integrationMutationID == nil else { return }
        integrationMutationID = skill.id
        Task {
            defer { integrationMutationID = nil }
            do {
                var params: [String: Any] = ["enabled": enabled, "name": skill.name]
                if let path = skill.path { params["path"] = path }
                _ = try await client.request(method: "skills/config/write", params: params)
                await loadSkills()
                await loadAccountResources()
            } catch {
                transientError = "Skill could not be \(enabled ? "enabled" : "disabled"): \(error.localizedDescription)"
            }
        }
    }

    func installPlugin(_ plugin: DesktopPluginRecord) {
        guard plugin.canInstall,
              capabilities.supports(method: "plugin/install"),
              integrationMutationID == nil else { return }
        integrationMutationID = plugin.id
        Task {
            defer { integrationMutationID = nil }
            do {
                _ = try await client.request(method: "plugin/install", params: plugin.selector.requestParams)
                await loadAccountResources()
            } catch {
                transientError = "Plugin could not be installed: \(error.localizedDescription)"
            }
        }
    }

    func uninstallPlugin(_ plugin: DesktopPluginRecord) {
        guard capabilities.supports(method: "plugin/uninstall"), integrationMutationID == nil else { return }
        integrationMutationID = plugin.id
        Task {
            defer { integrationMutationID = nil }
            do {
                _ = try await client.request(
                    method: "plugin/uninstall",
                    params: ["pluginId": plugin.id]
                )
                await loadAccountResources()
            } catch {
                transientError = "Plugin could not be uninstalled: \(error.localizedDescription)"
            }
        }
    }

    func openAppLink(_ app: DesktopAppRecord) {
        guard app.isEnabled,
              !app.isAccessible,
              capabilities.supports(.appsLinking),
              let url = app.installURL,
              url.scheme?.lowercased() == "https" else {
            transientError = "This app did not provide a secure connection URL."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func loginMCP(_ server: DesktopMCPServerStatus) {
        guard capabilities.supports(.mcpOAuth), integrationMutationID == nil else { return }
        integrationMutationID = "mcp:\(server.id)"
        Task {
            defer { integrationMutationID = nil }
            do {
                var params: [String: Any] = ["name": server.name, "timeoutSecs": 300]
                if let selectedThreadID,
                   let runtimeID = runtimeThreadID(forUIThreadID: selectedThreadID) {
                    params["threadId"] = runtimeID
                }
                let response = try await client.request(
                    method: "mcpServer/oauth/login",
                    params: params,
                    requiring: .mcpOAuth
                )
                guard let rawURL = response.string("authorizationUrl"),
                      let url = URL(string: rawURL),
                      url.scheme?.lowercased() == "https" else {
                    throw CodexAppServerClientError.malformedResponse("insecure MCP OAuth URL")
                }
                NSWorkspace.shared.open(url)
            } catch {
                transientError = "MCP authorization could not start: \(error.localizedDescription)"
            }
        }
    }

    func reloadMCPServers() {
        guard capabilities.supports(.mcpReload), integrationMutationID == nil else { return }
        integrationMutationID = "mcp-reload"
        Task {
            defer { integrationMutationID = nil }
            do {
                _ = try await client.request(method: "config/mcpServer/reload", requiring: .mcpReload)
                await loadAccountResources()
            } catch {
                transientError = "MCP servers could not be reloaded: \(error.localizedDescription)"
            }
        }
    }

    func ensureInteractiveTerminalShell(cols: Int = 100, rows: Int = 24) {
        guard hasExplicitWorkspace,
              capabilities.supports(.commandExec),
              interactiveTerminal?.isRunning != true else { return }
        startInteractiveTerminalShell(cols: cols, rows: rows)
    }

    func restartInteractiveTerminalShell(cols: Int = 100, rows: Int = 24) {
        guard hasExplicitWorkspace, capabilities.supports(.commandExec) else { return }
        if let session = interactiveTerminal, session.isRunning {
            interactiveTerminal?.isTerminating = true
            Task {
                _ = try? await client.request(
                    method: "command/exec/terminate",
                    params: ["processId": session.id],
                    requiring: .commandExec
                )
                guard interactiveTerminal?.id == session.id else { return }
                flushInteractiveTerminalOutput(processID: session.id)
                interactiveTerminal = nil
                interactiveTerminalPendingOutput = Data()
                interactiveTerminalPendingProcessID = nil
                startInteractiveTerminalShell(cols: cols, rows: rows)
            }
            return
        }
        startInteractiveTerminalShell(cols: cols, rows: rows)
    }

    func runInteractiveTerminalCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if interactiveTerminal?.isRunning == true {
            writeInteractiveTerminalInput(trimmed + "\n")
            return
        }
        ensureInteractiveTerminalShell()
        // Defer the typed command until the shell is up.
        Task { @MainActor in
            for _ in 0..<40 {
                if interactiveTerminal?.isRunning == true {
                    writeInteractiveTerminalInput(trimmed + "\n")
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    func resizeInteractiveTerminal(cols: Int, rows: Int) {
        guard let session = interactiveTerminal, session.isRunning else { return }
        let safeCols = max(20, cols)
        let safeRows = max(5, rows)
        Task {
            _ = try? await client.request(
                method: "command/exec/resize",
                params: [
                    "processId": session.id,
                    "size": ["cols": safeCols, "rows": safeRows],
                ],
                requiring: .commandExec
            )
        }
    }

    private func startInteractiveTerminalShell(cols: Int, rows: Int) {
        let processID = "veo-terminal-\(UUID().uuidString)"
        let cwd = effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        interactiveTerminalPendingOutput = Data()
        interactiveTerminalPendingProcessID = processID
        interactiveTerminal = DesktopInteractiveTerminalState(
            id: processID,
            command: "/bin/zsh -i",
            workingDirectory: cwd,
            output: "",
            isRunning: true,
            isTerminating: false,
            exitCode: nil,
            errorMessage: nil,
            outputWasCapped: false
        )
        let terminalAccess: DesktopAccessMode = accessMode == .fullAccess ? .workspace : accessMode
        let safeCols = max(20, cols)
        let safeRows = max(5, rows)
        Task {
            do {
                let response = try await client.request(
                    method: "command/exec",
                    params: [
                        "command": ["/bin/zsh", "-i"],
                        "processId": processID,
                        "tty": true,
                        "streamStdin": true,
                        "streamStdoutStderr": true,
                        "disableTimeout": true,
                        "outputBytesCap": 4_194_304,
                        "cwd": cwd,
                        "sandboxPolicy": terminalAccess.sandboxPolicy(workspacePath: cwd),
                        "size": ["cols": safeCols, "rows": safeRows],
                    ],
                    requiring: .commandExec,
                    timeoutSeconds: nil
                )
                guard interactiveTerminal?.id == processID else { return }
                flushInteractiveTerminalOutput(processID: processID)
                if let stdout = response.string("stdout"), !stdout.isEmpty {
                    interactiveTerminal?.output += stdout
                }
                if let stderr = response.string("stderr"), !stderr.isEmpty {
                    interactiveTerminal?.output += stderr
                }
                interactiveTerminal?.exitCode = response.number("exitCode").map(Int.init)
                interactiveTerminal?.outputWasCapped = response.bool("capReached")
                    ?? interactiveTerminal?.outputWasCapped
                    ?? false
                interactiveTerminal?.isRunning = false
                interactiveTerminal?.isTerminating = false
            } catch {
                guard interactiveTerminal?.id == processID else { return }
                flushInteractiveTerminalOutput(processID: processID)
                interactiveTerminal?.isRunning = false
                interactiveTerminal?.isTerminating = false
                interactiveTerminal?.errorMessage = error.localizedDescription
            }
        }
    }

    func writeInteractiveTerminalInput(_ input: String, closeStdin: Bool = false) {
        guard let session = interactiveTerminal, session.isRunning else { return }
        Task {
            do {
                var params: [String: Any] = [
                    "processId": session.id,
                    "closeStdin": closeStdin,
                ]
                if !input.isEmpty {
                    params["deltaBase64"] = Data(input.utf8).base64EncodedString()
                }
                _ = try await client.request(
                    method: "command/exec/write",
                    params: params,
                    requiring: .commandExec
                )
            } catch {
                guard interactiveTerminal?.id == session.id else { return }
                interactiveTerminal?.errorMessage = error.localizedDescription
            }
        }
    }

    func terminateInteractiveTerminal() {
        guard let session = interactiveTerminal,
              session.isRunning,
              !session.isTerminating else { return }
        interactiveTerminal?.isTerminating = true
        Task {
            do {
                _ = try await client.request(
                    method: "command/exec/terminate",
                    params: ["processId": session.id],
                    requiring: .commandExec
                )
                guard interactiveTerminal?.id == session.id else { return }
                flushInteractiveTerminalOutput(processID: session.id)
                interactiveTerminal?.isRunning = false
                interactiveTerminal?.isTerminating = false
            } catch {
                guard interactiveTerminal?.id == session.id else { return }
                interactiveTerminal?.isTerminating = false
                interactiveTerminal?.errorMessage = error.localizedDescription
            }
        }
    }

    func clearInteractiveTerminal() {
        guard interactiveTerminal?.isRunning != true else { return }
        interactiveTerminal = nil
        interactiveTerminalPendingOutput = Data()
        interactiveTerminalPendingProcessID = nil
    }

    private func appendInteractiveTerminalOutput(_ data: Data, processID: String) {
        guard interactiveTerminal?.id == processID else { return }
        if interactiveTerminalPendingProcessID != processID {
            interactiveTerminalPendingOutput = Data()
            interactiveTerminalPendingProcessID = processID
        }
        interactiveTerminalPendingOutput.append(data)
        let bytes = Array(interactiveTerminalPendingOutput)
        let incompleteStart = trailingIncompleteUTF8Start(in: bytes)
        let prefixCount = incompleteStart ?? bytes.count
        if prefixCount > 0 {
            interactiveTerminal?.output += String(decoding: bytes[..<prefixCount], as: UTF8.self)
        }
        interactiveTerminalPendingOutput = incompleteStart.map {
            Data(bytes[$0...])
        } ?? Data()
    }

    private func flushInteractiveTerminalOutput(processID: String) {
        guard interactiveTerminalPendingProcessID == processID else { return }
        if !interactiveTerminalPendingOutput.isEmpty,
           interactiveTerminal?.id == processID {
            interactiveTerminal?.output += String(
                decoding: interactiveTerminalPendingOutput,
                as: UTF8.self
            )
        }
        interactiveTerminalPendingOutput = Data()
        interactiveTerminalPendingProcessID = nil
    }

    private func trailingIncompleteUTF8Start(in bytes: [UInt8]) -> Int? {
        guard !bytes.isEmpty else { return nil }
        let lowerBound = max(0, bytes.count - 4)
        for index in stride(from: bytes.count - 1, through: lowerBound, by: -1) {
            let byte = bytes[index]
            let expectedLength: Int
            switch byte {
            case 0xC2...0xDF: expectedLength = 2
            case 0xE0...0xEF: expectedLength = 3
            case 0xF0...0xF4: expectedLength = 4
            case 0x80...0xBF: continue
            default: return nil
            }
            let actualLength = bytes.count - index
            guard actualLength < expectedLength else { return nil }
            let continuationBytesAreValid = bytes[(index + 1)...].allSatisfy {
                (0x80...0xBF).contains($0)
            }
            return continuationBytesAreValid ? index : nil
        }
        return nil
    }

    private func stopInteractiveTerminalForContextChange() {
        guard let session = interactiveTerminal else { return }
        guard session.isRunning else {
            interactiveTerminal = nil
            return
        }
        guard !session.isTerminating, capabilities.supports(.commandExec) else { return }
        interactiveTerminal?.isTerminating = true
        Task {
            do {
                _ = try await client.request(
                    method: "command/exec/terminate",
                    params: ["processId": session.id],
                    requiring: .commandExec
                )
                guard interactiveTerminal?.id == session.id else { return }
                flushInteractiveTerminalOutput(processID: session.id)
                interactiveTerminal = nil
                interactiveTerminalPendingOutput = Data()
                interactiveTerminalPendingProcessID = nil
            } catch {
                guard interactiveTerminal?.id == session.id else { return }
                interactiveTerminal?.isTerminating = false
                interactiveTerminal?.errorMessage = error.localizedDescription
                transientError = "The previous project terminal could not be stopped cleanly: \(error.localizedDescription)"
            }
        }
    }

    func shutDown() {
        client.stop()
    }

    func refreshThreads() {
        Task {
            await loadVeoThreadsFromStore()
            refreshSelectedVeoThreadMetadata()
            guard runtimeState.isReady, showCodexThreads else { return }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchTerm = query.isEmpty ? nil : query
            await loadThreads(archived: isBrowsingArchivedThreads, searchTerm: searchTerm)
        }
    }

    func requestThreadMinimapAnalysis(_ request: DesktopThreadMinimapAnalysisRequest?) {
        guard DesktopAppearancePreferences.isThreadMinimapVisible,
              runtimeState.isReady,
              let request,
              let selectedThread,
              let model = resolvedUtilityModel else {
            threadMinimapAnalysisTask?.cancel()
            threadMinimapAnalysisTask = nil
            threadMinimapAnalysisKey = nil
            threadMinimapTopicStartIDs = nil
            return
        }

        let key = "\(selectedThread.id)|\(model.id)|\(request.fingerprint)"
        guard threadMinimapAnalysisKey != key else { return }
        threadMinimapAnalysisKey = key
        threadMinimapAnalysisTask?.cancel()
        let selectedThreadID = selectedThread.id
        let cwd = selectedThread.cwd
        let modelName = model.model
        threadMinimapAnalysisTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self, !Task.isCancelled else { return }
            do {
                let output = try await utilityInference.infer(
                    prompt: request.prompt,
                    outputSchema: request.outputSchema,
                    model: modelName,
                    effort: DesktopUtilityModelPreferences.reasoningEffort,
                    cwd: cwd
                )
                guard !Task.isCancelled,
                      self.selectedThreadID == selectedThreadID,
                      self.threadMinimapAnalysisKey == key,
                      let object = Self.utilityJSONObject(from: output),
                      let returnedIDs = object["topicStartIDs"] as? [String] else { return }
                let candidates = Set(request.candidateTurnIDs)
                var validIDs = Set(returnedIDs.filter(candidates.contains))
                if let firstID = request.candidateTurnIDs.first {
                    validIDs.insert(firstID)
                }
                threadMinimapTopicStartIDs = validIDs
            } catch {
                // The deterministic topic grouping remains available as an offline fallback.
                guard self.threadMinimapAnalysisKey == key else { return }
                threadMinimapTopicStartIDs = nil
            }
        }
    }

    private static func utilityJSONObject(from text: String) -> [String: Any]? {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("```"), let firstNewline = normalized.firstIndex(of: "\n") {
            normalized = String(normalized[normalized.index(after: firstNewline)...])
            if normalized.hasSuffix("```") {
                normalized.removeLast(3)
            }
        }
        guard let data = normalized.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    func setSearchesMessageContent(_ enabled: Bool) {
        searchesMessageContent = enabled && canSearchMessageContent
    }

    func setBrowsingArchivedThreads(_ enabled: Bool) {
        guard isBrowsingArchivedThreads != enabled else { return }
        isBrowsingArchivedThreads = enabled
        searchedThreads = nil
        searchOccurrencesByThreadID = [:]
        searchSnippetByThreadID = [:]
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchTerm = query.isEmpty ? nil : query
        Task {
            await loadVeoThreadsFromStore(archived: enabled)
            if showCodexThreads, runtimeState.isReady {
                await loadThreads(archived: enabled, searchTerm: searchTerm)
            }
        }
    }

    func setThreadPinned(_ thread: DesktopThread, pinned: Bool) {
        if thread.origin == .veo {
            Task {
                do {
                    try await threadStore.setPinned(veoID: thread.id, pinned: pinned)
                    var updated = thread
                    // DesktopThread.isPinned is a let — rebuild via makeVeo/parse path
                    updated = DesktopThread.makeVeo(
                        id: thread.selection.bareID,
                        title: thread.title,
                        preview: thread.preview,
                        cwd: thread.cwd,
                        updatedAt: Date(),
                        status: thread.status,
                        isPinned: pinned,
                        codexThreadId: thread.codexThreadId,
                        parentThreadID: thread.parentThreadID,
                        agentNickname: thread.agentNickname,
                        agentRole: thread.agentRole,
                        canAcceptDirectInput: thread.canAcceptDirectInput,
                        activeFlags: thread.activeFlags,
                        agentDepth: thread.agentDepth,
                        sessionID: thread.sessionID,
                        workspaceKind: thread.workspaceKind
                    )
                    replaceThread(updated)
                    rebuildCodexMappings()
                } catch {
                    transientError = "Chat could not be \(pinned ? "pinned" : "unpinned"): \(error.localizedDescription)"
                }
            }
            return
        }
        guard let runtimeID = thread.runtimeThreadID else {
            transientError = "Chat could not be \(pinned ? "pinned" : "unpinned"): missing Codex thread."
            return
        }
        Task {
            do {
                let response = try await client.request(
                    method: "thread/metadata/update",
                    params: ["threadId": runtimeID, "isPinned": pinned],
                    requiring: .threadManagement
                )
                if let object = response["thread"] as? [String: Any],
                   let updated = DesktopThread.parse(object, origin: .codex) {
                    replaceThread(updated)
                } else if showCodexThreads {
                    await loadThreads()
                }
            } catch {
                transientError = "Chat could not be \(pinned ? "pinned" : "unpinned"): \(error.localizedDescription)"
            }
        }
    }

    func renameThread(_ thread: DesktopThread, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if thread.origin == .veo {
            Task {
                do {
                    try await threadStore.rename(veoID: thread.id, title: trimmed)
                    var updated = thread
                    updated = DesktopThread.makeVeo(
                        id: thread.selection.bareID,
                        title: trimmed,
                        preview: thread.preview,
                        cwd: thread.cwd,
                        updatedAt: Date(),
                        status: thread.status,
                        isPinned: thread.isPinned,
                        codexThreadId: thread.codexThreadId,
                        parentThreadID: thread.parentThreadID,
                        agentNickname: thread.agentNickname,
                        agentRole: thread.agentRole,
                        canAcceptDirectInput: thread.canAcceptDirectInput,
                        activeFlags: thread.activeFlags,
                        agentDepth: thread.agentDepth,
                        sessionID: thread.sessionID,
                        workspaceKind: thread.workspaceKind
                    )
                    replaceThread(updated)
                } catch {
                    transientError = "Chat could not be renamed: \(error.localizedDescription)"
                }
            }
            return
        }
        guard let runtimeID = thread.runtimeThreadID else {
            transientError = "Chat could not be renamed: missing Codex thread."
            return
        }
        Task {
            do {
                _ = try await client.request(
                    method: "thread/name/set",
                    params: ["threadId": runtimeID, "name": trimmed],
                    requiring: .threadManagement
                )
                if showCodexThreads {
                    await loadThreads(archived: isBrowsingArchivedThreads)
                }
            } catch {
                transientError = "Chat could not be renamed: \(error.localizedDescription)"
            }
        }
    }

    func archiveThread(_ thread: DesktopThread) {
        if thread.origin == .veo {
            let affectedThreadIDs = threadFamilyIDs(rootedAt: thread.id)
            Task {
                do {
                    try await threadStore.setArchived(veoID: thread.id, archived: true)
                    reconcileArchivedThreadIDs(affectedThreadIDs, notificationThread: thread)
                    await loadVeoThreadsFromStore()
                } catch {
                    transientError = "Chat could not be archived: \(error.localizedDescription)"
                }
            }
            return
        }
        guard let runtimeID = thread.runtimeThreadID else {
            transientError = "Chat could not be archived: missing Codex thread."
            return
        }
        let affectedThreadIDs = threadFamilyIDs(rootedAt: thread.id)
        Task {
            do {
                _ = try await client.request(
                    method: "thread/archive",
                    params: ["threadId": runtimeID],
                    requiring: .threadManagement
                )
                reconcileArchivedThreadIDs(affectedThreadIDs)
                if showCodexThreads {
                    await loadThreads(archived: true)
                }
            } catch {
                transientError = "Chat could not be archived: \(error.localizedDescription)"
            }
        }
    }

    func unarchiveThread(_ thread: DesktopThread) {
        if thread.origin == .veo {
            Task {
                do {
                    try await threadStore.setArchived(veoID: thread.id, archived: false)
                    archivedThreads.removeAll(where: { $0.id == thread.id })
                    await loadVeoThreadsFromStore()
                } catch {
                    transientError = "Chat could not be restored: \(error.localizedDescription)"
                }
            }
            return
        }
        guard let runtimeID = thread.runtimeThreadID else {
            transientError = "Chat could not be restored: missing Codex thread."
            return
        }
        Task {
            do {
                _ = try await client.request(
                    method: "thread/unarchive",
                    params: ["threadId": runtimeID],
                    requiring: .threadManagement
                )
                archivedCodexThreads.removeAll(where: { $0.id == thread.id })
                if showCodexThreads {
                    await loadThreads()
                }
            } catch {
                transientError = "Chat could not be restored: \(error.localizedDescription)"
            }
        }
    }

    func deleteThread(_ thread: DesktopThread) {
        if thread.origin == .veo {
            let affectedThreadIDs = threadFamilyIDs(rootedAt: thread.id)
            let temporaryPaths = Set(affectedThreadIDs.compactMap { id -> String? in
                guard let affected = findThread(id), affected.workspaceKind.isAppManaged else { return nil }
                return affected.cwd
            })
            Task {
                do {
                    for id in affectedThreadIDs {
                        try await threadStore.deleteThread(veoID: id)
                    }
                    let retainedTemporaryPaths = try await threadStore.appManagedWorkspacePaths()
                    var cleanupError: Error?
                    for path in temporaryPaths where !retainedTemporaryPaths.contains(path) {
                        do {
                            try temporaryWorkspaceService.removeWorkspace(atPath: path)
                        } catch {
                            cleanupError = error
                        }
                    }
                    reconcileDeletedThreadIDs(affectedThreadIDs)
                    rebuildCodexMappings()
                    if let cleanupError {
                        transientError = "The chat was deleted, but its temporary files could not be removed yet: \(cleanupError.localizedDescription)"
                    }
                } catch {
                    transientError = "Chat could not be deleted: \(error.localizedDescription)"
                }
            }
            return
        }
        guard let runtimeID = thread.runtimeThreadID else {
            transientError = "Chat could not be deleted: missing Codex thread."
            return
        }
        let affectedThreadIDs = threadFamilyIDs(rootedAt: thread.id)
        Task {
            do {
                _ = try await client.request(
                    method: "thread/delete",
                    params: ["threadId": runtimeID],
                    requiring: .threadManagement
                )
                reconcileDeletedThreadIDs(affectedThreadIDs)
            } catch {
                transientError = "Chat could not be deleted: \(error.localizedDescription)"
            }
        }
    }

    func loadTurnBoundaries(for threadID: String) async -> [DesktopTurnBoundary] {
        guard let runtimeID = runtimeThreadID(forUIThreadID: threadID) else {
            transientError = "Fork points could not be loaded: this chat has no Codex session yet."
            return []
        }
        do {
            let response = try await client.request(
                method: "thread/read",
                params: ["threadId": runtimeID, "includeTurns": true]
            )
            let thread = response["thread"] as? [String: Any]
            let turns = thread?["turns"] as? [[String: Any]] ?? []
            return turns.enumerated().compactMap { index, turn in
                DesktopTurnBoundary.parse(turn, index: index)
            }
        } catch {
            transientError = "Fork points could not be loaded: \(error.localizedDescription)"
            return []
        }
    }

    func forkThread(_ thread: DesktopThread, through turnID: String?) {
        guard let runtimeID = thread.runtimeThreadID else {
            transientError = "Chat could not be forked: start a turn in this chat first."
            return
        }
        Task {
            do {
                var params: [String: Any] = [
                    "threadId": runtimeID,
                    "cwd": thread.cwd,
                    "approvalPolicy": accessMode.approvalPolicyValue,
                    "sandbox": accessMode.sandboxValue,
                ]
                if let turnID { params["lastTurnId"] = turnID }
                let response = try await client.request(
                    method: "thread/fork",
                    params: params,
                    requiring: .threadManagement
                )
                guard let object = response["thread"] as? [String: Any],
                      let forkedCodexID = object.string("id") else {
                    throw CodexAppServerClientError.malformedResponse("thread/fork")
                }
                if thread.origin == .veo {
                    let forked = DesktopThread.makeVeo(
                        title: object.string("name") ?? thread.title,
                        preview: object.string("preview") ?? thread.preview,
                        cwd: object.string("cwd") ?? thread.cwd,
                        codexThreadId: forkedCodexID,
                        parentThreadID: thread.id,
                        workspaceKind: thread.workspaceKind
                    )
                    try await threadStore.upsertThread(forked, isArchived: false)
                    threads.removeAll(where: { $0.id == forked.id })
                    threads.insert(forked, at: 0)
                    rebuildCodexMappings()
                    isBrowsingArchivedThreads = false
                    selectThread(forked.id)
                } else {
                    guard let forked = DesktopThread.parse(object, origin: .codex) else {
                        throw CodexAppServerClientError.malformedResponse("thread/fork")
                    }
                    codexThreads.removeAll(where: { $0.id == forked.id })
                    codexThreads.insert(forked, at: 0)
                    isBrowsingArchivedThreads = false
                    selectThread(forked.id)
                }
            } catch {
                transientError = "Chat could not be forked: \(error.localizedDescription)"
            }
        }
    }

    func compactThread(_ thread: DesktopThread) {
        guard !thread.isRunning else { return }
        guard let runtimeID = thread.runtimeThreadID else {
            transientError = "Context could not be compacted: this chat has no Codex session yet."
            return
        }
        Task {
            do {
                _ = try await client.request(
                    method: "thread/compact/start",
                    params: ["threadId": runtimeID],
                    requiring: .manualCompaction
                )
            } catch {
                transientError = "Context could not be compacted: \(error.localizedDescription)"
            }
        }
    }

    func reviewChanges(_ request: DesktopReviewRequest = DesktopReviewRequest()) {
        guard let threadID = selectedThreadID, !isBusyTurn else { return }
        guard request.isValid else {
            transientError = "Complete the review target before starting."
            return
        }
        guard let runtimeID = runtimeThreadID(forUIThreadID: threadID) else {
            transientError = "Review could not start: this chat has no Codex session yet."
            return
        }
        Task {
            do {
                let response = try await client.request(
                    method: "review/start",
                    params: [
                        "threadId": runtimeID,
                        "target": request.targetPayload,
                        "delivery": request.delivery.rawValue,
                    ],
                    requiring: .review
                )
                var destinationUIThreadID = threadID
                if request.delivery == .detached,
                   let reviewRuntimeID = response.string("reviewThreadId"),
                   reviewRuntimeID != runtimeID,
                   let sourceThread = findThread(threadID) {
                    let reviewThread = DesktopThread.makeVeo(
                        title: "Review · \(sourceThread.title)",
                        cwd: sourceThread.cwd,
                        codexThreadId: reviewRuntimeID,
                        parentThreadID: sourceThread.id,
                        workspaceKind: sourceThread.workspaceKind
                    )
                    try await threadStore.upsertThread(reviewThread, isArchived: false)
                    threads.removeAll(where: { $0.id == reviewThread.id })
                    threads.insert(reviewThread, at: 0)
                    rebuildCodexMappings()
                    destinationUIThreadID = reviewThread.id
                    selectThread(reviewThread.id)
                }
                if let turn = response["turn"] as? [String: Any],
                   let turnID = turn.string("id") {
                    activeTurnIDByThread[destinationUIThreadID] = turnID
                    if selectedThreadID == destinationUIThreadID {
                        activeTurnID = turnID
                        isRunningTurn = true
                    }
                }
            } catch {
                transientError = "Review could not start: \(error.localizedDescription)"
            }
        }
    }

    func beginNewChat() {
        guard prepareForWorkspaceChange?() != false else { return }
        createNewChat(workspaceKind: .projectless, projectURL: nil)
    }

    func beginProjectChat(at url: URL) {
        guard prepareForWorkspaceChange?() != false else { return }
        setWorkspace(url)
        createNewChat(workspaceKind: .project, projectURL: url)
    }

    /// Switching away from a running thread is allowed: the turn keeps running on the
    /// runtime and `thread/resume` rehydrates its state when the thread is selected again.
    private func createNewChat(workspaceKind: DesktopWorkspaceKind, projectURL: URL?) {
        let bareID = UUID().uuidString
        let targetWorkspaceURL: URL
        do {
            switch workspaceKind {
            case .project:
                guard let projectURL else {
                    throw CodexAppServerClientError.invalidInput("Choose a project before starting this chat.")
                }
                targetWorkspaceURL = projectURL.standardizedFileURL
            case .projectless, .temporary:
                targetWorkspaceURL = try temporaryWorkspaceService.createWorkspace(forVeoID: bareID)
            }
        } catch {
            transientError = "Chat could not be created: \(error.localizedDescription)"
            return
        }

        if realtimeSession != nil { stopRealtimeVoice() }
        searchOccurrencesTask?.cancel()
        stopInteractiveTerminalForContextChange()
        invalidateAccountResourceContext()
        invalidateGitContext()
        timelineLoadGeneration = UUID()
        threadMinimapAnalysisTask?.cancel()
        threadMinimapAnalysisTask = nil
        threadMinimapAnalysisKey = nil
        threadMinimapTopicStartIDs = nil
        isLoadingTimeline = false
        saveCurrentDraft()
        newChatGenerationID = UUID()

        let created = DesktopThread.makeVeo(
            id: bareID,
            cwd: targetWorkspaceURL.path,
            workspaceKind: workspaceKind
        )
        let previousDraftContext = currentDraftContextID
        let previousThreadID = selectedThreadID
        threads.removeAll(where: { $0.id == created.id })
        threads.insert(created, at: 0)
        rebuildCodexMappings()
        persistVeoThread(created, isArchived: false)
        selectedThreadID = created.id
        defaults.set(created.id, forKey: "VeoDesktop.selectedThreadID")
        discardTemporaryChatIfNeeded(leaving: previousThreadID)
        discardUnusedNewChatIfNeeded(leaving: previousThreadID)
        migrateDraftContext(from: previousDraftContext, to: created.id)
        timeline = []
        activeTurnID = nil
        isSubmittingTurn = false
        isRunningTurn = false
        isPlanModeEnabled = false
        isGoalModeEnabled = false
        activeGoalObjective = nil
        transientError = nil
        availableSkillSuggestions = []
        composerSuggestions = []
        isBrowsingArchivedThreads = false
        restoreDraft()
        refreshInvalidatedGitContextIfNeeded()
        if runtimeState.isReady {
            Task {
                await loadSkills()
                await loadAccountResources()
            }
        }
    }

    func toggleSelectedChatTemporary() {
        guard canToggleTemporaryChat, let selectedThreadID,
              let index = threads.firstIndex(where: { $0.id == selectedThreadID }) else { return }
        threads[index].workspaceKind = threads[index].workspaceKind == .temporary ? .projectless : .temporary
        persistVeoThread(threads[index], isArchived: false)
    }

    /// Temporary chats are ephemeral: once the user leaves one it is deleted along with
    /// its app-managed scratch folder. Deletion is deferred while a turn is still running
    /// and retried from `turn/completed`.
    private func discardTemporaryChatIfNeeded(leaving previousThreadID: String?) {
        guard let previousThreadID, previousThreadID != selectedThreadID,
              let thread = findThread(previousThreadID),
              thread.origin == .veo,
              thread.workspaceKind == .temporary else { return }
        guard activeTurnIDByThread[previousThreadID] == nil,
              queuedDraftsByThreadID[previousThreadID]?.isEmpty != false else { return }
        deleteThread(thread)
    }

    /// A brand-new chat that never started a turn is not worth keeping: leaving it
    /// should feel like the chat was never created. Anything with a runtime thread,
    /// timeline content, a pending queue, or a saved draft is preserved.
    private func discardUnusedNewChatIfNeeded(leaving previousThreadID: String?) {
        guard let previousThreadID, previousThreadID != selectedThreadID,
              let thread = findThread(previousThreadID),
              thread.origin == .veo,
              thread.runtimeThreadID == nil,
              thread.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !thread.isPinned,
              activeTurnIDByThread[previousThreadID] == nil,
              queuedDraftsByThreadID[previousThreadID]?.isEmpty != false,
              !threads.contains(where: { $0.parentThreadID == previousThreadID }) else { return }
        let draftContextID = "thread:\(previousThreadID)"
        guard (draftsByContextID[draftContextID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (attachmentsByContextID[draftContextID] ?? []).isEmpty else { return }
        deleteThread(thread)
    }

    func selectThread(_ id: String?) {
        guard selectedThreadID != id else { return }
        guard prepareForWorkspaceChange?() != false else { return }
        if let id {
            guard let thread = findThread(id), Self.workspaceExists(for: thread) else {
                discardThreadFromLoadedCatalog(id)
                return
            }
        }
        if realtimeSession != nil { stopRealtimeVoice() }
        searchOccurrencesTask?.cancel()
        stopInteractiveTerminalForContextChange()
        invalidateAccountResourceContext()
        invalidateGitContext()
        let loadGeneration = UUID()
        timelineLoadGeneration = loadGeneration
        threadMinimapAnalysisTask?.cancel()
        threadMinimapAnalysisTask = nil
        threadMinimapAnalysisKey = nil
        threadMinimapTopicStartIDs = nil
        isLoadingTimeline = false
        saveCurrentDraft()
        let previousThreadID = selectedThreadID
        selectedThreadID = id
        if let id {
            defaults.set(id, forKey: "VeoDesktop.selectedThreadID")
        } else {
            defaults.removeObject(forKey: "VeoDesktop.selectedThreadID")
        }
        discardTemporaryChatIfNeeded(leaving: previousThreadID)
        discardUnusedNewChatIfNeeded(leaving: previousThreadID)
        timeline = []
        activeTurnID = nil
        isSubmittingTurn = false
        isRunningTurn = false
        isPlanModeEnabled = id.map(planModeThreadIDs.contains) ?? false
        isGoalModeEnabled = false
        activeGoalObjective = nil
        transientError = nil
        availableSkillSuggestions = []
        composerSuggestions = []
        restoreDraft()
        refreshInvalidatedGitContextIfNeeded()

        guard let id else { return }
        Task {
            await prepareAndResumeSelectedThread(id, loadGeneration: loadGeneration)
            await loadSkills()
            await loadAccountResources()
            let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if searchesMessageContent, !term.isEmpty {
                scheduleSearchOccurrences(threadID: id, searchTerm: term)
            }
        }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Open a project"
        panel.message = "Choose the folder Codex should work in."
        panel.prompt = "Open Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginProjectChat(at: url)
    }

    func chooseMediaAttachments() {
        guard hasExplicitWorkspace else { return }
        let panel = NSOpenPanel()
        panel.title = "Attach image or audio"
        panel.message = selectedThread?.workspaceKind.isAppManaged == true
            ? "Selected media will be copied into this projectless chat."
            : accessMode == .fullAccess
            ? "Choose local media for this message."
            : "Choose media inside the current project."
        panel.prompt = "Attach"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .audio]
        panel.directoryURL = effectiveWorkspaceURL
        guard panel.runModal() == .OK else { return }
        _ = addAttachmentURLs(panel.urls, forceFileMention: false)
    }

    func chooseFileMention() {
        guard hasExplicitWorkspace else { return }
        let panel = NSOpenPanel()
        panel.title = selectedThread?.workspaceKind.isAppManaged == true
            ? "Mention a file"
            : "Mention a project file"
        panel.message = selectedThread?.workspaceKind.isAppManaged == true
            ? "Selected files will be copied into this projectless chat."
            : "Choose a file inside \(effectiveWorkspaceURL.lastPathComponent)."
        panel.prompt = "Mention"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = effectiveWorkspaceURL
        guard panel.runModal() == .OK else { return }
        _ = addAttachmentURLs(panel.urls, forceFileMention: true)
    }

    @discardableResult
    func addDroppedFiles(_ urls: [URL]) -> Bool {
        addAttachmentURLs(urls, forceFileMention: false)
    }

    func removeAttachment(_ id: String) {
        attachments.removeAll(where: { $0.id == id })
    }

    func updateComposerAutocomplete() {
        autocompleteTask?.cancel()
        if composerPaletteContext != nil {
            if draft.isEmpty { return }
            composerPaletteContext = nil
        }
        guard let finalCharacter = draft.last,
              !finalCharacter.isWhitespace else {
            autocompleteToken = nil
            composerSuggestions = []
            return
        }
        let token = draft
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .last
            .map(String.init)
        autocompleteToken = token

        guard let token else {
            composerSuggestions = []
            return
        }
        if token.hasPrefix("$") {
            let query = String(token.dropFirst())
            composerSuggestions = availableSkillSuggestions
                .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                .prefix(8)
                .map { $0 }
            return
        }
        if token.hasPrefix("/"),
           draft.trimmingCharacters(in: .whitespacesAndNewlines) == token {
            let query = String(token.dropFirst()).lowercased()
            let matches = DesktopComposerCommand.all
                .filter {
                    query.isEmpty
                        || $0.name.hasPrefix(query)
                        || $0.name.localizedCaseInsensitiveContains(query)
                        || $0.description.localizedCaseInsensitiveContains(query)
                }
                .sorted { lhs, rhs in
                    let lhsPrefix = lhs.name.hasPrefix(query)
                    let rhsPrefix = rhs.name.hasPrefix(query)
                    if lhsPrefix != rhsPrefix { return lhsPrefix }
                    return DesktopComposerCommand.all.firstIndex(of: lhs) ?? 0
                        < DesktopComposerCommand.all.firstIndex(of: rhs) ?? 0
                }
            composerSuggestions = matches.prefix(10).map { command in
                DesktopComposerSuggestion(
                    kind: .command,
                    title: command.invocation,
                    subtitle: command.description,
                    source: command.invocation
                )
            }
            return
        }
        guard token.hasPrefix("@"), hasExplicitWorkspace else {
            composerSuggestions = []
            return
        }

        let query = String(token.dropFirst())
        let root = effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let contextID = currentDraftContextID
        autocompleteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self, !Task.isCancelled else { return }
            do {
                let response = try await client.request(
                    method: "fuzzyFileSearch",
                    params: [
                        "query": query,
                        "roots": [root],
                        "cancellationToken": UUID().uuidString,
                    ]
                )
                guard !Task.isCancelled,
                      autocompleteToken == token,
                      currentDraftContextID == contextID,
                      effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path == root else { return }
                let rows = response["files"] as? [[String: Any]] ?? []
                composerSuggestions = rows.prefix(8).compactMap { row in
                    guard row.string("match_type") != "directory",
                          let path = row.string("path") else { return nil }
                    let rowRoot = row.string("root") ?? root
                    let absolutePath = path.hasPrefix("/")
                        ? path
                        : URL(fileURLWithPath: rowRoot, isDirectory: true)
                            .appendingPathComponent(path).path
                    return DesktopComposerSuggestion(
                        kind: .file,
                        title: row.string("file_name") ?? URL(fileURLWithPath: path).lastPathComponent,
                        subtitle: path,
                        source: absolutePath
                    )
                }
            } catch {
                guard autocompleteToken == token,
                      currentDraftContextID == contextID else { return }
                composerSuggestions = []
            }
        }
    }

    func selectComposerSuggestion(_ suggestion: DesktopComposerSuggestion) {
        switch suggestion.kind {
        case .file:
            _ = addAttachmentURLs(
                [URL(fileURLWithPath: suggestion.source)],
                forceFileMention: true
            )
        case .skill:
            if !attachments.contains(where: { $0.kind == .skill && $0.source == suggestion.source }) {
                attachments.append(.init(
                    kind: .skill,
                    source: suggestion.source,
                    name: suggestion.title
                ))
            }
        case .command:
            guard let command = DesktopComposerCommand.named(suggestion.source) else { return }
            executeComposerCommand(command, arguments: "")
            return
        case .model:
            selectModel(suggestion.source)
            closeComposerPalette()
            return
        case .reasoning:
            selectReasoningEffort(suggestion.source)
            closeComposerPalette()
            return
        case .accessMode:
            guard let mode = DesktopAccessMode(rawValue: suggestion.source) else { return }
            updateAccessMode(mode)
            closeComposerPalette()
            return
        }

        if let autocompleteToken,
           draft.hasSuffix(autocompleteToken) {
            draft.removeLast(autocompleteToken.count)
        }
        composerSuggestions = []
        autocompleteToken = nil
    }

    @discardableResult
    func moveComposerSuggestionSelection(by offset: Int) -> Bool {
        guard !composerSuggestions.isEmpty else { return false }
        let currentIndex = selectedComposerSuggestionID
            .flatMap { id in composerSuggestions.firstIndex(where: { $0.id == id }) }
            ?? 0
        let count = composerSuggestions.count
        let nextIndex = (currentIndex + offset % count + count) % count
        selectedComposerSuggestionID = composerSuggestions[nextIndex].id
        return true
    }

    @discardableResult
    func acceptSelectedComposerSuggestion() -> Bool {
        guard let selectedComposerSuggestionID,
              let suggestion = composerSuggestions.first(where: { $0.id == selectedComposerSuggestionID })
                ?? composerSuggestions.first else { return false }
        selectComposerSuggestion(suggestion)
        return true
    }

    @discardableResult
    func dismissComposerSuggestions() -> Bool {
        guard !composerSuggestions.isEmpty else { return false }
        closeComposerPalette()
        return true
    }

    /// Executes a recognized Veo slash command locally so it is never sent to the model as prose.
    @discardableResult
    func executeComposerCommandIfPresent() -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }

        let components = trimmed.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
        guard let invocation = components.first.map(String.init),
              let command = DesktopComposerCommand.named(invocation) else { return false }

        composerSuggestions = []
        autocompleteToken = nil
        let arguments = components.count > 1
            ? String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        executeComposerCommand(command, arguments: arguments)
        return true
    }

    private func executeComposerCommand(_ command: DesktopComposerCommand, arguments: String) {
        draft = ""
        transientError = nil
        composerPaletteContext = nil
        switch command.action {
        case .model:
            presentModelSuggestions()
        case .reasoning:
            presentReasoningSuggestions()
        case .permissions:
            presentAccessModeSuggestions()
        case .newChat:
            beginNewChat()
            sendCommandArgumentsIfPresent(arguments)
        case .temporaryChat:
            guard let selectedThread else {
                transientError = "Start a projectless chat before making it temporary."
                return
            }
            guard selectedThread.workspaceKind == .projectless else {
                transientError = selectedThread.workspaceKind == .temporary
                    ? "This chat is already temporary."
                    : "Temporary mode is only available for projectless chats."
                return
            }
            guard canToggleTemporaryChat else {
                transientError = "A chat can only become temporary before its first turn starts."
                return
            }
            toggleSelectedChatTemporary()
        case .compact:
            guard let selectedThread else {
                transientError = "Start a chat before compacting context."
                return
            }
            compactThread(selectedThread)
        case .review:
            composerCommandDestinationRequest = .review
        case .rename:
            guard let selectedThread else {
                transientError = "Select a chat before renaming it."
                return
            }
            if arguments.isEmpty {
                composerCommandDestinationRequest = .rename
            } else {
                renameThread(selectedThread, name: arguments)
            }
        case .archive:
            guard let selectedThread else {
                transientError = "Select a thread before archiving it."
                return
            }
            archiveThread(selectedThread)
        case .fork:
            guard selectedThread != nil else {
                transientError = "Select a thread before forking it."
                return
            }
            composerCommandDestinationRequest = .fork
        case .plan:
            setPlanModeEnabled(true)
            sendCommandArgumentsIfPresent(arguments)
        case .goal:
            setGoalModeEnabled(true)
            sendCommandArgumentsIfPresent(arguments)
        case .mention:
            chooseFileMention()
        case .status:
            composerCommandDestinationRequest = .settings(.runtime)
        case .usage:
            composerCommandDestinationRequest = .settings(.account)
        case .integrations:
            composerCommandDestinationRequest = .settings(.integrations)
        case .changes:
            composerCommandDestinationRequest = .changes
        case .stop:
            stopTurn()
        case .copyLastResponse:
            guard let response = timeline.last(where: { $0.kind == .assistant })?.body,
                  !response.isEmpty else {
                transientError = "There is no Codex response to copy yet."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(response, forType: .string)
        case .initAgents:
            draft = "Create an AGENTS.md file with concise project-specific instructions for Codex. Inspect the repository first and preserve existing guidance."
            if canSend { sendDraft() }
        case .settings(let category):
            composerCommandDestinationRequest = .settings(category)
        case .terminal:
            composerCommandDestinationRequest = .terminal
        case .reconnect:
            reconnect()
        case .revealProject:
            revealWorkspace()
        case .refreshChats:
            refreshThreads()
        case .delete:
            guard selectedThread != nil else {
                transientError = "Select a chat before deleting it."
                return
            }
            composerCommandDestinationRequest = .delete
        }
    }

    private func presentModelSuggestions() {
        guard !models.isEmpty else {
            transientError = "No models are available from the local Codex runtime."
            return
        }
        composerPaletteContext = .models
        composerSuggestions = models.map { model in
            DesktopComposerSuggestion(
                kind: .model,
                title: model.displayName,
                subtitle: model.description,
                source: model.id
            )
        }
        selectedComposerSuggestionID = composerSuggestions
            .first(where: { $0.source == selectedModelID })?.id
            ?? composerSuggestions.first?.id
    }

    private func presentReasoningSuggestions() {
        guard let model = selectedModel, !model.supportedReasoningEfforts.isEmpty else {
            transientError = "The selected model does not expose reasoning choices."
            return
        }
        composerPaletteContext = .reasoning
        composerSuggestions = model.supportedReasoningEfforts.map { option in
            DesktopComposerSuggestion(
                kind: .reasoning,
                title: option.title,
                subtitle: option.description.isEmpty ? "Use \(option.title.lowercased()) reasoning" : option.description,
                source: option.id
            )
        }
        selectedComposerSuggestionID = composerSuggestions
            .first(where: { $0.source == selectedReasoningEffort })?.id
            ?? composerSuggestions.first?.id
    }

    private func presentAccessModeSuggestions() {
        composerPaletteContext = .accessModes
        composerSuggestions = DesktopAccessMode.allCases.map { mode in
            DesktopComposerSuggestion(
                kind: .accessMode,
                title: mode.title,
                subtitle: mode.detail,
                source: mode.rawValue
            )
        }
        selectedComposerSuggestionID = composerSuggestions
            .first(where: { $0.source == accessMode.rawValue })?.id
            ?? composerSuggestions.first?.id
    }

    private func closeComposerPalette() {
        composerPaletteContext = nil
        composerSuggestions = []
        autocompleteToken = nil
    }

    func consumeComposerCommandDestinationRequest() {
        composerCommandDestinationRequest = nil
    }

    private func sendCommandArgumentsIfPresent(_ arguments: String) {
        guard !arguments.isEmpty else { return }
        draft = arguments
        if canSend { sendDraft() }
    }

    private func scheduleThreadSearch() {
        threadSearchTask?.cancel()
        searchOccurrencesTask?.cancel()
        searchOccurrencesByThreadID = [:]
        searchSnippetByThreadID = [:]
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchTerm = query.isEmpty ? nil : query
        if searchTerm == nil { searchedThreads = nil }
        guard showCodexThreads, runtimeState.isReady else { return }
        let archived = isBrowsingArchivedThreads
        threadSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            await loadThreads(archived: archived, searchTerm: searchTerm)
        }
    }

    func setWorkspace(_ url: URL) {
        guard prepareForWorkspaceChange?() != false else { return }
        stopInteractiveTerminalForContextChange()
        invalidateAccountResourceContext()
        invalidateGitContext()
        if selectedThreadID == nil { saveCurrentDraft() }
        workspaceURL = url
        availableSkillSuggestions = []
        composerSuggestions = []
        defaults.set(url.path, forKey: "VeoDesktop.workspacePath")
        if selectedThreadID == nil { restoreDraft() }
        refreshInvalidatedGitContextIfNeeded()
        if runtimeState.isReady {
            Task {
                await loadSkills()
                await loadAccountResources()
            }
        }
    }

    @discardableResult
    private func addAttachmentURLs(
        _ urls: [URL],
        forceFileMention: Bool
    ) -> Bool {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]
        let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "webm", "ogg"]
        var added = false

        for rawURL in urls {
            var url = rawURL.standardizedFileURL.resolvingSymlinksInPath()
            guard url.isFileURL else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }

            var pathIsInWorkspace = isInsideWorkspace(url)
            if !pathIsInWorkspace, selectedThread?.workspaceKind.isAppManaged == true {
                do {
                    url = try temporaryWorkspaceService.importFile(
                        at: url,
                        intoWorkspaceAtPath: effectiveWorkspaceURL.path
                    ).standardizedFileURL.resolvingSymlinksInPath()
                    pathIsInWorkspace = true
                } catch {
                    transientError = "Could not copy \(rawURL.lastPathComponent) into this temporary chat: \(error.localizedDescription)"
                    continue
                }
            }
            let fileExtension = url.pathExtension.lowercased()
            let kind: DesktopComposerAttachment.Kind
            if forceFileMention || (!imageExtensions.contains(fileExtension) && !audioExtensions.contains(fileExtension)) {
                guard pathIsInWorkspace else {
                    transientError = "File mentions must stay inside the current workspace."
                    continue
                }
                kind = .fileMention
            } else if imageExtensions.contains(fileExtension) {
                guard accessMode == .fullAccess || pathIsInWorkspace else {
                    transientError = "Workspace access can attach media only from the current workspace."
                    continue
                }
                kind = .localImage
            } else {
                guard audioExtensions.contains(fileExtension) else {
                    transientError = "Codex does not support this audio format."
                    continue
                }
                guard accessMode == .fullAccess || pathIsInWorkspace else {
                    transientError = "Workspace access can attach media only from the current workspace."
                    continue
                }
                kind = .localAudio
            }

            guard !attachments.contains(where: { $0.kind == kind && $0.source == url.path }) else { continue }
            let displayName: String
            if kind == .fileMention, pathIsInWorkspace {
                displayName = workspaceRelativePath(for: url)
            } else {
                displayName = url.lastPathComponent
            }
            attachments.append(.init(kind: kind, source: url.path, name: displayName))
            added = true
        }
        return added
    }

    private func isInsideWorkspace(_ url: URL) -> Bool {
        let workspace = effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == workspace || candidate.hasPrefix(workspace + "/")
    }

    private func validateAttachments(
        _ attachments: [DesktopComposerAttachment],
        workspacePath: String,
        accessMode: DesktopAccessMode
    ) throws {
        let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        for attachment in attachments {
            switch attachment.kind {
            case .localImage, .localAudio, .fileMention:
                let url = URL(fileURLWithPath: attachment.source)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    throw CodexAppServerClientError.invalidInput(
                        "Attachment no longer exists: \(attachment.name)"
                    )
                }
                let isInWorkspace = url.path == workspace || url.path.hasPrefix(workspace + "/")
                if attachment.kind == .fileMention, !isInWorkspace {
                    throw CodexAppServerClientError.invalidInput(
                        "File mentions must stay inside this chat's workspace."
                    )
                }
                if attachment.kind != .fileMention,
                   accessMode != .fullAccess,
                   !isInWorkspace {
                    throw CodexAppServerClientError.invalidInput(
                        "Workspace access cannot send \(attachment.name) from outside this chat's workspace."
                    )
                }
            case .image, .audio:
                guard let url = URL(string: attachment.source),
                      url.scheme?.lowercased() == "https" else {
                    throw CodexAppServerClientError.invalidInput(
                        "Remote media attachments must use a secure HTTPS URL."
                    )
                }
            case .skill:
                let path = URL(fileURLWithPath: attachment.source)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                guard FileManager.default.fileExists(atPath: path),
                      skillPathsByWorkspacePath[workspace]?.contains(path) == true else {
                    throw CodexAppServerClientError.invalidInput(
                        "Skill is no longer available for this project: \(attachment.name)"
                    )
                }
            }
        }
    }

    private func workspaceRelativePath(for url: URL) -> String {
        let workspace = effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.hasPrefix(workspace + "/") else { return url.lastPathComponent }
        return String(candidate.dropFirst(workspace.count + 1))
    }

    func setFollowUpBehavior(_ behavior: DesktopFollowUpBehavior) {
        followUpBehavior = behavior
        defaults.set(behavior.rawValue, forKey: "VeoDesktop.followUpBehavior")
    }

    func updateAccessMode(_ mode: DesktopAccessMode) {
        guard isAccessModeAllowed(mode) else {
            transientError = "This access mode is disabled by managed Codex requirements."
            return
        }
        accessMode = mode
        defaults.set(mode.rawValue, forKey: "VeoDesktop.accessMode")
    }

    func selectModel(_ id: String) {
        guard let model = models.first(where: { $0.id == id }) else { return }
        selectedModelID = model.id
        selectedReasoningEffort = model.defaultReasoningEffort
        selectedServiceTier = model.defaultServiceTier
        defaults.set(model.id, forKey: "VeoDesktop.modelID")
        defaults.set(model.defaultReasoningEffort, forKey: "VeoDesktop.reasoningEffort")
        persistServiceTier(model.defaultServiceTier)
        updateActiveThreadSettings()
    }

    func selectReasoningEffort(_ effort: String) {
        guard selectedModel?.supportedReasoningEfforts.contains(where: { $0.id == effort }) == true else { return }
        selectedReasoningEffort = effort
        defaults.set(effort, forKey: "VeoDesktop.reasoningEffort")
        updateActiveThreadSettings()
    }

    func selectServiceTier(_ tier: String?) {
        guard tier == nil || selectedModel?.serviceTiers.contains(where: { $0.id == tier }) == true else { return }
        selectedServiceTier = tier
        persistServiceTier(tier)
        updateActiveThreadSettings()
    }

    func setPlanModeEnabled(_ enabled: Bool) {
        guard !enabled || (supportsPlanMode && hasExplicitWorkspace) else { return }
        isPlanModeEnabled = enabled
        if let threadID = selectedThreadID {
            persistPlanMode(enabled, threadID: threadID)
            updateActiveThreadSettings()
        }
    }

    func setGoalModeEnabled(_ enabled: Bool) {
        guard !enabled || hasExplicitWorkspace else { return }
        guard isGoalModeEnabled != enabled else { return }

        if enabled {
            isGoalModeEnabled = true
            return
        }

        let previousObjective = activeGoalObjective
        isGoalModeEnabled = false
        activeGoalObjective = nil

        guard previousObjective != nil,
              let threadID = selectedThreadID,
              let runtimeID = runtimeThreadID(forUIThreadID: threadID) else { return }
        Task {
            do {
                _ = try await client.request(
                    method: "thread/goal/clear",
                    params: ["threadId": runtimeID]
                )
            } catch {
                guard selectedThreadID == threadID else { return }
                isGoalModeEnabled = true
                activeGoalObjective = previousObjective
                transientError = "Goal could not be cleared: \(error.localizedDescription)"
            }
        }
    }

    func revealWorkspace() {
        NSWorkspace.shared.activateFileViewerSelecting([effectiveWorkspaceURL])
    }

    func openTerminal() {
        let script = "tell application \"Terminal\" to do script \"cd " + shellQuoted(effectiveWorkspaceURL.path) + "\""
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            transientError = error[NSAppleScript.errorMessage] as? String ?? "Terminal could not open."
        }
    }

    func sendDraft() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let payload = DesktopComposerPayload(
            text: message,
            attachments: attachments,
            accessMode: accessMode,
            model: selectedModel?.model,
            reasoningEffort: selectedReasoningEffort,
            serviceTier: selectedServiceTier,
            isPlanMode: isPlanModeEnabled
        )
        draft = ""
        attachments = []

        if isBusyTurn {
            guard let threadID = selectedThreadID else {
                draft = message
                attachments = payload.attachments
                return
            }
            enqueue(payload, queueKey: threadID)
            if followUpBehavior == .steer, isRunningTurn {
                steerQueuedDraft(payload.id)
            }
            return
        }

        let requestedThreadID = selectedThreadID
        let queueKey = requestedThreadID ?? currentDraftContextID
        let originNewChatGenerationID = requestedThreadID == nil ? newChatGenerationID : nil
        // Reserve before enqueue so the composer never treats this as a waiting follow-up.
        queuedDeliveryInFlightIDs.insert(payload.id)
        enqueue(payload, queueKey: queueKey)
        isSubmittingTurn = true
        upsertOptimisticUser(payload, turnID: nil)
        Task {
            defer { queuedDeliveryInFlightIDs.remove(payload.id) }
            await send(
                payload,
                to: requestedThreadID,
                fromQueue: true,
                queuedUnder: queueKey,
                newChatGenerationID: originNewChatGenerationID,
                inFlightAlreadyReserved: true
            )
        }
    }

    func updateQueuedDraft(_ id: String, text: String) {
        guard !queuedDeliveryInFlightIDs.contains(id) else { return }
        let queueKey = currentQueueContextID
        guard let index = queuedDraftsByThreadID[queueKey]?.firstIndex(where: { $0.id == id }) else { return }
        queuedDraftsByThreadID[queueKey]?[index].text = text
        persistInteractionSnapshot()
    }

    func removeQueuedDraft(_ id: String) {
        guard !queuedDeliveryInFlightIDs.contains(id) else { return }
        removeQueuedDraft(id, queueKey: currentQueueContextID)
    }

    func steerQueuedDraft(_ id: String) {
        guard let threadID = selectedThreadID,
              !queuedDeliveryInFlightIDs.contains(id),
              let payload = queuedDraftsByThreadID[threadID]?.first(where: { $0.id == id }) else { return }
        Task { await steer(payload, threadID: threadID) }
    }

    func sendNextQueuedDraft() {
        guard !isBusyTurn else { return }
        if let threadID = selectedThreadID {
            Task { await flushNextQueuedDraft(threadID: threadID) }
        } else {
            let queueKey = currentQueueContextID
            let generationID = newChatGenerationID
            Task {
                guard let payload = queuedDraftsByThreadID[queueKey]?.first else { return }
                isSubmittingTurn = true
                upsertOptimisticUser(payload, turnID: nil)
                await send(
                    payload,
                    to: nil,
                    fromQueue: true,
                    queuedUnder: queueKey,
                    newChatGenerationID: generationID
                )
            }
        }
    }

    func stopTurn() {
        guard let threadID = selectedThreadID else { return }
        Task {
            do {
                guard let turnID = try await resolveActiveTurnID(threadID: threadID) else {
                    transientError = "No active turn was found."
                    isRunningTurn = false
                    return
                }
                guard let runtimeID = runtimeThreadID(forUIThreadID: threadID) else {
                    transientError = "No Codex session is bound to this chat yet."
                    return
                }
                _ = try await client.request(
                    method: "turn/interrupt",
                    params: ["threadId": runtimeID, "turnId": turnID]
                )
            } catch {
                transientError = error.localizedDescription
            }
        }
    }

    func submitPendingAnswers(_ answers: [String: [String]]) {
        guard let request = pendingRequest, request.kind == .userInput else { return }
        let payload = answers.reduce(into: [String: Any]()) { result, entry in
            result[entry.key] = ["answers": entry.value]
        }
        completePendingRequest(request, result: ["answers": payload])
    }

    func resolvePendingRequest(approved: Bool, forSession: Bool = false) {
        guard let request = pendingRequest else { return }

        let result: [String: Any]
        switch request.kind {
        case .userInput:
            let emptyAnswers = request.questions.reduce(into: [String: Any]()) { result, question in
                result[question.id] = ["answers": []]
            }
            result = ["answers": emptyAnswers]
        case .commandApproval, .fileApproval:
            result = ["decision": approved ? (forSession ? "acceptForSession" : "accept") : "decline"]
        case .permissionApproval:
            result = [
                "permissions": approved ? (request.requestedPermissions ?? [:]) : [:],
                "scope": forSession ? "session" : "turn",
            ]
        case .mcpElicitation:
            result = ["action": "decline"]
        }
        completePendingRequest(request, result: result)
    }

    func resolvePendingApproval(_ decision: DesktopApprovalDecision) {
        guard let request = pendingRequest,
              request.kind == .commandApproval || request.kind == .fileApproval,
              request.approvalDecisions.contains(where: { $0.id == decision.id }) else { return }
        completePendingRequest(request, result: ["decision": decision.rpcValue])
    }

    func submitMCPForm(_ values: [String: String]) {
        guard let request = pendingRequest,
              request.kind == .mcpElicitation,
              request.mcpMode == "form" else { return }

        var content: [String: Any] = [:]
        for field in request.mcpFields {
            let raw = (values[field.id] ?? field.defaultValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty, !field.isRequired { continue }
            switch field.valueKind {
            case .string:
                content[field.id] = raw
            case .number:
                guard let number = Double(raw) else {
                    transientError = "\(field.title) must be a number."
                    return
                }
                content[field.id] = number
            case .integer:
                guard let integer = Int(raw) else {
                    transientError = "\(field.title) must be a whole number."
                    return
                }
                content[field.id] = integer
            case .boolean:
                content[field.id] = (raw as NSString).boolValue
            case .stringArray:
                let values = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if field.isRequired, values.isEmpty {
                    transientError = "Choose at least one value for \(field.title)."
                    return
                }
                content[field.id] = values
            }
        }
        completePendingRequest(
            request,
            result: ["action": "accept", "content": content]
        )
    }

    func openPendingMCPURL() {
        guard let request = pendingRequest,
              request.kind == .mcpElicitation,
              request.mcpMode == "url",
              let rawURL = request.detail,
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https" else {
            transientError = "Tool links must use a secure HTTPS URL."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func acceptPendingMCPURL() {
        guard let request = pendingRequest,
              request.kind == .mcpElicitation,
              request.mcpMode == "url",
              let rawURL = request.detail,
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https" else {
            transientError = "Tool links must use a secure HTTPS URL."
            return
        }
        completePendingRequest(request, result: ["action": "accept"])
    }

    private func connect() async {
        do {
            if client.isRunning {
                client.stop()
            }
            try await client.start()
            capabilities = client.capabilities
            runtimeState = .ready
            transientError = nil
            await loadVeoThreadsFromStore()
            if showCodexThreads {
                let generation = codexThreadsLoadGeneration
                await loadThreads(archived: isBrowsingArchivedThreads)
                // Clears the toggle-on loading bar if the user enabled Codex threads
                // before the runtime finished connecting.
                finishCodexThreadsLoading(generation: generation)
            }
            await loadModels()
            await loadCollaborationModes()
            await loadRuntimeConfiguration()
            if let selectedThreadID, findThread(selectedThreadID) != nil {
                await prepareAndResumeSelectedThread(selectedThreadID, loadGeneration: timelineLoadGeneration)
            }
            await loadSkills()
            await loadAccountResources()
            if realtimeVoiceEnabled { await loadRealtimeVoices() }
        } catch {
            runtimeState = .unavailable(error.localizedDescription)
            finishCodexThreadsLoading(generation: codexThreadsLoadGeneration)
        }
    }

    private func scheduleConnection() {
        guard connectionTask == nil else { return }
        runtimeState = .starting
        connectionTask = Task { [weak self] in
            guard let self else { return }
            await self.connect()
            self.connectionTask = nil
        }
    }

    private func captureServerRequest(
        _ object: [String: Any],
        route: CodexAppServerRoute
    ) -> Bool {
        guard let parsed = DesktopPendingRequest.parse(object, route: route) else { return false }
        let request = remappedPendingRequest(parsed)
        let key = pendingRequestQueueKey(for: request.threadID)
        var queue = pendingRequestQueues[key] ?? []
        guard !queue.contains(where: { $0.id == request.id }) else { return true }
        queue.append(request)
        pendingRequestQueues[key] = queue
        pendingRequestOrder.append(request.id)
        updatePendingRequestProjection()
        notify(
            .attentionNeeded(
                threadTitle: threadTitle(request.threadID),
                detail: request.title
            ),
            threadID: request.threadID
        )
        return true
    }

    private func remappedPendingRequest(_ request: DesktopPendingRequest) -> DesktopPendingRequest {
        guard let runtimeID = request.threadID else { return request }
        let uiID = uiThreadID(forRuntimeThreadID: runtimeID)
        guard uiID != runtimeID else { return request }
        return DesktopPendingRequest(
            rpcID: request.rpcID,
            threadID: uiID,
            turnID: request.turnID,
            kind: request.kind,
            title: request.title,
            message: request.message,
            detail: request.detail,
            questions: request.questions,
            requestedPermissions: request.requestedPermissions,
            approvalDecisions: request.approvalDecisions,
            mcpFields: request.mcpFields,
            mcpMode: request.mcpMode
        )
    }

    private func completePendingRequest(
        _ request: DesktopPendingRequest,
        result: [String: Any]
    ) {
        do {
            try client.respond(to: request.rpcID, result: result)
            removePendingRequest(request)
        } catch {
            transientError = error.localizedDescription
        }
    }

    private func pendingRequestQueueKey(for threadID: String?) -> String {
        threadID ?? "__global__"
    }

    private func updatePendingRequestProjection() {
        pendingRequestCountsByThreadID = pendingRequestQueues.reduce(into: [:]) { result, entry in
            guard entry.key != "__global__", !entry.value.isEmpty else { return }
            result[entry.key] = entry.value.count
        }

        if let pendingRequest,
           pendingRequestOrder.contains(pendingRequest.id) {
            return
        }
        pendingRequest = pendingRequestOrder.lazy.compactMap { requestID in
            self.pendingRequestQueues.values.lazy
                .flatMap { $0 }
                .first(where: { $0.id == requestID })
        }.first
    }

    private func removePendingRequest(_ request: DesktopPendingRequest) {
        let key = pendingRequestQueueKey(for: request.threadID)
        var queue = pendingRequestQueues[key] ?? []
        queue.removeAll(where: { $0.id == request.id })
        if queue.isEmpty {
            pendingRequestQueues.removeValue(forKey: key)
        } else {
            pendingRequestQueues[key] = queue
        }
        pendingRequestOrder.removeAll(where: { $0 == request.id })
        if pendingRequest?.id == request.id {
            pendingRequest = nil
        }
        updatePendingRequestProjection()
    }

    private func expirePendingRequests(threadID: String, turnID: String?) {
        guard let turnID else { return }
        let key = pendingRequestQueueKey(for: threadID)
        let requests = pendingRequestQueues[key] ?? []
        for request in requests where request.turnID == turnID {
            removePendingRequest(request)
        }
    }

    private func purgePendingRequests(threadID: String) {
        let key = pendingRequestQueueKey(for: threadID)
        for request in pendingRequestQueues[key] ?? [] {
            removePendingRequest(request)
        }
    }

    private func reconcileResolvedServerRequest(
        rpcID: DesktopRPCRequestID,
        threadID: String?
    ) {
        if let threadID {
            let key = pendingRequestQueueKey(for: threadID)
            if let request = pendingRequestQueues[key]?.first(where: { $0.rpcID == rpcID }) {
                removePendingRequest(request)
                return
            }
        }
        if let request = pendingRequestQueues.values.lazy
            .flatMap({ $0 })
            .first(where: { $0.rpcID == rpcID }) {
            removePendingRequest(request)
        }
    }

    private func loadModels() async {
        do {
            var rows: [[String: Any]] = []
            var cursor: String?
            var seenCursors = Set<String>()

            while true {
                var params: [String: Any] = ["limit": 100, "includeHidden": false]
                if let cursor { params["cursor"] = cursor }
                let response = try await client.request(method: "model/list", params: params)
                rows.append(contentsOf: response["data"] as? [[String: Any]] ?? [])
                guard let nextCursor = response.string("nextCursor"), !nextCursor.isEmpty else { break }
                guard seenCursors.insert(nextCursor).inserted else {
                    throw CodexAppServerClientError.malformedResponse("model/list pagination")
                }
                cursor = nextCursor
            }

            let parsed = rows.compactMap(DesktopModelOption.parse)
            models = parsed
            guard let model = parsed.first(where: { $0.id == selectedModelID })
                    ?? parsed.first(where: \.isDefault)
                    ?? parsed.first else { return }

            selectedModelID = model.id
            defaults.set(model.id, forKey: "VeoDesktop.modelID")

            if !model.supportedReasoningEfforts.contains(where: { $0.id == selectedReasoningEffort }) {
                selectedReasoningEffort = model.defaultReasoningEffort
                defaults.set(model.defaultReasoningEffort, forKey: "VeoDesktop.reasoningEffort")
            }
            if !model.serviceTiers.contains(where: { $0.id == selectedServiceTier }) {
                selectedServiceTier = model.defaultServiceTier
                persistServiceTier(model.defaultServiceTier)
            }
        } catch {
            transientError = "Models could not be loaded: \(error.localizedDescription)"
        }
    }

    private func loadRealtimeVoices() async {
        guard realtimeVoiceEnabled, capabilities.supports(.realtimeVoice) else {
            realtimeVoices = []
            return
        }
        do {
            let response = try await client.request(
                method: "thread/realtime/listVoices",
                params: [:],
                requiring: .realtimeVoice
            )
            let voices = response["voices"] as? [String: Any]
            let values = (voices?["v2"] as? [String])
                ?? (voices?["v1"] as? [String])
                ?? []
            var seen = Set<String>()
            realtimeVoices = values
                .filter { seen.insert($0).inserted }
                .map(DesktopVoiceOption.parse)
            let defaultVoice = voices?.string("defaultV2") ?? voices?.string("defaultV1")
            if let selectedRealtimeVoiceID,
               realtimeVoices.contains(where: { $0.id == selectedRealtimeVoiceID }) {
                return
            }
            selectedRealtimeVoiceID = defaultVoice ?? realtimeVoices.first?.id
            if let selectedRealtimeVoiceID {
                defaults.set(selectedRealtimeVoiceID, forKey: "VeoDesktop.realtimeVoice")
            }
        } catch {
            capabilities = client.capabilities
            realtimeVoices = []
        }
    }

    private func loadSkills() async {
        guard hasExplicitWorkspace, capabilities.supports(.skills) else {
            availableSkillSuggestions = []
            return
        }
        let root = effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        do {
            let response = try await client.request(
                method: "skills/list",
                params: ["cwds": [root], "forceReload": false],
                requiring: .skills
            )
            guard effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path == root else { return }
            let entries = (response["data"] as? [[String: Any]] ?? []).filter { entry in
                guard let cwd = entry.string("cwd") else { return false }
                return URL(fileURLWithPath: cwd, isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path == root
            }
            let parsed = entries.flatMap { entry -> [DesktopComposerSuggestion] in
                let skills = entry["skills"] as? [[String: Any]] ?? []
                return skills.compactMap { skill in
                    guard skill.bool("enabled") != false,
                          let name = skill.string("name"),
                          let path = skill.string("path") else { return nil }
                    let interface = skill["interface"] as? [String: Any]
                    return DesktopComposerSuggestion(
                        kind: .skill,
                        title: interface?.string("displayName") ?? name,
                        subtitle: interface?.string("shortDescription")
                            ?? skill.string("description")
                            ?? path,
                        source: path
                    )
                }
            }
            var seen = Set<String>()
            availableSkillSuggestions = parsed
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            skillPathsByWorkspacePath[root] = Set(availableSkillSuggestions.map {
                URL(fileURLWithPath: $0.source).standardizedFileURL.resolvingSymlinksInPath().path
            })
        } catch {
            guard effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path == root else { return }
            availableSkillSuggestions = []
            skillPathsByWorkspacePath[root] = []
        }
    }

    private func invalidateAccountResourceContext() {
        accountOverviewLoadGeneration = UUID()
        accountResourcesLoadGeneration = UUID()
        isLoadingAccountOverview = false
        isLoadingAccountResources = false
        resourceOverviews = []
        skillRecords = []
        pluginRecords = []
        appRecords = []
        mcpServerStatuses = []
        workspaceMessages = []
        availableRateLimitResetCredits = 0
        availableRateLimitResetCreditID = nil
        accountOverviewMessage = nil
        accountResourcesMessage = nil
    }

    private func loadRuntimeConfiguration() async {
        guard runtimeState.isReady else { return }
        isLoadingRuntimeConfiguration = true
        runtimeConfigurationMessage = nil
        defer {
            isLoadingRuntimeConfiguration = false
            capabilities = client.capabilities
        }

        var failures: [String] = []

        if capabilities.supports(.permissionProfiles) {
            do {
                var rows: [[String: Any]] = []
                var cursor: String?
                var seen = Set<String>()
                repeat {
                    var params: [String: Any] = ["limit": 100]
                    if let cursor { params["cursor"] = cursor }
                    if hasExplicitWorkspace { params["cwd"] = effectiveWorkspaceURL.path }
                    let response = try await client.request(
                        method: "permissionProfile/list",
                        params: params,
                        requiring: .permissionProfiles
                    )
                    rows.append(contentsOf: response["data"] as? [[String: Any]] ?? [])
                    let next = response.string("nextCursor")
                    cursor = next?.isEmpty == false ? next : nil
                    if let cursor, !seen.insert(cursor).inserted { break }
                } while cursor != nil
                permissionProfiles = rows.compactMap(DesktopPermissionProfile.parse)
            } catch {
                permissionProfiles = []
                failures.append("Permission profiles")
            }
        } else {
            permissionProfiles = []
        }

        if capabilities.supports(method: "configRequirements/read") {
            do {
                let response = try await client.request(method: "configRequirements/read", params: [:])
                managedRequirements = DesktopManagedRequirements.parse(
                    response["requirements"] as? [String: Any]
                )
                reconcileAccessModeWithRequirements()
            } catch {
                managedRequirements = DesktopManagedRequirements()
                failures.append("Managed requirements")
            }
        } else {
            managedRequirements = DesktopManagedRequirements()
        }

        if capabilities.supports(method: "config/read") {
            do {
                let response = try await client.request(method: "config/read", params: [:])
                let config = response["config"] as? [String: Any] ?? [:]
                let keys = ["model", "modelProvider", "approvalPolicy", "sandboxMode", "serviceTier", "personality"]
                codexConfigDetails = keys.compactMap { key in
                    guard let value = config[key], !(value is NSNull) else { return nil }
                    return "\(Self.displayProtocolName(key)): \(Self.compactDisplayValue(value))"
                }
                if let layers = response["layers"] as? [[String: Any]], !layers.isEmpty {
                    codexConfigDetails.append("Configuration layers: \(layers.count)")
                }
            } catch {
                codexConfigDetails = []
                failures.append("Codex configuration")
            }
        } else {
            codexConfigDetails = []
        }

        if capabilities.supports(.experimentalFeatures) {
            do {
                var rows: [[String: Any]] = []
                var cursor: String?
                var seen = Set<String>()
                repeat {
                    var params: [String: Any] = ["limit": 100]
                    if let cursor { params["cursor"] = cursor }
                    let response = try await client.request(
                        method: "experimentalFeature/list",
                        params: params,
                        requiring: .experimentalFeatures
                    )
                    rows.append(contentsOf: response["data"] as? [[String: Any]] ?? [])
                    let next = response.string("nextCursor")
                    cursor = next?.isEmpty == false ? next : nil
                    if let cursor, !seen.insert(cursor).inserted { break }
                } while cursor != nil
                experimentalFeatures = rows.compactMap(DesktopExperimentalFeature.parse)
                    .filter { $0.stage != "removed" }
            } catch {
                experimentalFeatures = []
                failures.append("Experimental features")
            }
        } else {
            experimentalFeatures = []
        }

        if capabilities.supports(.hooks) {
            do {
                let cwds = hasExplicitWorkspace ? [effectiveWorkspaceURL.path] : []
                let response = try await client.request(
                    method: "hooks/list",
                    params: ["cwds": cwds],
                    requiring: .hooks
                )
                hookRecords = (response["data"] as? [[String: Any]] ?? []).flatMap { entry in
                    (entry["hooks"] as? [[String: Any]] ?? []).compactMap(DesktopHookRecord.parse)
                }
            } catch {
                hookRecords = []
                failures.append("Hooks")
            }
        } else {
            hookRecords = []
        }

        runtimeConfigurationMessage = failures.isEmpty
            ? nil
            : "Unavailable from this runtime: \(failures.joined(separator: ", "))."
    }

    private func reconcileAccessModeWithRequirements() {
        guard !isAccessModeAllowed(accessMode),
              let fallback = DesktopAccessMode.allCases.first(where: isAccessModeAllowed) else { return }
        accessMode = fallback
        defaults.set(fallback.rawValue, forKey: "VeoDesktop.accessMode")
        recordRuntimeNotice(
            method: "configRequirements/read",
            severity: .warning,
            title: "Access mode adjusted",
            detail: "Managed Codex requirements do not allow the previous access mode. Veo selected \(fallback.title)."
        )
    }

    private static func compactDisplayValue(_ value: Any) -> String {
        if let string = value as? String { return displayProtocolName(string) }
        if let number = value as? NSNumber { return number.stringValue }
        if let values = value as? [String] { return values.joined(separator: ", ") }
        return "Configured"
    }

    private func fetchAccountOverview(
        capabilities capabilitySnapshot: CodexAppServerCapabilities,
        refreshToken: Bool = false
    ) async -> DesktopAccountSnapshot {
        var snapshot = DesktopAccountSnapshot()

        if capabilitySnapshot.supports(.account) {
            do {
                let response = try await client.request(
                    method: "account/read",
                    params: ["refreshToken": refreshToken],
                    requiring: .account
                )
                snapshot.overview.requiresOpenAIAuth = response.bool("requiresOpenaiAuth") ?? false
                if let account = response["account"] as? [String: Any] {
                    switch account.string("type") {
                    case "apiKey":
                        snapshot.overview.accountType = "API key"
                    case "chatgpt":
                        snapshot.overview.accountType = "ChatGPT"
                        snapshot.overview.email = account.string("email")
                        snapshot.overview.plan = account.string("planType").map(Self.displayProtocolName)
                    case "amazonBedrock":
                        snapshot.overview.accountType = "Amazon Bedrock"
                    case let type?:
                        snapshot.overview.accountType = Self.displayProtocolName(type)
                    case nil:
                        break
                    }
                }
            } catch {
                snapshot.failures.append("Account")
            }

            do {
                let response = try await client.request(
                    method: "account/rateLimits/read",
                    requiring: .account
                )
                if let limits = response["rateLimits"] as? [String: Any] {
                    let primary = limits["primary"] as? [String: Any]
                    let secondary = limits["secondary"] as? [String: Any]
                    snapshot.overview.primaryUsedPercent = primary?.number("usedPercent").map(Int.init)
                    snapshot.overview.secondaryUsedPercent = secondary?.number("usedPercent").map(Int.init)
                    snapshot.overview.primaryResetsAt = primary?.number("resetsAt").map(Date.init(timeIntervalSince1970:))
                }
                if let resetCredits = response["rateLimitResetCredits"] as? [String: Any] {
                    snapshot.resetCreditCount = Int(resetCredits.number("availableCount") ?? 0)
                    snapshot.resetCreditID = (resetCredits["credits"] as? [[String: Any]])?
                        .first(where: { $0.string("status") == "available" })?
                        .string("id")
                }
            } catch {
                snapshot.failures.append("Rate limits")
            }

            do {
                let response = try await client.request(
                    method: "account/usage/read",
                    requiring: .account
                )
                let summary = response["summary"] as? [String: Any]
                snapshot.overview.lifetimeTokens = summary?.number("lifetimeTokens").map(Int.init)
            } catch {
                snapshot.failures.append("Usage")
            }
        }

        if capabilitySnapshot.supports(method: "account/workspaceMessages/read") {
            do {
                let response = try await client.request(method: "account/workspaceMessages/read", params: [:])
                if response.bool("featureEnabled") == true {
                    snapshot.workspaceMessages = (response["messages"] as? [[String: Any]] ?? [])
                        .compactMap(DesktopWorkspaceMessage.parse)
                }
            } catch {
                snapshot.failures.append("Workspace messages")
            }
        }

        return snapshot
    }

    private func applyAccountOverview(_ snapshot: DesktopAccountSnapshot) {
        accountOverview = snapshot.overview
        workspaceMessages = snapshot.workspaceMessages.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        availableRateLimitResetCredits = snapshot.resetCreditCount
        availableRateLimitResetCreditID = snapshot.resetCreditID
        accountOverviewMessage = snapshot.failures.isEmpty
            ? nil
            : "Unavailable: " + snapshot.failures.joined(separator: ", ")
    }

    private func loadAccountOverview(refreshToken: Bool = false) async {
        guard runtimeState.isReady else { return }
        let loadGeneration = UUID()
        let contextUIThreadID = selectedThreadID
        let contextWorkspacePath = hasExplicitWorkspace
            ? effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
            : nil
        accountOverviewLoadGeneration = loadGeneration
        isLoadingAccountOverview = true
        accountOverviewMessage = nil
        defer {
            if accountOverviewLoadGeneration == loadGeneration {
                isLoadingAccountOverview = false
                capabilities = client.capabilities
            }
        }

        let snapshot = await fetchAccountOverview(capabilities: capabilities, refreshToken: refreshToken)
        let currentWorkspacePath = hasExplicitWorkspace
            ? effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
            : nil
        guard accountOverviewLoadGeneration == loadGeneration,
              selectedThreadID == contextUIThreadID,
              currentWorkspacePath == contextWorkspacePath else { return }
        applyAccountOverview(snapshot)
    }

    private func noteOptimisticChatGPTLogin() {
        guard accountOverview.accountType == "Signed out" else { return }
        var overview = accountOverview
        overview.accountType = "ChatGPT"
        overview.requiresOpenAIAuth = false
        accountOverview = overview
    }

    private func refreshAccountAfterLogin() async {
        for _ in 0..<4 {
            await loadAccountOverview(refreshToken: true)
            if accountOverview.accountType != "Signed out" {
                await loadAccountResources()
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        await loadAccountResources()
    }

    private func loadAccountResources() async {
        guard runtimeState.isReady else { return }
        let loadGeneration = UUID()
        let contextUIThreadID = selectedThreadID
        let contextThreadID = contextUIThreadID.flatMap { runtimeThreadID(forUIThreadID: $0) }
        let contextWorkspacePath = hasExplicitWorkspace
            ? effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
            : nil
        let capabilitySnapshot = capabilities
        accountResourcesLoadGeneration = loadGeneration
        isLoadingAccountResources = true
        accountResourcesMessage = nil
        defer {
            if accountResourcesLoadGeneration == loadGeneration {
                isLoadingAccountResources = false
                capabilities = client.capabilities
            }
        }

        var rows: [DesktopResourceOverview] = []
        var loadedSkills: [DesktopSkillRecord] = []
        var loadedPlugins: [DesktopPluginRecord] = []
        var loadedApps: [DesktopAppRecord] = []
        var loadedMCPServers: [DesktopMCPServerStatus] = []
        let accountSnapshot = await fetchAccountOverview(capabilities: capabilitySnapshot)
        var failures = accountSnapshot.failures

        let accountWorkspacePath = hasExplicitWorkspace
            ? effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
            : nil
        if accountResourcesLoadGeneration == loadGeneration,
           selectedThreadID == contextUIThreadID,
           accountWorkspacePath == contextWorkspacePath {
            applyAccountOverview(accountSnapshot)
        }
        if capabilitySnapshot.supports(.skills), let contextWorkspacePath {
            do {
                let response = try await client.request(
                    method: "skills/list",
                    params: ["cwds": [contextWorkspacePath], "forceReload": false],
                    requiring: .skills
                )
                for entry in response["data"] as? [[String: Any]] ?? [] {
                    for skill in entry["skills"] as? [[String: Any]] ?? [] {
                        if let record = DesktopSkillRecord.parse(skill) {
                            loadedSkills.append(record)
                        }
                        guard let name = skill.string("name") else { continue }
                        let interface = skill["interface"] as? [String: Any]
                        let scope = skill.string("scope").map(Self.displayProtocolName) ?? "Skill"
                        rows.append(DesktopResourceOverview(
                            id: "skill:\(skill.string("path") ?? name)",
                            kind: .skill,
                            name: interface?.string("displayName") ?? name,
                            detail: interface?.string("shortDescription")
                                ?? skill.string("shortDescription")
                                ?? skill.string("description")
                                ?? scope,
                            status: skill.bool("enabled") == false ? "Disabled" : "Enabled"
                        ))
                    }
                }
            } catch {
                failures.append("Skills")
            }
        }

        if capabilitySnapshot.supports(.plugins) {
            do {
                let cwd = contextWorkspacePath.map { [$0] } ?? []
                let response = try await client.request(
                    method: "plugin/list",
                    params: ["cwds": cwd, "forceRefetch": false],
                    requiring: .plugins
                )
                for marketplace in response["marketplaces"] as? [[String: Any]] ?? [] {
                    let marketplaceName = marketplace.string("name") ?? "Marketplace"
                    let marketplacePath = marketplace.string("path")
                    for plugin in marketplace["plugins"] as? [[String: Any]] ?? [] {
                        if let record = DesktopPluginRecord.parse(
                            plugin,
                            marketplaceName: marketplaceName,
                            marketplacePath: marketplacePath
                        ) {
                            loadedPlugins.append(record)
                        }
                        guard let name = plugin.string("name") else { continue }
                        let interface = plugin["interface"] as? [String: Any]
                        let installed = plugin.bool("installed") ?? false
                        let enabled = plugin.bool("enabled") ?? false
                        rows.append(DesktopResourceOverview(
                            id: "plugin:\(plugin.string("id") ?? name)",
                            kind: .plugin,
                            name: interface?.string("displayName") ?? name,
                            detail: interface?.string("shortDescription") ?? marketplaceName,
                            status: installed ? (enabled ? "Enabled" : "Disabled") : "Available"
                        ))
                    }
                }
            } catch {
                failures.append("Plugins")
            }
        }

        if capabilitySnapshot.supports(.apps) {
            do {
                var cursor: String?
                var seenCursors = Set<String>()
                repeat {
                    var params: [String: Any] = ["limit": 100, "forceRefetch": false]
                    if let cursor { params["cursor"] = cursor }
                    if let contextThreadID { params["threadId"] = contextThreadID }
                    let response = try await client.request(
                        method: "app/list",
                        params: params,
                        requiring: .apps
                    )
                    for app in response["data"] as? [[String: Any]] ?? [] {
                        if let record = DesktopAppRecord.parse(app) {
                            loadedApps.append(record)
                        }
                        guard let name = app.string("name") else { continue }
                        let enabled = app.bool("isEnabled") ?? true
                        let accessible = app.bool("isAccessible") ?? false
                        rows.append(DesktopResourceOverview(
                            id: "app:\(app.string("id") ?? name)",
                            kind: .app,
                            name: name,
                            detail: app.string("description") ?? "Codex app integration",
                            status: !enabled ? "Disabled" : (accessible ? "Connected" : "Not connected")
                        ))
                    }
                    let nextCursor = response.string("nextCursor")
                    cursor = nextCursor?.isEmpty == false ? nextCursor : nil
                    if let cursor, !seenCursors.insert(cursor).inserted {
                        throw CodexAppServerClientError.malformedResponse("app/list pagination")
                    }
                } while cursor != nil
            } catch {
                failures.append("Apps")
            }
        }

        if capabilitySnapshot.supports(.mcpStatus) {
            do {
                var cursor: String?
                var seenCursors = Set<String>()
                repeat {
                    var params: [String: Any] = ["limit": 100, "detail": "toolsAndAuthOnly"]
                    if let cursor { params["cursor"] = cursor }
                    if let contextThreadID { params["threadId"] = contextThreadID }
                    let response = try await client.request(
                        method: "mcpServerStatus/list",
                        params: params,
                        requiring: .mcpStatus
                    )
                    for server in response["data"] as? [[String: Any]] ?? [] {
                        if let record = DesktopMCPServerStatus.parse(server) {
                            loadedMCPServers.append(record)
                        }
                        guard let name = server.string("name") else { continue }
                        let info = server["serverInfo"] as? [String: Any]
                        let tools = server["tools"] as? [String: Any] ?? [:]
                        let auth = Self.displayProtocolName(server.string("authStatus") ?? "unknown")
                        rows.append(DesktopResourceOverview(
                            id: "mcp:\(name)",
                            kind: .mcp,
                            name: info?.string("title") ?? name,
                            detail: info?.string("description") ?? "\(tools.count) tools available",
                            status: auth
                        ))
                    }
                    let nextCursor = response.string("nextCursor")
                    cursor = nextCursor?.isEmpty == false ? nextCursor : nil
                    if let cursor, !seenCursors.insert(cursor).inserted {
                        throw CodexAppServerClientError.malformedResponse("mcpServerStatus/list pagination")
                    }
                } while cursor != nil
            } catch {
                failures.append("MCP")
            }
        }

        let currentWorkspacePath = hasExplicitWorkspace
            ? effectiveWorkspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
            : nil
        guard accountResourcesLoadGeneration == loadGeneration,
              selectedThreadID == contextUIThreadID,
              currentWorkspacePath == contextWorkspacePath else { return }

        var seenRows = Set<String>()
        skillRecords = Dictionary(grouping: loadedSkills, by: \.id)
            .compactMap { $0.value.last }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        pluginRecords = Dictionary(grouping: loadedPlugins, by: \.id)
            .compactMap { $0.value.last }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        appRecords = Dictionary(grouping: loadedApps, by: \.id)
            .compactMap { $0.value.last }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        mcpServerStatuses = Dictionary(grouping: loadedMCPServers, by: \.id)
            .compactMap { $0.value.last }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        resourceOverviews = rows
            .filter { seenRows.insert($0.id).inserted }
            .sorted {
                if $0.kind.rawValue == $1.kind.rawValue {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        if !failures.isEmpty {
            accountResourcesMessage = "Unavailable: " + failures.joined(separator: ", ")
        }
    }

    private static func displayProtocolName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .capitalized
    }

    private func loadCollaborationModes() async {
        guard capabilities.supports(.collaborationModes) else {
            supportsPlanMode = false
            planModeReasoningEffort = nil
            return
        }
        do {
            let response = try await client.request(
                method: "collaborationMode/list",
                params: [:],
                requiring: .collaborationModes
            )
            let rows = response["data"] as? [[String: Any]] ?? []
            let plan = rows.first(where: { $0.string("mode") == "plan" })
            supportsPlanMode = plan != nil
            planModeReasoningEffort = plan?.string("reasoning_effort")
        } catch {
            supportsPlanMode = false
            planModeReasoningEffort = nil
        }
    }

    private func loadThreads(
        archived: Bool = false,
        searchTerm: String? = nil,
        forceStableFallback: Bool = false
    ) async {
        codexCatalogRequestGeneration += 1
        let requestGeneration = codexCatalogRequestGeneration
        let usesContentSearch = !forceStableFallback
            && searchTerm != nil
            && searchesMessageContent
            && canSearchMessageContent
        do {
            try Task.checkCancellation()
            var parsedByID: [String: DesktopThread] = [:]
            var mappedSnippets: [String: String] = [:]
            var cursor: String?
            var seenCursors = Set<String>()

            while true {
                try Task.checkCancellation()
                var params: [String: Any] = [
                    // Larger pages reduce main-actor/SwiftUI churn while the catalog fills.
                    "limit": 100,
                    "sortKey": "recency_at",
                    "sortDirection": "desc",
                    "archived": archived,
                    "sourceKinds": [
                        "cli", "vscode", "exec", "appServer", "subAgent",
                        "subAgentReview", "subAgentCompact", "subAgentThreadSpawn",
                        "subAgentOther", "unknown",
                    ],
                ]
                if let searchTerm, !searchTerm.isEmpty { params["searchTerm"] = searchTerm }
                if let cursor { params["cursor"] = cursor }

                let response: [String: Any]
                if usesContentSearch {
                    response = try await client.request(
                        method: "thread/search",
                        params: params,
                        requiring: .threadSearch,
                        timeoutSeconds: 120
                    )
                } else {
                    // Avoid rescanning every JSONL rollout on each page. The app-server's
                    // state database is already the authoritative thread catalog here.
                    params["useStateDbOnly"] = true
                    response = try await client.request(
                        method: "thread/list",
                        params: params,
                        timeoutSeconds: 120
                    )
                }
                try Task.checkCancellation()
                let data = Self.jsonObjectArray(response["data"])
                var pageRows: [[String: Any]] = []
                if usesContentSearch {
                    for hit in data {
                        guard let thread = hit["thread"] as? [String: Any],
                              let threadID = thread.string("id") else { continue }
                        pageRows.append(thread)
                        if let snippet = hit.string("snippet") {
                            mappedSnippets[DesktopThreadSelection.codex(threadID).storageKey] = snippet
                        }
                    }
                } else {
                    pageRows = data
                }

                let pageThreads = Self.threadsWithExistingWorkspaces(
                    pageRows.compactMap { DesktopThread.parse($0, origin: .codex) }
                )
                for thread in pageThreads {
                    parsedByID[thread.id] = thread
                }
                let parsed = parsedByID.values.sorted { $0.updatedAt > $1.updatedAt }

                try Task.checkCancellation()
                guard canPublishCodexCatalog(
                    requestGeneration: requestGeneration,
                    archived: archived,
                    searchTerm: searchTerm,
                    usesContentSearch: usesContentSearch,
                    forceStableFallback: forceStableFallback
                ) else { return }
                publishCodexCatalog(
                    parsed,
                    snippets: mappedSnippets,
                    archived: archived,
                    searchTerm: searchTerm,
                    isFinalPage: false
                )

                guard let nextCursor = response.string("nextCursor"), !nextCursor.isEmpty else {
                    break
                }
                guard seenCursors.insert(nextCursor).inserted else {
                    throw CodexAppServerClientError.malformedResponse("thread/list pagination")
                }
                cursor = nextCursor
            }

            try Task.checkCancellation()
            guard canPublishCodexCatalog(
                requestGeneration: requestGeneration,
                archived: archived,
                searchTerm: searchTerm,
                usesContentSearch: usesContentSearch,
                forceStableFallback: forceStableFallback
            ) else { return }
            let parsed = parsedByID.values.sorted { $0.updatedAt > $1.updatedAt }
            publishCodexCatalog(
                parsed,
                snippets: mappedSnippets,
                archived: archived,
                searchTerm: searchTerm,
                isFinalPage: true
            )
            if usesContentSearch,
               let selectedThreadID,
               DesktopThreadSelection.parse(selectedThreadID).origin == .codex,
               parsed.contains(where: { $0.id == selectedThreadID }),
               let searchTerm {
                scheduleSearchOccurrences(threadID: selectedThreadID, searchTerm: searchTerm)
            }
        } catch {
            if error is CancellationError { return }
            guard requestGeneration == codexCatalogRequestGeneration else { return }
            capabilities = client.capabilities
            if usesContentSearch {
                if !client.capabilities.supports(.threadSearch) {
                    searchesMessageContent = false
                } else {
                    await loadThreads(
                        archived: archived,
                        searchTerm: searchTerm,
                        forceStableFallback: true
                    )
                }
                return
            }
            transientError = error.localizedDescription
        }
    }

    private func canPublishCodexCatalog(
        requestGeneration: Int,
        archived: Bool,
        searchTerm: String?,
        usesContentSearch: Bool,
        forceStableFallback: Bool
    ) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSearchTerm = query.isEmpty ? nil : query
        guard requestGeneration == codexCatalogRequestGeneration,
              showCodexThreads,
              currentSearchTerm == searchTerm,
              isBrowsingArchivedThreads == archived else { return false }
        if !forceStableFallback {
            return usesContentSearch
                == (searchesMessageContent && searchTerm != nil && canSearchMessageContent)
        }
        return true
    }

    private func publishCodexCatalog(
        _ parsed: [DesktopThread],
        snippets: [String: String],
        archived: Bool,
        searchTerm: String?,
        isFinalPage: Bool
    ) {
        if searchTerm != nil {
            searchedThreads = parsed
            searchSnippetByThreadID = snippets
        } else if archived {
            archivedCodexThreads = parsed
            searchSnippetByThreadID = [:]
        } else {
            codexThreads = parsed
            searchSnippetByThreadID = [:]
        }
        transientError = nil

        guard isFinalPage, searchTerm == nil, !archived else { return }
        clearMissingSelectionIfNeeded(origin: .codex)
        let currentThreadsByID = Dictionary(uniqueKeysWithValues: parsed.map { ($0.id, $0) })
        agentStateByThreadID = agentStateByThreadID.filter { threadID, state in
            if DesktopThreadSelection.parse(threadID).origin == .veo {
                return findThread(threadID)?.isRunning == true || state.isActive
            }
            return currentThreadsByID[threadID]?.isRunning == true
        }
    }

    private func loadSearchOccurrences(threadID: String, searchTerm: String) async {
        guard searchesMessageContent, canSearchMessageContent else { return }
        guard let runtimeID = runtimeThreadID(forUIThreadID: threadID) else { return }
        do {
            try Task.checkCancellation()
            var rows: [[String: Any]] = []
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                try Task.checkCancellation()
                var params: [String: Any] = [
                    "threadId": runtimeID,
                    "searchTerm": searchTerm,
                    "limit": 100,
                ]
                if let cursor { params["cursor"] = cursor }
                let response = try await client.request(
                    method: "thread/searchOccurrences",
                    params: params,
                    requiring: .threadContentSearch
                )
                try Task.checkCancellation()
                rows.append(contentsOf: response["data"] as? [[String: Any]] ?? [])
                cursor = response.string("nextCursor")
                if let cursor, !cursor.isEmpty,
                   !seenCursors.insert(cursor).inserted {
                    throw CodexAppServerClientError.malformedResponse("thread/searchOccurrences pagination")
                }
                if cursor?.isEmpty == true { cursor = nil }
            } while cursor != nil

            try Task.checkCancellation()
            let currentTerm = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard searchesMessageContent,
                  currentTerm == searchTerm,
                  selectedThreadID == threadID else { return }
            searchOccurrencesByThreadID[threadID] = rows.compactMap(DesktopThreadSearchOccurrence.parse)
        } catch {
            if error is CancellationError { return }
            capabilities = client.capabilities
            if !client.capabilities.supports(.threadContentSearch) {
                searchesMessageContent = false
            }
        }
    }

    private func scheduleSearchOccurrences(threadID: String, searchTerm: String) {
        searchOccurrencesTask?.cancel()
        searchOccurrencesTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.loadSearchOccurrences(threadID: threadID, searchTerm: searchTerm)
        }
    }

    private func replaceThread(_ thread: DesktopThread) {
        guard Self.workspaceExists(for: thread) else {
            discardThreadFromLoadedCatalog(thread.id)
            return
        }
        switch thread.origin {
        case .veo:
            if let index = threads.firstIndex(where: { $0.id == thread.id }) {
                threads[index] = thread
            }
            if let index = archivedThreads.firstIndex(where: { $0.id == thread.id }) {
                archivedThreads[index] = thread
            }
        case .codex:
            if let index = codexThreads.firstIndex(where: { $0.id == thread.id }) {
                codexThreads[index] = thread
            }
            if let index = archivedCodexThreads.firstIndex(where: { $0.id == thread.id }) {
                archivedCodexThreads[index] = thread
            }
            if let index = searchedThreads?.firstIndex(where: { $0.id == thread.id }) {
                searchedThreads?[index] = thread
            }
        }
    }

    private func upsertThread(_ thread: DesktopThread) {
        guard Self.workspaceExists(for: thread) else {
            discardThreadFromLoadedCatalog(thread.id)
            return
        }
        switch thread.origin {
        case .veo:
            if let index = threads.firstIndex(where: { $0.id == thread.id }) {
                threads[index] = thread
            } else {
                threads.insert(thread, at: 0)
            }
            rebuildCodexMappings()
        case .codex:
            guard showCodexThreads else { return }
            if let index = codexThreads.firstIndex(where: { $0.id == thread.id }) {
                codexThreads[index] = thread
            } else {
                codexThreads.insert(thread, at: 0)
            }
            if let index = searchedThreads?.firstIndex(where: { $0.id == thread.id }) {
                searchedThreads?[index] = thread
            }
        }
    }

    private func updateThreadStatus(
        threadID: String,
        statusObject: [String: Any]
    ) {
        func update(_ rows: inout [DesktopThread]) -> DesktopThread? {
            guard let index = rows.firstIndex(where: { $0.id == threadID }) else { return nil }
            rows[index].status = statusObject.displayString("type")
                ?? statusObject.string("type")
                ?? rows[index].status
            rows[index].activeFlags = statusObject.stringArray("activeFlags")
            return rows[index]
        }
        if let updated = update(&threads) ?? update(&archivedThreads) {
            persistVeoThread(updated, isArchived: archivedThreads.contains(where: { $0.id == threadID }))
            return
        }
        _ = update(&codexThreads)
        _ = update(&archivedCodexThreads)
        if var searchedThreads {
            _ = update(&searchedThreads)
            self.searchedThreads = searchedThreads
        }
    }

    private func threadFamilyIDs(rootedAt rootID: String) -> Set<String> {
        let knownThreads = allKnownThreads
        var family: Set<String> = [rootID]
        var addedChild = true
        while addedChild {
            addedChild = false
            for thread in knownThreads where thread.parentThreadID.map(family.contains) == true {
                if family.insert(thread.id).inserted {
                    addedChild = true
                }
            }
        }
        return family
    }

    private func reconcileArchivedThreadIDs(
        _ threadIDs: Set<String>,
        notificationThread: DesktopThread? = nil
    ) {
        if let selectedThreadID, threadIDs.contains(selectedThreadID) {
            beginNewChat()
        }
        let known = allKnownThreads
        let isVeo = threadIDs.contains(where: { DesktopThreadSelection.parse($0).origin == .veo })
            || notificationThread?.origin == .veo
        if isVeo {
            threads.removeAll(where: { threadIDs.contains($0.id) })
        } else {
            codexThreads.removeAll(where: { threadIDs.contains($0.id) })
            searchedThreads?.removeAll(where: { threadIDs.contains($0.id) })
        }
        for threadID in threadIDs {
            queuedDraftsByThreadID.removeValue(forKey: threadID)
            activeTurnIDByThread.removeValue(forKey: threadID)
            queuedDispatchingThreadIDs.remove(threadID)
            purgePendingRequests(threadID: threadID)
            if let thread = notificationThread?.id == threadID
                ? notificationThread
                : known.first(where: { $0.id == threadID }) {
                if thread.origin == .veo {
                    if let index = archivedThreads.firstIndex(where: { $0.id == threadID }) {
                        archivedThreads[index] = thread
                    } else {
                        archivedThreads.append(thread)
                    }
                } else if showCodexThreads {
                    if let index = archivedCodexThreads.firstIndex(where: { $0.id == threadID }) {
                        archivedCodexThreads[index] = thread
                    } else {
                        archivedCodexThreads.append(thread)
                    }
                }
            }
        }
        rebuildCodexMappings()
        persistInteractionSnapshot()
    }

    private func reconcileUnarchivedThread(
        threadID: String,
        notificationThread: DesktopThread?
    ) {
        let origin = notificationThread?.origin ?? DesktopThreadSelection.parse(threadID).origin
        if origin == .veo {
            archivedThreads.removeAll(where: { $0.id == threadID })
            if let notificationThread {
                upsertThread(notificationThread)
            } else {
                Task { await loadVeoThreadsFromStore() }
            }
        } else {
            archivedCodexThreads.removeAll(where: { $0.id == threadID })
            if let notificationThread {
                upsertThread(notificationThread)
            } else if showCodexThreads {
                Task { await loadThreads() }
            }
        }
    }

    private func reconcileDeletedThreadIDs(_ threadIDs: Set<String>) {
        if let selectedThreadID, threadIDs.contains(selectedThreadID) {
            beginNewChat()
        }
        threads.removeAll(where: { threadIDs.contains($0.id) })
        archivedThreads.removeAll(where: { threadIDs.contains($0.id) })
        codexThreads.removeAll(where: { threadIDs.contains($0.id) })
        archivedCodexThreads.removeAll(where: { threadIDs.contains($0.id) })
        searchedThreads?.removeAll(where: { threadIDs.contains($0.id) })
        for threadID in threadIDs {
            removeThreadLocalState(threadID)
        }
        rebuildCodexMappings()
    }

    private func removeThreadLocalState(_ threadID: String) {
        draftsByContextID.removeValue(forKey: "thread:\(threadID)")
        attachmentsByContextID.removeValue(forKey: "thread:\(threadID)")
        queuedDraftsByThreadID.removeValue(forKey: threadID)
        activeTurnIDByThread.removeValue(forKey: threadID)
        queuedDispatchingThreadIDs.remove(threadID)
        tokenUsageByThreadID.removeValue(forKey: threadID)
        turnDiffByThreadID.removeValue(forKey: threadID)
        searchOccurrencesByThreadID.removeValue(forKey: threadID)
        searchSnippetByThreadID.removeValue(forKey: threadID)
        agentStateByThreadID.removeValue(forKey: threadID)
        planModeThreadIDs.remove(threadID)
        defaults.set(Array(planModeThreadIDs), forKey: "VeoDesktop.planModeThreadIDs")
        purgePendingRequests(threadID: threadID)
        persistInteractionSnapshot()
    }

    private func prepareAndResumeSelectedThread(_ uiThreadID: String, loadGeneration: UUID) async {
        guard selectedThreadID == uiThreadID,
              timelineLoadGeneration == loadGeneration,
              let thread = findThread(uiThreadID) else { return }
        guard Self.workspaceExists(for: thread) else {
            discardThreadFromLoadedCatalog(uiThreadID)
            return
        }

        isLoadingTimeline = true
        defer {
            if timelineLoadGeneration == loadGeneration {
                isLoadingTimeline = false
            }
        }

        if thread.origin == .veo {
            do {
                let localItems = try await threadStore.loadTimelineItems(veoID: uiThreadID)
                guard selectedThreadID == uiThreadID,
                      timelineLoadGeneration == loadGeneration else { return }
                timeline = localItems
                for item in timeline {
                    mergeAgentStates(item.agentStates)
                }
            } catch {
                guard selectedThreadID == uiThreadID,
                      timelineLoadGeneration == loadGeneration else { return }
                transientError = "Could not load local timeline: \(error.localizedDescription)"
            }
        }

        guard let runtimeID = thread.runtimeThreadID else {
            if let turnID = activeTurnIDByThread[uiThreadID] {
                activeTurnID = turnID
                isRunningTurn = true
            }
            return
        }
        guard runtimeState.isReady else { return }
        await resumeThread(uiThreadID: uiThreadID, runtimeID: runtimeID, loadGeneration: loadGeneration)
    }

    private func resumeThread(uiThreadID: String, runtimeID: String, loadGeneration: UUID) async {
        do {
            var params: [String: Any] = [
                "threadId": runtimeID,
                "approvalPolicy": accessMode.approvalPolicyValue,
                "sandbox": accessMode.sandboxValue,
            ]
            if let model = selectedModel?.model { params["model"] = model }
            if let tier = selectedServiceTier { params["serviceTier"] = tier }
            let response = try await client.request(
                method: "thread/resume",
                params: params
            )
            guard timelineLoadGeneration == loadGeneration,
                  selectedThreadID == uiThreadID else { return }
            let threadObject = response["thread"] as? [String: Any]
            if let threadObject {
                if let existing = findThread(uiThreadID), existing.origin == .veo {
                    let updated = DesktopThread.makeVeo(
                        id: existing.selection.bareID,
                        // Veo owns its display title, including model-powered auto naming.
                        title: existing.title,
                        preview: threadObject.string("preview") ?? existing.preview,
                        cwd: threadObject.string("cwd") ?? existing.cwd,
                        updatedAt: existing.updatedAt,
                        status: threadObject.displayString("status") ?? existing.status,
                        isPinned: existing.isPinned,
                        codexThreadId: existing.codexThreadId ?? runtimeID,
                        parentThreadID: existing.parentThreadID,
                        agentNickname: existing.agentNickname,
                        agentRole: existing.agentRole,
                        canAcceptDirectInput: existing.canAcceptDirectInput,
                        activeFlags: (threadObject["status"] as? [String: Any])?.stringArray("activeFlags")
                            ?? existing.activeFlags,
                        agentDepth: existing.agentDepth,
                        sessionID: threadObject.string("sessionId") ?? existing.sessionID,
                        workspaceKind: existing.workspaceKind
                    )
                    replaceThread(updated)
                    persistVeoThread(updated, isArchived: archivedThreads.contains(where: { $0.id == uiThreadID }))
                    if let turns = threadObject["turns"] as? [[String: Any]] {
                        try? await threadStore.replaceTimeline(veoID: uiThreadID, turns: turns)
                    }
                } else if let resumedThread = DesktopThread.parse(threadObject, origin: .codex) {
                    upsertThread(resumedThread)
                }
            }
            hydrateTimeline(from: threadObject)
            await applyActiveThreadSettings(threadID: uiThreadID)
            guard timelineLoadGeneration == loadGeneration,
                  selectedThreadID == uiThreadID else { return }
            await loadGoal(threadID: uiThreadID)
            guard timelineLoadGeneration == loadGeneration,
                  selectedThreadID == uiThreadID else { return }
            transientError = nil
        } catch {
            guard timelineLoadGeneration == loadGeneration,
                  selectedThreadID == uiThreadID else { return }
            transientError = error.localizedDescription
        }
    }

    private func send(
        _ payload: DesktopComposerPayload,
        to requestedThreadID: String?,
        fromQueue: Bool = false,
        queuedUnder initialQueueKey: String? = nil,
        newChatGenerationID originNewChatGenerationID: UUID? = nil,
        inFlightAlreadyReserved: Bool = false
    ) async {
        // The user may switch threads while this is in flight; only the pane that owns
        // this turn may write turn state back into the UI.
        // `requestedThreadID` / ownership keys are UI ids (`veo:…` / `codex:…`).
        let originUIThreadID = requestedThreadID
        var targetUIThreadID = originUIThreadID
        let newChatDraftContext = initialQueueKey ?? currentDraftContextID
        var deliveryQueueKey = initialQueueKey ?? originUIThreadID
        // Persisted queues must never inherit broader settings from whichever chat
        // happens to be selected when they dispatch. Legacy payloads fail safe.
        let deliveryAccessMode = payload.accessMode ?? .workspace
        let deliveryModel = payload.model
        let deliveryEffort = payload.reasoningEffort
        let deliveryTier = payload.serviceTier
        let ownsInFlightReservation: Bool
        if fromQueue, !inFlightAlreadyReserved {
            guard queuedDeliveryInFlightIDs.insert(payload.id).inserted else { return }
            ownsInFlightReservation = true
        } else {
            ownsInFlightReservation = false
        }
        defer {
            if ownsInFlightReservation {
                queuedDeliveryInFlightIDs.remove(payload.id)
            }
        }

        do {
            let uiThreadID: String
            if let originUIThreadID {
                uiThreadID = originUIThreadID
            } else {
                // Legacy path: create a Veo chat if New Chat somehow had no selection.
                let createdBareID = UUID().uuidString
                let startWorkspacePath = try temporaryWorkspaceService
                    .createWorkspace(forVeoID: createdBareID).path
                let created = DesktopThread.makeVeo(
                    id: createdBareID,
                    cwd: startWorkspacePath,
                    workspaceKind: .projectless
                )
                try await threadStore.upsertThread(created, isArchived: false)
                threads.removeAll(where: { $0.id == created.id })
                threads.insert(created, at: 0)
                rebuildCodexMappings()
                uiThreadID = created.id
                if let sourceQueueKey = deliveryQueueKey,
                   sourceQueueKey != created.id {
                    moveQueuedDraft(payload.id, from: sourceQueueKey, to: created.id)
                    deliveryQueueKey = created.id
                }
                if selectedThreadID == nil,
                   originNewChatGenerationID == newChatGenerationID {
                    saveCurrentDraft()
                    selectedThreadID = created.id
                    defaults.set(created.id, forKey: "VeoDesktop.selectedThreadID")
                    migrateDraftContext(from: newChatDraftContext, to: created.id)
                    restoreDraft()
                }
                if payload.isPlanMode {
                    persistPlanMode(true, threadID: created.id)
                }
            }
            targetUIThreadID = uiThreadID

            guard var thread = findThread(uiThreadID) else {
                throw CodexAppServerClientError.malformedResponse(
                    "Missing local chat metadata for \(uiThreadID)."
                )
            }

            let runtimeID: String
            if let existingRuntimeID = thread.runtimeThreadID {
                runtimeID = existingRuntimeID
            } else {
                guard thread.origin == .veo else {
                    throw CodexAppServerClientError.malformedResponse(
                        "Missing Codex thread id for \(uiThreadID)."
                    )
                }
                var startParams: [String: Any] = [
                    "cwd": thread.cwd,
                    "approvalPolicy": deliveryAccessMode.approvalPolicyValue,
                    "sandbox": deliveryAccessMode.sandboxValue,
                ]
                if let deliveryModel { startParams["model"] = deliveryModel }
                if let deliveryTier { startParams["serviceTier"] = deliveryTier }
                let response = try await client.request(
                    method: "thread/start",
                    params: startParams
                )
                guard let started = response["thread"] as? [String: Any],
                      let createdRuntimeID = started.string("id") else {
                    throw CodexAppServerClientError.malformedResponse("thread/start")
                }
                runtimeID = createdRuntimeID
                try await threadStore.setCodexThreadID(veoID: uiThreadID, codexThreadID: runtimeID)
                thread.codexThreadId = runtimeID
                replaceThread(thread)
                rebuildCodexMappings()
            }

            let targetWorkspacePath = try workspacePath(for: uiThreadID)
            try validateAttachments(
                payload.attachments,
                workspacePath: targetWorkspacePath,
                accessMode: deliveryAccessMode
            )

            if selectedThreadID == uiThreadID {
                try await prepareGoalIfNeeded(threadID: uiThreadID, objective: payload.trimmedText)
            }

            if selectedThreadID == uiThreadID {
                if fromQueue {
                    isSubmittingTurn = true
                    upsertOptimisticUser(payload, turnID: nil)
                }
                isRunningTurn = true
                transientError = nil
            }
            if thread.origin == .veo, selectedThreadID == uiThreadID {
                persistOptimisticUserItem(payload, veoID: uiThreadID)
            }
            var turnParams: [String: Any] = [
                "threadId": runtimeID,
                "input": payload.protocolInput,
                "clientUserMessageId": payload.id,
                "approvalPolicy": deliveryAccessMode.approvalPolicyValue,
                "cwd": targetWorkspacePath,
                "sandboxPolicy": deliveryAccessMode.sandboxPolicy(workspacePath: targetWorkspacePath),
            ]
            if let deliveryModel { turnParams["model"] = deliveryModel }
            if let deliveryEffort { turnParams["effort"] = deliveryEffort }
            if let deliveryTier { turnParams["serviceTier"] = deliveryTier }
            if let collaborationMode = collaborationModePayload(
                model: deliveryModel,
                reasoningEffort: deliveryEffort,
                isPlanMode: payload.isPlanMode
            ) {
                turnParams["collaborationMode"] = collaborationMode
            }
            let response = try await client.request(
                method: "turn/start",
                params: turnParams
            )
            if let turn = response["turn"] as? [String: Any],
               let turnID = turn.string("id") {
                activeTurnIDByThread[uiThreadID] = turnID
                if selectedThreadID == uiThreadID {
                    activeTurnID = turnID
                }
            }
            if fromQueue {
                removeQueuedDraft(payload.id, queueKey: deliveryQueueKey ?? uiThreadID)
            }
            if selectedThreadID == uiThreadID {
                isSubmittingTurn = false
            }
        } catch {
            let ownsVisiblePane: Bool
            if let targetUIThreadID {
                ownsVisiblePane = selectedThreadID == targetUIThreadID
            } else {
                ownsVisiblePane = selectedThreadID == nil
                    && originNewChatGenerationID == newChatGenerationID
            }
            if ownsVisiblePane {
                isSubmittingTurn = false
            }
            guard ownsVisiblePane else {
                refreshThreads()
                return
            }
            isRunningTurn = false
            activeTurnID = nil
            transientError = error.localizedDescription
            timeline.append(DesktopTimelineItem(
                id: "error-\(UUID().uuidString)",
                turnID: nil,
                kind: .error,
                title: "Couldn’t start the turn",
                body: error.localizedDescription,
                status: "failed"
            ))
        }
    }

    private func persistOptimisticUserItem(_ payload: DesktopComposerPayload, veoID: String) {
        let item: [String: Any] = [
            "id": "local-user-\(payload.id)",
            "type": "userMessage",
            "clientId": payload.id,
            "text": payload.trimmedText,
            "status": "complete",
        ]
        Task {
            try? await threadStore.upsertItemJSON(veoID: veoID, item: item, turnID: nil)
        }
    }

    private var currentDraftContextID: String {
        if let selectedThreadID { return "thread:\(selectedThreadID)" }
        let path = workspaceURL?.standardizedFileURL.path ?? "unscoped"
        return "new:\(path)"
    }

    private var currentQueueContextID: String {
        selectedThreadID ?? currentDraftContextID
    }

    private func saveCurrentDraft() {
        draftsByContextID[currentDraftContextID] = draft
        attachmentsByContextID[currentDraftContextID] = attachments
        persistInteractionSnapshot()
    }

    private func restoreDraft() {
        draft = draftsByContextID[currentDraftContextID] ?? ""
        attachments = attachmentsByContextID[currentDraftContextID] ?? []
    }

    private func persistCurrentDraft() {
        draftsByContextID[currentDraftContextID] = draft
        persistInteractionSnapshot()
    }

    private func persistCurrentAttachments() {
        attachmentsByContextID[currentDraftContextID] = attachments
        persistInteractionSnapshot()
    }

    private func migrateDraftContext(from sourceContextID: String, to threadID: String) {
        let targetContextID = "thread:\(threadID)"
        if draftsByContextID[targetContextID] == nil {
            draftsByContextID[targetContextID] = draftsByContextID[sourceContextID] ?? ""
        }
        if attachmentsByContextID[targetContextID] == nil {
            attachmentsByContextID[targetContextID] = attachmentsByContextID[sourceContextID] ?? []
        }
        draftsByContextID.removeValue(forKey: sourceContextID)
        attachmentsByContextID.removeValue(forKey: sourceContextID)
        persistInteractionSnapshot()
    }

    private func persistInteractionSnapshot() {
        let snapshot = DesktopInteractionSnapshot(
            draftsByContextID: draftsByContextID,
            attachmentsByContextID: attachmentsByContextID,
            queuedDraftsByThreadID: queuedDraftsByThreadID
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: "VeoDesktop.interactionSnapshot")
    }

    private func enqueue(_ payload: DesktopComposerPayload, queueKey: String) {
        var queue = queuedDraftsByThreadID[queueKey] ?? []
        guard !queue.contains(where: { $0.id == payload.id }) else { return }
        queue.append(payload)
        queuedDraftsByThreadID[queueKey] = queue
        persistInteractionSnapshot()
    }

    private func removeQueuedDraft(_ id: String, queueKey: String) {
        guard var queue = queuedDraftsByThreadID[queueKey] else { return }
        queue.removeAll(where: { $0.id == id })
        if queue.isEmpty {
            queuedDraftsByThreadID.removeValue(forKey: queueKey)
        } else {
            queuedDraftsByThreadID[queueKey] = queue
        }
        persistInteractionSnapshot()
    }

    private func moveQueuedDraft(_ id: String, from sourceKey: String, to destinationKey: String) {
        guard sourceKey != destinationKey,
              var source = queuedDraftsByThreadID[sourceKey],
              let payload = source.first(where: { $0.id == id }) else { return }
        source.removeAll(where: { $0.id == id })
        if source.isEmpty {
            queuedDraftsByThreadID.removeValue(forKey: sourceKey)
        } else {
            queuedDraftsByThreadID[sourceKey] = source
        }
        var destination = queuedDraftsByThreadID[destinationKey] ?? []
        if !destination.contains(where: { $0.id == id }) {
            destination.append(payload)
            queuedDraftsByThreadID[destinationKey] = destination
        }
        persistInteractionSnapshot()
    }

    private func flushNextQueuedDraft(threadID: String) async {
        guard activeTurnIDByThread[threadID] == nil,
              !queuedDispatchingThreadIDs.contains(threadID),
              let payload = queuedDraftsByThreadID[threadID]?.first else { return }
        queuedDispatchingThreadIDs.insert(threadID)
        defer { queuedDispatchingThreadIDs.remove(threadID) }
        if selectedThreadID == threadID {
            isSubmittingTurn = true
        }
        await send(
            payload,
            to: threadID,
            fromQueue: true,
            queuedUnder: threadID
        )
    }

    private func upsertOptimisticUser(_ payload: DesktopComposerPayload, turnID: String?) {
        guard !timeline.contains(where: { $0.clientID == payload.id }) else { return }
        timeline.append(DesktopTimelineItem(
            id: "local-user-\(payload.id)",
            turnID: turnID,
            clientID: payload.id,
            kind: .user,
            title: "You",
            body: payload.trimmedText,
            attachments: payload.attachments,
            status: "complete"
        ))
    }

    private func workspacePath(for threadID: String?) throws -> String {
        if let threadID, let thread = findThread(threadID) {
            return thread.cwd
        }
        if let threadID {
            throw CodexAppServerClientError.malformedResponse(
                "Missing local workspace metadata for chat \(threadID). Refresh chats before sending."
            )
        }
        guard let workspaceURL else {
            throw CodexAppServerClientError.malformedResponse(
                "Open a project before starting a chat."
            )
        }
        return workspaceURL.path
    }

    private func resolveActiveTurnID(
        threadID: String,
        forceRead: Bool = false
    ) async throws -> String? {
        // `threadID` is the UI id.
        if !forceRead {
            if let turnID = activeTurnIDByThread[threadID] { return turnID }
            if selectedThreadID == threadID, let activeTurnID { return activeTurnID }
        }

        guard let runtimeID = runtimeThreadID(forUIThreadID: threadID) else {
            activeTurnIDByThread.removeValue(forKey: threadID)
            if selectedThreadID == threadID {
                activeTurnID = nil
                isRunningTurn = false
            }
            return nil
        }

        let response = try await client.request(
            method: "thread/read",
            params: ["threadId": runtimeID, "includeTurns": true]
        )
        let thread = response["thread"] as? [String: Any]
        let turns = thread?["turns"] as? [[String: Any]] ?? []
        let runningTurn = turns.reversed().first(where: { turn in
            let status = turn.displayString("status")?.lowercased() ?? ""
            return status.contains("progress") || status.contains("active") || status.contains("running")
        })
        guard let resolvedTurnID = runningTurn?.string("id") else {
            activeTurnIDByThread.removeValue(forKey: threadID)
            if selectedThreadID == threadID {
                activeTurnID = nil
                isRunningTurn = false
            }
            return nil
        }

        activeTurnIDByThread[threadID] = resolvedTurnID
        if selectedThreadID == threadID {
            activeTurnID = resolvedTurnID
            isRunningTurn = true
        }
        return resolvedTurnID
    }

    private func steer(_ payload: DesktopComposerPayload, threadID: String) async {
        guard queuedDeliveryInFlightIDs.insert(payload.id).inserted else { return }
        defer { queuedDeliveryInFlightIDs.remove(payload.id) }
        guard capabilities.supports(.turnSteering) else {
            transientError = "This Codex runtime cannot steer an active turn. The message remains queued."
            return
        }

        do {
            guard let turnID = try await resolveActiveTurnID(threadID: threadID) else {
                await send(
                    payload,
                    to: threadID,
                    fromQueue: true,
                    queuedUnder: threadID,
                    inFlightAlreadyReserved: true
                )
                return
            }
            do {
                try await performSteer(payload, threadID: threadID, turnID: turnID)
            } catch {
                guard shouldRefreshTurn(after: error) else { throw error }
                if let refreshedTurnID = try await resolveActiveTurnID(
                    threadID: threadID,
                    forceRead: true
                ) {
                    try await performSteer(payload, threadID: threadID, turnID: refreshedTurnID)
                } else {
                    await send(
                        payload,
                        to: threadID,
                        fromQueue: true,
                        queuedUnder: threadID,
                        inFlightAlreadyReserved: true
                    )
                    return
                }
            }

            removeQueuedDraft(payload.id, queueKey: threadID)
            if selectedThreadID == threadID {
                upsertOptimisticUser(payload, turnID: activeTurnIDByThread[threadID])
                transientError = nil
            }
        } catch {
            transientError = "Follow-up remains queued: \(error.localizedDescription)"
        }
    }

    private func performSteer(
        _ payload: DesktopComposerPayload,
        threadID: String,
        turnID: String
    ) async throws {
        guard let runtimeID = runtimeThreadID(forUIThreadID: threadID) else {
            throw CodexAppServerClientError.malformedResponse("Missing Codex thread for steer.")
        }
        _ = try await client.request(
            method: "turn/steer",
            params: [
                "threadId": runtimeID,
                "expectedTurnId": turnID,
                "input": payload.protocolInput,
                "clientUserMessageId": payload.id,
            ],
            requiring: .turnSteering
        )
    }

    private func shouldRefreshTurn(after error: Error) -> Bool {
        guard case CodexAppServerClientError.rpc(_, let message) = error else { return false }
        return message.localizedCaseInsensitiveContains("turn")
            && (message.localizedCaseInsensitiveContains("active")
                || message.localizedCaseInsensitiveContains("expected")
                || message.localizedCaseInsensitiveContains("mismatch"))
    }

    private func updateActiveThreadSettings() {
        guard runtimeState.isReady, let threadID = selectedThreadID else { return }
        Task { await applyActiveThreadSettings(threadID: threadID) }
    }

    private func applyActiveThreadSettings(threadID: String) async {
        guard capabilities.supports(.collaborationModes) else { return }
        guard let runtimeID = runtimeThreadID(forUIThreadID: threadID) else { return }
        var params: [String: Any] = [
            "threadId": runtimeID,
            "serviceTier": selectedServiceTier ?? NSNull(),
        ]
        if let model = selectedModel?.model { params["model"] = model }
        if let effort = selectedReasoningEffort { params["effort"] = effort }
        if let collaborationMode = collaborationModePayload() {
            params["collaborationMode"] = collaborationMode
        }

        do {
            _ = try await client.request(
                method: "thread/settings/update",
                params: params,
                requiring: .collaborationModes
            )
        } catch {
            transientError = error.localizedDescription
        }
    }

    private func persistServiceTier(_ tier: String?) {
        if let tier {
            defaults.set(tier, forKey: "VeoDesktop.serviceTier")
        } else {
            defaults.removeObject(forKey: "VeoDesktop.serviceTier")
        }
    }

    private func collaborationModePayload() -> [String: Any]? {
        collaborationModePayload(
            model: selectedModel?.model,
            reasoningEffort: selectedReasoningEffort,
            isPlanMode: isPlanModeEnabled
        )
    }

    private func collaborationModePayload(
        model: String?,
        reasoningEffort: String?,
        isPlanMode: Bool
    ) -> [String: Any]? {
        guard let model else { return nil }

        var settings: [String: Any] = [
            "model": model,
            "developer_instructions": NSNull(),
        ]
        let effort = isPlanMode ? planModeReasoningEffort : reasoningEffort
        if let effort {
            settings["reasoning_effort"] = effort
        }
        return [
            "mode": isPlanMode ? "plan" : "default",
            "settings": settings,
        ]
    }

    private func persistPlanMode(_ enabled: Bool, threadID: String) {
        if enabled {
            planModeThreadIDs.insert(threadID)
        } else {
            planModeThreadIDs.remove(threadID)
        }
        defaults.set(Array(planModeThreadIDs).sorted(), forKey: "VeoDesktop.planModeThreadIDs")
    }

    private func loadGoal(threadID: String) async {
        guard let runtimeID = runtimeThreadID(forUIThreadID: threadID) else {
            if selectedThreadID == threadID {
                isGoalModeEnabled = false
                activeGoalObjective = nil
            }
            return
        }
        do {
            let response = try await client.request(
                method: "thread/goal/get",
                params: ["threadId": runtimeID]
            )
            guard selectedThreadID == threadID else { return }
            hydrateGoal(response["goal"] as? [String: Any])
        } catch {
            guard selectedThreadID == threadID else { return }
            isGoalModeEnabled = false
            activeGoalObjective = nil
        }
    }

    private func prepareGoalIfNeeded(threadID: String, objective: String) async throws {
        guard isGoalModeEnabled, activeGoalObjective == nil else { return }
        guard let runtimeID = runtimeThreadID(forUIThreadID: threadID) else { return }
        let response = try await client.request(
            method: "thread/goal/set",
            params: [
                "threadId": runtimeID,
                "objective": objective,
                "status": "active",
            ]
        )
        guard selectedThreadID == threadID else { return }
        hydrateGoal(response["goal"] as? [String: Any])
    }

    private func refreshSelectedVeoThreadMetadata() {
        guard let selectedThreadID,
              let thread = findThread(selectedThreadID),
              thread.origin == .veo else { return }
        let previewSource = timeline.last(where: { $0.kind == .assistant || $0.kind == .user })?.body
            ?? timeline.last?.body
            ?? thread.preview
        let preview = previewSource.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let titleSeed = timeline.first(where: { $0.kind == .user })?.body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldReplaceTitle = thread.title == "New chat" || thread.title.isEmpty
        let updated = DesktopThread.makeVeo(
            id: thread.selection.bareID,
            title: thread.title,
            preview: preview.isEmpty ? thread.preview : String(preview.prefix(160)),
            cwd: thread.cwd,
            updatedAt: Date(),
            status: thread.status,
            isPinned: thread.isPinned,
            codexThreadId: thread.codexThreadId,
            parentThreadID: thread.parentThreadID,
            agentNickname: thread.agentNickname,
            agentRole: thread.agentRole,
            canAcceptDirectInput: thread.canAcceptDirectInput,
            activeFlags: thread.activeFlags,
            agentDepth: thread.agentDepth,
            sessionID: thread.sessionID,
            workspaceKind: thread.workspaceKind
        )
        replaceThread(updated)
        persistVeoThread(updated, isArchived: archivedThreads.contains(where: { $0.id == updated.id }))
        if shouldReplaceTitle,
           let titleSeed,
           !titleSeed.isEmpty,
           timeline.contains(where: { $0.kind == .assistant && !$0.body.isEmpty }) {
            scheduleAutoTitle(for: updated, fallback: String(titleSeed.prefix(68)))
        }
    }

    private func scheduleAutoTitle(for thread: DesktopThread, fallback: String) {
        guard autoTitleTasksByThreadID[thread.id] == nil else { return }
        guard let model = resolvedUtilityModel else {
            applyAutoTitle(fallback, to: thread.id)
            return
        }

        let transcript = timeline
            .filter { $0.kind == .user || $0.kind == .assistant }
            .prefix(8)
            .map { item in
                let role = item.kind == .user ? "User" : "Assistant"
                return "\(role): \(String(item.body.prefix(700)))"
            }
            .joined(separator: "\n")
        let prompt = """
        Create a concise, specific title for this Veo chat. Describe the actual task, feature, or outcome rather than using generic words like chat, help, request, or conversation. Use plain text wording, 3 to 8 words, with no quotation marks and no ending punctuation.

        Conversation:
        \(transcript)
        """
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "title": ["type": "string", "minLength": 3, "maxLength": 68],
            ],
            "required": ["title"],
        ]
        let threadID = thread.id
        let cwd = thread.cwd
        let modelName = model.model
        autoTitleTasksByThreadID[threadID] = Task { [weak self] in
            guard let self else { return }
            defer { autoTitleTasksByThreadID[threadID] = nil }
            do {
                let output = try await utilityInference.infer(
                    prompt: prompt,
                    outputSchema: schema,
                    model: modelName,
                    effort: DesktopUtilityModelPreferences.reasoningEffort,
                    cwd: cwd
                )
                guard !Task.isCancelled,
                      let object = Self.utilityJSONObject(from: output),
                      let title = object["title"] as? String else { return }
                applyAutoTitle(title, to: threadID)
            } catch {
                guard !Task.isCancelled else { return }
                applyAutoTitle(fallback, to: threadID)
            }
        }
    }

    private func applyAutoTitle(_ proposedTitle: String, to threadID: String) {
        guard let thread = findThread(threadID),
              thread.origin == .veo,
              thread.title == "New chat" || thread.title.isEmpty else { return }
        let normalizedTitle = proposedTitle
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "\"'`")))
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "New chat"
        let title = String(normalizedTitle.prefix(68))
        guard !title.isEmpty, title != "New chat" else { return }
        let updated = DesktopThread.makeVeo(
            id: thread.selection.bareID,
            title: title,
            preview: thread.preview,
            cwd: thread.cwd,
            updatedAt: Date(),
            status: thread.status,
            isPinned: thread.isPinned,
            codexThreadId: thread.codexThreadId,
            parentThreadID: thread.parentThreadID,
            agentNickname: thread.agentNickname,
            agentRole: thread.agentRole,
            canAcceptDirectInput: thread.canAcceptDirectInput,
            activeFlags: thread.activeFlags,
            agentDepth: thread.agentDepth,
            sessionID: thread.sessionID,
            workspaceKind: thread.workspaceKind
        )
        replaceThread(updated)
        persistVeoThread(updated, isArchived: archivedThreads.contains(where: { $0.id == threadID }))
    }

    private func hydrateGoal(_ goal: [String: Any]?) {
        guard let goal,
              goal.string("status")?.lowercased() != "complete" else {
            isGoalModeEnabled = false
            activeGoalObjective = nil
            return
        }
        isGoalModeEnabled = true
        activeGoalObjective = goal.string("objective")
    }

    private func hydrateTimeline(from thread: [String: Any]?) {
        guard let thread else {
            timeline = []
            return
        }
        let turns = thread["turns"] as? [[String: Any]] ?? []
        timeline = turns.flatMap { turn -> [DesktopTimelineItem] in
            let turnID = turn.string("id")
            let items = turn["items"] as? [[String: Any]] ?? []
            return items.compactMap { DesktopTimelineItem.parse($0, turnID: turnID) }
        }
        for item in timeline {
            mergeAgentStates(item.agentStates)
        }

        if let latestTurn = turns.last {
            isSubmittingTurn = false
            isRunningTurn = false
            activeTurnID = nil
            let status = latestTurn.displayString("status")?.lowercased() ?? ""
            if status.contains("progress") || status.contains("active") || status.contains("running") {
                isRunningTurn = true
                activeTurnID = latestTurn.string("id")
                if let selectedThreadID, let activeTurnID {
                    activeTurnIDByThread[selectedThreadID] = activeTurnID
                }
            } else if let selectedThreadID {
                activeTurnIDByThread.removeValue(forKey: selectedThreadID)
            }
        }
    }

    private func recordRuntimeNotice(
        method: String,
        severity: DesktopRuntimeNotice.Severity,
        title: String,
        detail: String
    ) {
        let boundedDetail = detail.count > 1_000 ? String(detail.prefix(999)) + "…" : detail
        let notice = DesktopRuntimeNotice(
            id: "\(method)-\(UUID().uuidString)",
            severity: severity,
            title: title,
            detail: boundedDetail,
            createdAt: Date()
        )
        runtimeNotices.insert(notice, at: 0)
        if runtimeNotices.count > 20 {
            runtimeNotices.removeLast(runtimeNotices.count - 20)
        }
    }

    private func recordProtocolNotice(method: String, params: [String: Any]) {
        let message = params.string("message")
            ?? params.string("detail")
            ?? params.string("reason")
            ?? (params["error"] as? [String: Any])?.string("message")
            ?? Self.compactDisplayValue(params)
        let severity: DesktopRuntimeNotice.Severity = method == "warning"
            || method == "configWarning"
            || method == "guardianWarning"
            || method == "deprecationNotice"
            ? .warning : .info
        let title = Self.displayProtocolName(method)
        recordRuntimeNotice(
            method: method,
            severity: severity,
            title: title,
            detail: message
        )
        if severity == .warning {
            notifications?.showWarning(title: title, detail: message)
        }
    }

    private func appendProtocolActivity(
        method: String,
        params: [String: Any],
        threadID: String?
    ) {
        guard threadID == nil || threadID == selectedThreadID else { return }
        let turnID = params.string("turnId")
        let id = "\(method)-\(turnID ?? UUID().uuidString)"
        let title: String
        let body: String
        let kind: DesktopTimelineItem.Kind
        switch method {
        case "model/safetyBuffering/updated":
            title = "Response safety check"
            body = params.bool("showBufferingUi") == false
                ? "Codex completed a response safety check."
                : "Codex is checking this response before continuing."
            kind = .activity
        case "model/rerouted":
            title = "Model rerouted"
            let from = params.string("fromModel") ?? "the selected model"
            let to = params.string("toModel") ?? "another model"
            let reason = params.string("reason").map { "\n\($0)" } ?? ""
            body = "\(from) → \(to)" + reason
            kind = .activity
        case "model/verification":
            title = "Account verification required"
            body = "Codex requires additional account verification before this turn can continue."
            kind = .error
        case "hook/started":
            title = "Hook started"
            body = (params["run"] as? [String: Any])?.string("name") ?? "Running a configured lifecycle hook."
            kind = .activity
        case "hook/completed":
            title = "Hook completed"
            let run = params["run"] as? [String: Any]
            body = run?.string("statusMessage") ?? run?.string("name") ?? "Lifecycle hook finished."
            kind = .activity
        default:
            return
        }
        let item = DesktopTimelineItem(
            id: id,
            turnID: turnID,
            kind: kind,
            title: title,
            body: body,
            status: method.hasSuffix("started") ? "inProgress" : "completed"
        )
        if let index = timeline.firstIndex(where: { $0.id == id }) {
            timeline[index] = item
        } else {
            timeline.append(item)
        }
        recordRuntimeNotice(method: method, severity: kind == .error ? .error : .info, title: title, detail: body)
    }

    private func handle(_ event: [String: Any], route: CodexAppServerRoute) {
        guard let method = event.string("method"),
              let params = event["params"] as? [String: Any] else { return }

        if method == "serverRequest/resolved",
           let requestID = DesktopRPCRequestID(params["requestId"]) {
            let runtimeID = route.threadID ?? params.string("threadId")
            reconcileResolvedServerRequest(
                rpcID: requestID,
                threadID: runtimeID.map { uiThreadID(forRuntimeThreadID: $0) }
            )
            return
        }
        if method == "command/exec/outputDelta",
           let processID = params.string("processId"),
           interactiveTerminal?.id == processID,
           let encoded = params.string("deltaBase64"),
           let data = Data(base64Encoded: encoded) {
            appendInteractiveTerminalOutput(data, processID: processID)
            if params.bool("capReached") == true {
                interactiveTerminal?.outputWasCapped = true
            }
            return
        }
        if method.hasPrefix("thread/realtime/") {
            handleRealtimeEvent(method: method, params: params)
            return
        }
        if method == "skills/changed" {
            Task {
                await loadSkills()
                await loadAccountResources()
            }
            return
        }
        if method == "account/login/completed" {
            if params.bool("success") == true {
                accountLoginSession = nil
                noteOptimisticChatGPTLogin()
                presentAccountLoginURL(DesktopBrowserChatGPT.loginURL, accountLogin: false)
                Task { await refreshAccountAfterLogin() }
            } else if let session = accountLoginSession {
                accountLoginSession = session.applyingCompletion(params)
                Task { await loadAccountResources() }
            }
            return
        }
        if method == "account/updated" {
            Task { await loadAccountResources() }
            return
        }
        if method == "account/rateLimits/updated" {
            Task { await loadAccountResources() }
            return
        }
        if ["warning", "configWarning", "guardianWarning", "deprecationNotice"].contains(method) {
            recordProtocolNotice(method: method, params: params)
            return
        }
        if method == "mcpServer/oauthLogin/completed" {
            let oauthError = params.string("error")
                ?? (params["error"] as? [String: Any])?.string("message")
            if let oauthError, !oauthError.isEmpty {
                let boundedError = oauthError.count > 500
                    ? String(oauthError.prefix(499)) + "…"
                    : oauthError
                transientError = "MCP authorization failed: \(boundedError)"
            }
            Task { await loadAccountResources() }
            return
        }
        if method == "app/list/updated" {
            Task { await loadAccountResources() }
            return
        }
        if method == "mcpServer/startupStatus/updated"
            || method == "mcpServer/startup"
            || method == "mcpServer/startup/updated" {
            if let runtimeID = route.threadID ?? params.string("threadId") {
                let uiID = uiThreadID(forRuntimeThreadID: runtimeID)
                if uiID != selectedThreadID { return }
            }
            mcpServerStatuses = mcpServerStatuses.map { $0.applyingStartupNotification(params) }
            return
        }

        let runtimeEventThreadID = route.threadID ?? params.string("threadId")
        let eventThreadID = runtimeEventThreadID.map { uiThreadID(forRuntimeThreadID: $0) }
        if let eventThreadID {
            switch method {
            case "thread/started":
                if let object = params["thread"] as? [String: Any] {
                    if veoIDByCodexThreadID[runtimeEventThreadID ?? ""] != nil {
                        // Already bound to a Veo chat — refresh Veo metadata only.
                        refreshThreads()
                    } else if showCodexThreads,
                              let thread = DesktopThread.parse(object, origin: .codex) {
                        upsertThread(thread)
                    }
                }
            case "thread/archived":
                let notificationThread = (params["thread"] as? [String: Any])
                    .flatMap { DesktopThread.parse($0, origin: .codex) }
                reconcileArchivedThreadIDs(
                    threadFamilyIDs(rootedAt: eventThreadID),
                    notificationThread: notificationThread
                )
            case "thread/unarchived":
                let notificationThread = (params["thread"] as? [String: Any])
                    .flatMap { DesktopThread.parse($0, origin: .codex) }
                reconcileUnarchivedThread(
                    threadID: eventThreadID,
                    notificationThread: notificationThread
                )
            case "thread/deleted":
                // Codex deletions should not wipe Veo-owned rows that share a mapping.
                if DesktopThreadSelection.parse(eventThreadID).origin == .codex {
                    reconcileDeletedThreadIDs(threadFamilyIDs(rootedAt: eventThreadID))
                }
            case "thread/status/changed":
                if let status = params["status"] as? [String: Any] {
                    updateThreadStatus(threadID: eventThreadID, statusObject: status)
                }
            case "thread/closed":
                updateThreadStatus(threadID: eventThreadID, statusObject: ["type": "notLoaded"])
            case "turn/started":
                let turn = params["turn"] as? [String: Any]
                if let turnID = turn?.string("id") ?? params.string("turnId") {
                    activeTurnIDByThread[eventThreadID] = turnID
                }
            case "turn/completed":
                let turn = params["turn"] as? [String: Any]
                let completedTurnID = turn?.string("id") ?? params.string("turnId")
                if completedTurnID == nil || activeTurnIDByThread[eventThreadID] == completedTurnID {
                    activeTurnIDByThread.removeValue(forKey: eventThreadID)
                }
                compactingThreadIDs.remove(eventThreadID)
                expirePendingRequests(threadID: eventThreadID, turnID: completedTurnID)
                if !(turn?["error"] is [String: Any]) {
                    Task { await flushNextQueuedDraft(threadID: eventThreadID) }
                }
                announceTurnCompletion(turn: turn, threadID: eventThreadID)
                discardTemporaryChatIfNeeded(leaving: eventThreadID)
            case "thread/tokenUsage/updated":
                if let usageObject = params["tokenUsage"] as? [String: Any],
                   let usage = DesktopTokenUsage.parse(usageObject) {
                    tokenUsageByThreadID[eventThreadID] = usage
                }
            case "turn/diff/updated":
                var state = turnDiffByThreadID[eventThreadID] ?? DesktopTurnDiff()
                state.turnID = params.string("turnId") ?? state.turnID
                state.unifiedDiff = params.string("diff") ?? state.unifiedDiff
                turnDiffByThreadID[eventThreadID] = state
            case "item/started", "item/completed":
                if let item = params["item"] as? [String: Any] {
                    if item.string("type") == "contextCompaction" {
                        if method == "item/started" {
                            compactingThreadIDs.insert(eventThreadID)
                        } else {
                            compactingThreadIDs.remove(eventThreadID)
                        }
                    }
                    if let parsed = DesktopTimelineItem.parse(item, turnID: params.string("turnId")) {
                        mergeAgentStates(parsed.agentStates)
                        if DesktopThreadSelection.parse(eventThreadID).origin == .veo {
                            persistVeoItemJSON(item, veoID: eventThreadID, turnID: params.string("turnId"))
                        }
                    }
                }
            case "thread/compacted":
                compactingThreadIDs.remove(eventThreadID)
            case "item/fileChange/patchUpdated":
                var state = turnDiffByThreadID[eventThreadID] ?? DesktopTurnDiff()
                state.turnID = params.string("turnId") ?? state.turnID
                let changes = params["changes"] as? [[String: Any]] ?? []
                state.files = changes.compactMap(DesktopFilePatch.parse)
                turnDiffByThreadID[eventThreadID] = state
            default:
                break
            }
        }
        if let eventThreadID, eventThreadID != selectedThreadID {
            if method == "turn/completed" || method == "thread/started" {
                refreshThreads()
            }
            return
        }

        switch method {
        case "turn/started":
            let turn = params["turn"] as? [String: Any]
            activeTurnID = turn?.string("id") ?? params.string("turnId") ?? activeTurnID
            isSubmittingTurn = false
            isRunningTurn = true

        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let completedTurnID = turn?.string("id") ?? params.string("turnId")
            if let items = turn?["items"] as? [[String: Any]] {
                let turnID = turn?.string("id") ?? activeTurnID
                for item in items {
                    upsert(item: item, turnID: turnID, uiThreadID: eventThreadID)
                }
            }
            if let turnError = turn?["error"] as? [String: Any],
               let message = turnError.string("message") {
                transientError = message
                let turnID = turn?.string("id") ?? activeTurnID
                let errorItem = DesktopTimelineItem(
                    id: "turn-error-\(turnID ?? UUID().uuidString)",
                    turnID: turnID,
                    kind: .error,
                    title: "Turn failed",
                    body: message,
                    status: "failed"
                )
                if let index = timeline.firstIndex(where: { $0.id == errorItem.id }) {
                    timeline[index] = errorItem
                } else {
                    timeline.append(errorItem)
                }
            }
            let completesActiveTurn = activeTurnID == nil
                || completedTurnID == nil
                || activeTurnID == completedTurnID
            if completesActiveTurn {
                activeTurnID = nil
                isSubmittingTurn = false
                isRunningTurn = false
            }
            refreshThreads()

        case "item/started", "item/completed":
            if let item = params["item"] as? [String: Any] {
                upsert(item: item, turnID: params.string("turnId"), uiThreadID: eventThreadID)
            }

        case "item/mcpToolCall/progress":
            updateToolProgress(
                itemID: params.string("itemId"),
                message: params.string("message")
            )

        case "item/commandExecution/terminalInteraction":
            recordTerminalInteraction(
                itemID: params.string("itemId"),
                processID: params.string("processId")
            )

        case "item/agentMessage/delta":
            appendDelta(
                params.string("delta") ?? "",
                itemID: params.string("itemId"),
                turnID: params.string("turnId"),
                kind: .assistant,
                title: "Codex"
            )

        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            appendDelta(
                params.string("delta") ?? "",
                itemID: params.string("itemId"),
                turnID: params.string("turnId"),
                kind: .reasoning,
                title: "Thinking"
            )

        case "item/reasoning/summaryPartAdded":
            appendDelta(
                "\n\n",
                itemID: params.string("itemId"),
                turnID: params.string("turnId"),
                kind: .reasoning,
                title: "Thinking"
            )

        case "model/safetyBuffering/updated", "model/rerouted", "model/verification",
             "hook/started", "hook/completed":
            appendProtocolActivity(method: method, params: params, threadID: eventThreadID)

        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            appendDelta(
                params.string("delta") ?? "",
                itemID: params.string("itemId"),
                turnID: params.string("turnId"),
                kind: method.contains("commandExecution") ? .command : .fileChange,
                title: method.contains("commandExecution") ? "Command output" : "File changes"
            )

        case "turn/plan/updated":
            updatePlan(params)

        case "item/plan/delta":
            appendDelta(
                params.string("delta") ?? "",
                itemID: params.string("itemId"),
                turnID: params.string("turnId"),
                kind: .plan,
                title: "Plan"
            )

        case "thread/goal/updated":
            hydrateGoal(params["goal"] as? [String: Any])

        case "thread/goal/cleared":
            isGoalModeEnabled = false
            activeGoalObjective = nil

        case "thread/settings/updated":
            if let settings = params["threadSettings"] as? [String: Any],
               let collaborationMode = settings["collaborationMode"] as? [String: Any],
               let mode = collaborationMode.string("mode"),
               let runtimeID = params.string("threadId") {
                let uiID = uiThreadID(forRuntimeThreadID: runtimeID)
                isPlanModeEnabled = mode == "plan"
                persistPlanMode(isPlanModeEnabled, threadID: uiID)
            }

        case "error":
            let errorObject = params["error"] as? [String: Any]
            let message = errorObject?.string("message") ?? params.string("message") ?? "Codex reported an error."
            let details = errorObject?.string("additionalDetails")
            let willRetry = params.bool("willRetry") == true
            transientError = message
            let errorItem = DesktopTimelineItem(
                id: "runtime-error-\(params.string("turnId") ?? UUID().uuidString)",
                turnID: params.string("turnId"),
                kind: .error,
                title: willRetry ? "Codex error — retrying" : "Codex error",
                body: [message, details].compactMap { $0 }.joined(separator: "\n\n"),
                status: willRetry ? "retrying" : "failed"
            )
            if let index = timeline.firstIndex(where: { $0.id == errorItem.id }) {
                timeline[index] = errorItem
            } else {
                timeline.append(errorItem)
            }

        case "thread/name/updated", "thread/started", "thread/status/changed":
            refreshThreads()

        default:
            break
        }
    }

    private func upsert(item: [String: Any], turnID: String?, uiThreadID: String? = nil) {
        guard let parsed = DesktopTimelineItem.parse(item, turnID: turnID) else { return }
        mergeAgentStates(parsed.agentStates)
        if let clientID = parsed.clientID,
           let index = timeline.firstIndex(where: { $0.clientID == clientID }) {
            timeline[index] = mergingTimelineItem(timeline[index], with: parsed)
        } else if let index = timeline.firstIndex(where: { $0.id == parsed.id }) {
            timeline[index] = mergingTimelineItem(timeline[index], with: parsed)
        } else {
            timeline.append(parsed)
        }
        let veoID = uiThreadID ?? selectedThreadID
        if let veoID, DesktopThreadSelection.parse(veoID).origin == .veo {
            persistVeoItemJSON(item, veoID: veoID, turnID: turnID)
        }
    }

    private func persistVeoItemJSON(_ item: [String: Any], veoID: String, turnID: String?) {
        Task {
            try? await threadStore.upsertItemJSON(veoID: veoID, item: item, turnID: turnID)
        }
    }

    private func mergingTimelineItem(
        _ existing: DesktopTimelineItem,
        with incoming: DesktopTimelineItem
    ) -> DesktopTimelineItem {
        var merged = incoming
        if merged.clientID == nil { merged.clientID = existing.clientID }
        if merged.body.isEmpty
            || (merged.kind == .command && merged.body.hasPrefix("Running in ")) {
            merged.body = existing.body
        }
        if merged.detail == nil { merged.detail = existing.detail }
        if merged.attachments.isEmpty { merged.attachments = existing.attachments }
        if merged.status == nil { merged.status = existing.status }
        merged.agentStates = existing.agentStates.merging(merged.agentStates) { _, latest in latest }
        if var metadata = merged.toolMetadata {
            if metadata.status == .inProgress, metadata.progressMessage == nil {
                metadata.progressMessage = existing.toolMetadata?.progressMessage
            }
            merged.toolMetadata = metadata
        } else {
            merged.toolMetadata = existing.toolMetadata
        }
        var seenArtifactIDs = Set<String>()
        merged.artifacts = (existing.artifacts + merged.artifacts).filter {
            seenArtifactIDs.insert($0.id).inserted
        }
        if merged.citations.isEmpty { merged.citations = existing.citations }
        var seenTerminalInteractions = Set<String>()
        merged.terminalInteractions = (existing.terminalInteractions + merged.terminalInteractions)
            .filter { seenTerminalInteractions.insert($0).inserted }
        return merged
    }

    private func handleRealtimeEvent(method: String, params: [String: Any]) {
        guard let runtimeID = params.string("threadId") else { return }
        let uiID = uiThreadID(forRuntimeThreadID: runtimeID)
        guard realtimeSession?.threadID == uiID else { return }
        switch method {
        case "thread/realtime/started":
            if let session = realtimeSession {
                realtimeSession = session.applyingStarted(params)
            }
        case "thread/realtime/transcript/delta":
            appendRealtimeTranscript(params.string("delta") ?? "")
        case "thread/realtime/transcript/done":
            if let text = params.string("text"), !text.isEmpty,
               !realtimeTranscript.hasSuffix(text) {
                appendRealtimeTranscript(text, startsNewSegment: true)
            }
        case "thread/realtime/outputAudio/delta":
            guard let audio = params["audio"] as? [String: Any],
                  let data = audio.string("data"),
                  let sampleRate = audio.number("sampleRate").map(Int.init),
                  let channels = audio.number("numChannels").map(Int.init) else { return }
            _ = realtimeAudio.enqueuePlayback(
                base64PCM: data,
                sampleRate: sampleRate,
                numChannels: channels
            )
        case "thread/realtime/itemAdded":
            if let item = params["item"] as? [String: Any], selectedThreadID == uiID {
                upsert(item: item, turnID: activeTurnID, uiThreadID: uiID)
            }
        case "thread/realtime/error":
            stopRealtimeVoice(
                preservingError: params.string("message") ?? "Realtime voice failed."
            )
        case "thread/realtime/closed":
            realtimeAudio.stop()
            pendingRealtimeAudioChunks = []
            realtimeSession = nil
            realtimeTranscript = ""
        default:
            break
        }
    }

    private func appendRealtimeTranscript(
        _ text: String,
        startsNewSegment: Bool = false
    ) {
        guard !text.isEmpty else { return }
        if startsNewSegment, !realtimeTranscript.isEmpty {
            realtimeTranscript += "\n"
        }
        realtimeTranscript += text
        let maximumCharacters = 65_536
        if realtimeTranscript.count > maximumCharacters {
            realtimeTranscript = "[Earlier realtime transcript omitted]\n"
                + String(realtimeTranscript.suffix(maximumCharacters - 40))
        }
    }

    private func mergeAgentStates(_ states: [String: DesktopAgentState]) {
        guard !states.isEmpty else { return }
        for (threadID, state) in states {
            agentStateByThreadID[threadID] = state
        }
    }

    private func updateToolProgress(itemID: String?, message: String?) {
        guard let itemID, let message,
              let index = timeline.firstIndex(where: { $0.id == itemID }) else { return }
        if let metadata = timeline[index].toolMetadata {
            timeline[index].toolMetadata = metadata.applyingProgress([
                "itemId": itemID,
                "message": message,
            ])
        }
        timeline[index].body = message
    }

    private func recordTerminalInteraction(itemID: String?, processID: String?) {
        guard let itemID,
              let index = timeline.firstIndex(where: { $0.id == itemID }) else { return }
        let label = processID.map { "Input sent to process \($0)" } ?? "Input sent to terminal"
        // Never retain the stdin payload: terminal input can contain passwords or tokens.
        if !timeline[index].terminalInteractions.contains(label) {
            timeline[index].terminalInteractions.append(label)
        }
    }

    func navigateToSearchOccurrence(_ occurrence: DesktopThreadSearchOccurrence) {
        guard let threadID = selectedThreadID else { return }
        if timeline.contains(where: { $0.id == occurrence.itemID }) {
            timelineNavigationItemID = occurrence.itemID
            return
        }
        Task {
            do {
                guard let runtimeID = runtimeThreadID(forUIThreadID: threadID) else {
                    throw CodexAppServerClientError.malformedResponse("Missing Codex thread for search navigation.")
                }
                let response = try await client.request(
                    method: "thread/turns/list",
                    params: [
                        "threadId": runtimeID,
                        "cursor": occurrence.turnCursor,
                        "limit": 1,
                        "itemsView": "full",
                    ],
                    maturity: .experimental
                )
                guard selectedThreadID == threadID else { return }
                let turns = response["data"] as? [[String: Any]] ?? []
                for turn in turns {
                    let turnID = turn.string("id")
                    for item in turn["items"] as? [[String: Any]] ?? [] {
                        upsert(item: item, turnID: turnID, uiThreadID: threadID)
                    }
                }
            } catch {
                let loadGeneration = UUID()
                timelineLoadGeneration = loadGeneration
                await prepareAndResumeSelectedThread(threadID, loadGeneration: loadGeneration)
            }
            guard selectedThreadID == threadID,
                  timeline.contains(where: { $0.id == occurrence.itemID }) else {
                transientError = "That search match is not available in the loaded history."
                return
            }
            timelineNavigationItemID = occurrence.itemID
        }
    }

    func consumeTimelineNavigation() {
        timelineNavigationItemID = nil
    }

    private func appendDelta(
        _ delta: String,
        itemID: String?,
        turnID: String?,
        kind: DesktopTimelineItem.Kind,
        title: String
    ) {
        guard !delta.isEmpty else { return }
        guard isRunningTurn || isSubmittingTurn else { return }
        if let activeTurnID, let turnID, activeTurnID != turnID { return }
        let id = itemID ?? "stream-\(kind.rawValue)-\(turnID ?? "active")"
        if let index = timeline.firstIndex(where: { $0.id == id }) {
            if kind == .command, timeline[index].body.hasPrefix("Running in ") {
                timeline[index].body = delta
            } else {
                timeline[index].body += delta
            }
            if kind == .reasoning {
                timeline[index].status = "inProgress"
            }
        } else {
            timeline.append(DesktopTimelineItem(
                id: id,
                turnID: turnID,
                kind: kind,
                title: title,
                body: delta,
                status: "inProgress"
            ))
        }
    }

    private func updatePlan(_ params: [String: Any]) {
        let turnID = params.string("turnId")
        let steps = params["plan"] as? [[String: Any]] ?? []
        let body = steps.compactMap { step -> String? in
            guard let text = step.string("step") else { return nil }
            let marker: String
            switch step.string("status") {
            case "completed": marker = "✓"
            case "inProgress": marker = "→"
            default: marker = "○"
            }
            return "\(marker) \(text)"
        }.joined(separator: "\n")
        let explanation = params.string("explanation")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [explanation, body].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: "\n\n")
        guard !combined.isEmpty else { return }

        let item = DesktopTimelineItem(
            id: "turn-plan-\(turnID ?? "active")",
            turnID: turnID,
            kind: .plan,
            title: "Plan",
            body: combined,
            status: steps.allSatisfy { $0.string("status") == "completed" } ? "completed" : "inProgress"
        )
        if let index = timeline.firstIndex(where: { $0.id == item.id }) {
            timeline[index] = item
        } else {
            timeline.append(item)
        }
    }

    /// Foundation JSON arrays often fail `as? [[String: Any]]`; bridge element-wise.
    private static func jsonObjectArray(_ value: Any?) -> [[String: Any]] {
        if let rows = value as? [[String: Any]] { return rows }
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { row in
            if let object = row as? [String: Any] { return object }
            if let object = row as? NSDictionary {
                return object as? [String: Any]
            }
            return nil
        }
    }
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
