// FILE: DesktopWorkspaceView.swift
// Purpose: Renders the native macOS workspace: all-repo sidebar, conversation timeline, composer, and inspector.
// Layer: Desktop app view
// Depends on: SwiftUI, AppKit, DesktopCodexStore

import AppKit
import SwiftUI

private struct DesktopConversationInputVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var desktopConversationInputVisible: Bool {
        get { self[DesktopConversationInputVisibleKey.self] }
        set { self[DesktopConversationInputVisibleKey.self] = newValue }
    }
}

enum DesktopTheme {
    /// Default accent used when no custom color is stored.
    static let accent = Color(red: 0.18, green: 0.55, blue: 0.98)
    static let sidebarWidth: CGFloat = 318
    static let conversationWidth: CGFloat = 820
    static let conversationMinWidth: CGFloat = 560
    static let welcomeWidth: CGFloat = 680
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        Self.isDark(appearance)
            ? NSColor(srgbRed: 0.075, green: 0.078, blue: 0.082, alpha: 1)
            : NSColor(srgbRed: 0.965, green: 0.968, blue: 0.973, alpha: 1)
    })
    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        Self.isDark(appearance)
            ? NSColor(srgbRed: 0.105, green: 0.108, blue: 0.114, alpha: 1)
            : NSColor(srgbRed: 0.925, green: 0.929, blue: 0.937, alpha: 1)
    })
    static let raised = Color(nsColor: NSColor(name: nil) { appearance in
        Self.isDark(appearance)
            ? NSColor(white: 1, alpha: 0.045)
            : NSColor(white: 0, alpha: 0.04)
    })
    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        Self.isDark(appearance)
            ? NSColor(white: 1, alpha: 0.09)
            : NSColor(white: 0, alpha: 0.1)
    })
    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat = 8
    static let spaceM: CGFloat = 12
    static let spaceL: CGFloat = 16
    static let spaceXL: CGFloat = 24
    static let radiusCard: CGFloat = 11
    static let radiusControl: CGFloat = 8

    static func canvas(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? Color(red: 0.965, green: 0.968, blue: 0.973)
            : Color(red: 0.075, green: 0.078, blue: 0.082)
    }

    static func sidebar(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? Color(red: 0.925, green: 0.929, blue: 0.937)
            : Color(red: 0.105, green: 0.108, blue: 0.114)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// Applies Solid / Mica / Liquid Glass chrome behind the chat or settings sidebar.
struct DesktopSidebarChromeBackground: ViewModifier {
    let material: DesktopSidebarMaterial

    func body(content: Content) -> some View {
        content
            .background {
                Group {
                    switch material {
                    case .solid:
                        DesktopTheme.sidebar
                    case .mica:
                        DesktopVisualEffectBackground(material: .sidebar)
                    case .liquidGlass:
                        liquidGlassBackground
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
            }
    }

    @ViewBuilder
    private var liquidGlassBackground: some View {
        if #available(macOS 26.0, *) {
            // NavigationSplitView owns the system Liquid Glass sidebar surface.
            // A custom full-pane glassEffect masks that native material,
            // especially in Light appearance.
            Color.clear
        } else {
            DesktopVisualEffectBackground(material: .sidebar)
        }
    }
}

private struct DesktopVisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
        nsView.isEmphasized = false
    }
}

/// Disables AppKit’s system-blue list selection so rows can paint `veoAccent` themselves.
struct DesktopSidebarListSelectionStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        FinderView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FinderView)?.scheduleDisable()
    }

    private final class FinderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleDisable()
        }

        override func layout() {
            super.layout()
            scheduleDisable()
        }

        func scheduleDisable() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Self.disableNearbyTables(from: self)
            }
        }

        private static func disableNearbyTables(from view: NSView) {
            var current: NSView? = view
            while let candidate = current {
                if let table = table(in: candidate) {
                    table.selectionHighlightStyle = .none
                    return
                }
                for sibling in candidate.subviews {
                    if let table = table(in: sibling) {
                        table.selectionHighlightStyle = .none
                        return
                    }
                }
                current = candidate.superview
            }
        }

        private static func table(in root: NSView) -> NSTableView? {
            if let table = root as? NSTableView {
                return table
            }
            if let scroll = root as? NSScrollView, let table = scroll.documentView as? NSTableView {
                return table
            }
            for child in root.subviews {
                if let table = table(in: child) {
                    return table
                }
            }
            return nil
        }
    }
}

extension View {
    func desktopSidebarChrome(_ material: DesktopSidebarMaterial) -> some View {
        modifier(DesktopSidebarChromeBackground(material: material))
    }

    func desktopRightSidebarChrome(_ material: DesktopSidebarMaterial) -> some View {
        modifier(DesktopRightSidebarChromeBackground(material: material))
    }
}

/// Applies the independently configurable material behind the utility panel.
/// Unlike the leading NavigationSplitView sidebar, this pane owns its surface.
private struct DesktopRightSidebarChromeBackground: ViewModifier {
    let material: DesktopSidebarMaterial

    func body(content: Content) -> some View {
        content.background {
            switch material {
            case .solid:
                DesktopTheme.sidebar
                    .ignoresSafeArea(.container, edges: .top)
            case .mica:
                DesktopVisualEffectBackground(material: .sidebar)
                    .ignoresSafeArea(.container, edges: .top)
            case .liquidGlass:
                liquidGlassBackground
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
    }

    @ViewBuilder
    private var liquidGlassBackground: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Rectangle())
        } else {
            DesktopVisualEffectBackground(material: .sidebar)
        }
        #else
        DesktopVisualEffectBackground(material: .sidebar)
        #endif
    }
}

/// Solid / Mica / Liquid Glass canvas behind the main window content.
struct DesktopWindowChromeBackground: View {
    let material: DesktopWindowMaterial

    var body: some View {
        switch material {
        case .solid:
            DesktopTheme.canvas
                .ignoresSafeArea()
        case .mica:
            DesktopVisualEffectBackground(material: .underWindowBackground)
                .ignoresSafeArea()
        case .liquidGlass:
            liquidGlass
        }
    }

    @ViewBuilder
    private var liquidGlass: some View {
        // glassEffect is an Xcode 26 SDK symbol. Older CI compilers fall back
        // to Mica, matching the sidebar's pre-macOS 26 behavior.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: Rectangle())
                .ignoresSafeArea()
        } else {
            DesktopVisualEffectBackground(material: .underWindowBackground)
                .ignoresSafeArea()
        }
        #else
        DesktopVisualEffectBackground(material: .underWindowBackground)
            .ignoresSafeArea()
        #endif
    }
}

private struct DesktopNotificationToast: View {
    let toast: DesktopNotificationService.Toast
    let material: DesktopNotificationMaterial
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(toast.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss warning")
        }
        .padding(12)
        .frame(width: 360)
        .modifier(DesktopNotificationToastSurface(material: material))
        .accessibilityElement(children: .combine)
    }
}

private struct DesktopNotificationToastSurface: ViewModifier {
    let material: DesktopNotificationMaterial
    private let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        switch material {
        case .solid:
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.stroke(DesktopTheme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        case .mica:
            micaSurface(content)
        case .liquidGlass:
            liquidGlassSurface(content)
        }
    }

    private func micaSurface(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.stroke(DesktopTheme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    @ViewBuilder
    private func liquidGlassSurface(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: shape)
                .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
        } else {
            micaSurface(content)
        }
        #else
        micaSurface(content)
        #endif
    }
}

struct DesktopWorkspaceView: View {
    @EnvironmentObject private var notifications: DesktopNotificationService
    @EnvironmentObject private var menuBarController: DesktopMenuBarController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Bindable var store: DesktopCodexStore
    @ObservedObject var navigation: DesktopNavigationState
    @State private var inspectorVisible = false
    @State private var utilityPanelExpanded = false
    let canPresentNotice: Bool
    @State private var showsModelPickerUpgrade = false
    @SceneStorage("VeoDesktop.utilityPanel.width") private var utilityPanelWidth = 560.0
    @State private var utilityPanelResizeStartWidth: Double?
    @AppStorage(DesktopAppearancePreferences.accentColorKey) private var accentColorHex =
        DesktopAppearancePreferences.defaultAccentHex
    @AppStorage(DesktopNotificationPreferences.menuBarIconKey) private var showsMenuBarIcon = true
    @AppStorage(DesktopAppearancePreferences.notificationMaterialKey) private var notificationMaterialRaw =
        DesktopNotificationMaterial.mica.rawValue
    @StateObject private var terminalHub = DesktopLocalTerminalHub()
    @StateObject private var utilityPanel = DesktopUtilityPanelModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsInteractiveTerminal = false
    @State private var isTerminalWorkspace = false
    @State private var commandRenameTarget: DesktopThread?
    @State private var commandForkTarget: DesktopThread?
    @State private var commandDeleteTarget: DesktopThread?

