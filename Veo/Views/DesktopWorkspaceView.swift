// FILE: DesktopWorkspaceView.swift
// Purpose: Renders the native macOS workspace: all-repo sidebar, conversation timeline, composer, and inspector.
// Layer: Desktop app view
// Depends on: SwiftUI, AppKit, DesktopCodexStore

import AppKit
import SwiftUI

enum DesktopTheme {
    static let accent = Color(red: 0.18, green: 0.55, blue: 0.98)
    static let sidebarWidth: CGFloat = 318
    static let sidebarTitlebarClearance: CGFloat = 34
    static let conversationWidth: CGFloat = 820
    static let welcomeWidth: CGFloat = 680
    static let canvas = Color(red: 0.075, green: 0.078, blue: 0.082)
    static let sidebar = Color(red: 0.105, green: 0.108, blue: 0.114)
    static let raised = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.09)
    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat = 8
    static let spaceM: CGFloat = 12
    static let spaceL: CGFloat = 16
    static let spaceXL: CGFloat = 24
    static let radiusCard: CGFloat = 11
    static let radiusControl: CGFloat = 8
}

struct DesktopWorkspaceView: View {
    @ObservedObject var store: DesktopCodexStore
    @ObservedObject var navigation: DesktopNavigationState
    @AppStorage("VeoDesktop.inspectorVisible") private var inspectorVisible = false
    @StateObject private var terminalHub = DesktopLocalTerminalHub()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsChanges = false
    @State private var showsInteractiveTerminal = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Group {
                if navigation.page == .settings {
                    DesktopSettingsSidebarView(navigation: navigation)
                } else {
                    DesktopSidebarView(store: store) {
                        navigation.showSettings()
                    }
                }
            }
                .navigationSplitViewColumnWidth(min: 236, ideal: DesktopTheme.sidebarWidth, max: 360)
        } detail: {
            if navigation.page == .settings {
                DesktopSettingsPage(store: store, navigation: navigation)
            } else {
                DesktopConversationView(
                    store: store,
                    terminalHub: terminalHub,
                    showsInteractiveTerminal: $showsInteractiveTerminal
                )
                    .inspector(isPresented: $inspectorVisible) {
                        DesktopInspectorView(store: store)
                            .inspectorColumnWidth(min: 250, ideal: 286, max: 380)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 920, minHeight: 640)
        .tint(DesktopTheme.accent)
        .task {
            store.startIfNeeded()
        }
        .sheet(item: $store.pendingRequest) { request in
            DesktopPendingRequestView(request: request, store: store)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showsChanges) {
            DesktopDiffView(store: store)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.shutDown()
        }
        .toolbar {
            if navigation.page == .workspace {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        store.beginNewChat()
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    .help("New chat (⌘N)")

                    Button {
                        store.revealWorkspace()
                    } label: {
                        Label("Reveal project", systemImage: "folder")
                    }
                    .help("Reveal project in Finder")
                    .disabled(!store.hasExplicitWorkspace)

                    Button {
                        inspectorVisible.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    .help("Toggle inspector (⌘⌥I)")
                    .keyboardShortcut("i", modifiers: [.command, .option])

                    Button {
                        showsChanges = true
                    } label: {
                        Label("Changes", systemImage: "doc.text.magnifyingglass")
                    }
                    .help("Review repository and live turn changes")
                    .disabled(!store.hasExplicitWorkspace && store.selectedTurnDiff?.isEmpty != false)

                    Button {
                        showsInteractiveTerminal.toggle()
                    } label: {
                        Label("Terminal", systemImage: "terminal")
                    }
                    .help(showsInteractiveTerminal ? "Hide terminal panel" : "Show project terminal panel")
                    .keyboardShortcut("`", modifiers: .control)
                    .disabled(!store.hasExplicitWorkspace)
                }
            }
        }
        .onChange(of: store.hasExplicitWorkspace) { _, hasWorkspace in
            if !hasWorkspace {
                showsInteractiveTerminal = false
                terminalHub.terminateAll()
            }
        }
        .background {
            if navigation.page == .workspace {
                DesktopToolbarTrailingSpacerBridge()
            }
        }
    }
}

/// `NavigationSplitView` keeps its own flexible toolbar space on the sidebar
/// side of the divider, even for `.primaryAction` items. Maintain a second
/// native flexible space on the detail side so these actions stay trailing.
private struct DesktopToolbarTrailingSpacerBridge: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ToolbarWindowReaderView {
        let view = ToolbarWindowReaderView()
        view.onWindowChange = context.coordinator.attach
        view.onLayout = context.coordinator.refresh
        return view
    }

    func updateNSView(_ nsView: ToolbarWindowReaderView, context: Context) {
        guard let window = nsView.window else { return }
        context.coordinator.attach(to: window)
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var updateObserver: NSObjectProtocol?
        private var pendingRefresh: DispatchWorkItem?
        private var settlingWork: [DispatchWorkItem] = []

        func attach(to window: NSWindow) {
            guard self.window !== window else {
                refresh()
                return
            }

            if let updateObserver {
                NotificationCenter.default.removeObserver(updateObserver)
            }
            pendingRefresh?.cancel()
            settlingWork.forEach { $0.cancel() }
            settlingWork.removeAll()

            self.window = window
            updateObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }

            scheduleAlignment(after: 0)
            scheduleAlignment(after: 0.15)
            scheduleAlignment(after: 0.5)
        }

        func refresh() {
            pendingRefresh?.cancel()
            let work = alignmentWorkItem()
            pendingRefresh = work
            DispatchQueue.main.async(execute: work)
        }

        private func scheduleAlignment(after delay: TimeInterval) {
            let work = alignmentWorkItem()
            settlingWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func alignmentWorkItem() -> DispatchWorkItem {
            DispatchWorkItem { [weak self] in
                guard let window = self?.window else { return }
                Self.alignActions(in: window)
            }
        }

        private static func alignActions(in window: NSWindow) {
            guard let toolbar = window.toolbar else { return }
            let separatorPrefix = "com.apple.SwiftUI.splitViewSeparator"
            guard let separatorIndex = toolbar.items.firstIndex(where: {
                $0.itemIdentifier.rawValue.hasPrefix(separatorPrefix)
            }) else { return }

            let flexibleSpace = NSToolbarItem.Identifier.flexibleSpace
            let insertionIndex = separatorIndex + 1
            if toolbar.items.indices.contains(insertionIndex),
               toolbar.items[insertionIndex].itemIdentifier == flexibleSpace {
                return
            }

            // Preserve NavigationSplitView's leading spacer. If a prior toolbar
            // rebuild left our trailing spacer elsewhere, move that one back.
            if let misplacedIndex = toolbar.items.indices.last(where: {
                $0 > separatorIndex && toolbar.items[$0].itemIdentifier == flexibleSpace
            }) {
                toolbar.removeItem(at: misplacedIndex)
            }

            guard let updatedSeparatorIndex = toolbar.items.firstIndex(where: {
                $0.itemIdentifier.rawValue.hasPrefix(separatorPrefix)
            }) else { return }
            toolbar.insertItem(withItemIdentifier: flexibleSpace, at: updatedSeparatorIndex + 1)
        }

        deinit {
            pendingRefresh?.cancel()
            settlingWork.forEach { $0.cancel() }
            if let updateObserver {
                NotificationCenter.default.removeObserver(updateObserver)
            }
        }
    }
}

