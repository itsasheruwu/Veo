// FILE: DesktopSettingsPage.swift
// Purpose: Presents Veo settings inside the main workspace window.
// Layer: Desktop app view

import SwiftUI

struct DesktopSettingsSidebarView: View {
    @ObservedObject var navigation: DesktopNavigationState
    @State private var isBackHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(.system(size: 18, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesktopTheme.spaceL)
                .padding(.top, DesktopTheme.sidebarTitlebarClearance + 4)
                .padding(.bottom, DesktopTheme.spaceM)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(DesktopSettingsCategory.allCases) { category in
                        categoryButton(category)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

            Divider()

            Button {
                navigation.showWorkspace()
            } label: {
                Label("Back", systemImage: "chevron.backward")
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        Color.primary.opacity(isBackHovered ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.14)) {
                    isBackHovered = hovering
                }
            }
            .help("Back to workspace")
            .accessibilityLabel("Back to workspace")
        }
        .background(DesktopTheme.sidebar)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func categoryButton(_ category: DesktopSettingsCategory) -> some View {
        let isSelected = navigation.settingsCategory == category
        return Button {
            navigation.settingsCategory = category
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? DesktopTheme.accent : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(category.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .contentShape(Rectangle())
            .background(
                DesktopTheme.accent.opacity(isSelected ? 0.14 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DesktopTheme.accent.opacity(isSelected ? 0.2 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint(category.detail)
    }
}

struct DesktopSettingsPage: View {
    @ObservedObject var store: DesktopCodexStore
    @ObservedObject var navigation: DesktopNavigationState
    @State private var apiKey = ""
    @State private var confirmsLogout = false
    @State private var pluginInstallTarget: DesktopPluginRecord?
    @State private var pluginUninstallTarget: DesktopPluginRecord?

    var body: some View {
        ZStack {
            DesktopTheme.canvas
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(navigation.settingsCategory.title)
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                        Text(navigation.settingsCategory.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    settingsContent
                }
                .padding(.horizontal, 38)
                .padding(.top, 48)
                .padding(.bottom, 40)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Settings")
        .tint(DesktopTheme.accent)
        .animation(.easeOut(duration: 0.16), value: navigation.settingsCategory)
        .confirmationDialog(
            "Sign out of the local Codex account?",
            isPresented: $confirmsLogout,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) { store.logoutAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs the Codex CLI out for other local Codex clients too. No credentials are displayed or retained by Veo.")
        }
        .confirmationDialog(
            "Install plugin?",
            isPresented: Binding(
                get: { pluginInstallTarget != nil },
                set: { if !$0 { pluginInstallTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: pluginInstallTarget
        ) { plugin in
            Button("Install \(plugin.displayName)") {
                store.installPlugin(plugin)
                pluginInstallTarget = nil
            }
            Button("Cancel", role: .cancel) { pluginInstallTarget = nil }
        } message: { plugin in
            Text(pluginInstallMessage(plugin))
        }
        .confirmationDialog(
            "Uninstall plugin?",
            isPresented: Binding(
                get: { pluginUninstallTarget != nil },
                set: { if !$0 { pluginUninstallTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: pluginUninstallTarget
        ) { plugin in
            Button("Uninstall \(plugin.displayName)", role: .destructive) {
                store.uninstallPlugin(plugin)
                pluginUninstallTarget = nil
            }
            Button("Cancel", role: .cancel) { pluginUninstallTarget = nil }
        } message: { plugin in
            Text("This removes only the \(plugin.displayName) plugin from the local Codex installation.")
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch navigation.settingsCategory {
        case .general:
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Workspace defaults")

                SettingsPanel {
                    SettingsRow(
                        title: "Default project",
                        detail: store.workspaceURL?.path ?? "No project selected",
                        systemImage: "folder",
                        detailFontDesign: .monospaced
                    ) {
                        Button("Choose…") { store.chooseWorkspace() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    SettingsPanelDivider()

                    SettingsRow(
                        title: "Default access",
                        detail: store.accessMode.detail,
                        systemImage: "shield"
                    ) {
                        Picker("Default access", selection: Binding(
                            get: { store.accessMode },
                            set: { store.updateAccessMode($0) }
                        )) {
                            ForEach(DesktopAccessMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(width: 132)
                    }

                    SettingsPanelDivider()

                    SettingsRow(
                        title: "Show Codex threads",
                        detail: "List chats from the local Codex CLI in a separate sidebar section. Veo chats stay in their own list.",
                        systemImage: "list.bullet.rectangle"
                    ) {
                        Toggle("Show Codex threads", isOn: Binding(
                            get: { store.showCodexThreads },
                            set: { store.setShowCodexThreads($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }

        case .runtime:
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Local connection")

                SettingsPanel {
                    SettingsRow(
                        title: "Codex runtime",
                        detail: store.runtimeState.title,
                        systemImage: runtimeSymbol,
                        iconColor: runtimeColor
                    ) {
                        Button("Reconnect") { store.reconnect() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    SettingsPanelDivider()

                    SettingsRow(
                        title: "Connection",
                        detail: "Codex CLI on this Mac",
                        systemImage: "terminal"
                    ) {
                        EmptyView()
                    }

                    SettingsPanelDivider()

                    SettingsRow(
                        title: "Realtime voice (experimental)",
                        detail: "Opt-in microphone and audio through the configured model provider. Audio is not saved by Veo.",
                        systemImage: "waveform.and.mic"
                    ) {
                        Toggle("Realtime voice", isOn: Binding(
                            get: { store.realtimeVoiceEnabled },
                            set: { store.setRealtimeVoiceEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!store.capabilities.supports(.realtimeVoice))
                    }

                    if store.realtimeVoiceEnabled, !store.realtimeVoices.isEmpty {
                        SettingsPanelDivider()
                        SettingsRow(
                            title: "Voice",
                            detail: "Used only for experimental realtime audio output.",
                            systemImage: "speaker.wave.2"
                        ) {
                            Picker("Voice", selection: Binding(
                                get: { store.selectedRealtimeVoiceID ?? store.realtimeVoices.first?.id ?? "" },
                                set: { store.selectRealtimeVoice($0) }
                            )) {
                                ForEach(store.realtimeVoices) { voice in
                                    Text(voice.displayName).tag(voice.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .frame(width: 120)
                        }
                    }
                }

                Label(
                    "Veo works directly in your local project folders. Chats and changes stay connected to the Codex CLI running on this Mac.",
                    systemImage: "lock.shield"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .labelStyle(SettingsNoteLabelStyle())
                .padding(.top, 6)
            }

        case .account:
            VStack(alignment: .leading, spacing: 22) {
                settingsRefreshHeader("Account status")

                SettingsPanel {
                    SettingsRow(
                        title: store.accountOverview.accountType,
                        detail: store.accountOverview.email
                            ?? (store.accountOverview.requiresOpenAIAuth
                                ? "Authentication required"
                                : "Local Codex account"),
                        systemImage: "person.crop.circle"
                    ) {
                        if let plan = store.accountOverview.plan {
                            Text(plan)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    SettingsPanelDivider()

                    SettingsRow(
                        title: "Primary limit",
                        detail: accountLimitDetail(
                            usedPercent: store.accountOverview.primaryUsedPercent,
                            resetsAt: store.accountOverview.primaryResetsAt
                        ),
                        systemImage: "gauge.with.dots.needle.50percent"
                    ) {
                        accountLimitProgress(store.accountOverview.primaryUsedPercent)
                    }

                    SettingsPanelDivider()

                    SettingsRow(
                        title: "Secondary limit",
                        detail: accountLimitDetail(
                            usedPercent: store.accountOverview.secondaryUsedPercent,
                            resetsAt: nil
                        ),
                        systemImage: "clock.arrow.2.circlepath"
                    ) {
                        accountLimitProgress(store.accountOverview.secondaryUsedPercent)
                    }

                    SettingsPanelDivider()

                    SettingsRow(
                        title: "Lifetime usage",
                        detail: store.accountOverview.lifetimeTokens.map {
                            $0.formatted(.number.notation(.compactName)) + " tokens"
                        } ?? "Not reported by this runtime",
                        systemImage: "sum"
                    ) {
                        EmptyView()
                    }
                }

                accountActions

                accountResourcesNote
            }

        case .integrations:
            VStack(alignment: .leading, spacing: 22) {
                settingsRefreshHeader("Local integrations")

                skillsSection
                pluginsSection
                appsSection
                mcpSection

                accountResourcesNote
            }
        }
    }

    @ViewBuilder
    private var accountActions: some View {
        SettingsPanel {
            if store.accountOverview.accountType == "Signed out" || store.accountOverview.requiresOpenAIAuth {
                SettingsRow(
                    title: "Sign in with ChatGPT",
                    detail: "Continue in your browser through the local Codex runtime.",
                    systemImage: "person.badge.key"
                ) {
                    Button("Sign In") { store.startChatGPTLogin() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!store.capabilities.supports(.accountLogin) || store.integrationMutationID != nil)
                }

                SettingsPanelDivider()

                SettingsRow(
                    title: "Use an API key",
                    detail: "Sent once to the local Codex runtime; never saved by Veo.",
                    systemImage: "key.horizontal"
                ) {
                    HStack(spacing: 7) {
                        SecureField("API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                            .privacySensitive()
                        Button("Use Key") {
                            store.loginWithAPIKey(apiKey)
                            apiKey = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !store.capabilities.supports(method: "account/login/start")
                            || store.integrationMutationID != nil)
                    }
                }
            } else {
                SettingsRow(
                    title: "Shared local account",
                    detail: "Signing out affects the Codex CLI and other local clients.",
                    systemImage: "rectangle.portrait.and.arrow.right"
                ) {
                    Button("Sign Out", role: .destructive) { confirmsLogout = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!store.capabilities.supports(.accountLogout) || store.integrationMutationID != nil)
                }
            }

            if let session = store.accountLoginSession {
                SettingsPanelDivider()
                SettingsRow(
                    title: accountLoginTitle(session.state),
                    detail: accountLoginDetail(session),
                    systemImage: "safari"
                ) {
                    if case .awaitingUser = session.state {
                        Button("Cancel") { store.cancelAccountLogin() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(store.integrationMutationID != nil)
                    }
                }
            }
        }
    }

    private var skillsSection: some View {
        integrationSection(title: "Skills", empty: "No skills were reported.") {
            ForEach(Array(store.skillRecords.enumerated()), id: \.element.id) { index, skill in
                if index > 0 { SettingsPanelDivider() }
                SettingsRow(
                    title: skill.displayName,
                    detail: [skill.description, skillScopeName(skill.scope), skill.path]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "),
                    systemImage: "bolt.badge.checkmark"
                ) {
                    Toggle("Enabled", isOn: Binding(
                        get: { skill.enabled },
                        set: { store.setSkillEnabled(skill, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!store.capabilities.supports(method: "skills/config/write")
                        || store.integrationMutationID != nil)
                }
            }
        }
    }

    private var pluginsSection: some View {
        integrationSection(title: "Plugins", empty: "No plugins were reported.") {
            ForEach(Array(store.pluginRecords.enumerated()), id: \.element.id) { index, plugin in
                if index > 0 { SettingsPanelDivider() }
                SettingsRow(
                    title: plugin.displayName,
                    detail: [plugin.description, plugin.marketplaceName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    systemImage: "puzzlepiece.extension"
                ) {
                    if store.integrationMutationID == plugin.id {
                        ProgressView().controlSize(.small)
                    } else if plugin.installed {
                        Button("Uninstall", role: .destructive) { pluginUninstallTarget = plugin }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!store.capabilities.supports(method: "plugin/uninstall"))
                    } else if plugin.canInstall {
                        Button("Install") { pluginInstallTarget = plugin }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!store.capabilities.supports(method: "plugin/install"))
                    } else {
                        Text(plugin.unavailableReason)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var appsSection: some View {
        integrationSection(title: "Apps", empty: "No apps were reported by this runtime.") {
            ForEach(Array(store.appRecords.enumerated()), id: \.element.id) { index, app in
                if index > 0 { SettingsPanelDivider() }
                SettingsRow(
                    title: app.name,
                    detail: app.description,
                    systemImage: "app.connected.to.app.below.fill"
                ) {
                    if !app.isEnabled {
                        Text("Disabled")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    } else if app.isAccessible {
                        Text("Connected")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.green)
                    } else if app.installURL != nil {
                        Button("Connect…") { store.openAppLink(app) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!store.capabilities.supports(.appsLinking))
                    } else {
                        Text("Unavailable").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("MCP Servers")
                Spacer()
                Button("Reload") { store.reloadMCPServers() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!store.capabilities.supports(.mcpReload) || store.integrationMutationID != nil)
            }
            SettingsPanel {
                if store.mcpServerStatuses.isEmpty {
                    SettingsRow(title: "None reported", detail: "No MCP servers were reported.", systemImage: "server.rack") { EmptyView() }
                } else {
                    ForEach(Array(store.mcpServerStatuses.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { SettingsPanelDivider() }
                        SettingsRow(
                            title: server.title,
                            detail: mcpDetail(server),
                            systemImage: "server.rack"
                        ) {
                            if store.integrationMutationID == "mcp:\(server.id)" {
                                ProgressView().controlSize(.small)
                            } else if case .starting? = server.startupState {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Starting")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            } else if mcpNeedsLogin(server) {
                                Button(server.requiresReauthentication ? "Reauthorize…" : "Authorize…") {
                                    store.loginMCP(server)
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(!store.capabilities.supports(.mcpOAuth))
                            } else {
                                Text(mcpStatusName(server))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(mcpStatusColor(server))
                            }
                        }
                    }
                }
            }
        }
    }

    private func integrationSection<Content: View>(
        title: String,
        empty: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(title)
            SettingsPanel {
                if (title == "Skills" && store.skillRecords.isEmpty)
                    || (title == "Plugins" && store.pluginRecords.isEmpty)
                    || (title == "Apps" && store.appRecords.isEmpty) {
                    SettingsRow(title: "None reported", detail: empty, systemImage: "square.dashed") { EmptyView() }
                } else {
                    content()
                }
            }
        }
    }

    private func settingsRefreshHeader(_ title: String) -> some View {
        HStack {
            sectionTitle(title)
            Spacer()
            if store.isLoadingAccountResources {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Refresh") { store.refreshAccountResources() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.runtimeState != .ready || store.isLoadingAccountResources)
        }
    }

    @ViewBuilder
    private func resourceSection(_ kind: DesktopResourceOverview.Kind) -> some View {
        let resources = store.resourceOverviews.filter { $0.kind == kind }
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(kind.rawValue)
            SettingsPanel {
                if resources.isEmpty {
                    SettingsRow(
                        title: "None reported",
                        detail: "This runtime returned no \(kind.rawValue.lowercased()).",
                        systemImage: kind.systemImage
                    ) {
                        EmptyView()
                    }
                } else {
                    ForEach(Array(resources.enumerated()), id: \.element.id) { index, resource in
                        if index > 0 { SettingsPanelDivider() }
                        SettingsRow(
                            title: resource.name,
                            detail: resource.detail,
                            systemImage: kind.systemImage
                        ) {
                            Text(resource.status)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(resource.status == "Enabled" || resource.status == "Connected" ? .green : .secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var accountResourcesNote: some View {
        if let message = store.accountResourcesMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .labelStyle(SettingsNoteLabelStyle())
        } else {
            Label(
                "Inventory and supported actions come from the local Codex runtime. Veo never displays or stores tokens, API keys, or OAuth secrets.",
                systemImage: "lock.shield"
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .labelStyle(SettingsNoteLabelStyle())
        }
    }

    private func accountLimitDetail(usedPercent: Int?, resetsAt: Date?) -> String {
        guard let usedPercent else { return "Not reported by this runtime" }
        guard let resetsAt else { return "\(usedPercent)% used" }
        return "\(usedPercent)% used · resets \(resetsAt.formatted(.relative(presentation: .named)))"
    }

    private func skillScopeName(_ scope: DesktopSkillScope) -> String {
        switch scope {
        case .user: return "User"
        case .repo: return "Project"
        case .system: return "System"
        case .admin: return "Managed"
        case .unknown(let value): return value.capitalized
        }
    }

    private func accountLoginTitle(_ state: DesktopAccountLoginState) -> String {
        switch state {
        case .awaitingUser: return "Browser sign-in pending"
        case .completed: return "Sign-in complete"
        case .failed: return "Sign-in failed"
        case .canceled: return "Sign-in canceled"
        }
    }

    private func accountLoginDetail(_ session: DesktopAccountLoginSession) -> String {
        switch session.state {
        case .awaitingUser:
            return session.userCode.map { "Code: \($0)" } ?? "Complete sign-in in the secure browser window."
        case .completed:
            return "The local Codex account is refreshing."
        case .failed(let message):
            return message
        case .canceled:
            return "Start another sign-in when you are ready."
        }
    }

    private func pluginInstallMessage(_ plugin: DesktopPluginRecord) -> String {
        var details = [plugin.description]
        if let marketplace = plugin.marketplaceName { details.append("Source: \(marketplace)") }
        if !plugin.capabilityLabels.isEmpty {
            details.append("Capabilities: \(plugin.capabilityLabels.joined(separator: ", "))")
        }
        if plugin.mustShowInstallationInterstitial {
            details.append("This plugin requires an installation confirmation from its developer.")
        }
        return details.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func mcpNeedsLogin(_ server: DesktopMCPServerStatus) -> Bool {
        if server.requiresReauthentication { return true }
        switch server.authStatus {
        case .notLoggedIn: return true
        default: return false
        }
    }

    private func mcpDetail(_ server: DesktopMCPServerStatus) -> String {
        if server.requiresReauthentication {
            return "Authorization expired. Reauthorize to restore this server."
        }
        if let error = server.error, !error.isEmpty {
            return error
        }
        if case .failed? = server.startupState {
            return "This server failed to start."
        }
        if case .cancelled? = server.startupState {
            return "This server's startup was cancelled."
        }
        return server.description.isEmpty
            ? "\(server.toolNames.count) tools available"
            : server.description
    }

    private func mcpStatusName(_ server: DesktopMCPServerStatus) -> String {
        if let error = server.error, !error.isEmpty { return error }
        switch server.startupState {
        case .failed?: return "Startup failed"
        case .cancelled?: return "Stopped"
        case .unknown(let value)?: return value.capitalized
        case .starting?, .ready?, nil: return mcpAuthName(server.authStatus)
        }
    }

    private func mcpStatusColor(_ server: DesktopMCPServerStatus) -> Color {
        if server.error != nil { return .red }
        switch server.startupState {
        case .failed?: return .red
        case .cancelled?, .unknown?: return .secondary
        case .starting?, .ready?, nil: return .green
        }
    }

    private func mcpAuthName(_ status: DesktopMCPAuthStatus) -> String {
        switch status {
        case .unsupported: return "Ready"
        case .notLoggedIn: return "Sign-in required"
        case .bearerToken: return "Token"
        case .oauth: return "Authorized"
        case .unknown(let value): return value.capitalized
        }
    }

    @ViewBuilder
    private func accountLimitProgress(_ usedPercent: Int?) -> some View {
        if let usedPercent {
            ProgressView(value: Double(min(max(usedPercent, 0), 100)), total: 100)
                .frame(width: 92)
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }

    private var runtimeColor: Color {
        switch store.runtimeState {
        case .ready: return .green
        case .starting: return .orange
        case .unavailable: return .red
        }
    }

    private var runtimeSymbol: String {
        switch store.runtimeState {
        case .ready: return "checkmark.circle.fill"
        case .starting: return "clock.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }
}

private struct SettingsPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    var iconColor: Color = .secondary
    var detailFontDesign: Font.Design = .default
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5, design: detailFontDesign))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 18)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 68)
        .contentShape(Rectangle())
    }
}

private struct SettingsPanelDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 52)
    }
}

private struct SettingsNoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 9) {
            configuration.icon
                .frame(width: 18)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
