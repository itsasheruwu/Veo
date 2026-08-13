// FILE: DesktopUtilityPanelModels.swift
// Purpose: Shared state and preferences for Veo's right utility panel.
// Layer: Desktop app model

import Foundation

enum DesktopUtilityPanelTab: String, CaseIterable, Identifiable {
    case review
    case browser
    case files

    var id: Self { self }

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .review: return "arrow.left.arrow.right"
        case .browser: return "globe"
        case .files: return "folder"
        }
    }
}

struct DesktopUtilityPanelItem: Identifiable, Hashable {
    enum Content: Hashable {
        case review
        case browser(UUID)
        case files

        var kind: DesktopUtilityPanelTab {
            switch self {
            case .review: return .review
            case .browser: return .browser
            case .files: return .files
            }
        }
    }

    let id: UUID
    let content: Content

    init(id: UUID = UUID(), content: Content) {
        self.id = id
        self.content = content
    }
}

enum DesktopReviewLayout: String, CaseIterable, Identifiable {
    case unified
    case split

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum DesktopUtilityPreferences {
    static let selectedTabKey = "VeoDesktop.utilityPanel.selectedTab"
    static let reviewLayoutKey = "VeoDesktop.utilityPanel.reviewLayout"
    static let hideWhitespaceKey = "VeoDesktop.utilityPanel.hideWhitespace"
    static let restoreBrowserTabsKey = "VeoDesktop.browser.restoreTabs"
}

@MainActor
final class DesktopUtilityPanelModel: ObservableObject {
    @Published private(set) var tabs: [DesktopUtilityPanelItem] = []
    @Published private(set) var selectedTabID: UUID?
    @Published var presentsAIReview = false

    let files: DesktopFilesModel
    let browser: DesktopBrowserModel

    private let defaults: UserDefaults
    private var workspaceKey = ""
    private var tabsByWorkspace: [String: [DesktopUtilityPanelItem]] = [:]
    private var selectionByWorkspace: [String: UUID] = [:]
    private var preferredKind: DesktopUtilityPanelTab

    var selectedTab: DesktopUtilityPanelItem? {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs.first
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        files = DesktopFilesModel()
        browser = DesktopBrowserModel()
        preferredKind = defaults.string(forKey: DesktopUtilityPreferences.selectedTabKey)
            .flatMap(DesktopUtilityPanelTab.init(rawValue:)) ?? .review

        browser.tabAdded = { [weak self] browserTabID in
            self?.insertBrowserTab(browserTabID)
        }
        browser.tabRemoved = { [weak self] browserTabID in
            self?.removeBrowserTab(browserTabID)
        }
    }

    var didCloseLastTab: (() -> Void)?

    func show(_ tab: DesktopUtilityPanelTab, aiReview: Bool = false) {
        if let item = tabs.first(where: { $0.content.kind == tab }) {
            selectTab(item.id)
        } else {
            addTab(tab)
        }
        presentsAIReview = aiReview
    }

    func addTab(_ kind: DesktopUtilityPanelTab) {
        switch kind {
        case .review:
            let item = DesktopUtilityPanelItem(content: .review)
            tabs.append(item)
            selectTab(item.id)
        case .browser:
            _ = browser.addTab()
        case .files:
            let item = DesktopUtilityPanelItem(content: .files)
            tabs.append(item)
            selectTab(item.id)
        }
        cacheCurrentWorkspace()
    }

    func ensureOpenTab() {
        guard tabs.isEmpty else { return }
        addTab(preferredKind)
    }

    func selectTab(_ id: UUID) {
        guard let item = tabs.first(where: { $0.id == id }) else { return }
        selectedTabID = id
        preferredKind = item.content.kind
        defaults.set(preferredKind.rawValue, forKey: DesktopUtilityPreferences.selectedTabKey)
        if case .browser(let browserTabID) = item.content {
            browser.selectTab(browserTabID)
        }
        cacheCurrentWorkspace()
    }

    func closeTab(_ id: UUID) {
        guard let item = tabs.first(where: { $0.id == id }) else { return }
        if case .browser(let browserTabID) = item.content {
            browser.closeTab(browserTabID)
        } else {
            removeUtilityTab(id)
        }
    }