private final class ToolbarWindowReaderView: NSView {
    var onWindowChange: ((NSWindow) -> Void)?
    var onLayout: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        onWindowChange?(window)
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private struct DesktopPendingRequestView: View {
    let request: DesktopPendingRequest
    @ObservedObject var store: DesktopCodexStore
    @State private var selections: [String: String] = [:]
    @State private var customAnswers: [String: String] = [:]
    @State private var mcpValues: [String: String] = [:]

    private var canSubmitAnswers: Bool {
        request.questions.allSatisfy { question in
            let custom = customAnswers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !custom.isEmpty || selections[question.id] != nil
        }
    }

    private var canSubmitMCPForm: Bool {
        request.mcpFields.allSatisfy { field in
            let value = (mcpValues[field.id] ?? field.defaultValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !field.isRequired || !value.isEmpty else { return false }
            if field.valueKind == .number { return value.isEmpty || Double(value) != nil }
            if field.valueKind == .integer { return value.isEmpty || Int(value) != nil }
            return true
        }
    }

    private var hasSecureMCPURL: Bool {
        guard request.mcpMode == "url",
              let rawURL = request.detail,
              let url = URL(string: rawURL) else { return false }
        return url.scheme?.lowercased() == "https"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: request.kind == .userInput ? "questionmark.bubble.fill" : "checkmark.shield.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(DesktopTheme.accent)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(request.title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(request.message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let context = store.contextDescription(for: request) {
                        Label(context, systemImage: "text.bubble")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(22)

            Divider()

            if request.kind == .userInput {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(request.questions) { question in
                            questionView(question)
                        }
                    }
                    .padding(22)
                }
                .frame(maxHeight: 440)
            } else if request.kind == .mcpElicitation, request.mcpMode == "form" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if request.mcpFields.isEmpty {
                            Label("No additional information is required.", systemImage: "checkmark.circle")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(request.mcpFields) { field in
                                mcpFieldView(field)
                            }
                        }
                    }
                    .padding(22)
                }
                .frame(maxHeight: 440)
            } else if let detail = request.detail, !detail.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(14)
                }
                .frame(maxHeight: 260)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(22)
            }

            Divider()

            HStack {
                if request.kind == .userInput {
                    Button("Skip") {
                        store.resolvePendingRequest(approved: false)
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Continue") {
                        submitAnswers()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmitAnswers)
                    .keyboardShortcut(.defaultAction)
                } else if request.kind == .mcpElicitation {
                    Button("Decline") {
                        store.resolvePendingRequest(approved: false)
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    if request.mcpMode == "url" {
                        Button("Open Secure Link") {
                            store.openPendingMCPURL()
                        }
                        .disabled(!hasSecureMCPURL)
                        Button("Continue") {
                            store.acceptPendingMCPURL()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasSecureMCPURL)
                        .keyboardShortcut(.defaultAction)
                    } else if request.mcpMode == "form" {
                        Button("Submit") {
                            store.submitMCPForm(mcpValues)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmitMCPForm)
                        .keyboardShortcut(.defaultAction)
                    }
                } else if request.kind == .permissionApproval {
                    Button("Decline") {
                        store.resolvePendingRequest(approved: false)
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Allow for Session") {
                        store.resolvePendingRequest(approved: true, forSession: true)
                    }
                    Button("Allow Once") {
                        store.resolvePendingRequest(approved: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    ForEach(request.approvalDecisions) { decision in
                        if decision.intent == .approve {
                            Button(decision.title) {
                                store.resolvePendingApproval(decision)
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button(decision.title, role: .destructive) {
                                store.resolvePendingApproval(decision)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 540)
        .tint(DesktopTheme.accent)
    }

    @ViewBuilder
    private func questionView(_ question: DesktopRequestQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.header.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(DesktopTheme.accent)
                .tracking(0.7)
            Text(question.prompt)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(question.options) { option in
                        Button {
                            selections[question.id] = option.label
                            customAnswers[question.id] = ""
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: selections[question.id] == option.label ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selections[question.id] == option.label ? DesktopTheme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.system(size: 12.5, weight: .semibold))
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            if question.allowsOther || question.options.isEmpty {
                Group {
                    if question.isSecret {
                        SecureField(question.options.isEmpty ? "Answer" : "Other answer", text: answerBinding(for: question.id))
                    } else {
                        TextField(question.options.isEmpty ? "Answer" : "Other answer", text: answerBinding(for: question.id), axis: .vertical)
                            .lineLimit(1...4)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private func mcpFieldView(_ field: DesktopMCPFormField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text(field.title)
                    .font(.system(size: 13, weight: .semibold))
                if field.isRequired {
                    Text("Required")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(DesktopTheme.accent)
                }
            }
            if !field.detail.isEmpty {
                Text(field.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if field.valueKind == .stringArray, !field.options.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(field.options, id: \.self) { option in
                        Toggle(option, isOn: mcpMultiChoiceBinding(for: field, option: option))
                    }
                }
                .toggleStyle(.checkbox)
            } else if !field.options.isEmpty {
                Picker(field.title, selection: mcpBinding(for: field)) {
                    if !field.isRequired {
                        Text("Not set").tag("")
                    }
                    ForEach(field.options, id: \.self) { option in
                        Text(option.capitalized).tag(option)
                    }
                }
                .labelsHidden()
            } else if field.isSecret {
                SecureField(field.title, text: mcpBinding(for: field))
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(
                    field.valueKind == .stringArray ? "Comma-separated values" : field.title,
                    text: mcpBinding(for: field)
                )
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func mcpBinding(for field: DesktopMCPFormField) -> Binding<String> {
        Binding(
            get: { mcpValues[field.id] ?? field.defaultValue },
            set: { mcpValues[field.id] = $0 }
        )
    }

    private func mcpMultiChoiceBinding(
        for field: DesktopMCPFormField,
        option: String
    ) -> Binding<Bool> {
        Binding(
            get: {
                Set((mcpValues[field.id] ?? field.defaultValue)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .contains(option)
            },
            set: { selected in
                var values = (mcpValues[field.id] ?? field.defaultValue)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if selected {
                    if !values.contains(option) { values.append(option) }
                } else {
                    values.removeAll(where: { $0 == option })
                }
                mcpValues[field.id] = values.joined(separator: ", ")
            }
        )
    }

    private func answerBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { customAnswers[questionID, default: ""] },
            set: { value in
                customAnswers[questionID] = value
                if !value.isEmpty {
                    selections[questionID] = nil
                }
            }
        )
    }

    private func submitAnswers() {
        let answers = request.questions.reduce(into: [String: [String]]()) { result, question in
            let custom = customAnswers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !custom.isEmpty {
                result[question.id] = [custom]
            } else if let selection = selections[question.id] {
                result[question.id] = [selection]
            }
        }
        store.submitPendingAnswers(answers)
    }
}

private struct DesktopSidebarView: View {
    @ObservedObject var store: DesktopCodexStore
    let openSettings: () -> Void
    @AppStorage("VeoDesktop.collapsedProjectPaths") private var collapsedProjectPathsJSON = "[]"
    @AppStorage("VeoDesktop.sidebarOrganization") private var sidebarOrganizationRaw = DesktopSidebarOrganization.byProject.rawValue
    @AppStorage("VeoDesktop.sidebarSortMode") private var sidebarSortModeRaw = DesktopSidebarSortMode.priority.rawValue
    @AppStorage("VeoDesktop.manualThreadOrder") private var manualThreadOrderJSON = "[]"
    @State private var showsSearch = false
    @State private var renameTarget: DesktopThread?
    @State private var forkTarget: DesktopThread?
    @State private var deleteTarget: DesktopThread?
    @State private var expandedAgentThreadIDs = Set<String>()
    @FocusState private var searchFocused: Bool

    private var selection: Binding<String?> {
        Binding(
            get: { store.selectedThreadID },
            set: { store.selectThread($0) }
        )
    }

    private var pinnedThreads: [DesktopThread] {
        sortedThreads(store.filteredThreads.filter(\.isPinned))
    }

    private var workspaceGroups: [(path: String, name: String, threads: [DesktopThread])] {
        let candidates = store.filteredThreads
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        func root(for thread: DesktopThread) -> DesktopThread {
            var current = thread
            var visited = Set([thread.id])
            while let parentID = current.parentThreadID,
                  let parent = byID[parentID],
                  visited.insert(parentID).inserted {
                current = parent
            }
            return current
        }
        let grouped = Dictionary(grouping: candidates) { root(for: $0).cwd }
        return grouped
            .map { path, threads in
                (
                    path: path,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    threads: sortedThreads(threads)
                )
            }
            .sorted { lhs, rhs in
                (lhs.threads.map(\.updatedAt).max() ?? .distantPast)
                    > (rhs.threads.map(\.updatedAt).max() ?? .distantPast)
            }
    }

    private func flattenedEntries(for candidates: [DesktopThread]) -> [DesktopThreadTreeEntry] {
        let candidateIDs = Set(candidates.map(\.id))
        let children = Dictionary(grouping: candidates.filter { $0.parentThreadID != nil }) {
            $0.parentThreadID ?? ""
        }
        let roots = candidates.filter { thread in
            guard let parentID = thread.parentThreadID else { return true }
            return !candidateIDs.contains(parentID)
        }
        var entries: [DesktopThreadTreeEntry] = []
        var visited = Set<String>()

        func append(_ thread: DesktopThread, depth: Int) {
            guard visited.insert(thread.id).inserted else { return }
            let directChildren = sortedThreads(children[thread.id] ?? [])
            entries.append(DesktopThreadTreeEntry(
                thread: thread,
                depth: depth,
                hasChildren: !directChildren.isEmpty
            ))
            if !store.searchText.isEmpty || expandedAgentThreadIDs.contains(thread.id) {
                for child in directChildren { append(child, depth: depth + 1) }
            }
        }

        for root in sortedThreads(roots) { append(root, depth: 0) }
        for orphan in sortedThreads(candidates) where !visited.contains(orphan.id) {
            append(orphan, depth: 0)
        }
        return entries
    }

    var body: some View {
        VStack(spacing: 0) {
            primaryActions

            if showsSearch {
                searchField
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            repositoryHeader

            List(selection: selection) {
                veoThreadSections

                if store.showCodexThreads {
                    Section("Codex") {
                        let codexEntries = flattenedEntries(for: sortedThreads(store.filteredCodexThreads))
                        ForEach(codexEntries) { entry in
                            DesktopThreadRow(
                                thread: entry.thread,
                                showsWorkspace: true,
                                pendingRequestCount: store.pendingRequestCount(for: entry.thread.id),
                                agentState: store.agentState(for: entry.thread.id),
                                searchSnippet: store.searchSnippet(for: entry.thread.id),
                                treeDepth: entry.depth,
                                hasChildren: entry.hasChildren,
                                isExpanded: expandedAgentThreadIDs.contains(entry.thread.id),
                                toggleExpanded: { toggleAgentThread(entry.thread.id) }
                            )
                            .tag(entry.thread.id)
                            .contextMenu { threadContextMenu(entry.thread) }
                        }

                        if store.isLoadingCodexThreads {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .controlSize(.small)
                                Text("Loading Codex chats…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .listRowBackground(Color.clear)
                            .accessibilityLabel("Loading Codex chats")
                        } else if store.filteredCodexThreads.isEmpty, store.runtimeState.isReady {
                            Text(store.searchText.isEmpty
                                ? "No Codex CLI chats to show."
                                : "No Codex chats match your search.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                        }
                    }
                }

                if store.filteredThreads.isEmpty, store.runtimeState.isReady {
                    ContentUnavailableView {
                        Label("No chats yet", systemImage: "text.bubble")
                    } description: {
                        Text(
                            store.searchText.isEmpty
                                ? "Start a new chat, or enable Codex threads in the sidebar options to browse Codex CLI history."
                                : "No chats match your search."
                        )
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 30)

            sidebarFooter
        }
        .background(DesktopTheme.sidebar)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $renameTarget) { thread in
            DesktopRenameThreadView(thread: thread, store: store)
        }
        .sheet(item: $forkTarget) { thread in
            DesktopForkThreadView(thread: thread, store: store)
        }
        .alert(
            "Delete chat permanently?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { thread in
            Button("Delete", role: .destructive) {
                store.deleteThread(thread)
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: { thread in
            if thread.origin == .veo {
                Text("“\(thread.title)” and its spawned descendants will be removed from Veo. Local project files are not reverted.")
            } else {
                Text("“\(thread.title)” and its spawned descendants will be removed from Codex history. Local project files are not reverted.")
            }
        }
    }

    @ViewBuilder
    private var veoThreadSections: some View {
        if sidebarOrganization == .oneList {
            let entries = flattenedEntries(for: sortedThreads(store.filteredThreads))
            ForEach(entries) { entry in
                DesktopThreadRow(
                    thread: entry.thread,
                    showsWorkspace: true,
                    pendingRequestCount: store.pendingRequestCount(for: entry.thread.id),
                    agentState: store.agentState(for: entry.thread.id),
                    searchSnippet: store.searchSnippet(for: entry.thread.id),
                    treeDepth: entry.depth,
                    hasChildren: entry.hasChildren,
                    isExpanded: expandedAgentThreadIDs.contains(entry.thread.id),
                    toggleExpanded: { toggleAgentThread(entry.thread.id) }
                )
                .tag(entry.thread.id)
                .moveDisabled(!canManuallyReorder)
                .contextMenu { threadContextMenu(entry.thread) }
            }
            .onMove { offsets, destination in
                moveThreads(entries.map(\.thread), from: offsets, to: destination)
            }
        } else {
            if !pinnedThreads.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedThreads) { thread in
                        DesktopThreadRow(
                            thread: thread,
                            showsWorkspace: true,
                            pendingRequestCount: store.pendingRequestCount(for: thread.id),
                            agentState: store.agentState(for: thread.id),
                            searchSnippet: store.searchSnippet(for: thread.id),
                            hasChildren: false
                        )
                        .tag(thread.id)
                        .moveDisabled(!canManuallyReorder)
                        .contextMenu { threadContextMenu(thread) }
                    }
                    .onMove { offsets, destination in
                        moveThreads(pinnedThreads, from: offsets, to: destination)
                    }
                }
            }

            ForEach(workspaceGroups, id: \.path) { group in
                Section {
                    if !isProjectCollapsed(group.path) {
                        let entries = flattenedEntries(for: group.threads)
                        ForEach(entries) { entry in
                            DesktopThreadRow(
                                thread: entry.thread,
                                pendingRequestCount: store.pendingRequestCount(for: entry.thread.id),
                                agentState: store.agentState(for: entry.thread.id),
                                searchSnippet: store.searchSnippet(for: entry.thread.id),
                                treeDepth: entry.depth,
                                hasChildren: entry.hasChildren,
                                isExpanded: expandedAgentThreadIDs.contains(entry.thread.id),
                                toggleExpanded: { toggleAgentThread(entry.thread.id) }
                            )
                            .tag(entry.thread.id)
                            .moveDisabled(!canManuallyReorder)
                            .contextMenu { threadContextMenu(entry.thread) }
                        }
                        .onMove { offsets, destination in
                            moveThreads(entries.map(\.thread), from: offsets, to: destination)
                        }
                    }
                } header: {
                    HStack(spacing: 5) {
                        Button {
                            toggleProject(group.path)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(isProjectCollapsed(group.path) ? 0 : 90))
                                .frame(width: 13, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.searchText.isEmpty)
                        .help(isProjectCollapsed(group.path) ? "Expand \(group.name)" : "Collapse \(group.name)")
                        .accessibilityLabel(isProjectCollapsed(group.path) ? "Expand project \(group.name)" : "Collapse project \(group.name)")

                        Button {
                            store.setWorkspace(URL(fileURLWithPath: group.path))
                        } label: {
                            Label(group.name, systemImage: "folder")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(group.path)
                        .accessibilityLabel("Use project \(group.name)")
                    }
                    .textCase(nil)
                }
            }
        }
    }

    private var primaryActions: some View {
        VStack(spacing: 2) {
            Button {
                store.beginNewChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }

            Button {
                withAnimation(.easeOut(duration: 0.16)) { showsSearch.toggle() }
                if showsSearch { searchFocused = true }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13.5, weight: .medium))
        .labelStyle(VeoSidebarLabelStyle())
        .padding(.horizontal, 10)
        .padding(.top, DesktopTheme.sidebarTitlebarClearance)
        .padding(.bottom, DesktopTheme.spaceL)
    }

    private var repositoryHeader: some View {
        HStack {
            Text(store.isBrowsingArchivedThreads ? "Archived" : "Chats")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()

            sidebarOptionsMenu

            Button {
                store.chooseWorkspace()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .help("Open project")
            .accessibilityLabel("Open project")
        }
        .padding(.horizontal, DesktopTheme.spaceL)
        .padding(.bottom, DesktopTheme.spaceXS)
    }

    private var sidebarOptionsMenu: some View {
        Menu {
            Section("Organize sidebar") {
                ForEach(DesktopSidebarOrganization.allCases) { organization in
                    Toggle(organization.title, isOn: Binding(
                        get: { sidebarOrganization == organization },
                        set: { enabled in
                            if enabled {
                                sidebarOrganizationRaw = organization.rawValue
                            }
                        }
                    ))
                }
            }

            Section("Sort chats by") {
                ForEach(DesktopSidebarSortMode.allCases) { mode in
                    Toggle(mode.title, isOn: Binding(
                        get: { sidebarSortMode == mode },
                        set: { enabled in
                            if enabled {
                                setSidebarSortMode(mode)
                            }
                        }
                    ))
                }
            }

            Divider()

            Button {
                store.setShowCodexThreads(!store.showCodexThreads)
            } label: {
                HStack {
                    Text("Show Codex threads")
                    Spacer(minLength: 16)
                    if store.showCodexThreads {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                store.setBrowsingArchivedThreads(!store.isBrowsingArchivedThreads)
            } label: {
                Label(
                    store.isBrowsingArchivedThreads ? "Show Active Chats" : "Browse Archived Chats",
                    systemImage: store.isBrowsingArchivedThreads ? "text.bubble" : "archivebox"
                )
            }

            Divider()

            Button {
                collapseAllProjects()
            } label: {
                Label("Collapse All", systemImage: "rectangle.compress.vertical")
            }
            .disabled(!canCollapseAllProjects)

            Button {
                expandAllProjects()
            } label: {
                Label("Expand All", systemImage: "rectangle.expand.vertical")
            }
            .disabled(!canExpandAllProjects)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sidebar options")
        .accessibilityLabel("Sidebar options")
    }

    private var runtimeDot: some View {
        Circle()
            .fill(store.runtimeState.isReady ? Color.green : (store.runtimeState == .starting ? Color.orange : Color.red))
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
            .help(store.runtimeState.title)
            .accessibilityLabel("Codex runtime")
            .accessibilityValue(store.runtimeState.title)
    }

    @ViewBuilder
    private func threadContextMenu(_ thread: DesktopThread) -> some View {
        if let parentID = thread.parentThreadID,
           let parent = (store.threads + store.archivedThreads + store.codexThreads + store.archivedCodexThreads)
            .first(where: { $0.id == parentID }) {
            Button {
                store.selectThread(parent.id)
            } label: {
                Label("Go to Parent Agent", systemImage: "arrow.turn.up.left")
            }
            Divider()
        }
        if store.isBrowsingArchivedThreads {
            Button {
                store.unarchiveThread(thread)
            } label: {
                Label("Unarchive", systemImage: "arrow.up.bin")
            }
        } else {
            Button {
                store.setThreadPinned(thread, pinned: !thread.isPinned)
            } label: {
                Label(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin")
            }

            Button {
                renameTarget = thread
            } label: {
                Label("Rename…", systemImage: "pencil")
            }

            Button {
                forkTarget = thread
            } label: {
                Label("Fork…", systemImage: "arrow.triangle.branch")
            }
            .disabled(thread.isRunning)

            Button {
                store.compactThread(thread)
            } label: {
                Label("Compact Context", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .disabled(thread.isRunning)

            Divider()

            Button {
                store.archiveThread(thread)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }

        Divider()

        Button(role: .destructive) {
            deleteTarget = thread
        } label: {
            Label("Delete Permanently…", systemImage: "trash")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search every project", text: $store.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            Button {
                store.setSearchesMessageContent(!store.searchesMessageContent)
            } label: {
                Image(systemName: "text.magnifyingglass")
                    .foregroundStyle(store.searchesMessageContent ? DesktopTheme.accent : Color.secondary.opacity(0.65))
            }
            .buttonStyle(.plain)
            .disabled(!store.canSearchMessageContent)
            .help(store.canSearchMessageContent
                ? (store.searchesMessageContent ? "Search titles only" : "Search message content (experimental)")
                : "Message content search is unavailable in this Codex runtime")
            .accessibilityLabel("Search message content")
            .accessibilityValue(store.searchesMessageContent ? "On" : "Off")
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func toggleAgentThread(_ threadID: String) {
        if expandedAgentThreadIDs.contains(threadID) {
            expandedAgentThreadIDs.remove(threadID)
        } else {
            expandedAgentThreadIDs.insert(threadID)
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button {
                    if store.runtimeState.isReady {
                        store.refreshThreads()
                    } else {
                        store.reconnect()
                    }
                } label: {
                    HStack(spacing: 8) {
                        runtimeDot
                        Text(store.runtimeState.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(store.runtimeState.isReady ? "Refresh chats" : "Reconnect runtime")
                .accessibilityLabel(store.runtimeState.isReady ? "Refresh chats" : "Reconnect runtime")

                Spacer(minLength: 8)

                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(DesktopTheme.spaceM)
        }
    }

    private var collapsedProjectPaths: Set<String> {
        guard let data = collapsedProjectPathsJSON.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(paths)
    }

    private var sidebarOrganization: DesktopSidebarOrganization {
        DesktopSidebarOrganization(rawValue: sidebarOrganizationRaw) ?? .byProject
    }

    private var sidebarSortMode: DesktopSidebarSortMode {
        DesktopSidebarSortMode(rawValue: sidebarSortModeRaw) ?? .priority
    }

    private var manualThreadOrder: [String] {
        guard let data = manualThreadOrderJSON.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return ids
    }

    private var canManuallyReorder: Bool {
        sidebarSortMode == .manual && store.searchText.isEmpty
    }

    private var canCollapseAllProjects: Bool {
        sidebarOrganization == .byProject
            && store.searchText.isEmpty
            && workspaceGroups.contains { !collapsedProjectPaths.contains($0.path) }
    }

    private var canExpandAllProjects: Bool {
        sidebarOrganization == .byProject
            && store.searchText.isEmpty
            && workspaceGroups.contains { collapsedProjectPaths.contains($0.path) }
    }

    private func isProjectCollapsed(_ path: String) -> Bool {
        store.searchText.isEmpty && collapsedProjectPaths.contains(path)
    }

    private func toggleProject(_ path: String) {
        var paths = collapsedProjectPaths
        if paths.contains(path) {
            paths.remove(path)
        } else {
            paths.insert(path)
        }
        saveCollapsedProjectPaths(paths)
    }

    private func sortedThreads(_ threads: [DesktopThread]) -> [DesktopThread] {
        switch sidebarSortMode {
        case .priority:
            return threads.sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return lhs.updatedAt > rhs.updatedAt
            }
        case .lastUpdated:
            return threads.sorted { $0.updatedAt > $1.updatedAt }
        case .manual:
            let ranks = Dictionary(uniqueKeysWithValues: manualThreadOrder.enumerated().map { ($1, $0) })
            return threads.sorted { lhs, rhs in
                let lhsRank = ranks[lhs.id]
                let rhsRank = ranks[rhs.id]
                switch (lhsRank, rhsRank) {
                case let (lhsRank?, rhsRank?): return lhsRank < rhsRank
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.updatedAt > rhs.updatedAt
                }
            }
        }
    }

    private func setSidebarSortMode(_ mode: DesktopSidebarSortMode) {
        if mode == .manual, manualThreadOrder.isEmpty {
            saveManualThreadOrder(store.threads.sorted { $0.updatedAt > $1.updatedAt }.map(\.id))
        }
        sidebarSortModeRaw = mode.rawValue
    }

    private func moveThreads(_ threads: [DesktopThread], from offsets: IndexSet, to destination: Int) {
        guard canManuallyReorder else { return }
        var reorderedIDs = threads.map(\.id)
        reorderedIDs.move(fromOffsets: offsets, toOffset: destination)

        var masterOrder = manualThreadOrder
        for id in store.threads.sorted(by: { $0.updatedAt > $1.updatedAt }).map(\.id)
            where !masterOrder.contains(id) {
            masterOrder.append(id)
        }

        let movedIDs = Set(reorderedIDs)
        var reorderedIterator = reorderedIDs.makeIterator()
        for index in masterOrder.indices where movedIDs.contains(masterOrder[index]) {
            if let nextID = reorderedIterator.next() {
                masterOrder[index] = nextID
            }
        }
        saveManualThreadOrder(masterOrder)
    }

    private func saveManualThreadOrder(_ ids: [String]) {
        guard let data = try? JSONEncoder().encode(ids),
              let encoded = String(data: data, encoding: .utf8) else { return }
        manualThreadOrderJSON = encoded
    }

    private func collapseAllProjects() {
        var paths = collapsedProjectPaths
        paths.formUnion(workspaceGroups.map(\.path))
        saveCollapsedProjectPaths(paths)
    }

    private func expandAllProjects() {
        saveCollapsedProjectPaths([])
    }

    private func saveCollapsedProjectPaths(_ paths: Set<String>) {
        guard let data = try? JSONEncoder().encode(paths.sorted()),
              let encoded = String(data: data, encoding: .utf8) else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            collapsedProjectPathsJSON = encoded
        }
    }
}

private struct DesktopRenameThreadView: View {
    let thread: DesktopThread
    @ObservedObject var store: DesktopCodexStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(thread: DesktopThread, store: DesktopCodexStore) {
        self.thread = thread
        self.store = store
        _name = State(initialValue: thread.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Chat")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            TextField("Chat name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename", action: rename)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 430)
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.renameThread(thread, name: trimmed)
        dismiss()
    }
}

private struct DesktopForkThreadView: View {
    private static let allHistory = "__all_history__"

    let thread: DesktopThread
    @ObservedObject var store: DesktopCodexStore
    @Environment(\.dismiss) private var dismiss
    @State private var boundaries: [DesktopTurnBoundary] = []
    @State private var selectedBoundaryID = Self.allHistory
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Fork Chat")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Choose how much conversation history the new chat should copy. Project files are not rolled back or reverted.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)

            Divider()

            if isLoading {
                ProgressView("Loading turn boundaries…")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        boundaryButton(
                            id: Self.allHistory,
                            title: "All current history",
                            detail: "Fork from the latest completed state"
                        )
                        ForEach(boundaries.filter { !$0.status.lowercased().contains("progress") }) { boundary in
                            boundaryButton(
                                id: boundary.id,
                                title: boundary.title,
                                detail: boundary.startedAt?.formatted(date: .abbreviated, time: .shortened)
                                    ?? boundary.status.capitalized
                            )
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 390)
            }

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Fork Chat") {
                    store.forkThread(
                        thread,
                        through: selectedBoundaryID == Self.allHistory ? nil : selectedBoundaryID
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560)
        .task {
            boundaries = await store.loadTurnBoundaries(for: thread.id)
            isLoading = false
        }
    }

    private func boundaryButton(id: String, title: String, detail: String) -> some View {
        Button {
            selectedBoundaryID = id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selectedBoundaryID == id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selectedBoundaryID == id ? DesktopTheme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(
                selectedBoundaryID == id ? DesktopTheme.accent.opacity(0.1) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct VeoSidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: 17)
            configuration.title
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
}

private struct DesktopThreadTreeEntry: Identifiable {
    let thread: DesktopThread
    let depth: Int
    let hasChildren: Bool

    var id: String { thread.id }
}

private struct DesktopThreadRow: View {
    let thread: DesktopThread
    var showsWorkspace = false
    var pendingRequestCount = 0
    var agentState: DesktopAgentState?
    var searchSnippet: String?
    var treeDepth = 0
    var hasChildren = false
    var isExpanded = false
    var toggleExpanded: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(treeDepth) * 13, height: 1)
            if hasChildren {
                Button {
                    toggleExpanded?()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 18)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse subagents" : "Expand subagents")
            } else if thread.isSubagent {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            if thread.isRunning {
                Circle()
                    .fill(DesktopTheme.accent)
                    .frame(width: 5, height: 5)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.title)
                    .font(.system(size: 12.5, weight: .regular))
                    .lineLimit(1)
                if let searchSnippet, !searchSnippet.isEmpty {
                    Text(searchSnippet)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if thread.isSubagent {
                    Text([
                        thread.agentNickname,
                        thread.agentRole,
                        agentState?.displayStatus ?? thread.agentStatus,
                    ].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle((agentState?.isActive == true || thread.isRunning) ? DesktopTheme.accent : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if pendingRequestCount > 0 {
                Text("\(pendingRequestCount)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(.orange, in: Circle())
                    .accessibilityLabel("\(pendingRequestCount) request\(pendingRequestCount == 1 ? "" : "s") waiting")
            }
            Group {
                if thread.isRunning {
                    Text(thread.isSubagent ? "agent" : "live")
                        .foregroundStyle(DesktopTheme.accent)
                } else {
                    Text(Self.compactRelativeTime(from: thread.updatedAt))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10.5, weight: .medium))
        }
        .padding(.vertical, DesktopTheme.spaceXS)
        .contentShape(Rectangle())
        .help(thread.isSubagent
            ? "\(agentState?.displayStatus ?? thread.agentStatus) — \(thread.cwd)"
            : (showsWorkspace ? "\(thread.workspaceName) — \(thread.cwd)" : thread.cwd))
    }

    private static func compactRelativeTime(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        case ..<604_800: return "\(seconds / 86_400)d"
        default: return "\(seconds / 604_800)w"
        }
    }
}

private struct TimelineBottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct DesktopConversationView: View {
    @ObservedObject var store: DesktopCodexStore
    @ObservedObject var terminalHub: DesktopLocalTerminalHub
    @Binding var showsInteractiveTerminal: Bool
    @State private var isPinnedToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                DesktopTheme.canvas
                    .ignoresSafeArea()

                switch store.runtimeState {
                case .starting:
                    runtimeStarting
                case .unavailable(let message):
                    runtimeUnavailable(message)
                case .ready:
                    if store.selectedThreadID == nil, store.timeline.isEmpty {
                        DesktopWelcomeView(store: store)
                    } else {
                        conversation
                    }
                }
            }
            .navigationTitle(store.selectedThread?.title ?? "New chat")
            .overlay(alignment: .bottom) {
                if store.runtimeState.isReady,
                   store.selectedThreadID != nil || !store.timeline.isEmpty {
                    DesktopComposerView(store: store)
                }
            }

            if showsInteractiveTerminal {
                DesktopInteractiveTerminalPanel(
                    store: store,
                    hub: terminalHub,
                    isPresented: $showsInteractiveTerminal
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: showsInteractiveTerminal)
    }

    private var conversation: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if store.isLoadingTimeline {
                            DesktopTimelineSkeleton()
                        } else {
                            ForEach(store.timeline) { item in
                                DesktopTimelineRow(
                                    item: item,
                                    workspaceURL: store.effectiveWorkspaceURL
                                )
                                    .id(item.id)
                            }
                        }

                        if store.isSubmittingTurn {
                            ProgressView()
                                .controlSize(.small)
                                .help("Starting turn")
                        } else if store.isRunningTurn {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Codex is working locally")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .id("running")
                        }

                        if let error = store.transientError, !error.isEmpty {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                                .padding(12)
                                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .id("error")
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchor)
                            .background(
                                GeometryReader { anchor in
                                    Color.clear.preference(
                                        key: TimelineBottomOffsetKey.self,
                                        value: anchor.frame(in: .named(Self.scrollSpace)).maxY
                                    )
                                }
                            )
                    }
                    .frame(maxWidth: DesktopTheme.conversationWidth, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.top, 30)
                    .padding(.bottom, 188)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(TimelineBottomOffsetKey.self) { bottom in
                    // The tail is considered "in view" with a little slack so a half-line
                    // of overscroll doesn't unpin the timeline mid-stream.
                    isPinnedToBottom = bottom <= viewport.size.height + 48
                }
                .onChange(of: store.timeline.count) { _, _ in
                    scrollToEndIfPinned(proxy)
                }
                .onChange(of: store.timeline.last?.body.count ?? 0) { _, _ in
                    scrollToEndIfPinned(proxy)
                }
                .onChange(of: store.isRunningTurn) { _, _ in
                    scrollToEndIfPinned(proxy)
                }
                .onChange(of: store.selectedThreadID) { _, _ in
                    isPinnedToBottom = true
                    scrollToEnd(proxy, animated: false)
                }
                .onChange(of: store.timelineNavigationItemID) { _, itemID in
                    guard let itemID else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(itemID, anchor: .center)
                    }
                    store.consumeTimelineNavigation()
                }
                .overlay(alignment: .bottom) {
                    if !isPinnedToBottom {
                        Button {
                            isPinnedToBottom = true
                            scrollToEnd(proxy, animated: true)
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down")
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().stroke(DesktopTheme.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 164)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeOut(duration: 0.16), value: isPinnedToBottom)
            }
        }
    }

    private static let scrollSpace = "veo.timeline.scroll"
    private static let bottomAnchor = "veo.timeline.bottom"

    private func scrollToEndIfPinned(_ proxy: ScrollViewProxy) {
        guard isPinnedToBottom else { return }
        scrollToEnd(proxy, animated: true)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        let scroll = { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.2), scroll)
        } else {
            scroll()
        }
    }

    private var runtimeStarting: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Starting local Codex")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Veo is connecting directly to the Codex CLI on this Mac.")
                .foregroundStyle(.secondary)
        }
    }

    private func runtimeUnavailable(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(DesktopTheme.accent)
            Text("Codex isn’t ready")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Text("Install and sign in to the Codex CLI, then try again.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            Button("Try Again") {
                store.reconnect()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

private struct DesktopWelcomeView: View {
    @ObservedObject var store: DesktopCodexStore

    private var recentProjects: [(path: String, name: String)] {
        var seen = Set<String>()
        var projects: [(path: String, name: String)] = []
        for thread in store.filteredThreads.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard seen.insert(thread.cwd).inserted else { continue }
            projects.append((thread.cwd, URL(fileURLWithPath: thread.cwd).lastPathComponent))
            if projects.count == 5 { break }
        }
        return projects
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: DesktopTheme.spaceXL)

            VStack(alignment: .leading, spacing: DesktopTheme.spaceM) {
                Button {
                    store.chooseWorkspace()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(store.hasExplicitWorkspace ? store.effectiveWorkspaceURL.lastPathComponent : "Open project…")
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.leading, DesktopTheme.spaceS)
                .accessibilityLabel(store.hasExplicitWorkspace ? "Change project" : "Open project")

                DesktopComposerView(store: store, isWelcome: true)

                if !recentProjects.isEmpty {
                    VStack(alignment: .leading, spacing: DesktopTheme.spaceS) {
                        Text("Recent projects")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        FlowRecentProjects(projects: recentProjects) { path in
                            store.setWorkspace(URL(fileURLWithPath: path))
                        }
                    }
                    .padding(.leading, 2)
                }
            }
            .frame(maxWidth: DesktopTheme.welcomeWidth)
            .padding(.horizontal, 30)

            Spacer(minLength: DesktopTheme.spaceXL)

            Text("Veo runs Codex locally in the project folder you choose.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 28)
        }
    }
}

private struct FlowRecentProjects: View {
    let projects: [(path: String, name: String)]
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: DesktopTheme.spaceS) {
            ForEach(projects, id: \.path) { project in
                Button {
                    onSelect(project.path)
                } label: {
                    Label(project.name, systemImage: "folder")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(DesktopTheme.raised, in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous).stroke(DesktopTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(project.path)
                .accessibilityLabel("Open project \(project.name)")
            }
        }
    }
}

private struct DesktopTimelineRow: View {
    let item: DesktopTimelineItem
    let workspaceURL: URL?
    @State private var showsFullCommandOutput = false
    @State private var blockedArtifactURLMessage: String?

    var body: some View {
        switch item.kind {
        case .user:
            userRow
        case .assistant:
            assistantRow
        case .reasoning:
            reasoningRow
        case .command, .fileChange, .activity, .plan:
            activityRow
        case .error:
            errorRow
        }
    }

    private var userRow: some View {
        HStack {
            Spacer(minLength: 90)
            VStack(alignment: .leading, spacing: 8) {
                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                }
                if !item.attachments.isEmpty {
                    DesktopAttachmentStrip(attachments: item.attachments)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Codex")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            MarkdownMessageView(
                source: item.body,
                artifacts: item.artifacts,
                citations: item.citations,
                workspaceURL: workspaceURL
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reasoningRow: some View {
        DisclosureGroup {
            Text(item.body)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 7)
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var activityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: activitySymbol)
                    .foregroundStyle(activityTint)
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if let status = item.status {
                    Text(status.replacingOccurrences(of: "inProgress", with: "Running"))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(item.body)
                .font(.system(size: item.kind == .command ? 11.5 : 12.5, design: item.kind == .command ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(item.kind == .command && !showsFullCommandOutput ? 12 : nil)
                .textSelection(.enabled)

            if item.kind == .command, item.body.split(whereSeparator: \Character.isNewline).count > 12 {
                Button(showsFullCommandOutput ? "Show less" : "Show all output") {
                    showsFullCommandOutput.toggle()
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .medium))
            }

            if let metadata = item.toolMetadata {
                HStack(spacing: 12) {
                    if let progress = metadata.progressMessage, !progress.isEmpty {
                        Label(progress, systemImage: "arrow.triangle.2.circlepath")
                    }
                    if let duration = metadata.durationMilliseconds {
                        Label(formatDuration(duration), systemImage: "clock")
                    }
                    if let exitCode = metadata.exitCode {
                        Label("Exit \(exitCode)", systemImage: exitCode == 0 ? "checkmark.circle" : "xmark.circle")
                    }
                    if let processID = metadata.processID {
                        Label(processID, systemImage: "number")
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)

                if let arguments = metadata.argumentsJSON, !arguments.isEmpty {
                    DisclosureGroup("Inputs") {
                        Text(arguments)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.top, 5)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                if let error = metadata.errorMessage, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                }
            }

            if !item.terminalInteractions.isEmpty {
                ForEach(item.terminalInteractions, id: \.self) { interaction in
                    Label(interaction + " · input hidden", systemImage: "keyboard.badge.ellipsis")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            SafeToolArtifactListView(
                artifacts: item.artifacts,
                workspaceURL: workspaceURL,
                blockedURL: { blockedArtifactURLMessage = $0 }
            )
            SafeCitationListView(citations: item.citations, workspaceURL: workspaceURL)

            if let blockedArtifactURLMessage {
                Label(blockedArtifactURLMessage, systemImage: "hand.raised.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
        }
        .padding(DesktopTheme.spaceM)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: DesktopTheme.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesktopTheme.radiusControl, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 1)
        )
    }

    private var errorRow: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).fontWeight(.semibold)
                Text(item.body)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(.red)
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var activitySymbol: String {
        switch item.kind {
        case .command: return "terminal"
        case .fileChange: return "doc.badge.gearshape"
        case .plan: return "list.bullet.clipboard"
        default: return "gearshape.2"
        }
    }

    private var activityTint: Color {
        item.kind == .fileChange ? DesktopTheme.accent : .secondary
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds) ms" }
        return String(format: "%.1f s", Double(milliseconds) / 1_000)
    }

}

private struct DesktopTimelineSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach([0.82, 0.64, 0.91, 0.47], id: \.self) { width in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.primary.opacity(0.07))
                    .frame(maxWidth: DesktopTheme.conversationWidth * width)
                    .frame(height: 13)
            }
        }
        .redacted(reason: .placeholder)
    }
}

private struct DesktopComposerView: View {
    @ObservedObject var store: DesktopCodexStore
    var isWelcome = false
    @State private var focusToken = 0
    @State private var isOptionsPresented = false
    @State private var isQueuePresented = false

    var body: some View {
        Group {
            if isWelcome {
                composerCard
            } else {
                composerCard
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear { requestFocus() }
        .onChange(of: store.selectedThreadID) { _, _ in requestFocus() }
        .onChange(of: store.hasExplicitWorkspace) { _, _ in requestFocus() }
        .onChange(of: store.draft) { _, _ in store.updateComposerAutocomplete() }
    }

    private func requestFocus() {
        guard store.hasExplicitWorkspace else { return }
        focusToken += 1
    }

    private var composerCard: some View {
        VStack(spacing: DesktopTheme.spaceS) {
            if let error = store.transientError, !error.isEmpty, store.timeline.isEmpty {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !store.composerSuggestions.isEmpty {
                DesktopComposerAutocompletePanel(store: store)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !store.attachments.isEmpty {
                DesktopAttachmentStrip(
                    attachments: store.attachments,
                    onRemove: store.removeAttachment
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ComposerTextView(
                text: $store.draft,
                placeholder: isWelcome ? "Message Codex in this project…" : "Send follow-up",
                fontSize: isWelcome ? 15 : 14,
                minHeight: isWelcome ? 70 : 34,
                maxHeight: isWelcome ? 130 : 110,
                isEditable: store.hasExplicitWorkspace,
                focusToken: focusToken,
                onSubmit: {
                    guard store.canSend else { return false }
                    store.sendDraft()
                    return true
                }
            )
            .accessibilityLabel("Message Codex")

            HStack(spacing: 10) {
                Button {
                    isOptionsPresented.toggle()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 27, height: 27)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Composer options")
                .accessibilityLabel("Composer options")
                .popover(isPresented: $isOptionsPresented, arrowEdge: .bottom) {
                    DesktopComposerOptionsView(store: store) {
                        isOptionsPresented = false
                        DispatchQueue.main.async {
                            store.chooseWorkspace()
                        }
                    }
                }

                DesktopModelMenu(store: store)

                accessModeMenu

                if store.isBusyTurn {
                    followUpMenu
                }

                Spacer()

                if store.hasExplicitWorkspace,
                   !store.isRunningTurn,
                   !store.isPlanModeEnabled,
                   !store.isGoalModeEnabled {
                    Text("↩ send · ⇧↩ newline")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                DesktopComposerModePills(store: store)

                if store.realtimeVoiceEnabled,
                   store.capabilities.supports(.realtimeVoice),
                   store.selectedThreadID != nil {
                    Button {
                        if store.isRealtimeVoiceActive {
                            store.stopRealtimeVoice()
                        } else {
                            store.startRealtimeVoice()
                        }
                    } label: {
                        Image(systemName: store.isRealtimeVoiceActive ? "waveform.circle.fill" : "mic.circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(store.isRealtimeVoiceActive ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.selectedThread?.canAcceptDirectInput == false)
                    .help(store.isRealtimeVoiceActive ? "Stop realtime voice" : "Start realtime voice")
                    .accessibilityLabel(store.isRealtimeVoiceActive ? "Stop realtime voice" : "Start realtime voice")

                    if !store.realtimeVoices.isEmpty, !store.isRealtimeVoiceActive {
                        Menu {
                            ForEach(store.realtimeVoices) { voice in
                                Button {
                                    store.selectRealtimeVoice(voice.id)
                                } label: {
                                    HStack {
                                        Text(voice.displayName)
                                        if store.selectedRealtimeVoiceID == voice.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(store.realtimeVoices.first(where: { $0.id == store.selectedRealtimeVoiceID })?.displayName ?? "Voice")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .menuStyle(.borderlessButton)
                        .help("Realtime voice")
                    }
                }

                if !store.selectedQueuedDrafts.isEmpty {
                    Button {
                        isQueuePresented.toggle()
                    } label: {
                        Label("Queued \(store.selectedQueuedDrafts.count)", systemImage: "text.line.last.and.arrowtriangle.forward")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.orange.opacity(0.14), in: Capsule())
                            .overlay(Capsule().stroke(.orange.opacity(0.28), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .popover(isPresented: $isQueuePresented, arrowEdge: .bottom) {
                        DesktopQueuedDraftsPopover(store: store)
                    }
                    .help("Review queued follow-ups")
                }

                Button {
                    store.sendDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(.white, in: Circle())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(!store.canSend)
                .opacity(store.canSend ? 1 : 0.42)
                .help(sendButtonHelp)
                .accessibilityLabel(sendButtonHelp)

                if store.isRunningTurn {
                    Button {
                        store.stopTurn()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(.red, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop")
                    .accessibilityLabel("Stop turn")
                }
            }
            .font(.system(size: 11.5, weight: .medium))

            if store.realtimeSession != nil, !store.realtimeTranscript.isEmpty {
                Label(store.realtimeTranscript, systemImage: "waveform")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("Realtime transcript")
            }

            if !store.hasExplicitWorkspace {
                Text("Open a project to start a local chat")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if store.selectedThread?.canAcceptDirectInput == false {
                Text("This subagent thread is read-only. Continue in its parent chat.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DesktopTheme.spaceM)
        .modifier(ComposerGlassSurface())
        .frame(maxWidth: isWelcome ? DesktopTheme.welcomeWidth : DesktopTheme.conversationWidth)
        .dropDestination(for: URL.self) { urls, _ in
            store.addDroppedFiles(urls)
        }
    }

    private var accessModeMenu: some View {
        Menu {
            ForEach(DesktopAccessMode.allCases) { mode in
                Button {
                    store.updateAccessMode(mode)
                } label: {
                    HStack {
                        Text(mode.title)
                        if store.accessMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label(store.accessMode.title, systemImage: "shield")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(store.accessMode == .fullAccess ? .orange : .secondary)
        }
        .menuStyle(.borderlessButton)
        .help(store.accessMode.detail)
        .accessibilityLabel("Access mode")
        .accessibilityValue(store.accessMode.title)
    }

    private var followUpMenu: some View {
        Menu {
            ForEach(DesktopFollowUpBehavior.allCases) { behavior in
                Button {
                    store.setFollowUpBehavior(behavior)
                } label: {
                    Label(behavior.title, systemImage: behavior.systemImage)
                }
                .disabled(behavior == .steer && !store.capabilities.supports(.turnSteering))
            }
        } label: {
            Label(store.followUpBehavior.shortTitle, systemImage: store.followUpBehavior.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .help("Choose how messages sent during an active turn are handled")
    }

    private var sendButtonHelp: String {
        if store.isRunningTurn {
            return store.followUpBehavior == .steer ? "Steer current turn" : "Queue next message"
        }
        if store.isSubmittingTurn { return "Queue next message" }
        return "Send (Return)"
    }
}

private struct DesktopComposerAutocompletePanel: View {
    @ObservedObject var store: DesktopCodexStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.composerSuggestions) { suggestion in
                Button {
                    store.selectComposerSuggestion(suggestion)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: suggestion.kind == .file ? "doc.text" : "bolt.badge.checkmark")
                            .foregroundStyle(suggestion.kind == .file ? DesktopTheme.accent : .orange)
                            .frame(width: 17)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                            Text(suggestion.subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Text(suggestion.kind == .file ? "File" : "Skill")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(DesktopTheme.hairline, lineWidth: 1)
        )
        .frame(maxHeight: 260)
        .accessibilityLabel("Composer autocomplete")
    }
}

private struct DesktopQueuedDraftsPopover: View {
    @ObservedObject var store: DesktopCodexStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Queued follow-ups", systemImage: "text.line.last.and.arrowtriangle.forward")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(store.selectedQueuedDrafts.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.selectedQueuedDrafts) { payload in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(
                                "Queued message",
                                text: Binding(
                                    get: { payload.text },
                                    set: { store.updateQueuedDraft(payload.id, text: $0) }
                                ),
                                axis: .vertical
                            )
                            .textFieldStyle(.plain)
                            .lineLimit(2...6)
                            .font(.system(size: 12.5))

                            if !payload.attachments.isEmpty {
                                DesktopAttachmentStrip(attachments: payload.attachments)
                            }

                            HStack {
                                Text(payload.createdAt, style: .relative)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    store.removeQueuedDraft(payload.id)
                                }
                                .buttonStyle(.link)

                                if store.isRunningTurn {
                                    Button("Steer now") {
                                        store.steerQueuedDraft(payload.id)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(!store.capabilities.supports(.turnSteering))
                                } else if !store.isBusyTurn,
                                          payload.id == store.selectedQueuedDrafts.first?.id {
                                    Button("Send now") {
                                        store.sendNextQueuedDraft()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 390)
    }
}

private struct DesktopAttachmentStrip: View {
    let attachments: [DesktopComposerAttachment]
    var onRemove: ((String) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    DesktopAttachmentPreview(attachment: attachment, onRemove: onRemove)
                }
            }
        }
    }
}

private struct DesktopAttachmentPreview: View {
    let attachment: DesktopComposerAttachment
    let onRemove: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            preview
            Text(attachment.name)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            if let onRemove {
                Button {
                    onRemove(attachment.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .help(attachment.source)
    }

    @ViewBuilder
    private var preview: some View {
        if attachment.kind == .localImage,
           let image = NSImage(contentsOfFile: attachment.source) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
    }

    private var symbolName: String {
        switch attachment.kind {
        case .localImage, .image: return "photo"
        case .localAudio, .audio: return "waveform"
        case .fileMention: return "doc.text"
        case .skill: return "bolt.badge.checkmark"
        }
    }
}

private struct ComposerGlassSurface: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular
                        .tint(Color.black.opacity(0.18))
                        .interactive(),
                    in: shape
                )
        } else {
            content
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(shape.fill(Color.black.opacity(0.14)))
                }
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
        }
    }
}

private struct DesktopDiffView: View {
    private enum Presentation: String, CaseIterable, Identifiable {
        case repository = "Repository"
        case unified = "Unified"
        case files = "By File"
        var id: String { rawValue }
    }

    @ObservedObject var store: DesktopCodexStore
    @Environment(\.dismiss) private var dismiss
    @State private var presentation: Presentation = .repository

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Changes", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                Picker("Presentation", selection: $presentation) {
                    ForEach(Presentation.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 310)
                Spacer()
                if presentation != .repository {
                    Button("Review Changes") {
                        store.reviewChanges()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusyTurn)
                }
                Button("Done") { dismiss() }
            }
            .padding(14)

            Divider()

            Group {
                switch presentation {
                case .repository:
                    DesktopGitChangesView(
                        repository: store.gitRepository,
                        isRefreshing: store.isRefreshingGit,
                        isMutating: store.isMutatingGit,
                        message: store.gitMessage,
                        actions: DesktopGitChangesActions(
                            refresh: store.refreshGitRepository,
                            stage: store.stageGitFiles,
                            unstage: store.unstageGitFiles,
                            discard: store.discardGitFile,
                            commit: store.commitGitFiles,
                            createBranch: store.createGitBranch
                        )
                    )
                case .unified:
                    if let diff = store.selectedTurnDiff, !diff.isEmpty {
                        diffText(diff.unifiedDiff.isEmpty
                            ? diff.files.map { "### \($0.path)\n\($0.diff)" }.joined(separator: "\n\n")
                            : diff.unifiedDiff)
                    } else {
                        noLiveChanges
                    }
                case .files:
                    if let diff = store.selectedTurnDiff, !diff.isEmpty {
                        perFileDiff(diff)
                    } else {
                        noLiveChanges
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var noLiveChanges: some View {
        ContentUnavailableView(
            "No live changes",
            systemImage: "doc",
            description: Text("File patches from the current turn will appear here as Codex updates them.")
        )
    }

    private func perFileDiff(_ diff: DesktopTurnDiff) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(diff.files) { file in
                    DisclosureGroup {
                        Text(file.diff)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                            Text(file.path)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(file.kind.capitalized)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            .padding(16)
        }
    }

    private func diffText(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
        }
    }
}

private struct DesktopInspectorView: View {
    @ObservedObject var store: DesktopCodexStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                inspectorSection("Runtime") {
                    statusRow("Codex", store.runtimeState.title, color: store.runtimeState.isReady ? .green : .orange)
                    statusRow("Turn", store.isRunningTurn ? "Running" : "Idle", color: store.isRunningTurn ? DesktopTheme.accent : .secondary)
                }

                if let thread = store.selectedThread, thread.isSubagent {
                    inspectorSection("Subagent") {
                        statusRow(
                            thread.agentNickname ?? "Agent",
                            store.agentState(for: thread.id)?.displayStatus ?? thread.agentStatus,
                            color: (store.agentState(for: thread.id)?.isActive == true || thread.isRunning)
                                ? DesktopTheme.accent
                                : .secondary
                        )
                        if let role = thread.agentRole {
                            Label(role, systemImage: "person.text.rectangle")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        if let parentID = thread.parentThreadID,
                           let parent = (store.threads + store.archivedThreads + store.codexThreads + store.archivedCodexThreads)
                            .first(where: { $0.id == parentID }) {
                            Button {
                                store.selectThread(parent.id)
                            } label: {
                                Label("Open parent: \(parent.title)", systemImage: "arrow.turn.up.left")
                            }
                            .buttonStyle(.link)
                        }
                        if thread.canAcceptDirectInput == false {
                            Label("This child thread is read-only.", systemImage: "lock")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if store.searchesMessageContent, !store.selectedSearchOccurrences.isEmpty {
                    inspectorSection("Search matches") {
                        ForEach(store.selectedSearchOccurrences.prefix(12)) { occurrence in
                            Button {
                                store.navigateToSearchOccurrence(occurrence)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    highlightedSearchSnippet(occurrence)
                                    .font(.system(size: 11.5))
                                    .lineLimit(3)
                                    Text("Turn \(occurrence.turnID.prefix(8))")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                    }
                }

                if let usage = store.selectedTokenUsage {
                    inspectorSection("Context") {
                        if let fraction = usage.fractionUsed {
                            ProgressView(value: fraction)
                                .tint(usage.warningLevel == 2 ? .red : (usage.warningLevel == 1 ? .orange : DesktopTheme.accent))
                            Text("\(formatTokens(usage.totalTokens)) of \(formatTokens(usage.contextWindow ?? 0)) tokens used")
                                .font(.system(size: 11.5, weight: .medium))
                        } else {
                            Text("\(formatTokens(usage.totalTokens)) tokens used")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        Text("Latest turn: \(formatTokens(usage.lastTurnTokens)) tokens")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        if usage.warningLevel > 0 {
                            Label(
                                usage.warningLevel == 2
                                    ? "Context is nearly full. Compact before a long follow-up."
                                    : "Context is filling up.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(usage.warningLevel == 2 ? .red : .orange)
                        }
                        if let thread = store.selectedThread {
                            Button {
                                store.compactThread(thread)
                            } label: {
                                Label("Compact context", systemImage: "arrow.down.right.and.arrow.up.left")
                            }
                            .buttonStyle(.link)
                            .disabled(thread.isRunning)
                        }
                    }
                }

                inspectorSection("Project") {
                    Label(
                        store.hasExplicitWorkspace ? store.effectiveWorkspaceURL.lastPathComponent : "No project selected",
                        systemImage: "folder"
                    )
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.hasExplicitWorkspace ? store.effectiveWorkspaceURL.path : "Open a project before starting a chat.")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Choose…") { store.chooseWorkspace() }
                        Button("Reveal") { store.revealWorkspace() }
                            .disabled(!store.hasExplicitWorkspace)
                    }
                    .controlSize(.small)
                }

                inspectorSection("Access") {
                    Picker("Access", selection: Binding(
                        get: { store.accessMode },
                        set: { store.updateAccessMode($0) }
                    )) {
                        ForEach(DesktopAccessMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()

                    Text(store.accessMode.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                inspectorSection("Local tools") {
                    Button {
                        store.openTerminal()
                    } label: {
                        Label("Open Terminal here", systemImage: "terminal")
                    }
                    .buttonStyle(.link)

                    Button {
                        store.refreshThreads()
                    } label: {
                        Label("Refresh chats", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(18)
        }
    }

    private func highlightedSearchSnippet(_ occurrence: DesktopThreadSearchOccurrence) -> Text {
        let source = occurrence.snippet as NSString
        let before = source.substring(to: occurrence.matchStart)
        let match = source.substring(with: NSRange(
            location: occurrence.matchStart,
            length: occurrence.matchEnd - occurrence.matchStart
        ))
        let after = source.substring(from: occurrence.matchEnd)
        return Text(before) + Text(match).bold().foregroundColor(DesktopTheme.accent) + Text(after)
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Circle().fill(color).frame(width: 6, height: 6)
            Text(value)
        }
        .font(.system(size: 11.5, weight: .medium))
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

struct DesktopMenuBarView: View {
    @ObservedObject var store: DesktopCodexStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Veo").font(.headline)
                    Text(store.runtimeState.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(store.runtimeState.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
            }

            Divider()

            Button("Open Veo") {
                openWindow(id: "workspace")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("New Chat") {
                store.beginNewChat()
                openWindow(id: "workspace")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Open Project…") {
                store.chooseWorkspace()
                openWindow(id: "workspace")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Quit Veo") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}
