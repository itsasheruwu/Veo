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
                        detail: "Choose a local project folder.",
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
                        detail: "Reference a file in this project.",
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
                detail: "Find code and design references.",
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
            return "Continue the active goal."
        }
        switch store.goalMode {
        case .providerManaged: return "Use your next message as a goal."
        case .loop: return "Your next message starts a Loop."
        case .gauntlet: return "Your next message starts a Gauntlet."
        }
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
        let unavailable = store.modeUnavailableReason(mode)
        return HStack(alignment: .top, spacing: 9) {
            DesktopModeGlyph(name: mode.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(modeColor(mode))
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(unavailable ?? mode.composerMenuDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(unavailable ?? mode.composerMenuDetail)
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
        .accessibilityHint(unavailable ?? mode.composerMenuDetail)
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
        color: Color
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
                    .lineLimit(1)
                    .help(detail)
            }

            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}

private extension DesktopInteractionMode {
    var composerMenuDetail: String {
        switch self {
        case .agentic: "Investigate and make changes."
        case .plan: "Plan before making changes."
        case .debug: "Diagnose bugs with evidence."
        case .ask: "Answer with read-only access."
        case .roblox: "Use the Roblox and Luau workflow."
        }
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
                        onPress: { store.setInteractionMode(.agentic) }
                    )
                }

                if store.isWildEnabled {
                    DesktopComposerModePill(title: "Wild", systemImage: "veo.wild", color: .pink,
                                            onPress: { store.setWildEnabled(false) })
                }

                if store.isGoalModeEnabled {
                    DesktopGoalModePicker(store: store)
                }
            }
        }
    }
}

private struct DesktopGoalModePicker: View {
    let store: DesktopCodexStore
    @State private var isPresented = false

    var body: some View {
        DesktopComposerModePill(
            title: "Goal", systemImage: "target", color: .green,
            actionImage: "gearshape", actionLabel: "Goal settings", actionValue: store.goalMode.pickerTitle,
            actionHint: "Choose how this chat works toward its goal", isActionActive: isPresented,
            onPress: { isPresented.toggle() }
        )
        .accessibilityIdentifier("composer-goal-settings")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Goal mode", systemImage: "target")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.bottom, 2)
                ForEach(DesktopGoalMode.allCases) { mode in
                    modeChoice(mode)
                }
                if let status = store.goalModeStatus {
                    Text(status)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(status)
                        .padding(.horizontal, 7)
                }
                if store.activeGoalObjective != nil {
                    Text("Turn off Goal to switch modes.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                }
                Divider().padding(.vertical, 2)
                Button {
                    isPresented = false
                    store.setGoalModeEnabled(false)
                } label: {
                    Label("Turn off Goal", systemImage: "power")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .frame(width: 268)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Goal mode")
        }
        .onChange(of: store.selectedThreadID) { _, _ in isPresented = false }
    }

    private func modeChoice(_ mode: DesktopGoalMode) -> some View {
        let selected = store.goalMode == mode
        let unavailable = selected ? nil : store.goalModeUnavailableReason(mode)
        let detail = store.activeGoalObjective == nil ? unavailable ?? mode.pickerDetail : mode.pickerDetail
        return Button {
            store.setGoalMode(mode)
            isPresented = false
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: mode.pickerIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Color.green : .secondary)
                    .frame(width: 17)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.pickerTitle).font(.system(size: 12, weight: .medium))
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(detail)
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(selected ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.pickerTitle)
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(unavailable != nil)
    }
}

private extension DesktopGoalMode {
    var pickerTitle: String {
        switch self {
        case .providerManaged: "Provider-managed"
        case .loop: "Loop"
        case .gauntlet: "Gauntlet"
        }
    }

    var pickerDetail: String {
        switch self {
        case .providerManaged: "Use the provider’s built-in goal."
        case .loop: "Repeat until the goal is met."
        case .gauntlet: "Build, compare, and revise."
        }
    }

    var pickerIcon: String {
        switch self {
        case .providerManaged: "target"
        case .loop: "arrow.clockwise"
        case .gauntlet: "checkmark.shield"
        }
    }
}

private struct DesktopComposerModePill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let systemImage: String
    let color: Color
    var actionImage = "xmark"
    var actionLabel: String?
    var actionValue: String?
    var actionHint: String?
    var isActionActive = false
    let onPress: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if actionLabel != nil {
            pill
                .focusable(interactions: .activate)
                .focused($isFocused)
                .onKeyPress(keys: [.space, .return]) { _ in
                    onPress()
                    return .handled
                }
        } else {
            pill
        }
    }

    private var pill: some View {
        let showsAction = isHovered || isActionActive || (actionLabel != nil && isFocused)
        let spokenLabel = actionLabel ?? "Turn off \(title)"
        return Button(action: onPress) {
            ZStack {
                Label {
                    Text(title)
                } icon: {
                    DesktopModeGlyph(name: systemImage)
                }
                    .blur(radius: showsAction ? 3.5 : 0)
                    .opacity(showsAction ? 0.2 : 1)

                Image(systemName: actionImage)
                    .font(.system(size: actionLabel == nil ? 9 : 11, weight: .bold))
                    .opacity(showsAction ? 1 : 0)
                    .scaleEffect(showsAction ? 1 : 0.65)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(showsAction ? 0.2 : 0.14), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(showsAction ? 0.42 : 0.28), lineWidth: 1).allowsHitTesting(false))
            .fixedSize()
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsAction)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(spokenLabel)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(actionValue ?? "")
        .accessibilityHint(actionHint ?? "Removes \(title) from this chat")
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