    func moveTab(_ id: UUID, to destination: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let item = tabs.remove(at: source)
        tabs.insert(item, at: min(max(destination, 0), tabs.count))
        browser.reorderTabs(tabs.compactMap { item in
            guard case .browser(let id) = item.content else { return nil }
            return id
        })
        cacheCurrentWorkspace()
    }

    func switchWorkspace(to url: URL?) {
        cacheCurrentWorkspace()
        let canonical = url?.standardizedFileURL.resolvingSymlinksInPath()
        files.switchWorkspace(to: canonical)
        browser.switchWorkspace(to: canonical)
        workspaceKey = canonical?.path ?? "__no_workspace__"

        let validBrowserIDs = Set(browser.tabs.map(\.id))
        if let savedTabs = tabsByWorkspace[workspaceKey] {
            tabs = savedTabs.filter { item in
                guard case .browser(let id) = item.content else { return true }
                return validBrowserIDs.contains(id)
            }
            let representedBrowserIDs = Set(tabs.compactMap { item -> UUID? in
                guard case .browser(let id) = item.content else { return nil }
                return id
            })
            for browserTab in browser.tabs where !representedBrowserIDs.contains(browserTab.id) {
                insertBrowserTab(browserTab.id, selecting: false)
            }
        } else {
            tabs = [DesktopUtilityPanelItem(content: .review)]
            tabs.append(contentsOf: browser.tabs.map { DesktopUtilityPanelItem(content: .browser($0.id)) })
            tabs.append(DesktopUtilityPanelItem(content: .files))
        }

        if let savedSelection = selectionByWorkspace[workspaceKey],
           tabs.contains(where: { $0.id == savedSelection }) {
            selectTab(savedSelection)
        } else if let preferred = tabs.first(where: { $0.content.kind == preferredKind }) {
            selectTab(preferred.id)
        } else if let first = tabs.first {
            selectTab(first.id)
        }
    }

    func openWorkspaceFile(_ fileURL: URL, workspaceURL: URL) {
        browser.openWorkspaceFile(fileURL, workspaceURL: workspaceURL)
    }

    func openBrowser(url: URL, accountLogin: Bool = false) {
        browser.open(url, accountLogin: accountLogin)
        if let id = browser.selectedTabID {
            insertBrowserTab(id, selecting: true)
        }
    }

    func prepareForWorkspaceChange() -> Bool {
        files.flushPendingSave()
    }

    private func insertBrowserTab(_ browserTabID: UUID, selecting: Bool = true) {
        guard !tabs.contains(where: { $0.content == .browser(browserTabID) }) else {
            if selecting,
               let item = tabs.first(where: { $0.content == .browser(browserTabID) }) {
                selectTab(item.id)
            }
            return
        }
        let item = DesktopUtilityPanelItem(content: .browser(browserTabID))
        let insertionIndex: Int
        if let selectedTabID,
           let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            insertionIndex = selectedIndex + 1
        } else if let filesIndex = tabs.firstIndex(where: { $0.content.kind == .files }) {
            insertionIndex = filesIndex
        } else {
            insertionIndex = tabs.endIndex
        }
        tabs.insert(item, at: min(insertionIndex, tabs.endIndex))
        browser.reorderTabs(tabs.compactMap { item in
            guard case .browser(let id) = item.content else { return nil }
            return id
        })
        if selecting { selectTab(item.id) }
        cacheCurrentWorkspace()
    }

    private func removeBrowserTab(_ browserTabID: UUID) {
        guard let item = tabs.first(where: { $0.content == .browser(browserTabID) }) else { return }
        removeUtilityTab(item.id)
    }

    private func removeUtilityTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            selectedTabID = nil
            cacheCurrentWorkspace()
            didCloseLastTab?()
            return
        }
        if selectedTabID == id {
            selectTab(tabs[min(index, tabs.count - 1)].id)
        }
        cacheCurrentWorkspace()
    }

    private func cacheCurrentWorkspace() {
        guard !workspaceKey.isEmpty else { return }
        tabsByWorkspace[workspaceKey] = tabs
        if let selectedTabID { selectionByWorkspace[workspaceKey] = selectedTabID }
    }
}
