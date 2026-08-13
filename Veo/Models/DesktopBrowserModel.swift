// FILE: DesktopBrowserModel.swift
// Purpose: Window-scoped per-workspace browser tabs backed by a shared WebKit profile.
// Layer: Desktop app model

import AppKit
import CryptoKit
import Foundation
import WebKit

enum DesktopBrowserViewport: String, CaseIterable, Identifiable {
    case responsive
    case desktop
    case tablet
    case mobile

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var width: CGFloat? {
        switch self {
        case .responsive: return nil
        case .desktop: return 1280
        case .tablet: return 820
        case .mobile: return 390
        }
    }
}

struct DesktopBrowserConsoleMessage: Identifiable, Hashable {
    let id = UUID()
    let level: String
    let text: String
    let timestamp = Date()
}

struct DesktopBrowserDownload: Identifiable, Hashable {
    enum State: Hashable {
        case downloading(Double)
        case finished(URL)
        case failed(String)
    }

    let id: UUID
    let name: String
    var state: State
}

private struct DesktopBrowserRestoration: Codable {
    let urls: [String]
    let selectedIndex: Int
}

@MainActor
final class DesktopBrowserModel: ObservableObject {
    @Published private(set) var workspaceKey = ""
    @Published private(set) var tabs: [DesktopBrowserTab] = []
    @Published var selectedTabID: UUID?
    @Published var viewport: DesktopBrowserViewport = .responsive
    @Published var showsDeveloperTools = false
    @Published var downloads: [DesktopBrowserDownload] = []
    @Published var message: String?

    var tabAdded: ((UUID) -> Void)?
    var tabRemoved: ((UUID) -> Void)?

    private var tabsByWorkspace: [String: [DesktopBrowserTab]] = [:]
    private var selectionByWorkspace: [String: UUID] = [:]
    private var currentWorkspaceURL: URL?
    private let defaults = UserDefaults.standard

    var selectedTab: DesktopBrowserTab? {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs.first
    }

