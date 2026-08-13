// FILE: DesktopBrowserPanelView.swift
// Purpose: Embedded multi-tab WebKit browser with downloads and developer tools.
// Layer: Desktop app view

import AppKit
import SwiftUI
import WebKit

struct DesktopBrowserPanelView: View {
    @ObservedObject var model: DesktopBrowserModel
    @State private var addressDraft = ""
    @State private var javascriptDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            if let tab = model.selectedTab, tab.isLoading {
                ProgressView(value: tab.estimatedProgress).progressViewStyle(.linear)
            }
            Divider()

            if let tab = model.selectedTab {
                if let width = model.viewport.width {
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
            } else {
                ContentUnavailableView("No browser tab", systemImage: "globe")
            }

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
        .onChange(of: model.selectedTabID) { _, _ in syncAddress() }
        .onChange(of: model.selectedTab?.address) { _, _ in syncAddress() }
        .onAppear(perform: syncAddress)
    }

    private var navigationBar: some View {
        HStack(spacing: 6) {
            Button { model.selectedTab?.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(model.selectedTab?.canGoBack != true)
            Button { model.selectedTab?.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(model.selectedTab?.canGoForward != true)
            Button {
                if model.selectedTab?.isLoading == true {
                    model.selectedTab?.webView.stopLoading()
                } else {
                    model.selectedTab?.webView.reload()
                }
            } label: {
                Image(systemName: model.selectedTab?.isLoading == true ? "xmark" : "arrow.clockwise")
            }

            TextField("Search or enter address", text: $addressDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.navigate(address: addressDraft) }

            Menu {
                Picker("Viewport", selection: $model.viewport) {
                    ForEach(DesktopBrowserViewport.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button("Open in Safari") { model.openSelectedInSafari() }
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
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 38)
        .help(model.message ?? "Browser controls")
    }

    private var developerDrawer: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Console").font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Button("Clear") { model.selectedTab?.consoleMessages = [] }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.selectedTab?.consoleMessages ?? []) { entry in
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

    private func syncAddress() {
        addressDraft = model.selectedTab?.address ?? ""
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

private struct DesktopWebViewContainer: NSViewRepresentable {
    @ObservedObject var tab: DesktopBrowserTab

    func makeNSView(context: Context) -> WKWebView { tab.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
