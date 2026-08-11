// FILE: DesktopWorkspaceView.swift
// Purpose: Renders the native macOS workspace: all-repo sidebar, conversation timeline, composer, and inspector.
// Layer: Desktop app view
// Depends on: SwiftUI, AppKit, DesktopCodexStore

import AppKit
import SwiftUI

enum DesktopTheme {
    /// Default accent used when no custom color is stored.
    static let accent = Color(red: 0.18, green: 0.55, blue: 0.98)
    static let sidebarWidth: CGFloat = 318
    static let sidebarTitlebarClearance: CGFloat = 34
    static let conversationWidth: CGFloat = 820
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
                switch material {
                case .solid:
                    DesktopTheme.sidebar
                case .mica:
                    DesktopVisualEffectBackground(material: .sidebar)
                case .liquidGlass:
                    liquidGlassBackground
                }
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
private struct DesktopSidebarListSelectionStyle: NSViewRepresentable {
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
    @ObservedObject var store: DesktopCodexStore
    @ObservedObject var navigation: DesktopNavigationState
    @AppStorage("VeoDesktop.inspectorVisible") private var inspectorVisible = false
    @AppStorage(DesktopAppearancePreferences.accentColorKey) private var accentColorHex =
        DesktopAppearancePreferences.defaultAccentHex
    @AppStorage(DesktopNotificationPreferences.menuBarIconKey) private var showsMenuBarIcon = true
    @AppStorage(DesktopAppearancePreferences.notificationMaterialKey) private var notificationMaterialRaw =
        DesktopNotificationMaterial.mica.rawValue
    @StateObject private var terminalHub = DesktopLocalTerminalHub()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsChanges = false
    @State private var showsInteractiveTerminal = false
    @State private var commandRenameTarget: DesktopThread?
    @State private var commandForkTarget: DesktopThread?
    @State private var commandDeleteTarget: DesktopThread?