    func switchWorkspace(to url: URL?) {
        persistCurrentWorkspaceIfNeeded()
        if !workspaceKey.isEmpty {
            tabsByWorkspace[workspaceKey] = tabs
            if let selectedTabID { selectionByWorkspace[workspaceKey] = selectedTabID }
        }
        currentWorkspaceURL = url
        workspaceKey = url?.path ?? "__no_workspace__"
        if let existing = tabsByWorkspace[workspaceKey] {
            tabs = existing
        } else if defaults.bool(forKey: DesktopUtilityPreferences.restoreBrowserTabsKey),
                  let restoration = loadRestoration(for: workspaceKey) {
            tabs = restoration.urls.map { makeTab(address: $0) }
            if tabs.isEmpty { tabs = [makeTab(address: "about:blank")] }
            let index = min(max(restoration.selectedIndex, 0), tabs.count - 1)
            selectedTabID = tabs[index].id
        } else {
            tabs = [makeTab(address: "about:blank")]
        }
        if selectedTabID == nil || !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = selectionByWorkspace[workspaceKey] ?? tabs.first?.id
        }
    }

    @discardableResult
    func addTab(address: String = "about:blank", select: Bool = true) -> UUID {
        let tab = makeTab(address: address)
        tabs.append(tab)
        if select { selectedTabID = tab.id }
        cacheCurrentTabs()
        tabAdded?(tab.id)
        return tab.id
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        tab.invalidate()
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        cacheCurrentTabs()
        tabRemoved?(id)
    }

    func moveTab(_ id: UUID, to destination: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
        cacheCurrentTabs()
    }

    func reorderTabs(_ orderedIDs: [UUID]) {
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let ordered = orderedIDs.compactMap { byID[$0] }
        let remaining = tabs.filter { !orderedIDs.contains($0.id) }
        tabs = ordered + remaining
        cacheCurrentTabs()
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        cacheCurrentTabs()
    }

    func navigate(address rawAddress: String) {
        guard let tab = selectedTab else { return }
        let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = normalizedWebURL(trimmed) {
            tab.load(url)
        } else {
            var components = URLComponents(string: "https://duckduckgo.com/")!
            components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            if let url = components.url { tab.load(url) }
        }
        persistCurrentWorkspaceIfNeeded()
    }

    func openWorkspaceFile(_ fileURL: URL, workspaceURL: URL) {
        let workspace = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let file = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(workspace.path + "/") else {
            message = "Veo blocked a local page outside the selected workspace."
            return
        }
        let tab = makeTab(address: "about:blank")
        tab.allowedFileRoot = workspace
        tabs.append(tab)
        selectedTabID = tab.id
        tab.webView.loadFileURL(file, allowingReadAccessTo: workspace)
        cacheCurrentTabs()
        tabAdded?(tab.id)
    }

    func evaluateJavaScript(_ source: String) {
        guard let tab = selectedTab else { return }
        tab.webView.evaluateJavaScript(source) { result, error in
            Task { @MainActor in
                if let error {
                    tab.appendConsole(level: "error", text: error.localizedDescription)
                } else {
                    tab.appendConsole(level: "result", text: String(describing: result ?? "undefined"))
                }
            }
        }
    }

    func openSelectedInSafari() {
        guard let url = selectedTab?.webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealDownload(_ download: DesktopBrowserDownload) {
        guard case .finished(let url) = download.state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openDownload(_ download: DesktopBrowserDownload) {
        guard case .finished(let url) = download.state else { return }
        NSWorkspace.shared.open(url)
    }

    fileprivate func beginDownload(_ download: WKDownload, suggestedFilename: String) {
        let id = UUID()
        let safeName = sanitizedFilename(suggestedFilename)
        downloads.insert(.init(id: id, name: safeName, state: .downloading(0)), at: 0)
        let delegate = DesktopBrowserDownloadDelegate(id: id, name: safeName, model: self)
        download.delegate = delegate
        DesktopBrowserDownloadDelegate.retain(delegate, for: download)
    }

    fileprivate func updateDownload(id: UUID, state: DesktopBrowserDownload.State) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].state = state
    }

    private func makeTab(address: String, configuration: WKWebViewConfiguration? = nil) -> DesktopBrowserTab {
        let tab = DesktopBrowserTab(configuration: configuration)
        tab.openPopup = { [weak self] configuration, _ in
            guard let self else { return nil }
            let popup = self.makeTab(address: "about:blank", configuration: configuration)
            self.tabs.append(popup)
            self.selectedTabID = popup.id
            self.cacheCurrentTabs()
            self.tabAdded?(popup.id)
            return popup.webView
        }
        tab.downloadStarted = { [weak self] download, name in
            self?.beginDownload(download, suggestedFilename: name)
        }
        tab.stateChanged = { [weak self] in self?.cacheCurrentTabs() }
        tab.closeRequested = { [weak self, weak tab] in
            guard let id = tab?.id else { return }
            self?.closeTab(id)
        }
        if address != "about:blank", let url = normalizedWebURL(address) {
            tab.load(url)
        }
        return tab
    }

    private func normalizedWebURL(_ value: String) -> URL? {
        if value == "about:blank" { return URL(string: value) }
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return url
        }
        if !value.contains(" "), value.contains("."), let url = URL(string: "https://\(value)") {
            return url
        }
        if value.hasPrefix("localhost") || value.hasPrefix("127.0.0.1") || value.hasPrefix("[::1]") {
            return URL(string: "http://\(value)")
        }
        return nil
    }

    private func cacheCurrentTabs() {
        tabsByWorkspace[workspaceKey] = tabs
        if let selectedTabID { selectionByWorkspace[workspaceKey] = selectedTabID }
        persistCurrentWorkspaceIfNeeded()
    }

    private func persistCurrentWorkspaceIfNeeded() {
        guard !workspaceKey.isEmpty,
              defaults.bool(forKey: DesktopUtilityPreferences.restoreBrowserTabsKey) else { return }
        let urls = tabs.compactMap { $0.webView.url?.absoluteString ?? nonempty($0.address) }
        let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        let value = DesktopBrowserRestoration(urls: urls, selectedIndex: selectedIndex)
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: restorationKey(for: workspaceKey))
        }
    }

    private func loadRestoration(for key: String) -> DesktopBrowserRestoration? {
        guard let data = defaults.data(forKey: restorationKey(for: key)) else { return nil }
        return try? JSONDecoder().decode(DesktopBrowserRestoration.self, from: data)
    }

    private func restorationKey(for key: String) -> String {
        let digest = key.data(using: .utf8).map { Data(SHA256.hash(data: $0)) } ?? Data()
        return "VeoDesktop.browser.restore." + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func sanitizedFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let parts = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        return nonempty(parts.joined(separator: "-")) ?? "Download"
    }

    private func nonempty(_ value: String) -> String? { value.isEmpty ? nil : value }
}

