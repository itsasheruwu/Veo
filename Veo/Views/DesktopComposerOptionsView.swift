// FILE: DesktopComposerOptionsView.swift
// Purpose: Presents composer modes and their active status pills.
// Layer: Desktop app view

import SwiftUI

struct DesktopComposerOptionsView: View {
    @Bindable var store: DesktopCodexStore
    let openProject: () -> Void
    var didInsertPlugin: () -> Void = {}
    @Environment(\.veoAccent) private var veoAccent
    @State private var showsSavedPrompts = false
    @State private var showsPlugins = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if showsSavedPrompts {
                DesktopPromptLibraryView(store: store) { showsSavedPrompts = false }
            } else if showsPlugins {
                VStack(alignment: .leading, spacing: 10) {
                    Button { showsPlugins = false } label: { Label("Plugins", systemImage: "chevron.left") }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(store.pluginSuggestions()) { item in
                                Button {
                                    store.insertPluginMention(item)
                                    didInsertPlugin()
                                } label: {
                                    optionLabel(title: item.title, detail: item.subtitle, systemImage: "puzzlepiece.extension", color: veoAccent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 280)
                }
            } else {
                ScrollView { options }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 600)
            }
        }
        .padding(12)
        .frame(width: 326)
        .background(.regularMaterial)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsSavedPrompts)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(showsSavedPrompts ? "Saved prompts" : "Composer options")
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.hasExplicitWorkspace {
                Button(action: openProject) {
                    optionLabel(
                        title: "Open Project…",
                        detail: "Choose a local folder for this chat.",
                        systemImage: "folder.badge.plus",
                        color: veoAccent
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

            if !store.pluginSuggestions().isEmpty {
                Button { showsPlugins = true } label: {
                    optionLabel(title: "Plugins", detail: "Mention an enabled Codex plugin.", systemImage: "puzzlepiece.extension", color: veoAccent)
                }
                .buttonStyle(.plain)
            }

            Button { store.stashPrompt() } label: {
                optionLabel(title: "Save draft for later", detail: "Keep this prompt and its attachments.", systemImage: "tray.and.arrow.down", color: .secondary)
            }
            .buttonStyle(.plain)
            .disabled(store.isSavingPrompt || store.draft.isEmpty && store.attachments.isEmpty)
            Button { showsSavedPrompts = true } label: {
                optionLabel(title: "Saved prompts", detail: "Restore a prompt into this draft.", systemImage: "tray", color: .secondary)
            }
            .buttonStyle(.plain)
            Divider()

            optionToggle(
                title: "Wild",
                detail: "Find existing implementations and design references.",
                systemImage: "veo.wild",
                color: .pink,
                isOn: Binding(get: { store.isWildEnabled }, set: { store.setWildEnabled($0) })
            )
            .disabled(store.activeAgent != nil)

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
                    .disabled(store.modeUnavailableReason(mode) != nil)
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
                color: color,
                detailLines: 2
            )
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private func modeOptionLabel(_ mode: DesktopInteractionMode) -> some View {
        HStack(alignment: .top, spacing: 9) {
            DesktopModeGlyph(name: mode.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(modeColor(mode))
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(store.modeUnavailableReason(mode) ?? mode.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityHint(store.modeUnavailableReason(mode) ?? mode.detail)
    }

    private func modeColor(_ mode: DesktopInteractionMode) -> Color {
        switch mode {
        case .agentic: return veoAccent
        case .plan: return .orange
        case .debug: return .purple
        case .ask: return .blue
        case .roblox: return .red
        }
    }

    private func optionLabel(
        title: String,
        detail: String,
        systemImage: String,
        color: Color,
        detailLines: Int = 1
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            DesktopModeGlyph(name: systemImage)
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
                    .lineLimit(detailLines)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}

struct DesktopComposerModePills: View {
    @Bindable var store: DesktopCodexStore

    var body: some View {
        if store.interactionMode != .agentic || store.isGoalModeEnabled || store.isWildEnabled {
            HStack(spacing: 6) {
                let mode = store.interactionMode
                if mode != .agentic {
                    DesktopComposerModePill(
                        title: mode.title,
                        systemImage: mode.systemImage,
                        color: mode == .plan ? .orange : mode == .debug ? .purple : mode == .roblox ? .red : .blue,
                        onDismiss: { store.setInteractionMode(.agentic) }
                    )
                }

                if store.isWildEnabled {
                    DesktopComposerModePill(title: "Wild", systemImage: "veo.wild", color: .pink,
                                            onDismiss: { store.setWildEnabled(false) })
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
}

private struct DesktopComposerModePill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let systemImage: String
    let color: Color
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onDismiss) {
            ZStack {
                Label {
                    Text(title)
                } icon: {
                    DesktopModeGlyph(name: systemImage)
                }
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
            .overlay(Capsule().stroke(color.opacity(isHovered ? 0.42 : 0.28), lineWidth: 1).allowsHitTesting(false))
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
        .help("Turn off \(title)")
        .accessibilityLabel("Turn off \(title)")
        .accessibilityHint("Removes \(title) from this chat")
    }
}


struct DesktopModeGlyph: View {
    let name: String

    var body: some View {
        switch name {
        case "veo.roblox":
            Canvas { context, size in
                let width = size.width
                let height = size.height
                var shape = Path()
                shape.addRect(CGRect(x: width * 0.16, y: height * 0.16, width: width * 0.68, height: height * 0.68))
                shape.addRect(CGRect(x: width * 0.4, y: height * 0.4, width: width * 0.2, height: height * 0.2))
                context.translateBy(x: width / 2, y: height / 2)
                context.rotate(by: .degrees(14))
                context.translateBy(x: -width / 2, y: -height / 2)
                context.fill(shape, with: .foreground, style: FillStyle(eoFill: true))
            }.frame(width: 15, height: 15)
        case "veo.wild":
            VStack(spacing: -2) {
                UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                    .frame(width: 8, height: 6)
                    .overlay(alignment: .bottom) { Capsule().frame(width: 15, height: 1.5) }
                Image(systemName: "eyeglasses").font(.system(size: 9, weight: .semibold))
            }.frame(width: 16, height: 16)
        default:
            Image(systemName: name)
        }
    }
}