    private var accentColor: Color {
        DesktopAppearancePreferences.color(fromHex: accentColorHex) ?? DesktopTheme.accent
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Group {
                if navigation.page == .settings {
                    DesktopSettingsSidebarView(navigation: navigation)
                } else {
                    DesktopSidebarView(store: store) {
                        navigation.showSettings()
                    } openUpdates: {
                        navigation.showSettings(.updates)
                    }
                }
            }
                .navigationSplitViewColumnWidth(min: 236, ideal: DesktopTheme.sidebarWidth, max: 360)
        } detail: {
            Group {
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
        }
        .onChange(of: showsMenuBarIcon) { _, visible in
            menuBarController.setVisible(visible)
        }
        .onChange(of: store.composerCommandDestinationRequest) { _, destination in
            guard let destination else { return }
            switch destination {
            case .inspector:
                inspectorVisible = true
            case .settings(let category):
                navigation.showSettings(category)
            case .changes:
                showsChanges = true
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
        .sheet(item: $store.pendingRequest) { request in
            DesktopPendingRequestView(request: request, store: store)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showsChanges) {
            DesktopDiffView(store: store)
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
                showsInteractiveTerminal = false
                terminalHub.terminateAll()
            }
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
                    store.beginNewChat()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .help("New chat (⌘N)")
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

            ToolbarItem(id: "reveal-project", placement: .primaryAction) {
                Button {
                    store.revealWorkspace()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal workspace in Finder")
                .disabled(!store.hasExplicitWorkspace)
            }

            ToolbarItem(id: "changes", placement: .primaryAction) {
                Button {
                    showsChanges = true
                } label: {
                    Label("Changes", systemImage: "doc.text.magnifyingglass")
                }
                .help("Review repository and live turn changes")
                .disabled(!store.canUseProjectChanges)
            }

            ToolbarItem(id: "terminal", placement: .primaryAction) {
                Button {
                    showsInteractiveTerminal.toggle()
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .help(showsInteractiveTerminal ? "Hide terminal panel" : "Show workspace terminal panel")
                .keyboardShortcut("`", modifiers: .control)
                .disabled(!store.hasExplicitWorkspace)
            }

            ToolbarItem(id: "inspector", placement: .primaryAction) {
                Button {
                    inspectorVisible.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Toggle inspector (⌘⌥I)")
                .keyboardShortcut("i", modifiers: [.command, .option])
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
        .tint(veoAccent)
    }

    @ViewBuilder
    private func questionView(_ question: DesktopRequestQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.header.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(veoAccent)
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
                                    .foregroundStyle(selections[question.id] == option.label ? veoAccent : .secondary)
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
    @Environment(\.veoAccent) private var veoAccent
    @EnvironmentObject private var updateService: DesktopUpdateService
    @ObservedObject var store: DesktopCodexStore
    let openSettings: () -> Void
    let openUpdates: () -> Void
    @AppStorage("VeoDesktop.collapsedProjectPaths") private var collapsedProjectPathsJSON = "[]"
    @AppStorage("VeoDesktop.sidebarOrganization") private var sidebarOrganizationRaw = DesktopSidebarOrganization.byProject.rawValue
    @AppStorage("VeoDesktop.sidebarSortMode") private var sidebarSortModeRaw = DesktopSidebarSortMode.priority.rawValue
    @AppStorage("VeoDesktop.manualThreadOrder") private var manualThreadOrderJSON = "[]"
    @AppStorage("VeoDesktop.projectDisplayNames") private var projectDisplayNamesJSON = "{}"
    @AppStorage(DesktopAppearancePreferences.sidebarMaterialKey) private var sidebarMaterialRaw =
        DesktopSidebarMaterial.solid.rawValue
    @State private var showsSearch = false
    @State private var renameTarget: DesktopThread?
    @State private var editingProjectPath: String?
    @State private var editingProjectName = ""
    @State private var forkTarget: DesktopThread?
    @State private var deleteTarget: DesktopThread?
    @State private var expandedAgentThreadIDs = Set<String>()
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
        guard let data = projectDisplayNamesJSON.data(using: .utf8),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return names
    }

    private func projectGroups(
        for candidates: [DesktopThread]
    ) -> [(path: String, name: String, threads: [DesktopThread])] {
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
                    name: projectDisplayNames[path] ?? URL(fileURLWithPath: path).lastPathComponent,
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
            .background(DesktopSidebarListSelectionStyle())

            sidebarFooter
        }
        .desktopSidebarChrome(DesktopSidebarMaterial(rawValue: sidebarMaterialRaw) ?? .solid)
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
                            showsWorkspace: true,
                            pendingRequestCount: store.pendingRequestCount(for: thread.id),
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

            if !temporaryThreads.isEmpty {
                Section {
                    if !isProjectCollapsed(temporaryGroupKey) {
                        let entries = flattenedEntries(for: temporaryThreads)
                        ForEach(entries) { entry in
                            DesktopThreadRow(
                                thread: entry.thread,
                                pendingRequestCount: store.pendingRequestCount(for: entry.thread.id),
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
                    }
                    .textCase(nil)
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
                    }
                    .textCase(nil)
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
            updateStatusRow
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

    /// Sits directly above the runtime status so update state reads before connection state.
    @ViewBuilder
    private var updateStatusRow: some View {
        Button {
            switch updateService.phase {
            case .readyToRelaunch:
                updateService.relaunch()
            case let .available(release):
                if updateService.canInstallInPlace, release.downloadURL != nil {
                    updateService.installUpdate(release)
                } else {
                    openUpdates()
                }
            case .checking, .downloading:
                openUpdates()
            default:
                updateService.checkForUpdates(userInitiated: true)
            }
        } label: {
            HStack(spacing: 8) {
                updateIcon
                if case let .downloading(progress) = updateService.phase, progress < 1 {
                    DesktopShimmerText(
                        text: updateStatusTitle,
                        font: .system(size: 11.5, weight: .medium),
                        isActive: true
                    )
                } else {
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
                }
                .buttonStyle(.plain)
                .help("Update settings")
                .accessibilityLabel("Update settings")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DesktopTheme.spaceM)
        .padding(.top, 9)
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
        switch updateService.phase {
        case .checking:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 8, height: 8)
        case .downloading:
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

    private var updateStatusTitle: String {
        switch updateService.phase {
        case .checking:
            return "Checking for updates…"
        case let .downloading(progress):
            return progress >= 1 ? "Installing update…" : "Downloading update…"
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
            return updateService.canInstallInPlace
                ? "Download and install this update"
                : "Open the release page"
        case .readyToRelaunch:
            return "Relaunch Veo to finish updating"
        case let .failed(message):
            return message
        default:
            return "Check for updates"
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
            && allSidebarProjectPaths.contains(where: { !collapsedProjectPaths.contains($0) })
    }

    private var canExpandAllProjects: Bool {
        sidebarOrganization == .byProject
            && store.searchText.isEmpty
            && allSidebarProjectPaths.contains(where: { collapsedProjectPaths.contains($0) })
    }

    private var allSidebarProjectPaths: Set<String> {
        var paths = Set(workspaceGroups.map(\.path) + codexWorkspaceGroups.map(\.path))
        if !temporaryThreads.isEmpty { paths.insert(temporaryGroupKey) }
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
            showsWorkspace: showsWorkspace,
            pendingRequestCount: store.pendingRequestCount(for: entry.thread.id),
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
    @Environment(\.veoAccent) private var veoAccent
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
    var showsWorkspace = false
    var pendingRequestCount = 0
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
                DesktopShimmerText(
                    text: thread.title,
                    font: .system(size: 12.5, weight: .regular),
                    baseStyle: AnyShapeStyle(.primary),
                    isActive: showsActiveTurn
                )
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
        .listRowBackground(
            isSelected ? veoAccent.opacity(0.22) : Color.clear
        )
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

private struct DesktopConversationView: View {
    @Environment(\.veoAccent) private var veoAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: DesktopCodexStore
    @ObservedObject var terminalHub: DesktopLocalTerminalHub
    @Binding var showsInteractiveTerminal: Bool
    @AppStorage(DesktopAppearancePreferences.composerMaterialKey) private var composerMaterialRaw =
        DesktopComposerMaterial.liquidGlass.rawValue
    @AppStorage(DesktopAppearancePreferences.threadMinimapVisibleKey) private var showsThreadMinimap = true
    @AppStorage(DesktopAppearancePreferences.threadMinimapMaterialKey) private var threadMinimapMaterialRaw =
        DesktopMinimapMaterial.liquidGlass.rawValue
    @AppStorage(DesktopAppearancePreferences.windowMaterialKey) private var windowMaterialRaw =
        DesktopWindowMaterial.solid.rawValue
    @State private var isPinnedToBottom = true
    @State private var autoScrollGeneration = 0
    @State private var isAutoScrollInFlight = false
    @State private var pendingAutoScrollAnimation = false
    @State private var activeMinimapTurnID: String?
    @State private var minimapHover: DesktopThreadMinimapHover?
    @Namespace private var composerTransitionNamespace

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
                        transitionNamespace: composerTransitionNamespace
                    )
                }
            }
            .animation(composerTransitionAnimation, value: showsEmptyChat)

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

    private var conversation: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                let timelineEntries = DesktopTimelineEntry.make(from: store.timeline)
                let minimapAnalysisRequest = DesktopThreadMinimapTurn.analysisRequest(from: store.timeline)
                let minimapTurns = DesktopThreadMinimapTurn.make(
                    from: store.timeline,
                    modelTopicStartIDs: store.threadMinimapTopicStartIDs
                )
                let minimapAnalysisTaskID = [
                    store.selectedThreadID ?? "new",
                    minimapAnalysisRequest?.fingerprint ?? "unavailable",
                    String(store.utilityModelPreferenceRevision),
                    showsThreadMinimap ? "visible" : "hidden",
                ].joined(separator: "|")
                let minimapMaterial = DesktopMinimapMaterial(rawValue: threadMinimapMaterialRaw) ?? .liquidGlass
                let minimapHeight = min(
                    max(56, CGFloat(minimapTurns.count) * 14 + 24),
                    max(56, viewport.size.height - 390)
                )

                ZStack {
                    HStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 20) {
                        if store.isLoadingTimeline {
                            DesktopTimelineSkeleton()
                        } else {
                            ForEach(timelineEntries) { entry in
                                switch entry {
                                case .message(let item):
                                    DesktopTimelineRow(
                                        item: item,
                                        workspaceURL: store.effectiveWorkspaceURL,
                                        isTurnRunning: store.isBusyTurn
                                    )
                                    .id(item.id)
                                    .background {
                                        timelineBoundsReader(itemIDs: [item.id])
                                    }

                                case .activity(let group):
                                    DesktopActivityGroupView(
                                        group: group,
                                        workspaceURL: store.effectiveWorkspaceURL,
                                        isTurnRunning: store.isBusyTurn
                                    )
                                    .id(group.id)
                                    .background {
                                        timelineBoundsReader(itemIDs: group.itemIDs)
                                    }
                                }
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
                            .frame(height: Self.timelineBottomInset)
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

                        if showsThreadMinimap, minimapTurns.count > 1 {
                            DesktopThreadMinimapView(
                                turns: minimapTurns,
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
                       minimapTurns.count > 1,
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
                .task(id: minimapAnalysisTaskID) {
                    store.requestThreadMinimapAnalysis(
                        showsThreadMinimap ? minimapAnalysisRequest : nil
                    )
                }
                .onPreferenceChange(TimelineItemBoundsKey.self) { bounds in
                    updateActiveMinimapTurn(
                        bounds: bounds,
                        turns: minimapTurns,
                        viewportHeight: viewport.size.height
                    )
                }
                .onChange(of: store.timeline.count) { _, _ in
                    scheduleScrollToEndIfPinned(proxy, animated: false)
                }
                .onChange(of: store.timeline.last) { _, _ in
                    scheduleScrollToEndIfPinned(proxy, animated: false)
                }
                .onChange(of: store.isRunningTurn) { _, _ in
                    scheduleScrollToEndIfPinned(proxy, animated: true)
                }
                .onChange(of: store.isSubmittingTurn) { _, isSubmitting in
                    guard isSubmitting else { return }
                    isPinnedToBottom = true
                    scheduleScrollToEndIfPinned(proxy, animated: true)
                }
                .onChange(of: store.selectedThreadID) { _, _ in
                    isPinnedToBottom = true
                    activeMinimapTurnID = nil
                    minimapHover = nil
                    scheduleScrollToEndIfPinned(proxy, animated: false)
                }
                .onChange(of: showsThreadMinimap) { _, isVisible in
                    if !isVisible { minimapHover = nil }
                }
                .onChange(of: store.timelineNavigationItemID) { _, itemID in
                    guard let itemID else { return }
                    stopFollowingTail()
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
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsThreadMinimap)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: minimapHover?.turn.id)
            }
        }
    }

    private static let scrollSpace = "veo.timeline.scroll"
    private static let bottomAnchor = "veo.timeline.bottom"
    private static let timelineBottomInset: CGFloat = 188

    private func timelineBoundsReader(itemIDs: [String]) -> some View {
        GeometryReader { row in
            let frame = row.frame(in: .named(Self.scrollSpace))
            Color.clear.preference(
                key: TimelineItemBoundsKey.self,
                value: Dictionary(uniqueKeysWithValues: itemIDs.map { ($0, frame) })
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
        if animated {
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
        let turnByItemID = Dictionary(
            uniqueKeysWithValues: turns.flatMap { turn in turn.itemIDs.map { ($0, turn.id) } }
        )
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
            Button("Try Again") {
                store.reconnect()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

private struct DesktopEmptyChatView: View {
    @ObservedObject var store: DesktopCodexStore
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
    @ObservedObject var store: DesktopCodexStore

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
    @Environment(\.veoAccent) private var veoAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: DesktopTimelineItem
    let workspaceURL: URL?
    var isTurnRunning = false
    @State private var isDetailExpanded = false
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
                    if activityIsRunning {
                        ProgressView()
                            .controlSize(.mini)
                    } else if activityFailed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    } else if activityIsComplete {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tertiary)
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
        normalizedActivityStatus.contains("progress")
            || normalizedActivityStatus == "running"
            || normalizedActivityStatus == "active"
            || normalizedActivityStatus == "pending"
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
        item.kind == .fileChange ? veoAccent : .secondary
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.veoAccent) private var veoAccent
    @ObservedObject var store: DesktopCodexStore
    var isWelcome = false
    var transitionNamespace: Namespace.ID?
    @AppStorage(DesktopAppearancePreferences.composerMaterialKey) private var composerMaterialRaw =
        DesktopComposerMaterial.liquidGlass.rawValue
    @AppStorage(DesktopComposerPreferences.showsContextWindowUsageKey) private var showsContextWindowUsage = false
    @AppStorage(DesktopComposerPreferences.contextWindowUsageStyleKey) private var contextWindowUsageStyleRaw =
        DesktopContextWindowUsageStyle.percent.rawValue
    @AppStorage("VeoDesktop.projectDisplayNames") private var projectDisplayNamesJSON = "{}"
    @State private var focusToken = 0
    @State private var isOptionsPresented = false
    @State private var isQueuePresented = false
    @State private var isProjectChooserPresented = false

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
        .modifier(ComposerTransitionGeometry(
            namespace: transitionNamespace,
            isEnabled: transitionNamespace != nil,
            properties: composerMaterial == .liquidGlass ? .frame : .position,
            isSource: isWelcome
        ))
    }

    private var composerMaterial: DesktopComposerMaterial {
        DesktopComposerMaterial(rawValue: composerMaterialRaw) ?? .liquidGlass
    }

    private func requestFocus() {
        guard store.hasExplicitWorkspace else { return }
        focusToken += 1
    }

    private var composerCard: some View {
        VStack(spacing: 0) {
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
                    .transition(commandPaletteTransition)
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
                placeholder: isWelcome ? "Message Codex in this workspace…" : "Send follow-up",
                placeholderColor: composerPlaceholderColor,
                fontSize: isWelcome ? 15 : 14,
                minHeight: isWelcome ? 70 : 34,
                maxHeight: isWelcome ? 130 : 110,
                isEditable: store.hasExplicitWorkspace,
                focusToken: focusToken,
                onSubmit: {
                    if store.executeComposerCommandIfPresent() { return true }
                    guard store.canSend else { return false }
                    store.sendDraft()
                    return true
                },
                onMoveAutocomplete: store.moveComposerSuggestionSelection,
                onAcceptAutocomplete: store.acceptSelectedComposerSuggestion,
                onDismissAutocomplete: store.dismissComposerSuggestions
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

                if showsContextWindowUsage,
                   store.selectedThreadID != nil,
                   let usage = store.selectedTokenUsage,
                   usage.fractionUsed != nil {
                    DesktopContextWindowUsageView(
                        usage: usage,
                        style: DesktopContextWindowUsageStyle(rawValue: contextWindowUsageStyleRaw) ?? .percent,
                        modelName: store.modelDisplayName,
                        isCompacting: store.isSelectedThreadCompacting
                    )
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
            .padding(DesktopTheme.spaceM)

            if isWelcome {
                freshProjectBar
            }
        }
        .modifier(DesktopFloatingMaterialSurface(
            material: DesktopComposerMaterial(rawValue: composerMaterialRaw) ?? .liquidGlass
        ))
        .animation(commandPaletteAnimation, value: store.composerSuggestions.isEmpty)
        .frame(maxWidth: isWelcome ? DesktopTheme.welcomeWidth : DesktopTheme.conversationWidth)
        .dropDestination(for: URL.self) { urls, _ in
            store.addDroppedFiles(urls)
        }
    }

    private var freshProjectBar: some View {
        HStack {
            Spacer(minLength: 0)

            Button {
                isProjectChooserPresented.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                    Text("Choose project")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose the project for this chat")
            .accessibilityLabel("Choose project")
            .popover(isPresented: $isProjectChooserPresented, arrowEdge: .bottom) {
                projectChooserPopover
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesktopTheme.spaceM)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Divider().opacity(0.7)
        }
    }

    private var projectChooserPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose project")
                .font(.system(size: 13, weight: .semibold))

            if knownProjects.isEmpty {
                Text("No existing projects yet")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(knownProjects, id: \.path) { project in
                            Button {
                                chooseExistingProject(project.path)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(veoAccent)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(project.name)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                        Text(project.path)
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    if project.path == store.effectiveWorkspaceURL.path,
                                       store.currentWorkspaceKind == .project {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(veoAccent)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use project \(project.name)")
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Divider()

            Button {
                isProjectChooserPresented = false
                DispatchQueue.main.async {
                    store.chooseWorkspace()
                }
            } label: {
                Label("Add project…", systemImage: "folder.badge.plus")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 310)
        .background(.regularMaterial)
    }

    private var projectDisplayNames: [String: String] {
        guard let data = projectDisplayNamesJSON.data(using: .utf8),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return names
    }

    private var knownProjects: [(path: String, name: String)] {
        var latestUpdateByPath: [String: Date] = [:]
        for thread in store.threads {
            guard thread.workspaceKind == .project else { continue }
            latestUpdateByPath[thread.cwd] = max(latestUpdateByPath[thread.cwd] ?? .distantPast, thread.updatedAt)
        }
        if let workspaceURL = store.workspaceURL {
            latestUpdateByPath[workspaceURL.path] = max(latestUpdateByPath[workspaceURL.path] ?? .distantPast, .now)
        }
        return latestUpdateByPath
            .sorted { $0.value > $1.value }
            .map { path, _ in
                (path: path, name: projectDisplayNames[path] ?? URL(fileURLWithPath: path).lastPathComponent)
            }
    }

    private func chooseExistingProject(_ path: String) {
        isProjectChooserPresented = false
        store.beginProjectChat(at: URL(fileURLWithPath: path, isDirectory: true))
    }

    private var composerPlaceholderColor: NSColor {
        let material = DesktopComposerMaterial(rawValue: composerMaterialRaw) ?? .liquidGlass
        if material == .liquidGlass, colorScheme == .dark {
            return NSColor.labelColor.withAlphaComponent(0.72)
        }
        return .tertiaryLabelColor
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
    @State private var presentsReview = false

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
                        presentsReview = true
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
        .sheet(isPresented: $presentsReview) {
            DesktopReviewSheet(store: store)
        }
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
    @Environment(\.veoAccent) private var veoAccent
    @ObservedObject var store: DesktopCodexStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                inspectorSection("Runtime") {
                    statusRow("Codex", store.runtimeState.title, color: store.runtimeState.isReady ? .green : .orange)
                    statusRow("Turn", store.isRunningTurn ? "Running" : "Idle", color: store.isRunningTurn ? veoAccent : .secondary)
                }

                if let thread = store.selectedThread, thread.isSubagent {
                    inspectorSection("Subagent") {
                        statusRow(
                            thread.agentNickname ?? "Agent",
                            store.agentState(for: thread.id)?.displayStatus ?? thread.agentStatus,
                            color: (store.agentState(for: thread.id)?.isActive == true || thread.isRunning)
                                ? veoAccent
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
                                .tint(usage.warningLevel == 2 ? .red : (usage.warningLevel == 1 ? .orange : veoAccent))
                            Text("\(formatTokens(usage.currentContextTokens)) of \(formatTokens(usage.contextWindow ?? 0)) tokens used")
                                .font(.system(size: 11.5, weight: .medium))
                        } else {
                            Text("\(formatTokens(usage.currentContextTokens)) tokens used")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        Text("Thread total: \(formatTokens(usage.cumulativeTokens)) tokens")
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

                inspectorSection("Workspace") {
                    Label(
                        store.selectedThread?.workspaceName
                            ?? (store.workspaceURL?.lastPathComponent ?? "No workspace selected"),
                        systemImage: store.isProjectlessWorkspace ? "bubble.left.and.bubble.right" : "folder"
                    )
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.hasExplicitWorkspace ? store.effectiveWorkspaceURL.path : "Start a new chat or open a project.")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Choose Project…") { store.chooseWorkspace() }
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
        return Text(before) + Text(match).bold().foregroundColor(veoAccent) + Text(after)
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
