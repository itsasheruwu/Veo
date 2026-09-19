// FILE: DesktopExternalProviderSheet.swift
// Purpose: In-app add, reconnect, and model-curation sheet for Veo-owned providers.
// Layer: Desktop app view

import AppKit
import SwiftUI
import WebKit

struct DesktopExternalProviderSheet: View {
    @Bindable var store: DesktopCodexStore
    var existing: DesktopConnectedProvider?
    @Environment(\.dismiss) private var dismiss

    @State private var preset: DesktopExternalProviderPreset
    @State private var customName = ""
    @State private var baseURL = ""
    @State private var wireAPI: DesktopProviderWireAPI = .chat
    @State private var apiKey = ""
    @State private var models: [DesktopExternalModelRecord] = []
    @State private var isProbing = false
    @State private var isSaving = false
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var didProbe = false
    @State private var providerID: String?
    @State private var oauthChallenge: DesktopOAuthDeviceChallenge?
    @State private var oauthTask: Task<Void, Never>?
    @State private var oauthUsesSystemBrowser = false

    init(store: DesktopCodexStore, existing: DesktopConnectedProvider? = nil) {
        self.store = store
        self.existing = existing
        _preset = State(initialValue: existing?.preset ?? .anthropic)
        _customName = State(initialValue: existing?.name ?? "")
        _baseURL = State(initialValue: existing?.baseURL ?? DesktopExternalProviderPreset.anthropic.defaultBaseURL)
        _wireAPI = State(initialValue: existing?.wireAPI ?? .chat)
        _models = State(initialValue: existing?.models ?? [])
        _didProbe = State(initialValue: existing != nil)
        _providerID = State(initialValue: existing?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Add provider" : "Provider")
                .font(.system(size: 17, weight: .semibold))

            if existing == nil {
                Picker("Provider", selection: $preset) {
                    Section("API key") {
                        ForEach(DesktopExternalProviderPreset.allCases.filter { $0.authKind == .apiKey && $0 != .custom }) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Section("OAuth") {
                        ForEach(DesktopExternalProviderPreset.allCases.filter { $0.authKind == .oauth }) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Section("Other") {
                        Text(DesktopExternalProviderPreset.custom.title).tag(DesktopExternalProviderPreset.custom)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: preset) { _, newValue in
                    if existing == nil {
                        cancelOAuth()
                        baseURL = newValue.defaultBaseURL
                        wireAPI = newValue.defaultWireAPI
                        if newValue != .custom { customName = "" }
                        models = []
                        didProbe = false
                        errorMessage = nil
                        oauthUsesSystemBrowser = false
                    }
                }
            }

            Text(preset.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if preset == .custom {
                labeledField("Name") {
                    TextField("Provider name", text: $customName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if preset.authKind == .apiKey {
                labeledField("Base URL") {
                    TextField("https://", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(preset != .custom && existing == nil)
                }
            }

            if preset == .custom {
                labeledField("API") {
                    Picker("API", selection: $wireAPI) {
                        ForEach(DesktopProviderWireAPI.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            if preset.authKind == .apiKey {
                labeledField("API key") {
                    SecureField(existing == nil ? "Paste API key" : "Paste a new key to replace", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                oauthSection
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Button(didProbe ? "Refresh models" : "Connect") {
                    Task { await probe() }
                }
                .disabled(isProbing || isSaving || isSigningIn || !canProbe)
                if isProbing { ProgressView().controlSize(.small) }
                Spacer()
            }

            if didProbe {
                Text("Models in the picker")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Only models that are on appear in Veo. Connecting a provider does not add every model.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($models) { $model in
                            Toggle(isOn: $model.enabled) {
                                Text(model.displayName)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel", role: .cancel) {
                    cancelOAuth()
                    dismiss()
                }
                Spacer()
                Button("Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!didProbe || isProbing || isSaving || isSigningIn)
            }
        }
        .padding(20)
        .frame(width: 480, height: 640)
        .onDisappear { cancelOAuth() }
    }

    @ViewBuilder
    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Sign in with", selection: $oauthUsesSystemBrowser) {
                Text("In Veo").tag(false)
                Text("Your browser").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(isSigningIn)
            .accessibilityLabel("Sign-in location")

            HStack {
                Button(isSigningIn ? "Waiting for sign in…" : "Sign in") {
                    Task { await startOAuth() }
                }
                .disabled(isSigningIn || isSaving)
                if isSigningIn { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let oauthChallenge {
                Text("If asked, enter this code:")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(oauthChallenge.userCode)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .textSelection(.enabled)

                if oauthUsesSystemBrowser {
                    Text("Finish signing in in your browser, then return here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Button("Open browser again") {
                        openOAuthURL(oauthChallenge.verificationURL)
                    }
                    .buttonStyle(.link)
                    .disabled(isSaving)
                } else {
                    DesktopInlineWebView(url: oauthChallenge.verificationURL)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                    Button("Open in your browser instead") {
                        oauthUsesSystemBrowser = true
                        openOAuthURL(oauthChallenge.verificationURL)
                    }
                    .buttonStyle(.link)
                    .disabled(isSaving)
                }
            }
        }
    }

    private var canProbe: Bool {
        if preset.authKind == .oauth {
            let id = providerID ?? existing?.id ?? preset.rawValue
            return DesktopProviderOAuth.loadToken(providerID: id) != nil
        }
        if preset == .custom {
            return !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && URL(string: baseURL) != nil
                && (!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (existing != nil && DesktopProviderCredentialStore.hasKey(providerID: existing?.id ?? "")))
        }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (existing != nil && DesktopProviderCredentialStore.hasKey(providerID: existing?.id ?? ""))
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func draftProvider() -> DesktopConnectedProvider {
        if var existing {
            existing.name = preset == .custom
                ? (customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? existing.name : customName)
                : existing.name
            existing.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.wireAPI = wireAPI
            existing.models = models
            return existing
        }
        var provider = DesktopConnectedProvider.make(
            preset: preset,
            customName: customName,
            existingIDs: Set(DesktopModelCatalogPreferences.shared.providers.map(\.id))
        )
        if let providerID {
            provider.id = providerID
            if preset == .custom {
                provider.envKey = "VEO_PROVIDER_\(providerID.uppercased().replacingOccurrences(of: "-", with: "_"))_KEY"
            }
        }
        if preset == .custom {
            provider.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            provider.wireAPI = wireAPI
        }
        provider.models = models
        return provider
    }

    private func resolvedKey(for provider: DesktopConnectedProvider) async -> String? {
        if provider.authKind == .oauth, let preset = provider.preset {
            return try? await DesktopProviderOAuth.validAccessToken(providerID: provider.id, preset: preset)
        }
        let typed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return DesktopProviderCredentialStore.key(providerID: provider.id)
    }

    private func startOAuth() async {
        errorMessage = nil
        cancelOAuth()
        isSigningIn = true
        do {
            let challenge = try await DesktopProviderOAuth.startDeviceLogin(preset: preset)
            oauthChallenge = challenge
            if oauthUsesSystemBrowser {
                openOAuthURL(challenge.verificationURL)
            }
            let provider = draftProvider()
            providerID = provider.id
            oauthTask = Task {
                do {
                    let token = try await DesktopProviderOAuth.pollDeviceLogin(preset: preset, challenge: challenge)
                    guard !Task.isCancelled else { return }
                    _ = DesktopProviderOAuth.saveToken(token, providerID: provider.id)
                    await MainActor.run {
                        isSigningIn = false
                        oauthChallenge = nil
                    }
                    await probe()
                } catch is CancellationError {
                    await MainActor.run { isSigningIn = false }
                } catch {
                    await MainActor.run {
                        isSigningIn = false
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            isSigningIn = false
            errorMessage = error.localizedDescription
        }
    }

    private func openOAuthURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func cancelOAuth() {
        oauthTask?.cancel()
        oauthTask = nil
        oauthChallenge = nil
        isSigningIn = false
    }

    private func probe() async {
        errorMessage = nil
        isProbing = true
        defer { isProbing = false }
        let provider = draftProvider()
        guard let key = await resolvedKey(for: provider) else {
            errorMessage = preset.authKind == .oauth
                ? "Sign in before connecting this provider."
                : "Enter an API key to connect this provider."
            return
        }
        do {
            let discovered = try await DesktopExternalModelCatalog.probe(provider: provider, apiKey: key)
            let enabledByUpstream = Dictionary(uniqueKeysWithValues: models.map { ($0.upstreamID, $0.enabled) })
            models = discovered.map { record in
                var copy = record
                copy.enabled = enabledByUpstream[record.upstreamID] ?? false
                return copy
            }
            providerID = provider.id
            didProbe = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        var provider = draftProvider()
        provider.models = models
        let typed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await store.saveExternalProvider(
                provider,
                apiKey: provider.authKind == .oauth ? nil : (typed.isEmpty ? nil : typed)
            )
            apiKey = ""
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DesktopInlineWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url {
            view.load(URLRequest(url: url))
        }
    }
}
