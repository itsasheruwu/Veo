// FILE: DesktopSettingsPage.swift
// Purpose: Presents Veo settings inside the main workspace window.
// Layer: Desktop app view

import AppKit
import SwiftUI

struct DesktopSettingsSidebarView: View {
    @Environment(\.veoAccent) private var veoAccent
    @ObservedObject var navigation: DesktopNavigationState
    @AppStorage(DesktopAppearancePreferences.sidebarMaterialKey) private var sidebarMaterialRaw =
        DesktopSidebarMaterial.solid.rawValue
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
        .desktopSidebarChrome(DesktopSidebarMaterial(rawValue: sidebarMaterialRaw) ?? .solid)
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
                    .foregroundStyle(isSelected ? veoAccent : .secondary)
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
                veoAccent.opacity(isSelected ? 0.14 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(veoAccent.opacity(isSelected ? 0.2 : 0), lineWidth: 1)
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
    @EnvironmentObject private var updateService: DesktopUpdateService
    @EnvironmentObject private var notifications: DesktopNotificationService
    @AppStorage(DesktopTerminalPreferences.agentCLIsEnabledKey) private var agentCLIsEnabled = false
    @AppStorage(DesktopTerminalPreferences.yoloModeKey) private var agentCLIsYoloMode = false
    @AppStorage(DesktopTerminalPreferences.yoloClaudeKey) private var agentCLIsYoloClaude = true
    @AppStorage(DesktopTerminalPreferences.yoloCodexKey) private var agentCLIsYoloCodex = true
    @AppStorage(DesktopAppearancePreferences.appearanceModeKey) private var appearanceModeRaw =
        DesktopAppearanceMode.dark.rawValue
    @AppStorage(DesktopAppearancePreferences.accentColorKey) private var accentColorHex =
        DesktopAppearancePreferences.defaultAccentHex
    @AppStorage(DesktopAppearancePreferences.sidebarMaterialKey) private var sidebarMaterialRaw =
        DesktopSidebarMaterial.solid.rawValue
    @AppStorage(DesktopAppearancePreferences.composerMaterialKey) private var composerMaterialRaw =
        DesktopComposerMaterial.liquidGlass.rawValue
    @AppStorage(DesktopAppearancePreferences.windowMaterialKey) private var windowMaterialRaw =
        DesktopWindowMaterial.solid.rawValue
    @AppStorage(DesktopNotificationPreferences.systemAlertsKey) private var notificationSystemAlerts = true
    @AppStorage(DesktopNotificationPreferences.inAppWarningsKey) private var notificationInAppWarnings = true
    @AppStorage(DesktopNotificationPreferences.menuBarIconKey) private var notificationMenuBarIcon = true
    @AppStorage(DesktopNotificationPreferences.completionSoundKey) private var notificationCompletionSound = false
    @AppStorage(DesktopNotificationPreferences.customSoundPathKey) private var notificationSoundPath = ""
    @AppStorage(DesktopNotificationPreferences.customSoundNameKey) private var notificationSoundName = ""
    @AppStorage(DesktopAppearancePreferences.threadMinimapVisibleKey) private var showsThreadMinimap = true
    @AppStorage(DesktopAppearancePreferences.threadMinimapMaterialKey) private var threadMinimapMaterialRaw =
        DesktopMinimapMaterial.liquidGlass.rawValue
    @AppStorage(DesktopComposerPreferences.showsContextWindowUsageKey) private var showsContextWindowUsage = false
    @AppStorage(DesktopComposerPreferences.contextWindowUsageStyleKey) private var contextWindowUsageStyleRaw =
        DesktopContextWindowUsageStyle.percent.rawValue
    @State private var apiKey = ""
    @State private var confirmsLogout = false
    @State private var pluginInstallTarget: DesktopPluginRecord?
    @State private var pluginUninstallTarget: DesktopPluginRecord?
    @State private var notificationSoundError: String?

    private var accentColor: Color {
        DesktopAppearancePreferences.color(fromHex: accentColorHex) ?? DesktopTheme.accent
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { accentColor },
            set: { accentColorHex = DesktopAppearancePreferences.hex(from: $0) }
        )
    }

    private var appearanceModeBinding: Binding<DesktopAppearanceMode> {
        Binding(
            get: { DesktopAppearanceMode(rawValue: appearanceModeRaw) ?? .dark },
            set: { appearanceModeRaw = $0.rawValue }
        )
    }

