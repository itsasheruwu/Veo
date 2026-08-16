// FILE: DesktopSubagentsPanelView.swift
// Purpose: Shows thread-scoped subagent status, transcripts, and reusable agent pills.
// Layer: Desktop app view

import SwiftUI

struct DesktopSubagentsPanelView: View {
    @ObservedObject var store: DesktopCodexStore
    @ObservedObject var model: DesktopUtilityPanelModel

    private var agents: [DesktopSubagentSummary] { store.selectedSubagents }

    var body: some View {
        Group {
            if let selectedID = model.selectedSubagentID,
               let agent = agents.first(where: { $0.id == selectedID }) {
                DesktopSubagentDetailView(agent: agent, store: store) {
                    model.selectedSubagentID = nil
                }
            } else {
                agentList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: agents.map(\.id)) { _, ids in
            if let selectedID = model.selectedSubagentID, !ids.contains(selectedID) {
                model.selectedSubagentID = nil
            }
        }
    }

    private var agentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                agentSection(title: "Active", agents: agents.filter(\.isActive), showsEmptyState: true)
                agentSection(title: "Done", agents: agents.filter { !$0.isActive }, showsEmptyState: false)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
    }

    @ViewBuilder
    private func agentSection(
        title: String,
        agents: [DesktopSubagentSummary],
        showsEmptyState: Bool
    ) -> some View {
        if !agents.isEmpty || showsEmptyState {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(title) · \(agents.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                if agents.isEmpty {
                    Text("No active subagents")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(agents) { agent in
                        DesktopSubagentListRow(agent: agent) {
                            model.selectedSubagentID = agent.id
                        }
                    }
                }
            }
        }
    }
}

private struct DesktopSubagentListRow: View {
    let agent: DesktopSubagentSummary
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                DesktopSubagentAvatar(id: agent.id, isActive: agent.isActive)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(agent.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(agent.state.displayStatus)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(agent.isActive ? .secondary : .tertiary)
                    }

                    Text(agent.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.055 : 0.001))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(agent.title), \(agent.state.displayStatus), \(agent.detail)")
    }
}

private struct DesktopSubagentDetailView: View {
    let agent: DesktopSubagentSummary
    @ObservedObject var store: DesktopCodexStore
    let back: () -> Void

    @State private var timeline: [DesktopTimelineItem] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private var loadKey: String {
        [agent.id, agent.state.status, agent.state.message ?? ""].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to subagents")

                DesktopSubagentAvatar(id: agent.id, isActive: agent.isActive, size: 23)
                Text(agent.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Open Chat") { store.selectRuntimeThread(agent.id) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color.primary.opacity(0.018))

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 7) {
                        if agent.isActive {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: agent.state.status == "errored" ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(agent.state.status == "errored" ? .red : .green)
                        }
                        Text(agent.state.displayStatus)
                            .font(.system(size: 11.5, weight: .medium))
                        if let message = nonempty(agent.state.message) {
                            Text(message)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if let prompt = nonempty(agent.prompt) {
                        Text(prompt)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if isLoading, timeline.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading agent activity")
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    } else if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                    } else {
                        ForEach(timeline) { item in
                            DesktopSubagentTranscriptRow(item: item, workspaceURL: store.effectiveWorkspaceURL)
                        }
                    }
                }
                .padding(16)
            }
        }
        .task(id: loadKey) { await loadTimeline() }
    }

    @MainActor
    private func loadTimeline() async {
        isLoading = true
        loadError = nil
        do {
            timeline = try await store.loadSubagentTimeline(runtimeThreadID: agent.id)
        } catch {
            loadError = "Agent activity is not available yet."
        }
        isLoading = false
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct DesktopSubagentTranscriptRow: View {
    let item: DesktopTimelineItem
    let workspaceURL: URL?

    var body: some View {
        switch item.kind {
        case .user:
            Text(item.body)
                .font(.system(size: 12.5))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .assistant:
            MarkdownMessageView(
                source: item.body,
                artifacts: item.artifacts,
                citations: item.citations,
                workspaceURL: workspaceURL
            )
        case .reasoning:
            Label(reasoningPreview, systemImage: "brain")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        case .error:
            Label(item.body, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(.red)
        case .command, .fileChange, .plan, .activity:
            Label(item.title, systemImage: transcriptSymbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var transcriptSymbol: String {
        switch item.kind {
        case .command: return "terminal"
        case .fileChange: return "doc.badge.gearshape"
        case .plan: return "list.bullet.clipboard"
        default: return "gearshape.2"
        }
    }

    private var reasoningPreview: String {
        let firstLine = item.body
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? "Thinking"
        guard firstLine.count > 100 else { return firstLine }
        return String(firstLine.prefix(99)) + "…"
    }
}

struct DesktopSubagentPillStrip: View {
    let agents: [DesktopSubagentSummary]
    var showsEventLabel = true
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(agents) { agent in
                    Button { onSelect(agent.id) } label: {
                        HStack(spacing: 6) {
                            DesktopSubagentAvatar(id: agent.id, isActive: agent.isActive, size: 14)
                            Text(agent.title)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(agent.isActive ? .primary : .secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .background(Color.primary.opacity(agent.isActive ? 0.075 : 0.035), in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.075), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Open \(agent.title) in Subagents")
                }

                if showsEventLabel {
                    Text(eventLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 1)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    private var eventLabel: String {
        agents.contains(where: \.isActive) ? "started working" : "finished"
    }
}

struct DesktopTurnSubagentsPopover: View {
    let agents: [DesktopSubagentSummary]
    let material: DesktopComposerMaterial
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Subagents")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(agents.filter(\.isActive).count) active · \(agents.filter { !$0.isActive }.count) done")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)

            Divider()

            ForEach(agents) { agent in
                Button { onSelect(agent.id) } label: {
                    HStack(alignment: .top, spacing: 9) {
                        DesktopSubagentAvatar(id: agent.id, isActive: agent.isActive, size: 17)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.title)
                                .font(.system(size: 11.5, weight: .medium))
                            Text(agent.detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Text(agent.state.displayStatus)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 390)
        .modifier(DesktopFloatingMaterialSurface(material: material))
        .padding(8)
    }
}

struct DesktopSubagentAvatar: View {
    let id: String
    let isActive: Bool
    var size: CGFloat = 20

    private let symbols = ["atom", "sparkles", "circle.hexagongrid.fill", "aqi.medium", "camera.filters"]
    private let colors: [Color] = [.purple, .pink, .mint, .green, .orange, .cyan]

    private var seed: Int {
        id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
    }

    var body: some View {
        Image(systemName: symbols[seed % symbols.count])
            .font(.system(size: size * 0.63, weight: .semibold))
            .foregroundStyle(colors[seed % colors.count])
            .frame(width: size, height: size)
            .background(colors[seed % colors.count].opacity(isActive ? 0.16 : 0.09), in: Circle())
            .overlay {
                if isActive {
                    Circle().stroke(colors[seed % colors.count].opacity(0.35), lineWidth: 0.7)
                }
            }
            .accessibilityHidden(true)
    }
}
