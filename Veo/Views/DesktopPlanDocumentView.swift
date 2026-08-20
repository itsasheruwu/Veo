// FILE: DesktopPlanDocumentView.swift
// Purpose: Presents proposed plans as persistent, editable task documents.
// Layer: Desktop app view

import SwiftUI

struct DesktopPlanDocumentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.veoAccent) private var veoAccent
    @ObservedObject var store: DesktopCodexStore

    let reference: DesktopPlanReference
    let fallbackMarkdown: String
    var isStreaming = false
    var showsSidebarAction = true
    var onOpenSidebar: (DesktopPlanReference) -> Void = { _ in }

    @State private var isCollapsed = false

    private var artifact: DesktopPlanArtifact? { store.planArtifact(for: reference) }
    private var markdown: String { store.planMarkdown(for: reference, fallback: fallbackMarkdown) }
    private var editingDraft: String? { store.planEditingDraft(for: reference) }
    private var isLatest: Bool { store.isLatestPlan(reference) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !isCollapsed {
                Divider().opacity(0.55)

                Group {
                    if let editingDraft {
                        editor(markdown: editingDraft)
                    } else {
                        MarkdownMessageView(
                            source: markdown,
                            workspaceURL: store.effectiveWorkspaceURL,
                            isStreaming: isStreaming
                        )
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 15)
                    }
                }
                .transition(.opacity)

                if let error = store.planErrorsByID[reference.storageID], !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }

                if !isStreaming, editingDraft == nil {
                    Divider().opacity(0.55)
                    footer
                }
            }
        }
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isLatest ? veoAccent.opacity(0.78) : Color.primary.opacity(0.14))
                .frame(width: 3)
                .padding(.vertical, 12)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isCollapsed)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: editingDraft != nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed plan")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isLatest ? veoAccent : .secondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(planTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(statusTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: 8)

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isCollapsed.toggle()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand plan" : "Collapse plan")
            .accessibilityLabel(isCollapsed ? "Expand plan" : "Collapse plan")
        }
        .padding(.leading, 15)
        .padding(.trailing, 10)
        .padding(.vertical, 11)
    }

    private func editor(markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: Binding(
                get: { store.planEditingDraft(for: reference) ?? markdown },
                set: { store.updatePlanEditingDraft($0, reference: reference) }
            ))
            .font(.system(size: 13.5, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 220)
            .accessibilityLabel("Plan Markdown")

            HStack(spacing: 8) {
                Button("Cancel") { store.cancelPlanEditing(reference) }
                    .keyboardShortcut(.escape, modifiers: [])
                if artifact?.isEdited == true {
                    Button("Revert") { store.revertPlanEditing(reference) }
                }
                Spacer()
                Button("Save") { store.savePlanEditing(reference) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                store.beginPlanEditing(reference)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(DesktopPlanSecondaryActionStyle())
            .help("Edit plan Markdown")
            .disabled(artifact?.lifecycle != .ready)

            Menu {
                if showsSidebarAction {
                    Button {
                        onOpenSidebar(reference)
                    } label: {
                        Label("Open in Sidebar", systemImage: "sidebar.right")
                    }
                    Divider()
                }

                Button {
                    store.copyPlan(reference)
                } label: {
                    Label("Copy Markdown", systemImage: "doc.on.doc")
                }

                Button {
                    store.exportPlan(reference)
                } label: {
                    Label("Export Markdown…", systemImage: "square.and.arrow.up")
                }

                if artifact?.isEdited == true {
                    Divider()
                    Button {
                        store.revertPlanEditing(reference)
                    } label: {
                        Label("Revert to Codex Plan", systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .foregroundStyle(.secondary)
            .help("More plan actions")
            .accessibilityLabel("More plan actions")

            Spacer(minLength: 8)

            DesktopPlanImplementControl(
                isImplementing: artifact?.lifecycle == .implementing,
                isEnabled: canImplement,
                help: implementHelp,
                implement: { store.implementPlan(reference) },
                implementInNewTask: { store.implementPlan(reference, inNewTask: true) }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var canImplement: Bool {
        isLatest && store.canImplementSelectedPlan
    }

    private var implementHelp: String {
        guard isLatest else { return "A newer plan is ready" }
        if !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.attachments.isEmpty {
            return "Send or clear feedback and attachments first"
        }
        return canImplement ? "Implement this plan in the current task" : "Plan is not ready to implement"
    }

    private var planTitle: String {
        for line in markdown.split(separator: "\n") {
            let title = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            if !title.isEmpty { return title }
        }
        return "Proposed Plan"
    }

    private var statusTitle: String {
        if isStreaming { return "Drafting plan…" }
        guard let artifact else { return "Ready" }
        switch artifact.lifecycle {
        case .ready: return artifact.isEdited ? "Edited" : (isLatest ? "Ready" : "Superseded")
        case .superseded: return "Superseded"
        case .implementing: return "Implementing"
        case .implemented: return "Implemented"
        }
    }

    private var statusColor: Color {
        if artifact?.lifecycle == .implementing { return veoAccent }
        return .secondary
    }
}

private struct DesktopPlanSecondaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.45))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.09 : 0.045),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct DesktopPlanImplementControl: View {
    @Environment(\.veoAccent) private var veoAccent

    let isImplementing: Bool
    let isEnabled: Bool
    let help: String
    var usesCommandReturn = false
    let implement: () -> Void
    let implementInNewTask: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            primaryButton

            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(width: 1, height: 14)
                .allowsHitTesting(false)

            Menu {
                Button("Implement in New Task", action: implementInNewTask)
                    .disabled(!isEnabled)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 25, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!isEnabled || isImplementing)
            .accessibilityLabel("Implementation options")
        }
        .foregroundStyle(isEnabled || isImplementing ? veoAccent : Color.secondary.opacity(0.52))
        .background(
            Color.primary.opacity(isHovered && isEnabled ? 0.085 : 0.05),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isEnabled ? veoAccent.opacity(isHovered ? 0.34 : 0.2) : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .help(help)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if usesCommandReturn {
            primaryButtonBody
                .keyboardShortcut(.return, modifiers: .command)
        } else {
            primaryButtonBody
        }
    }

    private var primaryButtonBody: some View {
        Button(action: implement) {
            HStack(spacing: 5) {
                if isImplementing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "hammer")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text(isImplementing ? "Implementing…" : "Implement")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isImplementing)
        .accessibilityLabel(isImplementing ? "Implementing plan" : "Implement plan")
    }
}

struct DesktopPlanPanelView: View {
    @ObservedObject var store: DesktopCodexStore
    let reference: DesktopPlanReference

    var body: some View {
        ScrollView {
            DesktopPlanDocumentView(
                store: store,
                reference: reference,
                fallbackMarkdown: store.planArtifact(for: reference)?.originalMarkdown ?? "",
                showsSidebarAction: false
            )
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Plan")
    }
}
