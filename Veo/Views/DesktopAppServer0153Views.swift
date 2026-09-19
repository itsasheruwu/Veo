// FILE: DesktopAppServer0153Views.swift
// Purpose: Native controls for optional app-server 0.153 capabilities.
// Layer: Desktop app view

import Foundation
import SwiftUI

struct DesktopBackgroundAgentTerminalsButton: View {
    @Bindable var store: DesktopCodexStore
    @Bindable private var coordinator: DesktopAppServer0153Coordinator
    @State private var presented = false
    @State private var confirmsClean = false

    init(store: DesktopCodexStore) {
        self.store = store
        self.coordinator = store.appServer0153
    }

    var body: some View {
        Button {
            presented.toggle()
            if presented { store.refreshBackgroundAgentTerminals() }
        } label: {
            Label("Background", systemImage: "terminal.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(store.selectedRuntimeThreadID == nil || !store.capabilities.supports(.backgroundTerminals))
        .help("Background agent terminals for this chat")
        .accessibilityLabel("Background agent terminals")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Background agent terminals", systemImage: "terminal.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { store.refreshBackgroundAgentTerminals() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                    if !coordinator.backgroundTerminals.isEmpty {
                        Button("Clean All", role: .destructive) { confirmsClean = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(14)
                Divider()
                Group {
                    switch coordinator.backgroundTerminalState {
                    case .idle, .loading:
                        ProgressView("Loading terminals…").controlSize(.small)
                    case .failed(let message):
                        ContentUnavailableView("Couldn’t load terminals", systemImage: "exclamationmark.triangle", description: Text(message))
                    case .loaded where coordinator.backgroundTerminals.isEmpty:
                        ContentUnavailableView("No background terminals", systemImage: "terminal", description: Text("This Codex thread has no background processes."))
                    case .loaded:
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(coordinator.backgroundTerminals) { terminal in
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(terminal.command).font(.system(size: 11.5, design: .monospaced)).lineLimit(3)
                                            Text(terminal.cwd).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                            HStack(spacing: 8) {
                                                if let pid = terminal.osPID { Text("PID \(pid)") }
                                                if let cpu = terminal.cpuPercent { Text(String(format: "%.1f%% CPU", cpu)) }
                                                if let rss = terminal.rssKB { Text(ByteCountFormatter.string(fromByteCount: rss * 1024, countStyle: .memory)) }
                                            }
                                            .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Button("Terminate", role: .destructive) { store.terminateBackgroundAgentTerminal(terminal.processID) }
                                            .buttonStyle(.bordered).controlSize(.small)
                                    }
                                    .padding(12)
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(coordinator.backgroundTerminals.isEmpty ? 20 : 0)
            }
            .frame(width: 430, height: 330)
            .confirmationDialog("Clean all background terminals?", isPresented: $confirmsClean) {
                Button("Terminate and clean all", role: .destructive) { store.cleanBackgroundAgentTerminals() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This only affects background processes owned by the selected Codex thread. Your native terminal tabs stay open.") }
        }
    }
}

struct DesktopThreadCapabilityBar: View {
    @Bindable private var coordinator: DesktopAppServer0153Coordinator

    init(store: DesktopCodexStore) {
        self.coordinator = store.appServer0153
    }

    var body: some View {
        if let status = coordinator.liveSettingsState.label {
            HStack(spacing: 10) {
                Label(status, systemImage: liveSettingsIcon)
                    .foregroundStyle(liveSettingsColor)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var liveSettingsIcon: String {
        switch coordinator.liveSettingsState {
        case .applying: return "arrow.triangle.2.circlepath"
        case .applied: return "checkmark.circle"
        case .nextTurnOnly: return "arrow.forward.circle"
        case .failed: return "exclamationmark.triangle"
        case .idle: return "circle"
        }
    }

    private var liveSettingsColor: Color {
        switch coordinator.liveSettingsState {
        case .failed: return .red
        case .nextTurnOnly: return .orange
        default: return .secondary
        }
    }
}

struct DesktopApprovalReviewPanel: View {
    @Bindable var store: DesktopCodexStore
    @Bindable private var coordinator: DesktopAppServer0153Coordinator
    @State private var approvalTarget: DesktopApprovalReview?

    init(store: DesktopCodexStore) {
        self.store = store
        self.coordinator = store.appServer0153
    }

    var body: some View {
        if !store.selectedApprovalReviews.isEmpty {
            DisclosureGroup("Approval reviews (\(store.selectedApprovalReviews.count))") {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(store.selectedApprovalReviews) { review in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: review.phase == .reviewing ? "hourglass" : review.status.lowercased().contains("den") ? "hand.raised.fill" : "checkmark.shield")
                                .foregroundStyle(review.canApproveDeniedAction ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(review.status).font(.system(size: 11.5, weight: .semibold))
                                Text(review.actionSummary).font(.system(size: 11, design: .monospaced)).lineLimit(3)
                                if let risk = review.riskLevel { Text("Risk: \(risk)").font(.caption).foregroundStyle(.secondary) }
                                if let rationale = review.rationale { Text(rationale).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                                if review.status.lowercased().contains("den"), !review.canApproveDeniedAction {
                                    Text("This runtime does not provide a verified retry assessment. Retry through the original approval request.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if review.canApproveDeniedAction {
                                Button("Review & retry…") { approvalTarget = review }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(10)
            .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .confirmationDialog("Approve this denied action and retry it?", isPresented: Binding(
                get: { approvalTarget != nil }, set: { if !$0 { approvalTarget = nil } }
            ), titleVisibility: .visible) {
                Button("Approve this exact action", role: .destructive) {
                    if let approvalTarget { store.approveGuardianDeniedAction(approvalTarget) }
                    approvalTarget = nil
                }
                Button("Cancel", role: .cancel) { approvalTarget = nil }
            } message: {
                Text("This retries the reviewed action with your approval. Review its requested permissions before continuing.\n\n\(approvalTarget?.actionSummary ?? "")")
            }
        }
    }
}

struct DesktopIntegrationSetupView: View {
    @Bindable var store: DesktopCodexStore
    @Bindable private var coordinator: DesktopAppServer0153Coordinator
    @State private var search = ""
    @State private var marketplaceSource = ""
    @State private var selectedImportIDs = Set<String>()
    @State private var confirmsImport = false
    @State private var marketplaceToRemove: DesktopMarketplaceRecord?
    @State private var mutationInFlight = false

    init(store: DesktopCodexStore) {
        self.store = store
        self.coordinator = store.appServer0153
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Setup & migration").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Refresh") { Task { await coordinator.refreshIntegrationSetup(cwd: store.effectiveWorkspaceURL.path) } }
                    .buttonStyle(.bordered).controlSize(.small)
            }

            GroupBox("Marketplaces") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Git URL or local source", text: $marketplaceSource)
                        Button("Add…") { addMarketplace() }
                            .disabled(marketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(coordinator.marketplaces) { market in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(market.description ?? market.name).font(.system(size: 11.5, weight: .medium))
                                Text("\(market.pluginCount) plugins · \(market.path ?? "remote catalog")").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Upgrade") { Task { do { try await coordinator.upgradeMarketplace(name: market.name) } catch { coordinator.reportIntegrationError(error) } } }
                            Button("Remove…", role: .destructive) { marketplaceToRemove = market }
                        }.controlSize(.small)
                    }
                    if coordinator.marketplaces.isEmpty { Text("No marketplaces reported.").foregroundStyle(.secondary) }
                }.padding(6)
            }

            GroupBox("Plugin search") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Search workspace plugins", text: $search)
                            .onSubmit { Task { await coordinator.searchPlugins(search, cwd: store.effectiveWorkspaceURL.path) } }
                        Button("Search") { Task { await coordinator.searchPlugins(search, cwd: store.effectiveWorkspaceURL.path) } }
                    }
                    ForEach(coordinator.pluginSearchResults) { plugin in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.name).font(.system(size: 11.5, weight: .medium))
                            Text([plugin.description, plugin.marketplaceName].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }.padding(6)
            }

            GroupBox("Import from another agent") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Detection is limited to the selected project.").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Detect") { Task { await coordinator.detectExternalAgentConfiguration(cwd: store.effectiveWorkspaceURL.path) } }
                    }
                    ForEach(coordinator.externalImportItems) { item in
                        Toggle(isOn: Binding(
                            get: { selectedImportIDs.contains(item.id) },
                            set: { if $0 { selectedImportIDs.insert(item.id) } else { selectedImportIDs.remove(item.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.itemType.replacingOccurrences(of: "_", with: " ").capitalized).font(.system(size: 11.5, weight: .medium))
                                Text(item.description).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                DisclosureGroup("Preview") { Text(item.preview).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                            }
                        }
                    }
                    Button("Import selected…") { confirmsImport = true }
                        .buttonStyle(.borderedProminent).disabled(selectedImportIDs.isEmpty)
                    if let progress = coordinator.externalImportProgress { Text(progress.summary).font(.system(size: 10.5)).foregroundStyle(progress.isComplete ? .secondary : .primary) }
                }.padding(6)
            }

            if case .loading = coordinator.integrationState { ProgressView().controlSize(.small) }
            if case .failed(let message) = coordinator.integrationState { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            if let message = coordinator.integrationMessage { Text(message).font(.system(size: 10.5)).foregroundStyle(.secondary) }
        }
        .disabled(mutationInFlight || coordinator.isIntegrationMutating)
        .task(id: store.effectiveWorkspaceURL.path) {
            selectedImportIDs = []
            confirmsImport = false
            await coordinator.refreshIntegrationSetup(cwd: store.effectiveWorkspaceURL.path)
        }
        .confirmationDialog("Import selected artifacts?", isPresented: $confirmsImport, titleVisibility: .visible) {
            Button("Import \(selectedImportIDs.count) selected artifact(s)") {
                let ids = selectedImportIDs
                mutationInFlight = true
                Task {
                    defer { mutationInFlight = false }
                    do { try await coordinator.importExternalAgentConfiguration(ids: ids) }
                    catch { coordinator.reportIntegrationError(error) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Only the selected previews will be sent to the local Codex importer for this project.") }
        .confirmationDialog("Remove marketplace?", isPresented: Binding(
            get: { marketplaceToRemove != nil }, set: { if !$0 { marketplaceToRemove = nil } }
        ), titleVisibility: .visible) {
            Button("Remove \(marketplaceToRemove?.name ?? "marketplace")", role: .destructive) {
                if let target = marketplaceToRemove { Task { do { try await coordinator.removeMarketplace(name: target.name) } catch { coordinator.reportIntegrationError(error) } } }
                marketplaceToRemove = nil
            }
            Button("Cancel", role: .cancel) { marketplaceToRemove = nil }
        } message: { Text("This removes the selected marketplace from the local Codex installation. Installed plugins are shown separately.") }
    }

    private func addMarketplace() {
        let source = marketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        Task {
            do { try await coordinator.addMarketplace(source: source); marketplaceSource = ""; await coordinator.refreshIntegrationSetup(cwd: store.effectiveWorkspaceURL.path) }
            catch { coordinator.reportIntegrationError(error) }
        }
    }
}
