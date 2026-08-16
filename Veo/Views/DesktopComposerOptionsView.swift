// FILE: DesktopComposerOptionsView.swift
// Purpose: Presents composer modes and their active status pills.
// Layer: Desktop app view

import SwiftUI

struct DesktopComposerOptionsView: View {
    @ObservedObject var store: DesktopCodexStore
    let openProject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.hasExplicitWorkspace {
                Button(action: openProject) {
                    optionLabel(
                        title: "Open Project…",
                        detail: "Choose a local folder for this chat.",
                        systemImage: "folder.badge.plus",
                        color: .accentColor
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open project")

                Divider()
            }

            if store.hasExplicitWorkspace {
                Button {
                    store.chooseMediaAttachments()
                } label: {
                    optionLabel(
                        title: "Attach Image or Audio…",
                        detail: "Add local media to this message.",
                        systemImage: "paperclip",
                        color: .blue
                    )
                }
                .buttonStyle(.plain)

                Button {
                    store.chooseFileMention()
                } label: {
                    optionLabel(
                        title: "Mention Project File…",
                        detail: "Reference a sandbox-safe local path.",
                        systemImage: "doc.text.magnifyingglass",
                        color: .teal
                    )
                }
                .buttonStyle(.plain)

                Divider()
            }

            Text("Mode")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(DesktopInteractionMode.allCases) { mode in
                    Button {
                        store.setInteractionMode(mode)
                    } label: {
                        modeOptionLabel(mode)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSelect(mode))
                    .help(modeHelp(mode))
                }
            }

            Divider()

            optionToggle(
                title: "Goal",
                detail: goalDetail,
                systemImage: "target",
                color: .green,
                isOn: Binding(
                    get: { store.isGoalModeEnabled },
                    set: { store.setGoalModeEnabled($0) }
                )
            )
            .disabled(!store.hasExplicitWorkspace)
            .help("Keep working toward a persistent goal")
        }
        .padding(12)
        .frame(width: 326)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composer options")
    }

    private var goalDetail: String {
        if store.activeGoalObjective != nil {
            return "Keep working on the active goal."
        }
        return "Use your next message as an active goal."
    }

    private func optionToggle(
        title: String,
        detail: String,
        systemImage: String,
        color: Color,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            optionLabel(
                title: title,
                detail: detail,
                systemImage: systemImage,
                color: color
            )
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private func modeOptionLabel(_ mode: DesktopInteractionMode) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(modeColor(mode))
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(mode.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: store.interactionMode == mode ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(store.interactionMode == mode ? modeColor(mode) : .secondary.opacity(0.55))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mode.title)
        .accessibilityValue(store.interactionMode == mode ? "Selected" : "Not selected")
        .accessibilityHint(mode.detail)
    }

    private func canSelect(_ mode: DesktopInteractionMode) -> Bool {
        switch mode {
        case .agentic:
            return true
        case .plan:
            return store.hasExplicitWorkspace && store.supportsPlanMode
        case .debug:
            return store.hasExplicitWorkspace && store.supportsDebugMode
        }
    }

    private func modeHelp(_ mode: DesktopInteractionMode) -> String {
        switch mode {
        case .agentic:
            return mode.detail
        case .plan where !store.supportsPlanMode:
            return "Plan mode is unavailable in this Codex runtime"
        case .debug where !store.supportsDebugMode:
            return "Debug mode requires collaboration-mode support in the Codex runtime"
        default:
            return mode.detail
        }
    }

    private func modeColor(_ mode: DesktopInteractionMode) -> Color {
        switch mode {
        case .agentic: return .accentColor
        case .plan: return .orange
        case .debug: return .purple
        }
    }

    private func optionLabel(
        title: String,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}

struct DesktopComposerModePills: View {
    @ObservedObject var store: DesktopCodexStore

    var body: some View {
        HStack(spacing: 6) {
            if store.isPlanModeEnabled {
                DesktopComposerModePill(
                    title: "Plan",
                    systemImage: "list.bullet.clipboard",
                    color: .orange,
                    onDismiss: { store.setPlanModeEnabled(false) }
                )
            }

            if store.isDebugModeEnabled {
                DesktopComposerModePill(
                    title: "Debug",
                    systemImage: "ladybug",
                    color: .purple,
                    onDismiss: { store.setInteractionMode(.agentic) }
                )
            }

            if store.isGoalModeEnabled {
                DesktopComposerModePill(
                    title: "Goal",
                    systemImage: "target",
                    color: .green,
                    onDismiss: { store.setGoalModeEnabled(false) }
                )
            }
        }
    }
}

private struct DesktopComposerModePill: View {
    let title: String
    let systemImage: String
    let color: Color
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onDismiss) {
            ZStack {
                Label(title, systemImage: systemImage)
                    .blur(radius: isHovered ? 3.5 : 0)
                    .opacity(isHovered ? 0.2 : 1)

                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(isHovered ? 1 : 0)
                    .scaleEffect(isHovered ? 1 : 0.65)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(isHovered ? 0.2 : 0.14), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(isHovered ? 0.42 : 0.28), lineWidth: 1))
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
        .help("Turn off \(title)")
        .accessibilityLabel("Turn off \(title)")
        .accessibilityHint("Removes \(title) from this chat")
    }
}