    private var accentColor: Color {
        DesktopAppearancePreferences.color(fromHex: accentColorHex) ?? DesktopTheme.accent
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ZStack {
                DesktopSidebarView(store: store) {
                    navigation.showSettings()
                } openUpdates: {
                    navigation.showSettings(.updates)
                }
                .opacity(navigation.page == .workspace && !isTerminalWorkspace ? 1 : 0)
                .allowsHitTesting(navigation.page == .workspace && !isTerminalWorkspace)
                .accessibilityHidden(navigation.page != .workspace || isTerminalWorkspace)

                DesktopTerminalSessionSidebar(
                    store: store,
                    hub: terminalHub,
                    isWorkspace: $isTerminalWorkspace,
                    isPresented: $showsInteractiveTerminal
                ) {
                    navigation.showSettings()
                }
                .opacity(navigation.page == .workspace && isTerminalWorkspace ? 1 : 0)
                .allowsHitTesting(navigation.page == .workspace && isTerminalWorkspace)
                .accessibilityHidden(navigation.page != .workspace || !isTerminalWorkspace)

                DesktopSettingsSidebarView(navigation: navigation)
                    .opacity(navigation.page == .settings ? 1 : 0)
                    .allowsHitTesting(navigation.page == .settings)
                    .accessibilityHidden(navigation.page != .settings)
            }
            .navigationSplitViewColumnWidth(min: 236, ideal: DesktopTheme.sidebarWidth, max: 360)
        } detail: {
            ZStack {
                workspaceDetail
                    .opacity(navigation.page == .workspace ? 1 : 0)
                    .allowsHitTesting(navigation.page == .workspace)
                    .accessibilityHidden(navigation.page != .workspace)

                DesktopSettingsPage(store: store, navigation: navigation)
                    .opacity(navigation.page == .settings ? 1 : 0)
                    .allowsHitTesting(navigation.page == .settings)
                    .accessibilityHidden(navigation.page != .settings)
            }
            .toolbar(id: "workspace") { workspaceToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 920, minHeight: 640)
        .tint(accentColor)
        .environment(\.veoAccent, accentColor)
        .overlay(alignment: .topTrailing) {
            if let toast = notifications.toast {
                DesktopNotificationToast(
                    toast: toast,
                    material: DesktopNotificationMaterial(rawValue: notificationMaterialRaw) ?? .mica
                ) {
                    notifications.dismissToast()
                }
                .padding(.top, 46)
                .padding(.trailing, 18)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: notifications.toast)
        .task {
            store.attachNotifications(notifications)
            menuBarController.configure(store: store) {
                openWindow(id: "workspace")
            }
            menuBarController.setVisible(showsMenuBarIcon)
            store.startIfNeeded()
            if canPresentNotice && store.activeAgent == nil && DesktopModelPickerUpgrade.claimNotice() { showsModelPickerUpgrade = true }
        }
        .onChange(of: canPresentNotice && store.activeAgent == nil) { _, ready in
            if ready && DesktopModelPickerUpgrade.claimNotice() { showsModelPickerUpgrade = true }
        }
        .onChange(of: navigation.page) { _, page in
            if page == .settings {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onChange(of: showsMenuBarIcon) { _, visible in
            menuBarController.setVisible(visible)
        }
        .onChange(of: store.composerCommandDestinationRequest) { _, destination in
            guard let destination else { return }
            switch destination {
            case .sideChat:
                utilityPanel.show(.sideChat)
                utilityPanelExpanded = false
                inspectorVisible = true
            case .review:
                utilityPanel.show(.review, aiReview: true)
                if !utilityPanelExpanded { inspectorVisible = true }
            case .settings(let category):
                navigation.showSettings(category)
            case .changes:
                utilityPanel.show(.review)
                if !utilityPanelExpanded { inspectorVisible = true }
            case .terminal:
                showsInteractiveTerminal = true
            case .rename:
                commandRenameTarget = store.selectedThread
            case .fork:
                commandForkTarget = store.selectedThread
            case .delete:
                commandDeleteTarget = store.selectedThread
            }
            store.consumeComposerCommandDestinationRequest()
        }
        .sheet(item: $store.moveThreadTarget) { thread in
            DesktopChatMoveSheet(store: store, thread: thread)
        }
        .sheet(isPresented: $showsModelPickerUpgrade, onDismiss: {
            DesktopModelPickerUpgrade.finishNotice()
        }) {
            DesktopPickerUpgradeNotice(store: store) {
                DesktopModelPickerUpgrade.finishNotice(restoreNative: true)
                showsModelPickerUpgrade = false
            } keep: {
                DesktopModelPickerUpgrade.finishNotice()
                showsModelPickerUpgrade = false
            }
            .tint(accentColor)
            .environment(\.veoAccent, accentColor)
        }
        .sheet(item: $store.pendingRequest) { request in
            DesktopPendingRequestView(request: request, store: store)
                .interactiveDismissDisabled()
        }
        .sheet(item: $commandRenameTarget) { thread in
            DesktopRenameThreadView(thread: thread, store: store)
        }
        .sheet(item: $commandForkTarget) { thread in
            DesktopForkThreadView(thread: thread, store: store)
        }
        .alert(
            "Delete chat permanently?",
            isPresented: Binding(
                get: { commandDeleteTarget != nil },
                set: { if !$0 { commandDeleteTarget = nil } }
            ),
            presenting: commandDeleteTarget
        ) { thread in
            Button("Delete", role: .destructive) {
                store.deleteThread(thread)
                commandDeleteTarget = nil
            }
            Button("Cancel", role: .cancel) { commandDeleteTarget = nil }
        } message: { thread in
            if thread.workspaceKind.isAppManaged {
                Text("“\(thread.title)” and its projectless workspace will be removed from Veo.")
            } else {
                Text("“\(thread.title)” will be removed from Veo. Local project files are not reverted.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.shutDown()
        }
        .onChange(of: store.hasExplicitWorkspace) { _, hasWorkspace in
            if !hasWorkspace {
                isTerminalWorkspace = false
                showsInteractiveTerminal = false
                terminalHub.terminateAll()
            }
        }
        .onChange(of: showsInteractiveTerminal) { _, shown in
            if !shown {
                isTerminalWorkspace = false
            }
        }
        .onChange(of: isTerminalWorkspace) { _, active in
            if active {
                showsInteractiveTerminal = true
            }
        }
        .onAppear {
            store.prepareForWorkspaceChange = utilityPanel.prepareForWorkspaceChange
            store.cancelDeferredWorkspaceChange = utilityPanel.cancelDeferredWorkspaceChange
            utilityPanel.didCloseLastTab = {
                inspectorVisible = false
                utilityPanelExpanded = false
            }
            store.openInEmbeddedBrowser = { url, accountLogin in
                navigation.showWorkspace()
                inspectorVisible = true
                utilityPanel.openBrowser(url: url, accountLogin: accountLogin)
            }
            if let pending = store.takePendingEmbeddedBrowserURL() {
                store.openInEmbeddedBrowser?(pending.url, pending.accountLogin)
            }
            utilityPanel.switchWorkspace(
                to: store.hasExplicitWorkspace ? store.effectiveWorkspaceURL : nil,
                threadID: store.selectedThreadID
            )
            utilityPanel.setSubagentsAvailable(!store.selectedSubagents.isEmpty)
        }
        .sheet(isPresented: Binding(get: { store.requestedWorktreeProject != nil }, set: { if !$0 { store.requestedWorktreeProject = nil } })) {
            if let project = store.requestedWorktreeProject {
                DesktopWorktreePicker(store: store, projectURL: project) { action, directory in
                    showsInteractiveTerminal = true
                    isTerminalWorkspace = false
                    terminalHub.runProjectAction(action, in: directory)
                }
            }
        }
        .onOpenURL { url in
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
            navigation.showWorkspace()
            inspectorVisible = true
            utilityPanel.openBrowser(url: url)
        }
        .onChange(of: store.effectiveWorkspaceURL.path) { _, _ in
            utilityPanel.switchWorkspace(
                to: store.hasExplicitWorkspace ? store.effectiveWorkspaceURL : nil,
                threadID: store.selectedThreadID
            )
        }
        .onChange(of: store.selectedThreadID) { _, threadID in
            utilityPanel.switchWorkspace(
                to: store.hasExplicitWorkspace ? store.effectiveWorkspaceURL : nil,
                threadID: threadID
            )
        }
        .onChange(of: store.selectedSubagents) { _, agents in
            utilityPanel.setSubagentsAvailable(!agents.isEmpty)
        }
        .background {
            if navigation.page == .workspace {
                if #available(macOS 26.0, *) {
                    EmptyView()
                } else {
                    DesktopToolbarTrailingSpacerBridge()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some CustomizableToolbarContent {
        if navigation.page == .workspace {
            // ToolbarSpacer is an Xcode 26 SDK symbol. Older CI compilers use
            // DesktopToolbarTrailingSpacerBridge below instead.
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            }
            #endif

            ToolbarItem(id: "new-chat", placement: .primaryAction) {
                Button {
                    isTerminalWorkspace = false
                    store.beginNewChat()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .help("New chat")
            }

            if store.canToggleTemporaryChat {
                ToolbarItem(id: "temporary-chat", placement: .primaryAction) {
                    Button {
                        store.toggleSelectedChatTemporary()
                    } label: {
                        DesktopTemporaryChatIcon(isEnabled: store.isTemporaryChat)
                    }
                    .help(store.isTemporaryChat ? "Temporary chat on" : "Make this chat temporary")
                    .accessibilityLabel(store.isTemporaryChat ? "Temporary chat on" : "Make this chat temporary")
                }
            }

            ToolbarItem(id: "worktrees", placement: .primaryAction) {
                Button {
                    store.requestedWorktreeProject = URL(fileURLWithPath: DesktopProjectPreferences.shared.projectPath(for: store.effectiveWorkspaceURL.path))
                } label: { Label("Worktrees", systemImage: "arrow.triangle.branch") }
                .help("Create or reuse a project worktree")
                .keyboardShortcut(DesktopKeyboardPreferences.shared.shortcut(for: "worktrees"))
                .disabled(store.currentWorkspaceKind != .project)
            }

            ToolbarItem(id: "project-actions", placement: .primaryAction) {
                DesktopProjectActionsMenu(path: store.effectiveWorkspaceURL.path, enabled: store.hasExplicitWorkspace) { action in
                    showsInteractiveTerminal = true
                    isTerminalWorkspace = false
                    terminalHub.runProjectAction(action, in: store.effectiveWorkspaceURL)
                } configure: {
                    navigation.showSettings(.projects)
                }
            }

            ToolbarItem(id: "reveal-project", placement: .primaryAction) {
                Button {
                    store.revealWorkspace()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal workspace in Finder")
                .disabled(!store.hasExplicitWorkspace)
            }

            ToolbarItem(id: "terminal", placement: .primaryAction) {
                Button {
                    if showsInteractiveTerminal {
                        isTerminalWorkspace = false
                        showsInteractiveTerminal = false
                    } else {
                        showsInteractiveTerminal = true
                    }
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .help(showsInteractiveTerminal ? "Hide terminal panel" : "Show workspace terminal panel")
                .keyboardShortcut(DesktopKeyboardPreferences.shared.shortcut(for: "terminal"))
                .disabled(!store.hasExplicitWorkspace)
            }

            if inspectorVisible || utilityPanelExpanded {
                ToolbarItem(id: "utility-panel-full-screen", placement: .primaryAction) {
                    Button {
                        if utilityPanelExpanded {
                            utilityPanelExpanded = false
                            inspectorVisible = true
                        } else {
                            inspectorVisible = false
                            utilityPanelExpanded = true
                        }
                    } label: {
                        Label(
                            utilityPanelExpanded ? "Restore Utility Panel" : "Full Screen Utility Panel",
                            systemImage: utilityPanelExpanded
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                    }
                    .help(utilityPanelExpanded ? "Restore utility panel to the sidebar" : "Show utility panel full screen")
                }
            }

            ToolbarItem(id: "utility-panel", placement: .primaryAction) {
                Button {
                    if utilityPanelExpanded {
                        utilityPanelExpanded = false
                        inspectorVisible = false
                    } else {
                        if !inspectorVisible {
                            utilityPanel.ensureOpenTab()
                        }
                        inspectorVisible.toggle()
                    }
                } label: {
                    Label("Utility Panel", systemImage: "sidebar.trailing")
                }
            .help("Toggle utility panel (⌘⌥I)")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }

    private var workspaceDetail: some View {
        GeometryReader { geometry in
            let panelIsVisible = inspectorVisible || utilityPanelExpanded
            // Keep both panes useful. On compact windows the utility surface
            // takes the detail area instead of squeezing the composer away.
            let panelFillsDetail = utilityPanelExpanded
                || (panelIsVisible && geometry.size.width < DesktopTheme.conversationMinWidth + 420)
            let panelWidth = panelFillsDetail
                ? geometry.size.width
                : resolvedUtilityPanelWidth(availableWidth: geometry.size.width)

            ZStack(alignment: .trailing) {
                Group {
                    if isTerminalWorkspace {
                        DesktopTerminalWorkspaceView(
                            store: store,
                            hub: terminalHub,
                            isWorkspace: $isTerminalWorkspace,
                            isPresented: $showsInteractiveTerminal
                        )
                        .environment(\.terminalContextInsertion, store.addTerminalContext)
                    } else {
                        DesktopConversationView(
                            store: store,
                            terminalHub: terminalHub,
                            showsInteractiveTerminal: $showsInteractiveTerminal,
                            isTerminalWorkspace: $isTerminalWorkspace,
                            availableHeight: geometry.size.height,
                            isInputVisible: navigation.page == .workspace && (!panelIsVisible || !panelFillsDetail),
                            onOpenSubagent: { id in
                                utilityPanel.showSubagent(id)
                                if utilityPanelExpanded {
                                    utilityPanelExpanded = false
                                }
                                inspectorVisible = true
                            },
                            onOpenTurnDiff: { diff in
                                utilityPanel.showTurnDiff(diff)
                                utilityPanelExpanded = false
                                inspectorVisible = true
                            },
                            onOpenPlan: { reference in
                                utilityPanel.showPlan(reference)
                                if utilityPanelExpanded {
                                    utilityPanelExpanded = false
                                }
                                inspectorVisible = true
                            }
                        )
                    }
                }
                .padding(.trailing, panelIsVisible && !panelFillsDetail ? panelWidth : 0)
                .opacity(panelIsVisible && panelFillsDetail ? 0 : 1)
                .allowsHitTesting(!panelIsVisible || !panelFillsDetail)
                .accessibilityHidden(panelIsVisible && panelFillsDetail)

                if panelIsVisible {
                    HStack(spacing: 0) {
                        DesktopUtilityPanelResizeHandle(
                            width: panelWidth,
                            onChanged: resizeUtilityPanel,
                            onEnded: finishUtilityPanelResize,
                            adjustWidth: { delta in
                                utilityPanelWidth = min(max(Double(panelWidth + delta), 420), 900)
                            }
                        )
                        .frame(width: panelFillsDetail ? 0 : 7)
                        .opacity(panelFillsDetail ? 0 : 1)
                        .allowsHitTesting(!panelFillsDetail)
                        .accessibilityHidden(panelFillsDetail)

                        VStack(spacing: 0) {
                            if panelFillsDetail && !utilityPanelExpanded {
                                HStack {
                                    Button {
                                        inspectorVisible = false
                                    } label: {
                                        Label("Back to chat", systemImage: "chevron.left")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Close utility panel and return to chat")
                                    Spacer()
                                    Text("Utility panel")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                Divider()
                            }
                            DesktopUtilityPanelView(store: store, model: utilityPanel)
                        }
                    }
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity)
                }
            }
            .onChange(of: panelIsVisible && panelFillsDetail) { _, fillsDetail in
                if fillsDetail {
                    // Opacity/hit-testing do not resign an AppKit text view.
                    // A hidden composer must not keep receiving Return or text.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
            .transaction { transaction in
                // Expanding only changes geometry. Avoid animating the large
                // diff/editor/WebKit subtree or rebuilding it in a new parent.
                transaction.animation = nil
            }
        }
    }

    private func resolvedUtilityPanelWidth(availableWidth: CGFloat) -> CGFloat {
        let available = max(0, availableWidth)
        let upperBound = min(900, available, max(420, available - DesktopTheme.conversationMinWidth))
        let lowerBound = min(420, upperBound)
        return min(max(CGFloat(utilityPanelWidth), lowerBound), upperBound)
    }

    private func resizeUtilityPanel(translation: CGFloat) {
        if utilityPanelResizeStartWidth == nil {
            utilityPanelResizeStartWidth = utilityPanelWidth
        }
        guard let start = utilityPanelResizeStartWidth else { return }
        utilityPanelWidth = min(max(start - Double(translation), 420), 900)
    }

    private func finishUtilityPanelResize() {
        utilityPanelResizeStartWidth = nil
    }
}

private struct DesktopUtilityPanelResizeHandle: View {
    let width: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let adjustWidth: (CGFloat) -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Rectangle().fill(DesktopTheme.canvas)
            Rectangle().fill(DesktopTheme.hairline)
                .frame(width: 1)
            if isHovered {
                Rectangle().fill(Color.primary.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 7)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
        .onDisappear { NSCursor.arrow.set() }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in onChanged(value.translation.width) }
                .onEnded { _ in onEnded() }
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { adjustWidth(24); return .handled }
        .onKeyPress(.rightArrow) { adjustWidth(-24); return .handled }
        .accessibilityElement()
        .accessibilityLabel("Utility panel width")
        .accessibilityValue("\(Int(width)) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjustWidth(24)
            case .decrement: adjustWidth(-24)
            @unknown default: break
            }
        }
    }
}

private struct DesktopTemporaryChatIcon: View {
    let isEnabled: Bool

    var body: some View {
        ZStack {
            Canvas { context, size in
                let scaleX = size.width / 20
                let scaleY = size.height / 20
                var bubble = Path()
                bubble.move(to: CGPoint(x: 6 * scaleX, y: 15 * scaleY))
                bubble.addCurve(
                    to: CGPoint(x: 3 * scaleX, y: 11 * scaleY),
                    control1: CGPoint(x: 4 * scaleX, y: 15 * scaleY),
                    control2: CGPoint(x: 3 * scaleX, y: 13 * scaleY)
                )
                bubble.addLine(to: CGPoint(x: 3 * scaleX, y: 8 * scaleY))
                bubble.addCurve(
                    to: CGPoint(x: 7 * scaleX, y: 4 * scaleY),
                    control1: CGPoint(x: 3 * scaleX, y: 6 * scaleY),
                    control2: CGPoint(x: 5 * scaleX, y: 4 * scaleY)
                )
                bubble.addLine(to: CGPoint(x: 13 * scaleX, y: 4 * scaleY))
                bubble.addCurve(
                    to: CGPoint(x: 17 * scaleX, y: 8 * scaleY),
                    control1: CGPoint(x: 15 * scaleX, y: 4 * scaleY),
                    control2: CGPoint(x: 17 * scaleX, y: 6 * scaleY)
                )
                bubble.addLine(to: CGPoint(x: 17 * scaleX, y: 11 * scaleY))
                bubble.addCurve(
                    to: CGPoint(x: 13 * scaleX, y: 15 * scaleY),
                    control1: CGPoint(x: 17 * scaleX, y: 13 * scaleY),
                    control2: CGPoint(x: 15 * scaleX, y: 15 * scaleY)
                )
                bubble.addLine(to: CGPoint(x: 10 * scaleX, y: 15 * scaleY))
                bubble.addLine(to: CGPoint(x: 6 * scaleX, y: 18 * scaleY))
                bubble.addLine(to: CGPoint(x: 6.5 * scaleX, y: 15 * scaleY))

                context.stroke(
                    bubble,
                    with: .foreground,
                    style: StrokeStyle(
                        lineWidth: 1.65,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [2.6, 2.1]
                    )
                )
            }

            if isEnabled {
                Image(systemName: "checkmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .offset(y: -0.5)
            }
        }
        .frame(width: 20, height: 20)
        .foregroundStyle(isEnabled ? .primary : .secondary)
    }
}

/// Legacy fallback for macOS 14 and 15, before SwiftUI exposed `ToolbarSpacer`.
/// The bridge lives on the detail side so its flexible space follows the split
/// separator instead of competing with the sidebar's leading toolbar section.
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
    @Environment(\.veoAccent) private var veoAccent
    let request: DesktopPendingRequest
    @Bindable var store: DesktopCodexStore
    @State private var mcpValues: [String: String] = [:]

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
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(veoAccent)
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

            if request.kind == .mcpElicitation, request.mcpMode == "form" {
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
                if request.kind == .mcpElicitation {
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
        .tint(veoAccent)
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
                        .foregroundStyle(veoAccent)
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

}

private struct DesktopSidebarView: View {
    @Environment(\.veoAccent) private var veoAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var updateService: DesktopUpdateService
    @Bindable var store: DesktopCodexStore
    let openSettings: () -> Void
    let openUpdates: () -> Void
    @AppStorage("VeoDesktop.collapsedProjectPaths") private var collapsedProjectPathsJSON = "[]"
    @AppStorage("VeoDesktop.sidebarOrganization") private var sidebarOrganizationRaw = DesktopSidebarOrganization.byProject.rawValue
    @AppStorage("VeoDesktop.sidebarSortMode") private var sidebarSortModeRaw = DesktopSidebarSortMode.priority.rawValue
    @AppStorage("VeoDesktop.manualThreadOrder") private var manualThreadOrderJSON = "[]"
    @AppStorage("VeoDesktop.projectDisplayNames") private var projectDisplayNamesJSON = "{}"
    @AppStorage(DesktopAppearancePreferences.leftSidebarMaterialKey) private var sidebarMaterialRaw =
        DesktopSidebarMaterial.solid.rawValue
    @State private var showsSearch = false
    @State private var renameTarget: DesktopThread?
    @State private var editingProjectPath: String?
    @State private var editingProjectName = ""
    @State private var forkTarget: DesktopThread?
    @State private var deleteTarget: DesktopThread?
    @State private var expandedAgentThreadIDs = Set<String>()
    @State private var hoveredSidebarGroup: String?
    @State private var settingsGearTurns = 0
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedProjectPath: String?

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
        projectGroups(for: store.filteredThreads.filter { $0.workspaceKind == .project })
    }

    private var temporaryThreads: [DesktopThread] {
        sortedThreads(store.filteredThreads.filter { $0.workspaceKind.isAppManaged })
    }

    private var codexWorkspaceGroups: [(path: String, name: String, threads: [DesktopThread])] {
        projectGroups(for: store.filteredCodexThreads)
    }

    private var projectDisplayNames: [String: String] {
        DesktopSidebarPreferenceCache.shared.projectDisplayNames(rawJSON: projectDisplayNamesJSON)
    }

    private func projectGroups(
        for candidates: [DesktopThread]
    ) -> [(path: String, name: String, threads: [DesktopThread])] {
        var byID: [String: DesktopThread] = [:]
        byID.reserveCapacity(candidates.count)
        for candidate in candidates where byID[candidate.id] == nil {
            byID[candidate.id] = candidate
        }
        func root(for thread: DesktopThread) -> DesktopThread {
            var current = thread
            var visited = Set([thread.id])
            while let parentID = current.parentThreadID,
                  let parent = byID[parentID], parent.cwd == current.cwd,
                  visited.insert(parentID).inserted {
                current = parent
            }
            return current
        }
        let grouped = Dictionary(grouping: candidates) { root(for: $0).cwd }
        let displayNames = projectDisplayNames
        return grouped
            .map { path, threads in
                let sorted = sortedThreads(threads)
                return (
                    path: path,
                    name: displayNames[path] ?? URL(fileURLWithPath: path).lastPathComponent,
                    threads: sorted,
                    latestUpdatedAt: threads.lazy.map(\.updatedAt).max() ?? .distantPast
                )
            }
            .sorted { lhs, rhs in
                lhs.latestUpdatedAt > rhs.latestUpdatedAt
            }
            .map { (path: $0.path, name: $0.name, threads: $0.threads) }
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

            sidebarContent

            sidebarFooter
        }
        .desktopSidebarChrome(DesktopSidebarMaterial(rawValue: sidebarMaterialRaw) ?? .solid)
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
            if thread.origin == .veo, thread.workspaceKind.isAppManaged {
                Text("“\(thread.title),” its spawned descendants, and its projectless workspace will be removed from Veo.")
            } else if thread.origin == .veo {
                Text("“\(thread.title)” and its spawned descendants will be removed from Veo. Local project files are not reverted.")
            } else {
                Text("“\(thread.title)” and its spawned descendants will be removed from Codex history. Local project files are not reverted.")
            }
        }
    }

    @ViewBuilder
    private var sidebarContent: some View {
        if store.filteredThreads.isEmpty,
           store.filteredCodexThreads.isEmpty,
           !store.isLoadingCodexThreads,
           store.runtimeState.isReady {
            let isSearching = !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Keep the empty state outside List: list-row accessibility otherwise
            // merges the recovery button into a non-actionable row.
            ContentUnavailableView {
                Label(
                    isSearching ? "No matching chats" : (store.isBrowsingArchivedThreads ? "No archived chats" : "No chats yet"),
                    systemImage: isSearching ? "magnifyingglass" : "text.bubble"
                )
            } description: {
                Text(
                    isSearching
                        ? "Try another search or clear it to show your chats."
                        : (store.isBrowsingArchivedThreads
                            ? "Chats you archive will appear here."
                            : "Start a new chat, or enable Codex threads in the sidebar options to browse Codex CLI history.")
                )
            } actions: {
                if isSearching {
                    Button("Clear search") {
                        store.searchText = ""
                        searchFocused = true
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: selection) {
                veoThreadSections

                if store.showCodexThreads {
                    Section("Codex") {
                        if sidebarOrganization == .oneList {
                            let codexEntries = flattenedEntries(for: sortedThreads(store.filteredCodexThreads))
                            ForEach(codexEntries) { entry in
                                codexThreadRow(entry)
                            }
                        } else {
                            ForEach(codexWorkspaceGroups, id: \.path) { group in
                                codexProjectHeader(group.path, name: group.name)
                                if !isProjectCollapsed(group.path) {
                                    let entries = flattenedEntries(for: group.threads)
                                    ForEach(entries) { entry in
                                        codexThreadRow(entry, showsWorkspace: false)
                                    }
                                }
                            }
                        }

                        if store.isLoadingCodexThreads {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .listRowBackground(Color.clear)
                                .accessibilityLabel("Loading Codex chats")
                        } else if store.filteredCodexThreads.isEmpty, store.runtimeState.isReady {
                            Text(store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "No Codex CLI chats to show."
                                : "No Codex chats match your search.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 30)
            .background(DesktopSidebarListSelectionStyle())
        }
    }

    @ViewBuilder
    private var veoThreadSections: some View {
        if sidebarOrganization == .oneList {
            let entries = flattenedEntries(for: sortedThreads(store.filteredThreads))
            ForEach(entries) { entry in
                DesktopThreadRow(
                    thread: entry.thread,
                    showsAutoIndicator: store.shouldShowAutoIndicator(for: entry.thread.id),
                    showsWorkspace: true,
                    pendingRequestCount: store.pendingRequestCount(for: entry.thread.id),
                    hasReadyPlan: store.hasReadyPlan(for: entry.thread.id),
                    agentState: store.agentState(for: entry.thread.id),
                    searchSnippet: store.searchSnippet(for: entry.thread.id),
                    treeDepth: entry.depth,
                    hasChildren: entry.hasChildren,
                    isExpanded: expandedAgentThreadIDs.contains(entry.thread.id),
                    isSelected: store.selectedThreadID == entry.thread.id,
                    isTurnActive: store.isThreadTurnActive(entry.thread.id),
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
                            showsAutoIndicator: store.shouldShowAutoIndicator(for: thread.id),
                            showsWorkspace: true,
                            pendingRequestCount: store.pendingRequestCount(for: thread.id),
                            hasReadyPlan: store.hasReadyPlan(for: thread.id),
                            agentState: store.agentState(for: thread.id),
                            searchSnippet: store.searchSnippet(for: thread.id),
                            hasChildren: false,
                            isSelected: store.selectedThreadID == thread.id,
                            isTurnActive: store.isThreadTurnActive(thread.id)
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

            Section {
                if isProjectCollapsed(temporaryGroupKey) || temporaryThreads.isEmpty {
                    sidebarSectionPlaceholder
                } else {
                    let entries = flattenedEntries(for: temporaryThreads)
                    ForEach(entries) { entry in
                        DesktopThreadRow(
                            thread: entry.thread,
                            showsAutoIndicator: store.shouldShowAutoIndicator(for: entry.thread.id),
                            pendingRequestCount: store.pendingRequestCount(for: entry.thread.id),
                            hasReadyPlan: store.hasReadyPlan(for: entry.thread.id),
                            agentState: store.agentState(for: entry.thread.id),
                            searchSnippet: store.searchSnippet(for: entry.thread.id),
                            treeDepth: entry.depth,
                            hasChildren: entry.hasChildren,
                            isExpanded: expandedAgentThreadIDs.contains(entry.thread.id),
                            isSelected: store.selectedThreadID == entry.thread.id,
                            isTurnActive: store.isThreadTurnActive(entry.thread.id),
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
                        toggleProject(temporaryGroupKey)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isProjectCollapsed(temporaryGroupKey) ? 0 : 90))
                            .frame(width: 13, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.searchText.isEmpty)
                    .help(isProjectCollapsed(temporaryGroupKey) ? "Expand Projectless Chats" : "Collapse Projectless Chats")
                    .accessibilityLabel(isProjectCollapsed(temporaryGroupKey) ? "Expand Projectless Chats" : "Collapse Projectless Chats")

                    HStack(spacing: 5) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .resizable()
                            .scaledToFit()
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(veoAccent)
                            .frame(width: 14, height: 12)
                        Text("Projectless Chats")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12.5, weight: .semibold))

                    Spacer(minLength: 0)

                    if hoveredSidebarGroup == temporaryGroupKey {
                        newThreadButton(
                            help: "New projectless chat",
                            accessibilityLabel: "New projectless chat",
                            action: store.beginNewChat
                        )
                    }
                }
                .textCase(nil)
                .onHover { isHovering in
                    hoveredSidebarGroup = isHovering ? temporaryGroupKey : nil
                }
            }

            ForEach(workspaceGroups, id: \.path) { group in
                Section {
                    if !isProjectCollapsed(group.path) {
                        let entries = flattenedEntries(for: group.threads)
                        ForEach(entries) { entry in
                            DesktopThreadRow(
                                thread: entry.thread,
                                showsAutoIndicator: store.shouldShowAutoIndicator(for: entry.thread.id),
                                pendingRequestCount: store.pendingRequestCount(for: entry.thread.id),
                                hasReadyPlan: store.hasReadyPlan(for: entry.thread.id),
                                agentState: store.agentState(for: entry.thread.id),
                                searchSnippet: store.searchSnippet(for: entry.thread.id),
                                treeDepth: entry.depth,
                                hasChildren: entry.hasChildren,
                                isExpanded: expandedAgentThreadIDs.contains(entry.thread.id),
                                isSelected: store.selectedThreadID == entry.thread.id,
                                isTurnActive: store.isThreadTurnActive(entry.thread.id),
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

                        projectNameControl(path: group.path, name: group.name)

                        Spacer(minLength: 0)

                        if hoveredSidebarGroup == group.path {
                            newThreadButton(
                                help: "New chat in \(group.name)",
                                accessibilityLabel: "New chat in project \(group.name)",
                                action: {
                                    store.beginProjectChat(at: URL(fileURLWithPath: group.path, isDirectory: true))
                                }
                            )
                        }
                    }
                    .textCase(nil)
                    .onHover { isHovering in
                        hoveredSidebarGroup = isHovering ? group.path : nil
                    }
                    .contextMenu { projectContextMenu(path: group.path, name: group.name) }
                }
            }
        }
    }

    private func projectFolderLabel(_ name: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(veoAccent)
            Text(name)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func newThreadButton(
        help: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13.5, weight: .medium))
                .frame(width: 16, height: 18, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 18, alignment: .trailing)
        // Match the center of the thread row's trailing timestamp column.
        .padding(.trailing, 16)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    private var sidebarSectionPlaceholder: some View {
        Text(" ")
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func projectNameControl(path: String, name: String) -> some View {
        if editingProjectPath == path {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(veoAccent)
                TextField("Project name", text: $editingProjectName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .focused($focusedProjectPath, equals: path)
                    .onSubmit { finishRenamingProject(path) }
                    .onExitCommand { cancelRenamingProject() }
                    .onChange(of: focusedProjectPath) { oldPath, newPath in
                        if oldPath == path, newPath != path {
                            finishRenamingProject(path)
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                store.setWorkspace(URL(fileURLWithPath: path))
            } label: {
                projectFolderLabel(name)
            }
            .buttonStyle(.plain)
            .help(path)
            .accessibilityLabel("Use project \(name)")
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
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { showsSearch.toggle() }
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
        .padding(.top, DesktopTheme.spaceXS)
        // The expanded search field supplies its own spacing, so the standing
        // gap below the buttons would otherwise read as dead space.
        .padding(.bottom, showsSearch ? DesktopTheme.spaceXS : DesktopTheme.spaceL)
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
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
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

            Toggle("Show Codex threads", isOn: Binding(
                get: { store.showCodexThreads },
                set: { store.setShowCodexThreads($0) }
            ))

            Toggle("Browse Archived Chats", isOn: Binding(
                get: { store.isBrowsingArchivedThreads },
                set: { store.setBrowsingArchivedThreads($0) }
            ))

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
            .frame(width: 14, height: 14, alignment: .center)
            .help(store.runtimeState.title)
            .accessibilityLabel("Codex runtime")
            .accessibilityValue(store.runtimeState.title)
    }

    @ViewBuilder
    private func threadContextMenu(_ thread: DesktopThread) -> some View {
        if thread.origin == .veo {
            Button { store.requestChatMove(thread) } label: {
                Label("Move to project…", systemImage: "folder")
            }
            .disabled(store.moveUnavailableReason(thread) != nil)
            .help(store.moveUnavailableReason(thread) ?? "Move future turns to a different project")
        }
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
                    .foregroundStyle(store.searchesMessageContent ? veoAccent : Color.secondary.opacity(0.65))
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
            VStack(spacing: 0) {
                updateStatusRow
                HStack(spacing: 8) {
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

                    Button(action: openSettingsFromGear) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13))
                            .rotationEffect(.degrees(Double(settingsGearTurns) * 360))
                            .frame(width: 26, height: 26, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                    .accessibilityLabel("Settings")
                }
                .padding(.bottom, DesktopTheme.spaceM)
            }
            .padding(.horizontal, DesktopTheme.spaceM)
            .padding(.top, 9)
        }
    }

    private func openSettingsFromGear() {
        guard !reduceMotion else {
            openSettings()
            return
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            settingsGearTurns += 1
        } completion: {
            openSettings()
        }
    }

    /// Sits directly above the runtime status so update state reads before connection state.
    @ViewBuilder
    private var updateStatusRow: some View {
        Button {
            switch updateService.phase {
            case .readyToRelaunch:
                updateService.relaunch()
            case let .available(release):
                updateService.installUpdate(release)
            case .checking, .downloading, .installing:
                openUpdates()
            default:
                updateService.checkForUpdates(userInitiated: true)
            }
        } label: {
            HStack(spacing: 8) {
                updateIcon
                switch updateService.phase {
                case .downloading, .installing:
                    DesktopShimmerText(
                        text: updateStatusTitle,
                        font: .system(size: 11.5, weight: .medium),
                        isActive: true
                    )
                default:
                    Text(updateStatusTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(updateIsActionable ? veoAccent : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: openUpdates) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 26, height: 26, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .help("Update settings")
                .accessibilityLabel("Update settings")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(updateStatusHelp)
        .accessibilityLabel("Software update")
        .accessibilityValue(updateStatusTitle)
    }

    private var updateIsActionable: Bool {
        switch updateService.phase {
        case .available, .readyToRelaunch: return true
        default: return false
        }
    }

    @ViewBuilder
    private var updateIcon: some View {
        Group {
            switch updateService.phase {
            case .checking:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 8, height: 8)
            case .downloading, .installing:
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(veoAccent)
            case .available, .readyToRelaunch:
                Circle()
                    .fill(veoAccent)
                    .frame(width: 8, height: 8)
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.orange)
            case .idle, .upToDate:
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 14, height: 14, alignment: .center)
    }

    private var updateStatusTitle: String {
        switch updateService.phase {
        case .checking:
            return "Checking for updates…"
        case let .downloading(progress):
            return "Downloading update… \(Int((progress * 100).rounded()))%"
        case .installing:
            return "Installing update…"
        case let .available(release):
            return "Update available — \(release.version)"
        case let .readyToRelaunch(release):
            return "Relaunch to finish \(release.version)"
        case .failed:
            return "Update check failed"
        case .upToDate:
            return "Veo \(updateService.currentVersion) is up to date"
        case .idle:
            return "Check for updates"
        }
    }

    private var updateStatusHelp: String {
        switch updateService.phase {
        case .available:
            return "Download and install this update"
        case .readyToRelaunch:
            return "Relaunch Veo to finish updating"
        case let .failed(message):
            return message
        default:
            return "Check for updates"
        }
    }

    private var collapsedProjectPaths: Set<String> {
        DesktopSidebarPreferenceCache.shared.collapsedProjectPaths(rawJSON: collapsedProjectPathsJSON)
    }

    private var sidebarOrganization: DesktopSidebarOrganization {
        DesktopSidebarOrganization(rawValue: sidebarOrganizationRaw) ?? .byProject
    }

    private var sidebarSortMode: DesktopSidebarSortMode {
        DesktopSidebarSortMode(rawValue: sidebarSortModeRaw) ?? .priority
    }

    private var manualThreadOrder: [String] {
        DesktopSidebarPreferenceCache.shared.manualThreadOrder(rawJSON: manualThreadOrderJSON).ids
    }

    private var canManuallyReorder: Bool {
        sidebarSortMode == .manual && store.searchText.isEmpty
    }

    private var canCollapseAllProjects: Bool {
        sidebarOrganization == .byProject
            && store.searchText.isEmpty
            && allSidebarProjectPaths.contains(where: { !collapsedProjectPaths.contains($0) })
    }

    private var canExpandAllProjects: Bool {
        sidebarOrganization == .byProject
            && store.searchText.isEmpty
            && allSidebarProjectPaths.contains(where: { collapsedProjectPaths.contains($0) })
    }

    private var allSidebarProjectPaths: Set<String> {
        var paths = Set(workspaceGroups.map(\.path) + codexWorkspaceGroups.map(\.path))
        paths.insert(temporaryGroupKey)
        return paths
    }

    private var temporaryGroupKey: String { "__veo_temporary_chats__" }

    @ViewBuilder
    private func codexThreadRow(
        _ entry: DesktopThreadTreeEntry,
        showsWorkspace: Bool = true
    ) -> some View {
        DesktopThreadRow(
            thread: entry.thread,
            showsAutoIndicator: store.shouldShowAutoIndicator(for: entry.thread.id),
            showsWorkspace: showsWorkspace,
            pendingRequestCount: store.pendingRequestCount(for: entry.thread.id),
            hasReadyPlan: store.hasReadyPlan(for: entry.thread.id),
            agentState: store.agentState(for: entry.thread.id),
            searchSnippet: store.searchSnippet(for: entry.thread.id),
            treeDepth: entry.depth,
            hasChildren: entry.hasChildren,
            isExpanded: expandedAgentThreadIDs.contains(entry.thread.id),
            isSelected: store.selectedThreadID == entry.thread.id,
            isTurnActive: store.isThreadTurnActive(entry.thread.id),
            toggleExpanded: { toggleAgentThread(entry.thread.id) }
        )
        .tag(entry.thread.id)
        .contextMenu { threadContextMenu(entry.thread) }
    }

    private func codexProjectHeader(_ path: String, name: String) -> some View {
        HStack(spacing: 5) {
            Button {
                toggleProject(path)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isProjectCollapsed(path) ? 0 : 90))
                    .frame(width: 13, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!store.searchText.isEmpty)
            .help(isProjectCollapsed(path) ? "Expand \(name)" : "Collapse \(name)")
            .accessibilityLabel(isProjectCollapsed(path) ? "Expand project \(name)" : "Collapse project \(name)")

            projectNameControl(path: path, name: name)
        }
        .listRowBackground(Color.clear)
        .contextMenu { projectContextMenu(path: path, name: name) }
    }

    @ViewBuilder
    private func projectContextMenu(path: String, name: String) -> some View {
        Button {
            editingProjectName = name
            editingProjectPath = path
            DispatchQueue.main.async {
                focusedProjectPath = path
            }
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
    }

    private func finishRenamingProject(_ path: String) {
        guard editingProjectPath == path else { return }
        let trimmed = editingProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            renameProject(at: path, to: trimmed)
        }
        editingProjectPath = nil
        focusedProjectPath = nil
    }

    private func cancelRenamingProject() {
        editingProjectPath = nil
        focusedProjectPath = nil
    }

    private func renameProject(at path: String, to name: String) {
        var names = projectDisplayNames
        let folderName = URL(fileURLWithPath: path).lastPathComponent
        if name == folderName {
            names.removeValue(forKey: path)
        } else {
            names[path] = name
        }
        guard let data = try? JSONEncoder().encode(names),
              let encoded = String(data: data, encoding: .utf8) else { return }
        projectDisplayNamesJSON = encoded
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
            let ranks = DesktopSidebarPreferenceCache.shared
                .manualThreadOrder(rawJSON: manualThreadOrderJSON)
                .ranks
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
        saveCollapsedProjectPaths(collapsedProjectPaths.union(allSidebarProjectPaths))
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
    @Bindable var store: DesktopCodexStore
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
    @Environment(\.veoAccent) private var veoAccent
    private static let allHistory = "__all_history__"

    let thread: DesktopThread
    @Bindable var store: DesktopCodexStore
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
                    .foregroundStyle(selectedBoundaryID == id ? veoAccent : .secondary)
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
                selectedBoundaryID == id ? veoAccent.opacity(0.1) : Color.primary.opacity(0.035),
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
    @Environment(\.veoAccent) private var veoAccent
    let thread: DesktopThread
    var showsAutoIndicator = false
    var showsWorkspace = false
    var pendingRequestCount = 0
    var hasReadyPlan = false
    var agentState: DesktopAgentState?
    var searchSnippet: String?
    var treeDepth = 0
    var hasChildren = false
    var isExpanded = false
    var isSelected = false
    var isTurnActive = false
    var toggleExpanded: (() -> Void)?

    private var showsActiveTurn: Bool {
        isTurnActive || thread.isRunning || agentState?.isActive == true
    }

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
            if showsActiveTurn {
                Circle()
                    .fill(veoAccent)
                    .frame(width: 5, height: 5)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    DesktopShimmerText(
                        text: thread.title,
                        font: .system(size: 12.5, weight: .regular),
                        baseStyle: AnyShapeStyle(.primary),
                        isActive: showsActiveTurn
                    )
                    .lineLimit(1)

                    if showsAutoIndicator {
                        Text("AUTO")
                            .font(.system(size: 7.5, weight: .bold, design: .rounded))
                            .foregroundStyle(veoAccent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(veoAccent.opacity(0.1), in: Capsule())
                            .accessibilityLabel("Auto route")
                    }
                }
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
                        .foregroundStyle(showsActiveTurn ? veoAccent : .secondary)
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
            if hasReadyPlan {
                Image(systemName: "list.bullet.clipboard.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(veoAccent)
                    .accessibilityLabel("Plan ready")
            }
            Group {
                if showsActiveTurn {
                    Text(thread.isSubagent ? "agent" : "live")
                        .foregroundStyle(veoAccent)
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
        .listRowBackground(rowBackground)
    }

    /// Inset rounded selection matching macOS sidebar conventions.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? veoAccent.opacity(0.22) : Color.clear)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
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

private struct DesktopTimelineScrollObserver: NSViewRepresentable {
    let onUserScroll: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserScroll: onUserScroll)
    }

    func makeNSView(context: Context) -> FinderView {
        let view = FinderView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: FinderView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll
        nsView.scheduleAttachment()
    }

    final class FinderView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleAttachment()
        }

        override func layout() {
            super.layout()
            scheduleAttachment()
        }

        func scheduleAttachment() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                coordinator?.attach(toNearestScrollViewFrom: self)
            }
        }
    }

    final class Coordinator {
        var onUserScroll: (Bool) -> Void

        private weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?

        init(onUserScroll: @escaping (Bool) -> Void) {
            self.onUserScroll = onUserScroll
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func attach(toNearestScrollViewFrom view: NSView) {
            var candidate: NSView? = view.superview
            while let current = candidate, !(current is NSScrollView) {
                candidate = current.superview
            }
            guard let nearestScrollView = candidate as? NSScrollView,
                  nearestScrollView !== scrollView else { return }

            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            scrollView = nearestScrollView
            nearestScrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: nearestScrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.handleBoundsChange()
            }
        }

        private func handleBoundsChange() {
            guard let event = NSApp.currentEvent else { return }
            switch event.type {
            case .scrollWheel, .leftMouseDragged, .keyDown:
                break
            default:
                return
            }

            guard let scrollView, let documentView = scrollView.documentView else { return }
            let visibleBottom = scrollView.contentView.bounds.maxY
            let contentBottom = documentView.bounds.maxY
            let distanceFromBottom = max(0, contentBottom - visibleBottom)
            onUserScroll(distanceFromBottom <= 28)
        }
    }
}

private struct TimelineItemBoundsKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct DesktopComposerHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DesktopConversationTurnDivider: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(DesktopTheme.hairline)
            .frame(height: 1 / max(displayScale, 1))
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct DesktopConversationView: View {
    @Environment(\.veoAccent) private var veoAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: DesktopCodexStore
    @ObservedObject var terminalHub: DesktopLocalTerminalHub
    @Binding var showsInteractiveTerminal: Bool
    @Binding var isTerminalWorkspace: Bool
    let availableHeight: CGFloat
    let isInputVisible: Bool
    let onOpenSubagent: (String) -> Void
    let onOpenTurnDiff: (DesktopTurnDiff) -> Void
    let onOpenPlan: (DesktopPlanReference) -> Void
    @AppStorage(DesktopAppearancePreferences.composerMaterialKey) private var composerMaterialRaw =
        DesktopComposerMaterial.liquidGlass.rawValue
    @AppStorage(DesktopAppearancePreferences.threadMinimapVisibleKey) private var showsThreadMinimap = true
    @AppStorage(DesktopAppearancePreferences.threadMinimapMaterialKey) private var threadMinimapMaterialRaw =
        DesktopMinimapMaterial.liquidGlass.rawValue
    @AppStorage(DesktopAppearancePreferences.windowMaterialKey) private var windowMaterialRaw =
        DesktopWindowMaterial.solid.rawValue
    @State private var isPinnedToBottom = true
    @State private var composerHeight: CGFloat = 0
    @State private var expandedWorkTurns: Set<String> = []
    @State private var expansionThreadID: String?
    @State private var autoScrollGeneration = 0
    @State private var isAutoScrollInFlight = false
    @State private var pendingAutoScrollAnimation = false
    @State private var activeMinimapTurnID: String?
    @State private var minimapHover: DesktopThreadMinimapHover?
    @State private var minimapSnapshot = DesktopThreadMinimapSnapshot.empty
    @State private var minimapSnapshotThreadID: String?
    @State private var minimapSnapshotRevision = -1
    @State private var minimapTurns: [DesktopThreadMinimapTurn] = []
    @State private var minimapTurnIDByItemID: [String: String] = [:]
    @State private var minimapAnalysisRequest: DesktopThreadMinimapAnalysisRequest?
    @Namespace private var composerTransitionNamespace
    @State private var messageSendTransition = DesktopMessageSendTransition()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                DesktopWindowChromeBackground(
                    material: DesktopWindowMaterial(rawValue: windowMaterialRaw) ?? .solid
                )

                switch store.runtimeState {
                case .starting:
                    runtimeStarting
                case .unavailable(let message):
                    runtimeUnavailable(message)
                case .ready:
                    if store.selectedThreadID == nil, store.timeline.isEmpty {
                        DesktopWelcomeView(store: store)
                    } else if showsEmptyChat {
                        DesktopEmptyChatView(
                            store: store,
                            composerTransitionNamespace: composerTransitionNamespace
                        )
                    } else {
                        conversation
                            .transition(.identity)
                            .transaction { transaction in
                                if messageSendTransition.isPresenting { transaction.animation = nil }
                            }
                    }
                }
            }
            .navigationTitle(store.selectedThread?.title ?? "New chat")
            .overlay(alignment: .bottom) {
                if store.runtimeState.isReady,
                   !showsEmptyChat,
                   store.selectedThreadID != nil || !store.timeline.isEmpty {
                    DesktopComposerView(
                        store: store,
                        transitionNamespace: composerTransitionNamespace,
                        onOpenSubagent: onOpenSubagent
                    )
                    .background {
                        GeometryReader { composer in
                            Color.clear.preference(
                                key: DesktopComposerHeightPreferenceKey.self,
                                value: composer.size.height
                            )
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            }
            .onPreferenceChange(DesktopComposerHeightPreferenceKey.self) { height in
                guard height.isFinite, abs(composerHeight - height) > 0.5 else { return }
                composerHeight = height
            }
            .animation(composerTransitionAnimation, value: showsEmptyChat)
            .overlay { DesktopMessageSendOverlay(transition: messageSendTransition) }
            .coordinateSpace(name: DesktopMessageSendTransition.coordinateSpace)
            .clipped()

            if showsInteractiveTerminal, !isTerminalWorkspace {
                DesktopInteractiveTerminalPanel(
                    store: store,
                    hub: terminalHub,
                    isPresented: $showsInteractiveTerminal,
                    isWorkspace: $isTerminalWorkspace,
                    availableHeight: availableHeight
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environment(messageSendTransition)
        .environment(\.desktopConversationInputVisible, isInputVisible)
        .onChange(of: store.selectedThreadID) { _, _ in messageSendTransition.cancel() }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled { messageSendTransition.cancel() }
        }
        .onDisappear { messageSendTransition.cancel() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsInteractiveTerminal)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isTerminalWorkspace)
        .onChange(of: showsInteractiveTerminal) { _, shown in
            if !shown {
                isTerminalWorkspace = false
            }
        }
    }

    private var showsEmptyChat: Bool {
        store.selectedThreadID != nil
            && store.timeline.isEmpty
            && !store.isLoadingTimeline
            && !store.isSubmittingTurn
            && !store.isRunningTurn
    }

    private var composerTransitionAnimation: Animation? {
        let material = DesktopComposerMaterial(rawValue: composerMaterialRaw) ?? .liquidGlass
        guard !reduceMotion else { return nil }
        switch material {
        case .liquidGlass:
            return .spring(response: 0.62, dampingFraction: 0.78, blendDuration: 0.12)
        case .solid, .mica:
            return .easeInOut(duration: 0.28)
        }
    }

    private var liveWorkStatus: some View {
        let waiting = store.selectedUserInputRequest != nil ? "Waiting for your answer"
            : store.pendingRequest != nil ? "Waiting for approval"
            : store.isSelectedThreadCompacting ? "Compacting context…"
            : store.isSubmittingTurn && store.selectedLiveTurnStart == nil ? "Starting turn…" : nil
        return DesktopConversationTurnStatus(
            presentation: .init(id: "live", startedAt: store.selectedLiveTurnStart),
            isRunning: true,
            waitingLabel: waiting,
            hasDetails: false,
            isExpanded: false,
            toggle: {}
        )
    }

    private var conversation: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                let timelineEntries = store.timelineEntries
                let activeTimelineItemIDs = store.selectedActiveTimelineItemIDs
                let turnAnchors = DesktopConversationTurnAnchors(store.timeline)
                let presentations = store.selectedTurnPresentations
                let livePromptID = store.timeline.first { $0.kind == .user && activeTimelineItemIDs.contains($0.id) }?.id
                let hasCurrentMinimapSnapshot = showsThreadMinimap
                    && minimapSnapshotThreadID == store.selectedThreadID
                    // Keep the last settled map visible while a turn streams. Rebuilding
                    // an entire long conversation for every output batch adds no useful
                    // navigation signal until the turn settles.
                    && (minimapSnapshotRevision == store.timelineRevision || store.isBusyTurn)
                let visibleMinimapTurns = hasCurrentMinimapSnapshot ? minimapTurns : []
                let visibleMinimapAnalysisRequest = hasCurrentMinimapSnapshot && !store.isBusyTurn
                    ? minimapAnalysisRequest
                    : nil
                let minimapSnapshotTaskID = [
                    store.selectedThreadID ?? "new",
                    store.isBusyTurn ? "streaming" : String(store.timelineRevision),
                    store.isBusyTurn ? "streaming" : "idle",
                    showsThreadMinimap ? "visible" : "hidden",
                ].joined(separator: "|")
                let minimapAnalysisTaskID = [
                    store.selectedThreadID ?? "new",
                    visibleMinimapAnalysisRequest?.fingerprint ?? "unavailable",
                    String(store.utilityModelPreferenceRevision),
                    store.isBusyTurn ? "streaming" : "idle",
                    showsThreadMinimap ? "visible" : "hidden",
                ].joined(separator: "|")
                let minimapMaterial = DesktopMinimapMaterial(rawValue: threadMinimapMaterialRaw) ?? .liquidGlass
                let minimapHeight = min(
                    max(56, CGFloat(visibleMinimapTurns.count) * 14 + 24),
                    max(56, viewport.size.height - 390)
                )

                ZStack {
                    HStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 20) {
                        if store.historyNextCursor != nil {
                            Button {
                                store.loadMoreHistory()
                            } label: {
                                if store.isLoadingMoreHistory {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Load earlier history", systemImage: "clock.arrow.circlepath")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(store.isLoadingMoreHistory)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Load earlier conversation history")
                        }
                        if store.isLoadingTimeline {
                            DesktopTimelineSkeleton()
                        } else {
                            ForEach(timelineEntries) { entry in
                                switch entry {
                                case .turnDivider:
                                    DesktopConversationTurnDivider()

                                case .message(let item):
                                    DesktopTimelineRow(
                                        store: store,
                                        item: item,
                                        workspaceURL: store.effectiveWorkspaceURL,
                                        isTurnRunning: activeTimelineItemIDs.contains(item.id),
                                        autoContinuationJob: item.kind == .error
                                            ? store.autoContinuationJob(for: store.selectedThreadID)
                                            : nil,
                                        onAutoContinuationEnabled: { enabled in
                                            guard let threadID = store.selectedThreadID else { return }
                                            store.setAutoContinuationEnabled(enabled, threadID: threadID)
                                        },
                                        onRetryAutoContinuation: {
                                            guard let threadID = store.selectedThreadID else { return }
                                            store.retryAutoContinuation(threadID: threadID)
                                        }
                                    )
                                    .id(item.id)
                                    .background {
                                        if showsThreadMinimap, !store.isBusyTurn {
                                            timelineBoundsReader(itemIDs: [item.id])
                                        }
                                    }

                                    if item.kind == .user,
                                       let turnID = item.turnID,
                                       let presentation = presentations[turnID],
                                       presentation.completedAt != nil {
                                        let isContinuation = turnAnchors.promptByTurn[turnID] != item.id
                                        let segment = isContinuation ? item.id : turnID
                                        if !isContinuation || turnAnchors.workBySegment[segment] != nil {
                                            DesktopConversationTurnStatus(
                                                presentation: isContinuation ? turnAnchors.continuation(after: item, turn: presentation) : presentation,
                                                isRunning: false,
                                                isContinuation: isContinuation,
                                                summary: turnAnchors.summary(for: segment),
                                                hasDetails: turnAnchors.workBySegment[segment] != nil,
                                                isExpanded: expandedWorkTurns.contains(segment),
                                                toggle: {
                                                    if !expandedWorkTurns.insert(segment).inserted {
                                                        expandedWorkTurns.remove(segment)
                                                    }
                                                }
                                            )
                                        }
                                    } else if livePromptID == item.id {
                                        liveWorkStatus
                                    }

                                    if let turnID = item.turnID,
                                       turnAnchors.replyByTurn[turnID] == item.id,
                                       let diff = presentations[turnID]?.diff {
                                        DesktopTurnDiffLink(diff: diff) { onOpenTurnDiff(diff) }
                                    }

                                case .plan(let item):
                                    if let threadID = store.selectedThreadID {
                                        let reference = DesktopPlanReference(
                                            threadID: threadID,
                                            itemID: item.id
                                        )
                                        DesktopPlanDocumentView(
                                            store: store,
                                            reference: reference,
                                            fallbackMarkdown: item.body,
                                            isStreaming: store.planArtifact(for: reference) == nil
                                                && activeTimelineItemIDs.contains(item.id),
                                            onOpenSidebar: onOpenPlan
                                        )
                                        .id(item.id)
                                        .background {
                                            if showsThreadMinimap, !store.isBusyTurn {
                                                timelineBoundsReader(itemIDs: [item.id])
                                            }
                                        }
                                    }

                                case .activity(let group):
                                    let groupTurn = group.items.first?.turnID
                                    let collapsed = groupTurn.map {
                                        presentations[$0]?.completedAt != nil
                                            && turnAnchors.promptByTurn[$0] != nil
                                            && !expandedWorkTurns.contains(
                                                group.items.first.flatMap { turnAnchors.segmentByItem[$0.id] } ?? $0
                                            )
                                    } ?? false
                                    if !collapsed || group.hasFailure || group.isRoblox || group.isResearch {
                                    DesktopActivityGroupView(
                                        group: group,
                                        workspaceURL: store.effectiveWorkspaceURL,
                                        isTurnRunning: group.itemIDs.contains(where: activeTimelineItemIDs.contains),
                                        subagents: store.subagents(in: group.items),
                                        onOpenSubagent: onOpenSubagent
                                    )
                                    .id(group.id)
                                    .background {
                                        if showsThreadMinimap, !store.isBusyTurn {
                                            timelineBoundsReader(itemIDs: group.itemIDs)
                                        }
                                    }

                                    }
                                case .imageGeneration(let item):
                                    DesktopImageGenerationCard(item: item, workspaceURL: store.effectiveWorkspaceURL,
                                                               isTurnRunning: activeTimelineItemIDs.contains(item.id))
                                        .id(item.id)

                                case .viewedImages(let group):
                                    DesktopViewedImagesView(
                                        group: group,
                                        workspaceURL: store.effectiveWorkspaceURL
                                    )
                                    .id(group.id)
                                    .background {
                                        if showsThreadMinimap, !store.isBusyTurn {
                                            timelineBoundsReader(itemIDs: group.itemIDs)
                                        }
                                    }
                                }
                            }
                        }

                        if store.isBusyTurn && livePromptID == nil {
                            liveWorkStatus
                        }

                        if store.visibleTransientError != nil {
                            DesktopErrorNotice(store: store)
                                .id("error")
                        }

                        Color.clear
                            .frame(height: composerHeight + 12)
                            .id(Self.bottomAnchor)
                            }
                            .frame(maxWidth: DesktopTheme.conversationWidth, alignment: .leading)
                            .padding(.horizontal, 34)
                            .padding(.top, 30)
                            .frame(maxWidth: .infinity)
                            .background {
                                DesktopTimelineScrollObserver { userIsNearBottom in
                                    if userIsNearBottom {
                                        isPinnedToBottom = true
                                    } else {
                                        stopFollowingTail()
                                    }
                                }
                            }
                        }

                        if showsThreadMinimap, visibleMinimapTurns.count > 1 {
                            DesktopThreadMinimapView(
                                turns: visibleMinimapTurns,
                                activeTurnID: activeMinimapTurnID,
                                material: minimapMaterial,
                                onSelect: { turn in
                                    stopFollowingTail()
                                    activeMinimapTurnID = turn.id
                                    scrollToTurn(turn, proxy: proxy)
                                },
                                onHover: { minimapHover = $0 }
                            )
                            .frame(width: 38, height: minimapHeight)
                            .frame(maxHeight: .infinity, alignment: .center)
                            .padding(.leading, 4)
                            .padding(.trailing, 10)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                    }

                    if showsThreadMinimap,
                       visibleMinimapTurns.count > 1,
                       let minimapHover,
                       viewport.size.width >= 242,
                       viewport.size.height >= 120 {
                        let previewWidth = min(320, viewport.size.width - 82)
                        let viewportTop = viewport.frame(in: .global).minY
                        let localCenter = minimapHover.globalCenterY > 0
                            ? minimapHover.globalCenterY - viewportTop
                            : 70
                        let previewCenterY = min(max(localCenter, 54), viewport.size.height - 54)

                        DesktopThreadMinimapPreview(turn: minimapHover.turn, material: minimapMaterial)
                            .frame(width: previewWidth)
                            .position(
                                x: viewport.size.width - previewWidth / 2 - 58,
                                y: previewCenterY
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .trailing)))
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: Self.scrollSpace)
                .task(id: store.selectedThreadID) {
                    isPinnedToBottom = true
                    await Task.yield()
                    scheduleScrollToEndIfPinned(proxy, animated: false)
                }
                .task(id: minimapSnapshotTaskID) {
                    refreshMinimapPresentation()
                }
                .task(id: minimapAnalysisTaskID) {
                    store.requestThreadMinimapAnalysis(
                        visibleMinimapAnalysisRequest,
                        isVisible: showsThreadMinimap
                    )
                }
                .onPreferenceChange(TimelineItemBoundsKey.self) { bounds in
                    updateActiveMinimapTurn(
                        bounds: bounds,
                        turns: visibleMinimapTurns,
                        viewportHeight: viewport.size.height
                    )
                }
                .onChange(of: store.timeline.count) { _, _ in
                    scheduleScrollToEndIfPinned(proxy, animated: false)
                }
                .onChange(of: store.timeline.last) { _, _ in
                    scheduleScrollToEndIfPinned(proxy, animated: false)
                }
                .onChange(of: composerHeight) { _, _ in
                    scheduleScrollToEndIfPinned(proxy, animated: false)
                }
                .onChange(of: store.isRunningTurn) { _, _ in
                    scheduleScrollToEndIfPinned(proxy, animated: !messageSendTransition.isPresenting)
                }
                .onChange(of: store.isSubmittingTurn) { _, isSubmitting in
                    guard isSubmitting else { return }
                    isPinnedToBottom = true
                    scheduleScrollToEndIfPinned(proxy, animated: !messageSendTransition.isPresenting)
                }
                .onChange(of: store.selectedThreadID) { _, _ in
                    isPinnedToBottom = true
                    activeMinimapTurnID = nil
                    minimapHover = nil
                    clearMinimapPresentation()
                    scheduleScrollToEndIfPinned(proxy, animated: false)
                }
                .task(id: store.selectedThreadID) {
                    if expansionThreadID != store.selectedThreadID {
                        expandedWorkTurns = []
                        expansionThreadID = store.selectedThreadID
                    }
                    if let threadID = store.selectedThreadID { await store.loadTurnPresentations(threadID: threadID) }
                }
                .onChange(of: showsThreadMinimap) { _, isVisible in
                    if !isVisible {
                        minimapHover = nil
                        activeMinimapTurnID = nil
                        clearMinimapPresentation()
                        store.requestThreadMinimapAnalysis(nil, isVisible: false)
                    }
                }
                .onChange(of: store.threadMinimapTopicStartIDs) { _, _ in
                    refreshMinimapTopicTurns()
                }
                .onChange(of: store.timelineNavigationItemID) { _, itemID in
                    guard let itemID else { return }
                    stopFollowingTail()
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
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
                                .overlay {
                                    Capsule().stroke(DesktopTheme.hairline, lineWidth: 1)
                                        .allowsHitTesting(false)
                                }
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, composerHeight + 8)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isPinnedToBottom)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsThreadMinimap)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: minimapHover?.turn.id)
            }
        }
    }

    private func refreshMinimapPresentation() {
        guard showsThreadMinimap else {
            clearMinimapPresentation()
            return
        }

        let threadID = store.selectedThreadID
        let revision = store.timelineRevision
        if store.isBusyTurn {
            minimapAnalysisRequest = nil
            return
        }
        if minimapSnapshotThreadID == threadID,
           minimapSnapshotRevision == revision {
            if minimapAnalysisRequest == nil {
                minimapAnalysisRequest = minimapSnapshot.makeAnalysisRequest()
            }
            refreshMinimapTopicTurns()
            return
        }

        let snapshot = DesktopThreadMinimapSnapshot(items: store.timeline)
        guard !Task.isCancelled,
              showsThreadMinimap,
              store.selectedThreadID == threadID,
              store.timelineRevision == revision else { return }

        let analysisRequest = snapshot.makeAnalysisRequest()
        minimapSnapshotThreadID = nil
        minimapSnapshot = snapshot
        replaceMinimapTurns(snapshot.topicTurns(modelTopicStartIDs: store.threadMinimapTopicStartIDs))
        minimapAnalysisRequest = analysisRequest
        minimapSnapshotRevision = revision
        minimapSnapshotThreadID = threadID
    }

    private func refreshMinimapTopicTurns() {
        guard showsThreadMinimap,
              minimapSnapshotThreadID == store.selectedThreadID,
              minimapSnapshotRevision == store.timelineRevision else { return }
        replaceMinimapTurns(minimapSnapshot.topicTurns(modelTopicStartIDs: store.threadMinimapTopicStartIDs))
    }

    private func clearMinimapPresentation() {
        minimapSnapshotThreadID = nil
        minimapSnapshotRevision = -1
        minimapSnapshot = .empty
        replaceMinimapTurns([])
        minimapAnalysisRequest = nil
    }

    private func replaceMinimapTurns(_ turns: [DesktopThreadMinimapTurn]) {
        var turnIDByItemID: [String: String] = [:]
        turnIDByItemID.reserveCapacity(turns.reduce(into: 0) { $0 += $1.itemIDs.count })
        for turn in turns {
            for itemID in turn.itemIDs where turnIDByItemID[itemID] == nil {
                turnIDByItemID[itemID] = turn.id
            }
        }
        minimapTurns = turns
        minimapTurnIDByItemID = turnIDByItemID
    }

    private static let scrollSpace = "veo.timeline.scroll"
    private static let bottomAnchor = "veo.timeline.bottom"

    private func timelineBoundsReader(itemIDs: [String]) -> some View {
        GeometryReader { row in
            let frame = row.frame(in: .named(Self.scrollSpace))
            Color.clear.preference(
                key: TimelineItemBoundsKey.self,
                value: Dictionary(itemIDs.map { ($0, frame) }, uniquingKeysWith: { first, _ in first })
            )
        }
    }

    private func scheduleScrollToEndIfPinned(_ proxy: ScrollViewProxy, animated: Bool) {
        guard isPinnedToBottom else { return }
        autoScrollGeneration += 1
        pendingAutoScrollAnimation = pendingAutoScrollAnimation || animated
        guard !isAutoScrollInFlight else { return }
        isAutoScrollInFlight = true

        Task { @MainActor in
            var appliedGeneration = -1

            repeat {
                appliedGeneration = autoScrollGeneration
                let shouldAnimate = pendingAutoScrollAnimation
                pendingAutoScrollAnimation = false

                // Wait for LazyVStack to commit the latest streamed height. A newer
                // delta requests another pass instead of cancelling this one.
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(12))
                guard isPinnedToBottom else { break }
                scrollToEnd(proxy, animated: shouldAnimate && !reduceMotion)
                await Task.yield()
            } while isPinnedToBottom && appliedGeneration != autoScrollGeneration

            let needsAnotherPass = isPinnedToBottom && appliedGeneration != autoScrollGeneration
            isAutoScrollInFlight = false
            if needsAnotherPass {
                scheduleScrollToEndIfPinned(proxy, animated: pendingAutoScrollAnimation)
            }
        }
    }

    private func stopFollowingTail() {
        isPinnedToBottom = false
        autoScrollGeneration += 1
        pendingAutoScrollAnimation = false
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        let scroll = { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.2), scroll)
        } else {
            scroll()
        }
    }

    private func scrollToTurn(_ turn: DesktopThreadMinimapTurn, proxy: ScrollViewProxy) {
        let scroll = { proxy.scrollTo(turn.targetItemID, anchor: .top) }
        if reduceMotion {
            scroll()
        } else {
            withAnimation(.easeInOut(duration: 0.28), scroll)
        }
    }

    private func updateActiveMinimapTurn(
        bounds: [String: CGRect],
        turns: [DesktopThreadMinimapTurn],
        viewportHeight: CGFloat
    ) {
        guard showsThreadMinimap, turns.count > 1 else {
            activeMinimapTurnID = nil
            return
        }
        let turnByItemID = minimapTurnIDByItemID
        let focusY = min(max(viewportHeight * 0.28, 80), 190)
        var bestByTurn: [String: CGFloat] = [:]

        for (itemID, frame) in bounds where frame.maxY >= 0 && frame.minY <= viewportHeight {
            guard let turnID = turnByItemID[itemID] else { continue }
            let distance: CGFloat
            if frame.minY <= focusY, frame.maxY >= focusY {
                distance = 0
            } else {
                distance = min(abs(frame.minY - focusY), abs(frame.maxY - focusY))
            }
            bestByTurn[turnID] = min(bestByTurn[turnID] ?? .greatestFiniteMagnitude, distance)
        }

        guard let next = bestByTurn.min(by: { $0.value < $1.value })?.key,
              next != activeMinimapTurnID else { return }
        activeMinimapTurnID = next
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
                .foregroundStyle(veoAccent)
            Text("Codex isn’t ready")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Text("Install and sign in to the Codex CLI, then try again.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                Button("Try Again") { store.reconnect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canReconnect)
                Button("Runtime settings") {
                    store.performErrorRecovery(.settings(.runtime))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(40)
    }
}

private struct DesktopEmptyChatView: View {
    @Bindable var store: DesktopCodexStore
    let composerTransitionNamespace: Namespace.ID

    var body: some View {
        VStack(spacing: 20) {
            Text("What should we work on?")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            DesktopComposerView(
                store: store,
                isWelcome: true,
                transitionNamespace: composerTransitionNamespace
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }
}

private struct DesktopWelcomeView: View {
    @Bindable var store: DesktopCodexStore

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: DesktopTheme.spaceXL)

            VStack(alignment: .leading, spacing: DesktopTheme.spaceM) {
                DesktopComposerView(store: store, isWelcome: true)
            }
            .frame(maxWidth: DesktopTheme.welcomeWidth)
            .padding(.horizontal, 30)

            Spacer(minLength: DesktopTheme.spaceXL)

            Text("Veo runs Codex locally in a temporary workspace or a project folder you choose.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 28)
        }
    }
}

private struct DesktopTimelineRow: View {
    @Environment(DesktopMessageSendTransition.self) private var messageSendTransition: DesktopMessageSendTransition?
    let store: DesktopCodexStore
    @Environment(\.veoAccent) private var veoAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: DesktopTimelineItem
    let workspaceURL: URL?
    var isTurnRunning = false
    var autoContinuationJob: DesktopAutoContinuationJob?
    var onAutoContinuationEnabled: (Bool) -> Void = { _ in }
    var onRetryAutoContinuation: () -> Void = {}
    @State private var isDetailExpanded = false
    @State private var showsFullCommandOutput = false
    @State private var blockedArtifactURLMessage: String?
    @State private var confirmsHistoryRevert = false
    @State private var showsQuoteEditor = false
    @State private var confirmsEditFromHere = false

    var body: some View {
        Group {
            switch item.kind {
            case .user:
                userRow
            case .assistant:
                assistantRow
            case .reasoning:
                reasoningRow
            case .command, .fileChange, .activity, .plan, .planUpdate, .imageView:
                activityRow
            case .error:
                errorRow
            }
        }
        .contextMenu {
            if item.kind == .assistant {
                Button("Quote response…") { showsQuoteEditor = true }
            }
            if item.kind == .user, item.turnID != nil {
                Button("Edit from here…") { confirmsEditFromHere = true }
                    .disabled(!store.canRevertSelectedHistory)
            }
            if item.turnID != nil {
                Button("Revert history to before this turn…", role: .destructive) {
                    confirmsHistoryRevert = true
                }
                .disabled(!store.canRevertSelectedHistory)
                .help("Available for chats created with paginated Codex history when no turn is running.")
            }
        }
        .confirmationDialog("Edit this prompt and remove later conversation?", isPresented: $confirmsEditFromHere, titleVisibility: .visible) {
            Button("Revert history, keep files", role: .destructive) { store.editFromHere(item, restoreFiles: false) }
            Button("Revert history and restore workspace files", role: .destructive) { store.editFromHere(item, restoreFiles: true) }
                .disabled(store.checkpoint(for: item) == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The prompt and attachments return to your draft. Restoring files replaces tracked and nonignored workspace files and staged changes with the saved checkpoint, including removing new files. A recovery checkpoint is saved first. External actions are not undone.")
        }
        .sheet(isPresented: $showsQuoteEditor) {
            DesktopQuoteEditor(item: item, threadID: store.selectedThreadID ?? "") { store.insertContextAtCaret($0) }
        }
        .confirmationDialog(
            "Revert conversation history?",
            isPresented: $confirmsHistoryRevert,
            titleVisibility: .visible
        ) {
            Button("Remove this turn and everything after it", role: .destructive) {
                if let turnID = item.turnID { store.revertHistory(before: turnID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes conversation history from this point onward. Files in the project are not reverted.")
        }
    }

    private var userRow: some View {
        HStack {
            Spacer(minLength: 90)
            VStack(alignment: .leading, spacing: 8) {
                if !item.body.isEmpty {
                    Text(DesktopInlineContext.displayText(item.body))
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .modifier(DesktopSendGeometry(part: .text, role: .message(item.clientID)))
                }
                ForEach(DesktopInlineContext.scan(item.body), id: \.range.location) { reference in
                    Button(reference.label, systemImage: reference.url.scheme == "veo-quote" ? "quote.bubble" : "link") {
                        store.openInlineContext(reference.url)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                if !item.attachments.isEmpty {
                    DesktopAttachmentStrip(attachments: item.attachments, sendRole: .message(item.clientID))
                }
                if item.turnID != nil {
                    Button("Edit from here…", systemImage: "pencil") { confirmsEditFromHere = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(!store.canRevertSelectedHistory)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .modifier(DesktopSendGeometry(part: .bubble, role: .message(item.clientID)))
            .opacity(messageSendTransition?.presents(item.clientID) == true ? 0 : 1)
            .animation(nil, value: messageSendTransition?.presents(item.clientID))
        }
    }

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 12)
                Button { showsQuoteEditor = true } label: {
                    Label("Quote response", systemImage: "quote.bubble")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Quote response")
                .disabled(item.body.isEmpty)
            }
            .foregroundStyle(.secondary)
            MarkdownMessageView(
                source: item.body,
                artifacts: item.artifacts.filter { artifact in !item.generatedConcepts.contains(where: { $0.source == artifact.source }) },
                citations: item.citations,
                workspaceURL: workspaceURL,
                isStreaming: isActivelyStreamingResponse
            )
            if item.generatedConcepts.count > 1 {
                DesktopGeneratedConcepts(artifacts: item.generatedConcepts, workspaceURL: workspaceURL) { concepts, feedback in
                    store.addConceptFeedback(concepts, from: item.generatedConcepts, feedback: feedback)
                }
            } else if let concept = item.generatedConcepts.first {
                DesktopConceptImage(artifact: concept, workspaceURL: workspaceURL, label: "Generated image")
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isActivelyThinking: Bool {
        guard isTurnRunning else { return false }
        let normalized = (item.status ?? "").lowercased()
        if normalized.contains("complete") || normalized.contains("failed") || normalized == "done" {
            return false
        }
        // Live reasoning deltas mark inProgress; stop once the item completes even if the turn continues.
        return normalized.contains("progress")
            || normalized == "active"
            || normalized == "running"
    }

    private var isActivelyStreamingResponse: Bool {
        guard isTurnRunning,
              item.kind == .assistant,
              !item.body.isEmpty else { return false }
        let normalized = (item.status ?? "").lowercased()
        if normalized.contains("complete") || normalized.contains("failed") || normalized == "done" {
            return false
        }
        return normalized.contains("progress")
            || normalized == "active"
            || normalized == "running"
    }

    private var reasoningRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                toggleDetail()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain")
                        .font(.system(size: 10.5, weight: .medium))
                        .frame(width: 14)
                    DesktopShimmerText(
                        text: "Thinking",
                        font: .system(size: 11.5, weight: .medium),
                        baseStyle: AnyShapeStyle(.secondary),
                        isActive: isActivelyThinking
                    )
                    if !isDetailExpanded, let preview = compactBodyPreview {
                        Text(preview)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isDetailExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDetailExpanded ? "Hide thinking" : "Show thinking")

            if isDetailExpanded {
                Text(item.body)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 21)
                    .transition(.opacity)
            }
        }
    }

    private var activityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleDetail()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: activitySymbol)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(activityTint)
                        .frame(width: 14)
                    Text(item.title)
                        .font(.system(size: 11.5, weight: .medium, design: item.kind == .command ? .monospaced : .default))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if activityIsRunning || activityFailed || activityIsComplete {
                        DesktopActivityCompletionMark(
                            isLoading: activityIsRunning,
                            hasFailure: activityFailed
                        )
                        .frame(width: 12, height: 12)
                    }
                    if let duration = item.toolMetadata?.durationMilliseconds {
                        Text(formatDuration(duration))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isDetailExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isDetailExpanded ? "Hide" : "Show") details for \(item.title)")

            if isDetailExpanded {
                activityDetails
                    .padding(.leading, 21)
                    .transition(.opacity)
            }
        }
    }

    private var activityDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.body)
                .font(.system(size: item.kind == .command ? 11.5 : 12.5, design: item.kind == .command ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(item.kind == .command && !showsFullCommandOutput ? 12 : nil)
                .textSelection(.enabled)

            if item.kind == .command, !item.body.isEmpty {
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
    }

    private var compactBodyPreview: String? {
        item.body
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private var normalizedActivityStatus: String {
        (item.status ?? "").lowercased()
    }

    private var activityIsRunning: Bool {
        isTurnRunning && (
            normalizedActivityStatus.contains("progress")
            || normalizedActivityStatus == "running"
            || normalizedActivityStatus == "active"
            || normalizedActivityStatus == "pending"
        )
    }

    private var activityFailed: Bool {
        normalizedActivityStatus.contains("fail")
            || normalizedActivityStatus.contains("error")
            || normalizedActivityStatus.contains("cancel")
    }

    private var activityIsComplete: Bool {
        normalizedActivityStatus.contains("complete")
            || normalizedActivityStatus.contains("success")
            || normalizedActivityStatus == "done"
    }

    private func toggleDetail() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            isDetailExpanded.toggle()
        }
    }

    private var errorRow: some View {
        Group {
            if let autoContinuationJob,
               item.turnID == autoContinuationJob.failedTurnID {
                usageLimitRow(autoContinuationJob)
            } else {
                DesktopErrorNotice(store: store, item: item)
            }
        }
    }

    private func usageLimitRow(_ job: DesktopAutoContinuationJob) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Usage limit reached", systemImage: "gauge.with.dots.needle.100percent")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.orange)
            Text(usageLimitDetail(job))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Toggle(
                    "Auto-continue when limits reset",
                    isOn: Binding(
                        get: { job.isEnabled && job.status != .completed },
                        set: onAutoContinuationEnabled
                    )
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                Spacer()
                Button("Try Again", action: onRetryAutoContinuation)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func usageLimitDetail(_ job: DesktopAutoContinuationJob) -> String {
        if job.status == .dispatching { return "Continuing the interrupted task now…" }
        if job.status == .blocked, let detail = job.detail { return detail }
        guard let dispatchAt = job.dispatchAt else {
            return "Veo is waiting for Codex to report when the limit resets."
        }
        return job.isEnabled
            ? "Auto-resuming \(dispatchAt.formatted(.relative(presentation: .named)))."
            : "Turn on auto-continue to resume after the limit resets."
    }

    private var activitySymbol: String {
        if item.id.hasPrefix("veo-user-input-answer-") { return "checkmark.bubble" }
        switch item.kind {
        case .command: return "terminal"
        case .fileChange: return "doc.badge.gearshape"
        case .plan: return "list.bullet.clipboard"
        case .planUpdate: return "checklist"
        case .imageView: return "photo"
        default: return "gearshape.2"
        }
    }

    private var activityTint: Color {
        if item.id.hasPrefix("veo-user-input-answer-") { return veoAccent }
        return item.kind == .fileChange ? veoAccent : .secondary
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
    @Environment(\.desktopConversationInputVisible) private var isInputVisible
    @Environment(DesktopMessageSendTransition.self) private var messageSendTransition: DesktopMessageSendTransition?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.veoAccent) private var veoAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: DesktopCodexStore
    var isWelcome = false
    var transitionNamespace: Namespace.ID?
    var onOpenSubagent: (String) -> Void = { _ in }
    @AppStorage(DesktopAppearancePreferences.composerMaterialKey) private var composerMaterialRaw =
        DesktopComposerMaterial.liquidGlass.rawValue
    @AppStorage(DesktopComposerPreferences.showsContextWindowUsageKey) private var showsContextWindowUsage = false
    @AppStorage(DesktopComposerPreferences.contextWindowUsageStyleKey) private var contextWindowUsageStyleRaw =
        DesktopContextWindowUsageStyle.percent.rawValue
    @State private var focusToken = 0
    @State private var pickerGroup = DesktopComposerPickerGroup()
    @State private var dictation = DesktopDictation()
    @State private var dictationDraft: DesktopDictationDraft?
    @State private var dictatedSelection: (text: String, offset: Int)?

    @State private var isOptionsPresented = false
    @State private var recalledPromptIndex: Int?
    @State private var isAttachmentDropTarget = false
    @State private var askQuestionDraftsByRequestID: [String: DesktopAskQuestionsComposerDraft] = [:]

    var body: some View {
        Group {
            if isWelcome {
                composerCard
            } else {
                VStack(spacing: 10) {
                    if !dictation.isActive { DesktopTurnStatusView(store: store, onOpenSubagent: onOpenSubagent) }
                    composerCard
                }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear { requestFocus() }
        .onDisappear { dictation.cancel() }
        .onChange(of: isInputVisible) { _, visible in
            if visible { requestFocus() }
            else { dictation.cancel() }
        }
        .onChange(of: store.selectedThreadID) { _, _ in
            dictation.cancel()
            dictatedSelection = nil
            recalledPromptIndex = nil
            requestFocus()
        }
        .onChange(of: store.hasExplicitWorkspace) { _, _ in requestFocus() }
        .onChange(of: store.selectedUserInputRequest?.id) { previousID, requestID in
            if requestID != nil {
                isAttachmentDropTarget = false
                dictation.cancel()
            }
            if let previousID, !store.hasPendingRequest(id: previousID) {
                askQuestionDraftsByRequestID.removeValue(forKey: previousID)
            }
        }
        .onChange(of: store.pendingRequestCountsByThreadID) { _, _ in
            let pendingIDs = store.pendingUserInputRequestIDs
            askQuestionDraftsByRequestID = askQuestionDraftsByRequestID.filter {
                pendingIDs.contains($0.key)
            }
        }
        .onChange(of: store.draft) { _, _ in
            if dictation.isActive { dictation.cancel() }
            store.updateComposerAutocomplete()
        }
        .onChange(of: store.effectiveWorkspaceURL.path) { _, _ in dictation.cancel() }
        .onChange(of: store.realtimeSession != nil) { _, active in
            if active { dictation.cancel() }
        }
        .onChange(of: dictation.isActive) { _, active in
            if !active { requestFocus() }
        }
        .modifier(ComposerTransitionGeometry(
            namespace: transitionNamespace,
            isEnabled: transitionNamespace != nil,
            properties: composerMaterial == .liquidGlass ? .frame : .position,
            isSource: isWelcome
        ))
    }

    private func recallPrompt(_ direction: Int) -> Bool {
        guard store.attachments.isEmpty else { return false }
        let prompts = store.timeline.reversed().filter { $0.kind == .user && !$0.body.isEmpty }.map(\.body)
        if let index = recalledPromptIndex, prompts.indices.contains(index), prompts[index] == store.draft {
            let next = index - direction
            if next < 0 {
                recalledPromptIndex = nil
                store.draft = ""
            } else if prompts.indices.contains(next) {
                recalledPromptIndex = next
                store.draft = prompts[next]
            }
            return true
        }
        guard direction == -1, store.draft.isEmpty, let latest = prompts.first else { return false }
        recalledPromptIndex = 0
        store.draft = latest
        return true
    }

    private func submitDraft() {
        guard !dictation.isActive else { return }
        store.sendDraft { payload in
            guard !reduceMotion else { return }
            messageSendTransition?.begin(payload)
        }
    }

    private var composerMaterial: DesktopComposerMaterial {
        DesktopComposerMaterial(rawValue: composerMaterialRaw) ?? .liquidGlass
    }

    private var reviewPlan: DesktopPlanArtifact? {
        guard !isWelcome else { return nil }
        return store.selectedPlanForReview
    }

    private var askQuestionsAnimation: Animation? {
        if reduceMotion { return nil }
        switch composerMaterial {
        case .liquidGlass:
            return .spring(response: 0.42, dampingFraction: 0.86)
        case .mica, .solid:
            return .easeInOut(duration: 0.28)
        }
    }

    @ViewBuilder
    private var attachmentDropOverlay: some View {
        if isAttachmentDropTarget, store.hasExplicitWorkspace {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(veoAccent.opacity(0.52), lineWidth: 1)
                    }

                VStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Drop to attach")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(veoAccent)
            }
            .padding(-2)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .accessibilityHidden(true)
        }
    }

    private func requestFocus() {
        guard isInputVisible, store.hasExplicitWorkspace, store.selectedUserInputRequest == nil else { return }
        focusToken += 1
    }

    private var composerCard: some View {
        VStack(spacing: 0) {
            if !dictation.isActive && !isWelcome && !store.selectedQueuedDrafts.isEmpty {
                DesktopQueuedDraftsView(store: store)
                    .transition(.asymmetric(
                        insertion: .offset(y: 5).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            if !dictation.isActive && !store.selectedAsyncQuestions.isEmpty {
                DesktopAsyncQuestionsView(store: store)
                Divider()
            }
            if let request = store.selectedUserInputRequest, !isWelcome {
                DesktopAskQuestionsComposerView(
                    request: request,
                    store: store,
                    draft: askQuestionsDraftBinding(for: request.id)
                )
                    .id(request.id)
                    .transition(.opacity)
            } else {
            VStack(spacing: DesktopTheme.spaceS) {
            if !dictation.isActive {
                if store.visibleTransientError != nil, store.timeline.isEmpty {
                    DesktopErrorNotice(store: store)
                }

                if let plan = reviewPlan,
                   let error = store.planErrorsByID[plan.reference.storageID],
                   !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !isWelcome {
                    DesktopApprovalReviewPanel(store: store)
                    DesktopThreadCapabilityBar(store: store)
                }

                if !store.composerSuggestions.isEmpty {
                    DesktopComposerAutocompletePanel(store: store)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(commandPaletteTransition)
                }

                if let visionFallbackStatus = store.visionFallbackStatus {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(visionFallbackStatus)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(visionFallbackStatus)
                }

                if !store.attachments.isEmpty {
                    DesktopAttachmentStrip(
                        attachments: store.attachments,
                        onRemove: store.removeAttachment,
                        sendRole: .composer
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(store.visionFallbackStatus == nil)
                }

            }

            ZStack(alignment: .topLeading) {
                ComposerTextView(
                    text: $store.draft,
                    placeholder: isWelcome
                        ? "Message \(store.providerTitle) in this workspace…"
                        : (reviewPlan == nil ? "Send follow-up" : "Ask Codex to revise this plan…"),
                    placeholderColor: composerPlaceholderColor,
                    fontSize: isWelcome ? 15 : 14,
                    minHeight: isWelcome ? 70 : 34,
                    maxHeight: isWelcome ? 130 : 110,
                    isEditable: isInputVisible && store.hasExplicitWorkspace && store.visionFallbackStatus == nil && !dictation.isActive,
                    focusToken: focusToken,
                    selectionAfterUpdate: dictatedSelection,
                    onSubmit: {
                        guard isInputVisible, !dictation.isActive else { return true }
                        if store.executeComposerCommandIfPresent() { return true }
                        guard store.canSend else { return false }
                        submitDraft()
                        return true
                    },
                    onTextViewReady: { messageSendTransition?.registerTextView($0) },
                    onMoveAutocomplete: store.moveComposerSuggestionSelection,
                    onSelection: store.updateComposerSelection,
                    onOpenContext: store.openInlineContext,
                    onRecallPrompt: recallPrompt,
                    onAcceptAutocomplete: store.acceptSelectedComposerSuggestion,
                    onDismissAutocomplete: store.dismissComposerSuggestions
                )
                .accessibilityLabel("Message \(store.providerTitle)")
                .onChange(of: store.composerFocusRevision) { _, _ in requestFocus() }
                .modifier(DesktopSendGeometry(part: .text, role: .composer))
                .frame(height: dictation.isActive ? 0 : nil)
                .opacity(dictation.isActive ? 0 : 1)
                .accessibilityHidden(dictation.isActive)
                .allowsHitTesting(!dictation.isActive)

                if dictation.isActive, let dictationDraft {
                    DesktopDictationVisual(
                        dictation: dictation, draft: dictationDraft, fontSize: isWelcome ? 15 : 14,
                        maxHeight: isWelcome ? 130 : 110, cancel: dictation.cancel
                    )
                    .overlay(alignment: .bottomTrailing) { dictationButton }
                }
            }
            if let error = dictation.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }


            if !dictation.isActive {
            VStack(alignment: .leading, spacing: 9) {
                DesktopComposerToolbarLayout {
                    DesktopWrappingControlsLayout(spacing: 7) {
                    Button {
                        isOptionsPresented.toggle()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 27, height: 27)
                            .background(DesktopTheme.raised, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Composer options")
                    .accessibilityLabel("Composer options")
                    .popover(isPresented: $isOptionsPresented, arrowEdge: .top) {
                        DesktopComposerOptionsView(store: store, openProject: {
                            isOptionsPresented = false
                            DispatchQueue.main.async { store.chooseWorkspace() }
                        }, didInsertPlugin: { isOptionsPresented = false })
                    }
                    .disabled(store.visionFallbackStatus != nil)
                    .layoutPriority(1)

                    DesktopComposerProviderPicker(store: store)
                    DesktopModelMenu(store: store)
                    DesktopComposerPermissionsPicker(store: store)
                    }
                    HStack(spacing: 8) {
                        if showsContextWindowUsage, let usage = store.selectedTokenUsage, usage.fractionUsed != nil {
                            DesktopContextWindowUsageView(
                                usage: usage,
                                style: DesktopContextWindowUsageStyle(rawValue: contextWindowUsageStyleRaw) ?? .percent,
                                modelName: store.modelDisplayName,
                                isCompacting: store.isSelectedThreadCompacting
                            )
                        }
                    DesktopComposerModePills(store: store)
                        .layoutPriority(1)
                    dictationButton
                    Button {
                        submitDraft()
                    } label: {
                        Image(systemName: store.isBusyTurn ? store.followUpBehavior.systemImage : "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(.white, in: Circle())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canSend || dictation.isActive)
                    .opacity(store.canSend && !dictation.isActive ? 1 : 0.42)
                    .help(sendButtonHelp)
                    .accessibilityLabel(sendButtonHelp)
                    .layoutPriority(1)

                    if store.isRunningTurn || store.isRoutingSelectedModel {
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
                        .layoutPriority(1)
                    }
                }
                    }
                    .environment(\.desktopComposerPickerGroup, pickerGroup)

                if hasSecondaryComposerControls {
                    DesktopWrappingControlsLayout(spacing: 8) {
                        if store.isBusyTurn {
                            followUpMenu
                                .layoutPriority(1)
                        }
                        if let plan = reviewPlan {
                            Button {
                                store.navigateToPlan(plan.reference)
                            } label: {
                                Image(systemName: "list.bullet.clipboard")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(veoAccent)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(veoAccent.opacity(0.18), lineWidth: 1)
                                            .allowsHitTesting(false)
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("Plan ready — scroll to plan")
                            .accessibilityLabel("Plan ready. Scroll to plan")
                            .layoutPriority(1)
                        }

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
                            .layoutPriority(1)

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
                                        .lineLimit(1)
                                }
                                .menuStyle(.borderlessButton)
                                .help("Realtime voice")
                            }
                        }

                        if let plan = reviewPlan {
                            DesktopPlanImplementControl(
                                isImplementing: plan.lifecycle == .implementing,
                                isEnabled: store.canImplementSelectedPlan,
                                help: store.canImplementSelectedPlan
                                    ? "Implement the approved plan"
                                    : "Send or clear feedback and attachments first",
                                usesCommandReturn: true,
                                implement: { store.implementPlan(plan.reference) },
                                implementInNewTask: { store.implementPlan(plan.reference, inNewTask: true) }
                            )
                            .layoutPriority(1)
                        }

                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Additional chat controls")
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .frame(minWidth: 0, maxWidth: .infinity)

            if store.realtimeSession != nil, !store.realtimeTranscript.isEmpty {
                Label(store.realtimeTranscript, systemImage: "waveform")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("Realtime transcript")
            }

            if !store.hasExplicitWorkspace, !isWelcome {
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
            }
            .padding(DesktopTheme.spaceM)

            if isWelcome && !dictation.isActive {
                DesktopComposerProjectBar(store: store)
            }
            }
        }
        .modifier(DesktopFloatingMaterialSurface(
            material: DesktopComposerMaterial(rawValue: composerMaterialRaw) ?? .liquidGlass
        ))
        .blur(radius: isAttachmentDropTarget ? 3.5 : 0)
        .overlay {
            attachmentDropOverlay
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: store.selectedQueuedDrafts.isEmpty)
        .animation(commandPaletteAnimation, value: store.composerSuggestions.isEmpty)
        .animation(askQuestionsAnimation, value: store.selectedUserInputRequest?.id)
        .animation(askQuestionsAnimation, value: reviewPlan?.reference.itemID)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isAttachmentDropTarget)
        .frame(maxWidth: isWelcome ? DesktopTheme.welcomeWidth : DesktopTheme.conversationWidth)
        .frame(maxWidth: .infinity)
        .dropDestination(
            for: URL.self,
            action: { urls, _ in
                isAttachmentDropTarget = false
                guard !dictation.isActive, store.visionFallbackStatus == nil,
                      store.selectedUserInputRequest == nil else { return false }
                return store.addDroppedFiles(urls)
            },
            isTargeted: { targeted in
                isAttachmentDropTarget = targeted
                    && store.hasExplicitWorkspace
                    && store.selectedUserInputRequest == nil
            }
        )
    }

    private var dictationButton: some View {
        let enabled = isInputVisible && store.hasExplicitWorkspace && store.visionFallbackStatus == nil
            && store.selectedThread?.canAcceptDirectInput != false && store.realtimeSession == nil
        let title = dictation.canFinish ? "Finish dictation" : dictation.isActive ? "Transcribing" : "Dictate"
        let icon = dictation.canFinish ? "stop.fill" : dictation.isActive ? "ellipsis" : "mic"
        return Button {
            if dictation.canFinish {
                dictation.finish()
                return
            }
            guard enabled, !dictation.isActive else { return }
            let snapshot = store.dictationDraft()
            dictationDraft = snapshot
            dictatedSelection = nil
            _ = store.dismissComposerSuggestions()
            Task {
                await dictation.start { spoken in
                    guard store.isCurrentDictationDraft(snapshot) else { return }
                    let result = snapshot.inserting(spoken)
                    dictatedSelection = (result.text, result.end)
                    store.draft = result.text
                    store.updateComposerSelection(text: result.text, range: NSRange(location: result.end, length: 0))
                }
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: dictation.canFinish ? 9 : 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(DesktopTheme.raised, in: Circle())
                .contentShape(Circle())
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: icon)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(!enabled || (dictation.isActive && !dictation.canFinish))
        .help(title + " (⌘⇧D)")
        .accessibilityLabel(title)
        .layoutPriority(1)
    }

    private func askQuestionsDraftBinding(
        for requestID: String
    ) -> Binding<DesktopAskQuestionsComposerDraft> {
        Binding(
            get: { askQuestionDraftsByRequestID[requestID] ?? DesktopAskQuestionsComposerDraft() },
            set: { askQuestionDraftsByRequestID[requestID] = $0 }
        )
    }

    private var hasSecondaryComposerControls: Bool {
        store.isBusyTurn || reviewPlan != nil
            || (store.realtimeVoiceEnabled && store.capabilities.supports(.realtimeVoice) && store.selectedThreadID != nil)
    }

    private var composerPlaceholderColor: NSColor {
        // Built from an explicit colour on purpose: the semantic label colours are
        // drawn far weaker than their nominal alpha inside the composer's text view,
        // which left the placeholder almost invisible on the darker materials.
        // Liquid Glass is the busiest backdrop, so it gets a touch more contrast.
        let material = DesktopComposerMaterial(rawValue: composerMaterialRaw) ?? .liquidGlass
        let alpha: CGFloat = material == .liquidGlass ? 0.34 : 0.30
        return colorScheme == .dark
            ? NSColor(white: 1, alpha: alpha)
            : NSColor(white: 0, alpha: alpha)
    }

    private var commandPaletteAnimation: Animation? {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        switch composerMaterial {
        case .solid, .mica:
            return .easeOut(duration: 0.18)
        case .liquidGlass:
            return .spring(response: 0.46, dampingFraction: 0.76, blendDuration: 0.1)
        }
    }

    private var commandPaletteTransition: AnyTransition {
        switch composerMaterial {
        case .solid, .mica:
            return .opacity.combined(with: .move(edge: .bottom))
        case .liquidGlass:
            return .opacity.combined(with: .scale(scale: 0.72, anchor: .bottom))
        }
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

/// A compact secondary control row that wraps instead of shrinking labels or
/// moving the model picker and Send button out of reach.
private struct DesktopWrappingControlsLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .greatestFiniteMagnitude).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (index, point) in layout.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  anchor: .topLeading, proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var origins: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: min(width, usedWidth), height: y + rowHeight), origins)
    }
}

private struct ComposerTransitionGeometry: ViewModifier {
    let namespace: Namespace.ID?
    let isEnabled: Bool
    let properties: MatchedGeometryProperties
    let isSource: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled, let namespace {
            content
                .matchedGeometryEffect(
                    id: "liquid-glass-composer",
                    in: namespace,
                    properties: properties,
                    anchor: .center,
                    isSource: isSource
                )
                .zIndex(2)
        } else {
            content
        }
    }
}



struct DesktopFloatingMaterialSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let material: DesktopComposerMaterial
    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        switch material {
        case .solid:
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.09), radius: 14, y: 7)
        case .mica:
            micaSurface(content)
        case .liquidGlass:
            // `.glassEffect` is unavailable to the Xcode 16.4 compiler even
            // when protected by a runtime availability check.
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(.regular.interactive(), in: shape)
            } else {
                micaSurface(content)
            }
            #else
            micaSurface(content)
            #endif
        }
    }

    private func micaSurface(_ content: Content) -> some View {
        content
            .background {
                DesktopVisualEffectBackground(material: .underWindowBackground)
                    .clipShape(shape)
            }
            .overlay(shape.stroke(Color.primary.opacity(0.11), lineWidth: 1))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.09), radius: 14, y: 7)
    }
}
