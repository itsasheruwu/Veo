// FILE: DesktopTurnStatusView.swift
// Purpose: Summarizes the active turn's todo progress and live file diffs above the composer.
// Layer: Desktop app view

import SwiftUI

struct DesktopTurnStatusView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.veoAccent) private var veoAccent
    @ObservedObject var store: DesktopCodexStore
    var onOpenSubagent: (String) -> Void = { _ in }
    @AppStorage(DesktopAppearancePreferences.composerMaterialKey) private var composerMaterialRaw =
        DesktopComposerMaterial.liquidGlass.rawValue
    @AppStorage(DesktopComposerPreferences.showsTurnStatusKey) private var showsTurnStatus = true
    @State private var showsPlan = false
    @State private var showsChanges = false
    @State private var showsAutoWorkflow = false
    @State private var showsSubagents = false

    private var material: DesktopComposerMaterial {
        DesktopComposerMaterial(rawValue: composerMaterialRaw) ?? .liquidGlass
    }

    private var plan: DesktopTurnPlan? {
        guard let plan = store.selectedTurnPlan, !plan.steps.isEmpty else { return nil }
        return plan
    }

    private var changes: DesktopTurnDiffSummary? {
        guard let diff = store.selectedTurnDiff, !diff.isEmpty else { return nil }
        let summary = DesktopTurnDiffSummary(diff: diff)
        return summary.files.isEmpty ? nil : summary
    }

    private var autoWorkflow: DesktopAutoWorkflowState? {
        store.selectedAutoWorkflowState
    }

    private var subagents: [DesktopSubagentSummary] {
        store.selectedSubagents
    }

    var body: some View {
        if showsTurnStatus, plan != nil || changes != nil || autoWorkflow != nil || !subagents.isEmpty {
            HStack(spacing: 8) {
                if store.isBusyTurn {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(veoAccent)
                        .accessibilityLabel("Turn in progress")
                }

                if let autoWorkflow {
                    Button {
                        showsAutoWorkflow.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("Auto · \(autoWorkflow.stageTitle)")
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(
                        isPresented: $showsAutoWorkflow,
                        attachmentAnchor: .point(.top),
                        arrowEdge: .bottom
                    ) {
                        DesktopAutoWorkflowPopover(
                            state: autoWorkflow,
                            material: material,
                            onOpenThread: store.selectRuntimeThread
                        )
                    }
                    .help("Show GPT-5.6 Auto workflow")
                    .accessibilityLabel("GPT-5.6 Auto, \(autoWorkflow.stageTitle). Show workflow details")
                }

                if autoWorkflow != nil, (!subagents.isEmpty || plan != nil || changes != nil) {
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }

                if !subagents.isEmpty {
                    Button {
                        showsSubagents.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person.2.wave.2")
                                .font(.system(size: 9.5, weight: .semibold))
                            let activeCount = subagents.filter(\.isActive).count
                            Text(activeCount > 0 ? "\(activeCount) working" : "\(subagents.count) agents")
                                .contentTransition(.numericText())
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(
                        isPresented: $showsSubagents,
                        attachmentAnchor: .point(.top),
                        arrowEdge: .bottom
                    ) {
                        DesktopTurnSubagentsPopover(
                            agents: subagents,
                            material: material,
                            onSelect: onOpenSubagent
                        )
                    }
                    .help("Show subagents")
                    .accessibilityLabel("\(subagents.count) subagents. Show details")
                }

                if !subagents.isEmpty, (plan != nil || changes != nil) {
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }

                if let plan {
                    Button {
                        showsPlan.toggle()
                    } label: {
                        Text("Step \(plan.currentStepNumber) / \(plan.steps.count)")
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(.plain)
                    .popover(
                        isPresented: $showsPlan,
                        attachmentAnchor: .point(.top),
                        arrowEdge: .bottom
                    ) {
                        DesktopTurnPlanPopover(plan: plan, material: material)
                    }
                    .help("Show to-dos")
                    .accessibilityLabel("Step \(plan.currentStepNumber) of \(plan.steps.count). Show to-dos")
                }

                if plan != nil, changes != nil {
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }

                if let changes {
                    Button {
                        showsChanges.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(changes.files.count) \(changes.files.count == 1 ? "file" : "files") changed")
                            animatedCount(changes.additions, prefix: "+", color: .green)
                            animatedCount(changes.deletions, prefix: "−", color: .red)
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(
                        isPresented: $showsChanges,
                        attachmentAnchor: .point(.top),
                        arrowEdge: .bottom
                    ) {
                        DesktopTurnChangesPopover(summary: changes, material: material)
                    }
                    .help("Show changed files and diffs")
                    .accessibilityLabel("\(changes.files.count) files changed, \(changes.additions) additions, \(changes.deletions) deletions")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .fixedSize(horizontal: true, vertical: false)
            .modifier(DesktopFloatingMaterialSurface(material: material))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: plan?.currentStepNumber)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .frame(maxWidth: DesktopTheme.conversationWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func animatedCount(_ value: Int, prefix: String, color: Color) -> some View {
        Text("\(prefix)\(value)")
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText(value: Double(value)))
            .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: value)
    }
}

private struct DesktopAutoWorkflowPopover: View {
    let state: DesktopAutoWorkflowState
    let material: DesktopComposerMaterial
    let onOpenThread: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("GPT-5.6 Auto")
                    .font(.system(size: 13, weight: .semibold))
                Text("Live stages from Codex collaboration events")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)

            Divider()

            ForEach(state.steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    stepIcon(step.status)
                        .frame(width: 16, height: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.system(size: 11.5, weight: .medium))
                        Text(step.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)

                        if !step.receiverThreadIDs.isEmpty {
                            HStack(spacing: 7) {
                                ForEach(step.receiverThreadIDs, id: \.self) { threadID in
                                    Button("Open agent") { onOpenThread(threadID) }
                                        .buttonStyle(.link)
                                        .font(.system(size: 10.5))
                                        .accessibilityLabel("Open \(step.title.lowercased()) agent thread")
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
            }

            if !state.warnings.isEmpty || state.verdict != nil {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(state.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let verdict = state.verdict {
                        Label("Reviewer verdict: \(verdict)", systemImage: verdict == "ship" ? "checkmark.seal" : "exclamationmark.bubble")
                            .foregroundStyle(verdict == "ship" ? Color.green : Color.primary)
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .padding(13)
            }
        }
        .frame(width: 390)
        .modifier(DesktopFloatingMaterialSurface(material: material))
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("GPT-5.6 Auto workflow details")
    }

    @ViewBuilder
    private func stepIcon(_ status: DesktopAutoWorkflowState.StepStatus) -> some View {
        switch status {
        case .active:
            ProgressView().controlSize(.mini)
        case .complete:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .unavailable:
            Image(systemName: "minus.circle").foregroundStyle(.orange)
        }
    }
}

private struct DesktopTurnPlanPopover: View {
    let plan: DesktopTurnPlan
    let material: DesktopComposerMaterial

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 10) {
                    if step.isInProgress {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 16, height: 18)
                    } else {
                        Image(systemName: step.isCompleted ? "checkmark.circle" : "circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 18)
                    }
                    Text(step.text)
                        .font(.system(size: 11.5, weight: step.isInProgress ? .medium : .regular))
                        .foregroundStyle(step.isCompleted ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
            }
        }
        .padding(.vertical, 5)
        .frame(width: 430)
        .modifier(DesktopFloatingMaterialSurface(material: material))
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turn to-dos")
    }

}

private struct DesktopTurnChangesPopover: View {
    let summary: DesktopTurnDiffSummary
    let material: DesktopComposerMaterial
    @State private var selectedPath: String?

    private var selectedFile: DesktopTurnDiffSummary.FileSummary? {
        summary.files.first(where: { $0.path == selectedPath })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(summary.files) { file in
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) {
                                selectedPath = selectedPath == file.path ? nil : file.path
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 15)
                                Text(file.displayName)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 12)
                                Text("+\(file.additions)")
                                    .foregroundStyle(.green)
                                Text("−\(file.deletions)")
                                    .foregroundStyle(.red)
                                Image(systemName: selectedPath == file.path ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .monospacedDigit()
                            .contentShape(Rectangle())
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .help(file.path)
                    }
                }
            }
            .frame(maxHeight: 260)

            if let file = selectedFile {
                Divider()
                DesktopCompactPatchView(file: file)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: 500)
        .modifier(DesktopFloatingMaterialSurface(material: material))
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files and diffs")
    }
}

private struct DesktopCompactPatchView: View {
    let file: DesktopTurnDiffSummary.FileSummary

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, rawLine in
                    let line = String(rawLine)
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(foreground(for: line))
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
                        .background(background(for: line))
                }
            }
            .textSelection(.enabled)
        }
        .frame(height: 230)
        .accessibilityLabel("Diff for \(file.path)")
    }

    private func foreground(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .secondary }
        return .primary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green.opacity(0.08) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red.opacity(0.08) }
        return .clear
    }
}