    private var sidebarMaterialBinding: Binding<DesktopSidebarMaterial> {
        Binding(
            get: { DesktopSidebarMaterial(rawValue: sidebarMaterialRaw) ?? .solid },
            set: { sidebarMaterialRaw = $0.rawValue }
        )
    }

    private var composerMaterialBinding: Binding<DesktopComposerMaterial> {
        Binding(
            get: { DesktopComposerMaterial(rawValue: composerMaterialRaw) ?? .liquidGlass },
            set: { composerMaterialRaw = $0.rawValue }
        )
    }

    private var windowMaterialBinding: Binding<DesktopWindowMaterial> {
        Binding(
            get: { DesktopWindowMaterial(rawValue: windowMaterialRaw) ?? .solid },
            set: { windowMaterialRaw = $0.rawValue }
        )
    }

    private var threadMinimapMaterialBinding: Binding<DesktopMinimapMaterial> {
        Binding(
            get: { DesktopMinimapMaterial(rawValue: threadMinimapMaterialRaw) ?? .liquidGlass },
            set: { threadMinimapMaterialRaw = $0.rawValue }
        )
    }

    private var contextWindowUsageStyleBinding: Binding<DesktopContextWindowUsageStyle> {
        Binding(
            get: { DesktopContextWindowUsageStyle(rawValue: contextWindowUsageStyleRaw) ?? .percent },
            set: { contextWindowUsageStyleRaw = $0.rawValue }
        )
    }

