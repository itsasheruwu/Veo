// FILE: DesktopBrowserPanelView.swift
// Purpose: Embedded multi-tab WebKit browser with downloads and developer tools.
// Layer: Desktop app view

import AppKit
import SwiftUI
import WebKit

struct DesktopBrowserPanelView: View {
    @ObservedObject var model: DesktopBrowserModel
    var accountLoginSession: DesktopAccountLoginSession?
    var onCancelAccountLogin: () -> Void = {}

    var body: some View {
        Group {
            if let tab = model.selectedTab {
                DesktopBrowserActiveTabPanel(
                    model: model,
                    tab: tab,
                    accountLoginSession: accountLoginSession,
                    onCancelAccountLogin: onCancelAccountLogin
                )
                .id(tab.id)
            } else {
                ContentUnavailableView("No browser tab", systemImage: "globe")
            }
        }
    }
}

// Observe the tab itself: its navigation and console state do not belong to the parent model.
private struct DesktopBrowserActiveTabPanel: View {
    @ObservedObject var model: DesktopBrowserModel
    @ObservedObject var tab: DesktopBrowserTab
    var accountLoginSession: DesktopAccountLoginSession?
    var onCancelAccountLogin: () -> Void = {}
    @State private var addressDraft = ""
    @State private var javascriptDraft = ""
    @AppStorage(DesktopBrowserPreferences.searchEngineKey) private var searchEngineRaw =
        DesktopBrowserSearchEngine.google.rawValue

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            if let prompt = accountLoginPrompt {
                accountLoginBanner(prompt)
            }
            if let message = model.message, !message.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(message).font(.system(size: 11.5)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss browser message")
                }
                .padding(10)
                .background(Color.primary.opacity(0.04))
            }
            DesktopBrowserSelectedContent(model: model, tab: tab)

            if model.showsDeveloperTools {
                Divider()
                developerDrawer
                    .frame(height: 210)
            }

            if !model.downloads.isEmpty {
                Divider()
                downloadsBar
            }
        }
        .onChange(of: tab.address) { _, newAddress in
            guard !tab.isStartPage else { return }
            addressDraft = newAddress
        }
        .onAppear {
            syncAddress(resetStartPage: true)
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 6) {
            Button { tab.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
                .help("Back")
                .accessibilityLabel("Back")
            Button { tab.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
                .help("Forward")
                .accessibilityLabel("Forward")
            Button {
                if tab.isLoading {
                    tab.webView.stopLoading()
                } else {
                    tab.webView.reload()
                }
            } label: {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
            }
            .disabled(tab.isStartPage)
            .help(tab.isLoading ? "Stop loading" : "Reload page")
            .accessibilityLabel(tab.isLoading ? "Stop loading" : "Reload page")

            DesktopBrowserAddressField(
                text: $addressDraft,
                placeholder: searchEngine.addressPlaceholder,
                onSubmit: { model.navigate(address: addressDraft) }
            )
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                    .allowsHitTesting(false)
            )

            Button {
                model.autofillSelectedTab()
            } label: {
                Image(systemName: "key.fill")
            }
            .disabled(tab.isStartPage)
            .help("AutoFill from Keychain")
            .accessibilityLabel("AutoFill from Keychain")

            Menu {
                Picker("Viewport", selection: $model.viewport) {
                    ForEach(DesktopBrowserViewport.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button("Open in Safari") { model.openSelectedInSafari() }
                Button("AutoFill from Keychain") { model.autofillSelectedTab() }
                    .disabled(tab.isStartPage)
                Button(model.showsDeveloperTools ? "Hide Developer Tools" : "Show Developer Tools") {
                    model.showsDeveloperTools.toggle()
                }
                Button("Inspect with Safari…") {
                    model.message = "In Safari, enable Develop in Settings → Advanced, then choose this Veo page from the Develop menu."
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .accessibilityLabel("Browser options")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    private var developerDrawer: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Console").font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Button("Clear") { tab.consoleMessages = [] }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(tab.consoleMessages) { entry in
                        HStack(alignment: .top, spacing: 7) {
                            Text(entry.level.uppercased())
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(consoleColor(entry.level))
                                .frame(width: 38, alignment: .leading)
                            Text(entry.text)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(8)
            }
            Divider()
            HStack(spacing: 6) {
                TextField("JavaScript expression", text: $javascriptDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { evaluateJavaScript() }
                Button("Run", action: evaluateJavaScript)
                    .buttonStyle(.borderedProminent)
            }
            .padding(7)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var downloadsBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.downloads.prefix(8)) { download in
                    HStack(spacing: 6) {
                        switch download.state {
                        case .downloading(let progress):
                            ProgressView(value: progress).controlSize(.mini).frame(width: 42)
                        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Text(download.name).font(.system(size: 10.5)).lineLimit(1)
                        if case .finished = download.state {
                            Button("Open") { model.openDownload(download) }.buttonStyle(.borderless)
                            Button("Reveal") { model.revealDownload(download) }.buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
    }

    private var accountLoginPrompt: String? {
        guard let session = accountLoginSession, case .awaitingUser = session.state else { return nil }
        if let code = session.userCode, !code.isEmpty {
            return "Enter \(code) to finish ChatGPT sign-in."
        }
        return "Finish ChatGPT sign-in in this tab to stay signed in here."
    }

    @ViewBuilder
    private func accountLoginBanner(_ prompt: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.badge.key")
                .foregroundStyle(.secondary)
            Text(prompt)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Cancel", action: onCancelAccountLogin)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05))
        Divider()
    }

    private var searchEngine: DesktopBrowserSearchEngine {
        DesktopBrowserSearchEngine(rawValue: searchEngineRaw) ?? .google
    }

    private func syncAddress(resetStartPage: Bool) {
        if tab.isStartPage {
            if resetStartPage { addressDraft = "" }
        } else {
            addressDraft = tab.address
        }
    }

    private func evaluateJavaScript() {
        let source = javascriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        model.evaluateJavaScript(source)
        javascriptDraft = ""
    }

    private func consoleColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "error": return .red
        case "warn": return .orange
        case "result": return .green
        default: return .secondary
        }
    }
}

private struct DesktopBrowserSelectedContent: View {
    @ObservedObject var model: DesktopBrowserModel
    @ObservedObject var tab: DesktopBrowserTab

    var body: some View {
        VStack(spacing: 0) {
            if tab.isLoading {
                ProgressView(value: tab.estimatedProgress).progressViewStyle(.linear)
            }
            if let offer = tab.passwordSaveOffer {
                passwordBanner(
                    title: "Save password for \(offer.server)?",
                    detail: offer.account,
                    confirmTitle: "Save",
                    confirm: tab.savePasswordOffer,
                    dismiss: tab.dismissPasswordOffer
                )
            } else if let account = tab.autofillAccount {
                passwordBanner(
                    title: "Keychain has a password for \(account)",
                    detail: nil,
                    confirmTitle: "Fill",
                    confirm: tab.autofillFromKeychain,
                    dismiss: { tab.autofillAccount = nil }
                )
            }
            if let error = tab.navigationError {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Page could not be loaded", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Try Again") { tab.retryNavigation() }
                        .controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .accessibilityElement(children: .contain)
            }
            Divider()
            page
        }
    }

    @ViewBuilder
    private var page: some View {
        if tab.isStartPage {
            DesktopBrowserStartPage { query in
                model.navigate(address: query)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let width = model.viewport.width {
            ScrollView(.horizontal) {
                DesktopWebViewContainer(tab: tab)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            .background(Color.black.opacity(0.08))
        } else {
            DesktopWebViewContainer(tab: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func passwordBanner(
        title: String,
        detail: String?,
        confirmTitle: String,
        confirm: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Not Now", action: dismiss)
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button(confirmTitle, action: confirm)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05))
    }
}

private struct DesktopBrowserStartPage: View {
    var onSubmit: (String) -> Void
    @State private var query = ""
    @AppStorage(DesktopAppearancePreferences.composerMaterialKey) private var composerMaterialRaw =
        DesktopComposerMaterial.liquidGlass.rawValue
    @AppStorage(DesktopBrowserPreferences.searchEngineKey) private var searchEngineRaw =
        DesktopBrowserSearchEngine.google.rawValue
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 14) {
                Text("What should we look up?")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                HStack(alignment: .center, spacing: 10) {
                    TextField(searchEngine.addressPlaceholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isFieldFocused)
                        .focusEffectDisabled()
                        .onSubmit(submitIfNeeded)

                    Button(action: submitIfNeeded) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(.white, in: Circle())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.42)
                    .help("Go")
                    .accessibilityLabel("Go")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .modifier(DesktopFloatingMaterialSurface(material: composerMaterial))
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear { isFieldFocused = true }
    }

    private var searchEngine: DesktopBrowserSearchEngine {
        DesktopBrowserSearchEngine(rawValue: searchEngineRaw) ?? .google
    }

    private var composerMaterial: DesktopComposerMaterial {
        DesktopComposerMaterial(rawValue: composerMaterialRaw) ?? .liquidGlass
    }

    private var canSubmit: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitIfNeeded() {
        guard canSubmit else { return }
        onSubmit(query)
    }
}

private struct DesktopBrowserAddressField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = AddressNSTextField(string: text)
        field.placeholderString = placeholder
        field.setAccessibilityLabel("Address or search")
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.lineBreakMode = .byTruncatingTail
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        field.focusRingType = .none
        field.cell?.focusRingType = .none
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DesktopBrowserAddressField
        init(_ parent: DesktopBrowserAddressField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        @objc func submit() {
            parent.onSubmit()
        }
    }
}

private final class AddressNSTextField: NSTextField {
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        currentEditor()?.focusRingType = .none
        return accepted
    }
}

private struct DesktopWebViewContainer: NSViewRepresentable {
    @ObservedObject var tab: DesktopBrowserTab

    func makeNSView(context: Context) -> WKWebView { tab.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