private struct DesktopTurnDiffSummary {
    struct FileSummary: Identifiable {
        let path: String
        let patch: String
        let additions: Int
        let deletions: Int

        var id: String { path }
        var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    let files: [FileSummary]
    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    init(diff: DesktopTurnDiff) {
        if !diff.files.isEmpty {
            files = diff.files.map { Self.makeFile(path: $0.path, patch: $0.diff) }
        } else {
            files = Self.parseUnifiedDiff(diff.unifiedDiff)
        }
    }

    private static func makeFile(path: String, patch: String) -> FileSummary {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        let additions = lines.count { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
        let deletions = lines.count { $0.hasPrefix("-") && !$0.hasPrefix("---") }
        return FileSummary(path: path, patch: patch, additions: additions, deletions: deletions)
    }

    private static func parseUnifiedDiff(_ diff: String) -> [FileSummary] {
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var result: [FileSummary] = []
        var path: String?
        var lines: [String] = []

        func appendCurrent() {
            guard let currentPath = path, !lines.isEmpty else { return }
            result.append(makeFile(path: currentPath, patch: lines.joined(separator: "\n")))
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                appendCurrent()
                lines = [line]
                let tokens = line.split(separator: " ")
                path = tokens.last.map(String.init).map { $0.hasPrefix("b/") ? String($0.dropFirst(2)) : $0 }
            } else {
                lines.append(line)
                if path == nil, line.hasPrefix("+++ ") {
                    let candidate = String(line.dropFirst(4))
                    path = candidate.hasPrefix("b/") ? String(candidate.dropFirst(2)) : candidate
                }
            }
        }
        appendCurrent()
        return result.isEmpty ? [makeFile(path: "Changes", patch: diff)] : result
    }
}