    var body: some View {
        ZStack {
            DesktopWindowChromeBackground(
                material: DesktopWindowMaterial(rawValue: windowMaterialRaw) ?? .solid
            )

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
        .tint(accentColor)
        .animation(.easeOut(duration: 0.16), value: navigation.settingsCategory)
        .task(id: navigation.settingsCategory) {
            notifications.refreshAuthorizationStatus()
            if navigation.settingsCategory == .account {
                store.refreshAccountOverview()
            }
        }
        .onChange(of: notificationSystemAlerts) { _, enabled in
            if enabled {
                notifications.prepareIfNeeded()
            } else {
                notifications.refreshAuthorizationStatus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notifications.refreshAuthorizationStatus()
        }
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
                                Text(mode.title)
                                    .tag(mode)
                                    .disabled(!store.isAccessModeAllowed(mode))
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

                sectionTitle("Background intelligence")
                    .padding(.top, 16)

                SettingsPanel {
                    SettingsRow(
                        title: "Utility model",
                        detail: "Used for thread minimap topics and automatic Veo chat names. Reasoning stays Low.",
                        systemImage: "sparkles"
                    ) {
                        Picker("Utility model", selection: Binding(
                            get: { store.utilityModelSelectionID },
                            set: { store.setUtilityModel($0) }
                        )) {
                            ForEach(store.utilityModelOptions) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(width: 170)
                        .disabled(store.utilityModelOptions.isEmpty)
                        .help("Choose the model Veo uses for automatic titles and minimap topic detection.")
                        .accessibilityLabel("Utility model")
                        .accessibilityValue(store.utilityModelDisplayName)
                    }
                }
            }

        case .appearance:
            appearanceSettings

        case .notifications:
            notificationSettings

        case .terminal:
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Agent CLIs")

                SettingsPanel {
                    SettingsRow(
                        title: "Agent CLIs",
                        detail: "Shell helpers for Claude and Codex in the docked terminal.",
                        systemImage: "hammer"
                    ) {
                        Toggle("Agent CLIs", isOn: $agentCLIsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    if agentCLIsEnabled {
                        SettingsRow(
                            title: "Start in yolo mode",
                            detail: "Always launch selected agent CLIs with dangerous bypass flags.",
                            systemImage: "flame",
                            nestDepth: 1,
                            nestStyle: .leaf
                        ) {
                            Toggle("Start in yolo mode", isOn: $agentCLIsYoloMode)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }

                        if agentCLIsYoloMode {
                            SettingsRow(
                                title: "Claude",
                                detail: "Always run with --dangerously-skip-permissions.",
                                assetImage: "ClaudeMark",
                                nestDepth: 2,
                                nestStyle: .branch
                            ) {
                                Toggle("Claude yolo", isOn: $agentCLIsYoloClaude)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            }

                            SettingsRow(
                                title: "Codex",
                                detail: "Always run in full-access yolo mode.",
                                assetImage: "CodexMark",
                                nestDepth: 2,
                                nestStyle: .leaf
                            ) {
                                Toggle("Codex yolo", isOn: $agentCLIsYoloCodex)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                Label(
                    "Applies to new docked terminal tabs. These modes skip permission prompts and sandboxes — use only when you trust the session.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .labelStyle(SettingsNoteLabelStyle())
                .padding(.top, 6)
            }

        case .runtime:
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    sectionTitle("Local connection")
                    Spacer()
                    if store.isLoadingRuntimeConfiguration {
                        ProgressView().controlSize(.small)
                    }
                    Button("Refresh") { store.refreshRuntimeConfiguration() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.runtimeState != .ready || store.isLoadingRuntimeConfiguration)
                }

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
                        Button("Unload Inactive") { store.unloadInactiveRuntimeThreads() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!store.capabilities.supports(.threadSubscriptions)
                                || store.integrationMutationID != nil)
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

                if !store.permissionProfiles.isEmpty || !store.managedRequirements.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Permissions and requirements")
                        SettingsPanel {
                            if !store.permissionProfiles.isEmpty {
                                ForEach(Array(store.permissionProfiles.enumerated()), id: \.element.id) { index, profile in
                                    if index > 0 { SettingsPanelDivider() }
                                    SettingsRow(
                                        title: profile.id,
                                        detail: profile.description ?? "Permission profile reported by Codex.",
                                        systemImage: profile.isAllowed ? "checkmark.shield" : "xmark.shield"
                                    ) {
                                        Text(profile.isAllowed ? "Allowed" : "Managed off")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(profile.isAllowed ? .green : .secondary)
                                    }
                                }
                            }

                            if !store.permissionProfiles.isEmpty, !store.managedRequirements.isEmpty {
                                SettingsPanelDivider()
                            }

                            if !store.managedRequirements.isEmpty {
                                SettingsRow(
                                    title: "Managed policy",
                                    detail: managedRequirementsDetail,
                                    systemImage: "building.2.crop.circle"
                                ) { EmptyView() }
                            }
                        }
                    }
                }

                if !store.codexConfigDetails.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Effective Codex configuration")
                        SettingsPanel {
                            ForEach(Array(store.codexConfigDetails.enumerated()), id: \.offset) { index, detail in
                                if index > 0 { SettingsPanelDivider() }
                                SettingsRow(
                                    title: detail,
                                    detail: "Resolved through Codex configuration layering.",
                                    systemImage: "slider.horizontal.3"
                                ) { EmptyView() }
                            }
                        }
                    }
                }

                if !store.experimentalFeatures.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Codex features")
                        SettingsPanel {
                            ForEach(Array(store.experimentalFeatures.enumerated()), id: \.element.id) { index, feature in
                                if index > 0 { SettingsPanelDivider() }
                                SettingsRow(
                                    title: feature.displayName,
                                    detail: feature.description ?? "\(feature.stage.capitalized) Codex feature.",
                                    systemImage: "flask"
                                ) {
                                    Toggle(feature.displayName, isOn: Binding(
                                        get: { feature.isEnabled },
                                        set: { store.setExperimentalFeature(feature, enabled: $0) }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .disabled(store.managedRequirements.featureRequirements[feature.id] != nil
                                        || store.integrationMutationID != nil)
                                }
                            }
                        }
                    }
                }

                if !store.hookRecords.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Lifecycle hooks")
                        SettingsPanel {
                            ForEach(Array(store.hookRecords.enumerated()), id: \.element.id) { index, hook in
                                if index > 0 { SettingsPanelDivider() }
                                SettingsRow(
                                    title: hook.eventName,
                                    detail: "\(hook.handlerType.capitalized) · \(hook.sourcePath)",
                                    systemImage: "arrow.trianglehead.branch"
                                ) {
                                    Text(hook.isEnabled ? (hook.isManaged ? "Managed" : hook.trustStatus.capitalized) : "Disabled")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(hook.isEnabled ? .secondary : .tertiary)
                                }
                            }
                        }
                    }
                }

                if !store.runtimeNotices.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Recent runtime notices")
                        SettingsPanel {
                            ForEach(Array(store.runtimeNotices.prefix(8).enumerated()), id: \.element.id) { index, notice in
                                if index > 0 { SettingsPanelDivider() }
                                SettingsRow(
                                    title: notice.title,
                                    detail: notice.detail,
                                    systemImage: notice.severity == .error ? "xmark.octagon" : "exclamationmark.triangle"
                                ) {
                                    Text(notice.createdAt, style: .time)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }
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

                if let message = store.runtimeConfigurationMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .labelStyle(SettingsNoteLabelStyle())
                }
            }

        case .updates:
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    sectionTitle("Software update")
                    Spacer()
                    if updateService.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Button("Check Now") { updateService.checkForUpdates(userInitiated: true) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(updateService.isBusy)
                }

                SettingsPanel {
                    SettingsRow(
                        title: "Installed version",
                        detail: updateStatusDetail,
                        systemImage: updateStatusSymbol,
                        iconColor: updateStatusColor
                    ) {
                        updateActionButton
                    }

                    SettingsPanelDivider()

                    SettingsRow(
                        title: "Check automatically",
                        detail: "Look for new Veo releases on launch and every few hours.",
                        systemImage: "arrow.triangle.2.circlepath"
                    ) {
                        Toggle("Check automatically", isOn: $updateService.automaticChecks)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    SettingsPanelDivider()

                    SettingsRow(
                        title: "Install automatically",
                        detail: updateService.canInstallInPlace
                            ? "Download and install updates without asking. Veo asks before relaunching."
                            : "This build runs from a location Veo cannot replace, so updates open the release page instead.",
                        systemImage: "square.and.arrow.down",
                        nestDepth: 1,
                        nestStyle: .leaf
                    ) {
                        Toggle("Install automatically", isOn: $updateService.automaticInstall)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!updateService.automaticChecks || !updateService.canInstallInPlace)
                    }
                }

                if let release = updateService.availableRelease, !release.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("What's new in \(release.title)")
                        ScrollView {
                            Text(release.notes)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(maxHeight: 220)
                        .background(
                            Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                }

                if case let .failed(message) = updateService.phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .labelStyle(SettingsNoteLabelStyle())
                }

                Label(
                    "Updates come from the public Veo releases on GitHub. Veo verifies the downloaded app's code signature before replacing the installed copy.",
                    systemImage: "lock.shield"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .labelStyle(SettingsNoteLabelStyle())
            }

        case .account:
            VStack(alignment: .leading, spacing: 22) {
                settingsRefreshHeader(
                    "Account status",
                    isLoading: store.isLoadingAccountOverview,
                    refresh: store.refreshAccountOverview
                )

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

                if !store.workspaceMessages.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Workspace messages")
                        SettingsPanel {
                            ForEach(Array(store.workspaceMessages.enumerated()), id: \.element.id) { index, message in
                                if index > 0 { SettingsPanelDivider() }
                                SettingsRow(
                                    title: message.type.capitalized,
                                    detail: message.body,
                                    systemImage: message.type == "headline" ? "megaphone" : "bubble.left.and.text.bubble.right"
                                ) {
                                    if let createdAt = message.createdAt {
                                        Text(createdAt, style: .date)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }

                accountOverviewNote
            }

        case .integrations:
            VStack(alignment: .leading, spacing: 22) {
                settingsRefreshHeader(
                    "Local integrations",
                    isLoading: store.isLoadingAccountResources,
                    refresh: store.refreshAccountResources
                )

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
                    HStack(spacing: 7) {
                        Button("Device Code") { store.startChatGPTDeviceCodeLogin() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Sign In") { store.startChatGPTLogin() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
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

                if store.availableRateLimitResetCredits > 0 {
                    SettingsPanelDivider()
                    SettingsRow(
                        title: "Rate-limit reset",
                        detail: "\(store.availableRateLimitResetCredits) reset credit\(store.availableRateLimitResetCredits == 1 ? "" : "s") available.",
                        systemImage: "arrow.counterclockwise.circle"
                    ) {
                        Button("Use Reset") { store.consumeRateLimitResetCredit() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(store.integrationMutationID != nil)
                    }
                }

                if store.capabilities.supports(method: "account/sendAddCreditsNudgeEmail") {
                    SettingsPanelDivider()
                    SettingsRow(
                        title: "Credit notification",
                        detail: "Ask the workspace owner to review available Codex credits.",
                        systemImage: "envelope.badge"
                    ) {
                        Button("Notify Owner") { store.sendCreditsNudgeEmail() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(store.integrationMutationID != nil)
                    }
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

    private func settingsRefreshHeader(
        _ title: String,
        isLoading: Bool,
        refresh: @escaping () -> Void
    ) -> some View {
        HStack {
            sectionTitle(title)
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Refresh", action: refresh)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.runtimeState != .ready || isLoading)
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
    private var accountOverviewNote: some View {
        if let message = store.accountOverviewMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .labelStyle(SettingsNoteLabelStyle())
        } else {
            Label(
                "Account details come straight from your local Codex session. Veo does not read or keep your credentials.",
                systemImage: "lock.shield"
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .labelStyle(SettingsNoteLabelStyle())
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

    private var managedRequirementsDetail: String {
        var parts: [String] = []
        if !store.managedRequirements.allowedSandboxModes.isEmpty {
            parts.append("Sandboxes: " + store.managedRequirements.allowedSandboxModes.joined(separator: ", "))
        }
        if !store.managedRequirements.allowedApprovalPolicies.isEmpty {
            parts.append("Approvals: " + store.managedRequirements.allowedApprovalPolicies.joined(separator: ", "))
        }
        if let profile = store.managedRequirements.defaultPermissionProfile {
            parts.append("Default profile: \(profile)")
        }
        if !store.managedRequirements.featureRequirements.isEmpty {
            parts.append("\(store.managedRequirements.featureRequirements.count) managed feature requirement(s)")
        }
        return parts.isEmpty ? "Managed requirements are active." : parts.joined(separator: " · ")
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

    @ViewBuilder
    private var appearanceSettings: some View {
        appearanceSettingsBody
    }

    @ViewBuilder
    private var notificationSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("While you're away")

                SettingsPanel {
                    SettingsRow(
                        title: "Turn alerts",
                        detail: notificationTurnAlertDetail,
                        systemImage: "bell.badge"
                    ) {
                        Toggle("Turn alerts", isOn: $notificationSystemAlerts)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    if notificationSystemAlerts,
                       notifications.authorizationState == .denied {
                        SettingsRow(
                            title: "Allow notifications in macOS",
                            detail: "Veo is enabled here, but system alerts are blocked.",
                            systemImage: "bell.slash",
                            iconColor: .orange,
                            nestDepth: 1,
                            nestStyle: .leaf
                        ) {
                            Button("Open System Settings") {
                                notifications.openSystemNotificationSettings()
                            }
                            .controlSize(.small)
                        }
                    }

                    SettingsPanelDivider()

                    SettingsRow(
                        title: "Warning banners",
                        detail: "Show warning-level runtime notices briefly inside Veo.",
                        systemImage: "exclamationmark.triangle"
                    ) {
                        Toggle("Warning banners", isOn: $notificationInAppWarnings)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    SettingsPanelDivider()

                    SettingsRow(
                        title: "Menu bar item",
                        detail: "Keep Veo in the menu bar for quick access and turn status.",
                        systemImage: "menubar.arrow.up.rectangle"
                    ) {
                        Toggle("Menu bar item", isOn: $notificationMenuBarIcon)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                Label {
                    Text("Alerts stay quiet for the chat you're already watching. macOS decides how they appear — change that in System Settings → Notifications.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .labelStyle(SettingsNoteLabelStyle())
                .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Sound")

                SettingsPanel {
                    SettingsRow(
                        title: "Play a sound",
                        detail: "Sound off a finished turn or a waiting approval.",
                        systemImage: "speaker.wave.2"
                    ) {
                        Toggle("Play a sound", isOn: $notificationCompletionSound)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    if notificationCompletionSound {
                        SettingsRow(
                            title: "Sound",
                            detail: notificationSoundDisplayName,
                            systemImage: "waveform",
                            nestDepth: 1,
                            nestStyle: .leaf
                        ) {
                            HStack(spacing: 8) {
                                Button("Preview") {
                                    notifications.playSound()
                                }
                                Button("Choose…") {
                                    chooseNotificationSound()
                                }
                                if DesktopNotificationPreferences.customSoundPath != nil {
                                    Button("Reset") {
                                        DesktopNotificationPreferences.clearCustomSound()
                                        notificationSoundPath = ""
                                        notificationSoundName = ""
                                        notificationSoundError = nil
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }

                if let notificationSoundError {
                    Label(notificationSoundError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private var notificationTurnAlertDetail: String {
        if notificationSystemAlerts, notifications.authorizationState == .denied {
            return "Enabled in Veo, blocked by macOS."
        }
        return "Notify when Codex finishes a turn or needs a decision."
    }

    private var notificationSoundDisplayName: String {
        if !notificationSoundName.isEmpty { return notificationSoundName }
        if !notificationSoundPath.isEmpty {
            return URL(fileURLWithPath: notificationSoundPath).deletingPathExtension().lastPathComponent
        }
        return "Default sound"
    }

    private func chooseNotificationSound() {
        let panel = NSOpenPanel()
        panel.title = "Choose a notification sound"
        panel.prompt = "Use Sound"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let importedURL = try DesktopNotificationPreferences.importCustomSound(from: url)
            notificationSoundPath = importedURL.path
            notificationSoundName = url.deletingPathExtension().lastPathComponent
            notificationSoundError = nil
            notifications.playSound()
        } catch {
            notificationSoundError = "Veo couldn't save that sound: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var appearanceSettingsBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Theme")

                HStack(spacing: 12) {
                    ForEach(DesktopAppearanceMode.allCases) { mode in
                        AppearanceModePreviewCard(
                            mode: mode,
                            isSelected: appearanceModeBinding.wrappedValue == mode
                        ) {
                            appearanceModeBinding.wrappedValue = mode
                        }
                    }
                }

                SettingsPanel {
                    SettingsRow(
                        title: "Theme material",
                        detail: windowMaterialBinding.wrappedValue.title,
                        systemImage: "macwindow"
                    ) {
                        Picker("Theme material", selection: windowMaterialBinding) {
                            ForEach(DesktopWindowMaterial.allCases) { material in
                                Text(material.title).tag(material)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Accent")

                SettingsPanel {
                    SettingsRow(
                        title: "Accent color",
                        detail: "Used for selection, links, and controls",
                        systemImage: "paintpalette",
                        iconColor: accentColor
                    ) {
                        AccentColorSwatchPicker(color: accentColorBinding)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Sidebar")

                SettingsPanel {
                    SettingsRow(
                        title: "Sidebar material",
                        detail: sidebarMaterialBinding.wrappedValue.title,
                        systemImage: "sidebar.leading"
                    ) {
                        Picker("Sidebar material", selection: sidebarMaterialBinding) {
                            ForEach(DesktopSidebarMaterial.allCases) { material in
                                Text(material.title).tag(material)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                    }
                }

                Label {
                    Text("Liquid Glass follows your macOS Liquid Glass and transparency settings. On older macOS it uses Mica.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .labelStyle(SettingsNoteLabelStyle())
                .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Composer")

                SettingsPanel {
                    SettingsRow(
                        title: "Composer material",
                        detail: composerMaterialBinding.wrappedValue.title,
                        systemImage: "rectangle.and.pencil.and.ellipsis"
                    ) {
                        Picker("Composer material", selection: composerMaterialBinding) {
                            ForEach(DesktopComposerMaterial.allCases) { material in
                                Text(material.title).tag(material)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                    }

                    SettingsPanelDivider()

                    SettingsRow(
                        title: "Show context window usage",
                        detail: "Display live token usage beside Send after a chat starts.",
                        systemImage: "gauge.with.dots.needle.33percent"
                    ) {
                        Toggle("Show context window usage", isOn: $showsContextWindowUsage)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    if showsContextWindowUsage {
                        SettingsRow(
                            title: "Usage style",
                            detail: contextWindowUsageStyleBinding.wrappedValue.title,
                            systemImage: "chart.bar.fill",
                            nestDepth: 1,
                            nestStyle: .leaf
                        ) {
                            Picker("Usage style", selection: contextWindowUsageStyleBinding) {
                                ForEach(DesktopContextWindowUsageStyle.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 210)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Thread minimap")

                SettingsPanel {
                    SettingsRow(
                        title: "Show thread minimap",
                        detail: "Display important topic changes beside longer conversations.",
                        systemImage: "list.bullet.rectangle.portrait"
                    ) {
                        Toggle("Show thread minimap", isOn: $showsThreadMinimap)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    if showsThreadMinimap {
                        SettingsPanelDivider()

                        SettingsRow(
                            title: "Minimap material",
                            detail: threadMinimapMaterialBinding.wrappedValue.title,
                            systemImage: "circle.lefthalf.filled",
                            nestDepth: 1,
                            nestStyle: .leaf
                        ) {
                            Picker("Minimap material", selection: threadMinimapMaterialBinding) {
                                ForEach(DesktopMinimapMaterial.allCases) { material in
                                    Text(material.title).tag(material)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 280)
                        }
                    }
                }
            }
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

    private var updateStatusDetail: String {
        switch updateService.phase {
        case .checking:
            return "Checking for a newer release…"
        case let .downloading(progress):
            return progress >= 1
                ? "Installing Veo \(updateService.availableRelease?.version ?? "")…"
                : "Downloading Veo \(updateService.availableRelease?.version ?? "")…"
        case let .available(release):
            return "Veo \(release.version) is available. You have \(updateService.currentVersion)."
        case let .readyToRelaunch(release):
            return "Veo \(release.version) is installed. Relaunch to start using it."
        case .failed:
            return "Veo \(updateService.currentVersion) — last check failed."
        case .upToDate:
            return lastCheckDetail
        case .idle:
            return "Veo \(updateService.currentVersion)"
        }
    }

    private var lastCheckDetail: String {
        guard let lastCheck = updateService.lastCheck else {
            return "Veo \(updateService.currentVersion) is up to date."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: lastCheck, relativeTo: Date())
        return "Veo \(updateService.currentVersion) is up to date. Checked \(relative)."
    }

    private var updateStatusSymbol: String {
        switch updateService.phase {
        case .checking, .downloading: return "arrow.triangle.2.circlepath"
        case .available: return "arrow.down.circle.fill"
        case .readyToRelaunch: return "arrow.clockwise.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle, .upToDate: return "checkmark.circle.fill"
        }
    }

    private var updateStatusColor: Color {
        switch updateService.phase {
        case .available, .readyToRelaunch: return accentColor
        case .failed: return .orange
        case .checking, .downloading: return .secondary
        case .idle, .upToDate: return .green
        }
    }

    @ViewBuilder
    private var updateActionButton: some View {
        switch updateService.phase {
        case let .available(release):
            HStack(spacing: 8) {
                Button("Skip") { updateService.skipAvailableVersion() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(updateService.canInstallInPlace && release.downloadURL != nil
                    ? "Install"
                    : "Download") {
                    updateService.installUpdate(release)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .readyToRelaunch:
            Button("Relaunch") { updateService.relaunch() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .downloading, .checking:
            ProgressView().controlSize(.small)
        case .failed, .idle, .upToDate:
            Button("Release Notes") { updateService.openReleasePage() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

/// Full-bleed square swatch that presents the system color picker as a popover.
private struct AccentColorSwatchPicker: View {
    @Binding var color: Color

    var body: some View {
        AccentColorWellRepresentable(color: $color)
            .frame(width: 28, height: 28)
            .accessibilityLabel("Accent color")
            .help("Accent color")
    }
}

private struct AccentColorWellRepresentable: NSViewRepresentable {
    @Binding var color: Color

    func makeCoordinator() -> Coordinator {
        Coordinator(color: $color)
    }

    func makeNSView(context: Context) -> SquareAccentColorWell {
        let well = SquareAccentColorWell()
        well.colorWellStyle = .minimal
        well.isBordered = false
        well.color = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        context.coordinator.well = well
        return well
    }

    func updateNSView(_ nsView: SquareAccentColorWell, context: Context) {
        context.coordinator.color = $color
        let next = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        if !nsView.color.isEqual(next) {
            nsView.color = next
        }
    }

    final class Coordinator: NSObject {
        var color: Binding<Color>
        weak var well: SquareAccentColorWell?

        init(color: Binding<Color>) {
            self.color = color
        }

        @objc func colorChanged(_ sender: NSColorWell) {
            let srgb = sender.color.usingColorSpace(.sRGB) ?? sender.color
            color.wrappedValue = Color(nsColor: srgb)
        }
    }
}

private final class SquareAccentColorWell: NSColorWell {
    override var intrinsicContentSize: NSSize {
        NSSize(width: 28, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (color.usingColorSpace(.sRGB) ?? color).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private struct AppearanceModePreviewCard: View {
    @Environment(\.veoAccent) private var veoAccent
    let mode: DesktopAppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                appearancePreview
                    .frame(maxWidth: .infinity)
                    .frame(height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                isSelected ? veoAccent : Color.primary.opacity(0.12),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                    .shadow(color: .black.opacity(isSelected ? 0.12 : 0.04), radius: isSelected ? 8 : 3, y: 2)

                Text(mode.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? veoAccent : .primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var appearancePreview: some View {
        switch mode {
        case .system:
            ZStack {
                AppearanceWindowMock(scheme: .light)
                AppearanceWindowMock(scheme: .dark)
                    .clipShape(AppearanceDiagonalSlash())
                AppearanceDiagonalSlash()
                    .stroke(Color.primary.opacity(0.35), lineWidth: 1)
            }
        case .light:
            AppearanceWindowMock(scheme: .light)
        case .dark:
            AppearanceWindowMock(scheme: .dark)
        }
    }
}

private struct AppearanceWindowMock: View {
    let scheme: ColorScheme

    var body: some View {
        HStack(spacing: 0) {
            DesktopTheme.sidebar(for: scheme)
                .frame(width: 28)
            DesktopTheme.canvas(for: scheme)
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(scheme == .light ? Color.black.opacity(0.12) : Color.white.opacity(0.14))
                            .frame(width: 46, height: 5)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(scheme == .light ? Color.black.opacity(0.08) : Color.white.opacity(0.1))
                            .frame(width: 34, height: 5)
                    }
                    .padding(.top, 14)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 3) {
                Circle().fill(Color.red.opacity(0.75)).frame(width: 5, height: 5)
                Circle().fill(Color.yellow.opacity(0.75)).frame(width: 5, height: 5)
                Circle().fill(Color.green.opacity(0.75)).frame(width: 5, height: 5)
            }
            .padding(7)
        }
    }
}

private struct AppearanceDiagonalSlash: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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

private enum SettingsNestStyle: Equatable {
    case none
    /// ├── mid sibling (spine continues below)
    case branch
    /// └── last sibling (spine stops at the elbow)
    case leaf

    var isNested: Bool { self != .none }
}

/// Single-path tree guide so vertical + elbow stay connected (no floating dashes).
private struct SettingsNestGuide: View {
    let style: SettingsNestStyle

    private let railColor = Color.primary.opacity(0.28)
    private let guideWidth: CGFloat = 14
    private let railX: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            guard style.isNested else { return }
            let midY = size.height * 0.5
            var path = Path()
            path.move(to: CGPoint(x: railX, y: 0))
            switch style {
            case .branch:
                path.addLine(to: CGPoint(x: railX, y: size.height))
            case .leaf:
                path.addLine(to: CGPoint(x: railX, y: midY))
            case .none:
                break
            }
            path.move(to: CGPoint(x: railX, y: midY))
            path.addLine(to: CGPoint(x: guideWidth, y: midY))
            context.stroke(
                path,
                with: .color(railColor),
                style: StrokeStyle(lineWidth: 1, lineCap: .square, lineJoin: .miter)
            )
        }
        .frame(width: guideWidth)
        .frame(maxHeight: .infinity)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String
    var systemImage: String? = nil
    var assetImage: String? = nil
    var iconColor: Color = .secondary
    var detailFontDesign: Font.Design = .default
    var nestDepth: Int = 0
    var nestStyle: SettingsNestStyle = .none
    @ViewBuilder let trailing: () -> Trailing

    private var nestIndent: CGFloat {
        guard nestDepth > 0 else { return 0 }
        // Align under the parent icon; each extra level steps in one guide width.
        return 20 + CGFloat(nestDepth - 1) * 18
    }

    var body: some View {
        HStack(spacing: nestStyle.isNested ? 8 : 14) {
            if nestStyle.isNested {
                SettingsNestGuide(style: nestStyle)
            }

            settingsRowIcon
                .frame(width: 22, height: 22)

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
        .padding(.leading, nestStyle.isNested ? nestIndent : 16)
        .padding(.trailing, 16)
        .frame(minHeight: 68)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var settingsRowIcon: some View {
        if let assetImage {
            Image(assetImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(iconColor)
        }
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