@MainActor
final class DesktopBrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id = UUID()
    @Published var title = "New Tab"
    @Published var address = ""
    @Published var isLoading = false
    @Published var estimatedProgress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var consoleMessages: [DesktopBrowserConsoleMessage] = []

    private(set) var webView: WKWebView!
    var openPopup: ((WKWebViewConfiguration, URLRequest?) -> WKWebView?)?
    var downloadStarted: ((WKDownload, String) -> Void)?
    var stateChanged: (() -> Void)?
    var closeRequested: (() -> Void)?
    var allowedFileRoot: URL?
    private var observations: [NSKeyValueObservation] = []

    init(configuration suppliedConfiguration: WKWebViewConfiguration? = nil) {
        super.init()
        let configuration = suppliedConfiguration ?? WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.removeScriptMessageHandler(forName: "veoConsole")
        configuration.userContentController.add(self, name: "veoConsole")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.consoleCaptureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        self.webView = webView
        observations = [
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.estimatedProgress = view.estimatedProgress }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.title = Self.nonempty(view.title) ?? "New Tab" }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.address = view.url?.absoluteString ?? "" }
            },
        ]
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func appendConsole(level: String, text: String) {
        consoleMessages.append(.init(level: level, text: text))
        if consoleMessages.count > 500 { consoleMessages.removeFirst(consoleMessages.count - 500) }
    }

    func invalidate() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "veoConsole")
        observations = []
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        refreshNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        refreshNavigationState()
        stateChanged?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        appendConsole(level: "error", text: error.localizedDescription)
        refreshNavigationState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about"].contains(scheme) {
            decisionHandler(.allow)
        } else if scheme == "file",
                  let root = allowedFileRoot,
                  url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloadStarted?(download, Self.nonempty(navigationAction.request.url?.lastPathComponent) ?? "Download")
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloadStarted?(download, navigationResponse.response.suggestedFilename ?? "Download")
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        openPopup?(configuration, navigationAction.request)
    }

    func webViewDidClose(_ webView: WKWebView) {
        closeRequested?()
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { response in completionHandler(response == .OK ? panel.urls : nil) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = Self.nonempty(webView.title) ?? "Web Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = Self.nonempty(webView.title) ?? "Web Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "veoConsole", let object = message.body as? [String: Any] else { return }
        appendConsole(
            level: object["level"] as? String ?? "log",
            text: object["text"] as? String ?? String(describing: message.body)
        )
    }

    private func refreshNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        address = webView.url?.absoluteString ?? address
        title = Self.nonempty(webView.title) ?? title
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static let consoleCaptureScript = """
    (() => {
      if (window.__veoConsoleInstalled) return;
      window.__veoConsoleInstalled = true;
      ['log', 'info', 'warn', 'error', 'debug'].forEach(level => {
        const original = console[level];
        console[level] = function(...args) {
          try {
            const text = args.map(value => {
              if (typeof value === 'string') return value;
              try { return JSON.stringify(value); } catch (_) { return String(value); }
            }).join(' ');
            window.webkit.messageHandlers.veoConsole.postMessage({ level, text });
          } catch (_) {}
          return original.apply(console, args);
        };
      });
      window.addEventListener('error', event => {
        window.webkit.messageHandlers.veoConsole.postMessage({ level: 'error', text: event.message || 'Script error' });
      });
    })();
    """
}

@MainActor
private final class DesktopBrowserDownloadDelegate: NSObject, WKDownloadDelegate {
    private static var retained: [ObjectIdentifier: DesktopBrowserDownloadDelegate] = [:]

    let id: UUID
    let name: String
    weak var model: DesktopBrowserModel?
    private var destinationURL: URL?
    private var progressObservation: NSKeyValueObservation?

    init(id: UUID, name: String, model: DesktopBrowserModel) {
        self.id = id
        self.name = name
        self.model = model
    }

    static func retain(_ delegate: DesktopBrowserDownloadDelegate, for download: WKDownload) {
        retained[ObjectIdentifier(download)] = delegate
        delegate.progressObservation = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak delegate] progress, _ in
            guard let delegate else { return }
            Task { @MainActor in
                delegate.model?.updateDownload(id: delegate.id, state: .downloading(progress.fractionCompleted))
            }
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        var destination = downloads.appendingPathComponent(name, isDirectory: false)
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            destination = downloads.appendingPathComponent(candidate, isDirectory: false)
            suffix += 1
        }
        destinationURL = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let finalURL = destinationURL {
            model?.updateDownload(id: id, state: .finished(finalURL))
        } else {
            model?.updateDownload(id: id, state: .failed("The download finished without a destination."))
        }
        Self.retained.removeValue(forKey: ObjectIdentifier(download))
        progressObservation = nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        model?.updateDownload(id: id, state: .failed(error.localizedDescription))
        Self.retained.removeValue(forKey: ObjectIdentifier(download))
        progressObservation = nil
    }
}
