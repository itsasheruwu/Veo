// FILE: DesktopComposerCommandPalette.swift
// Purpose: Material-aware keyboard command, file, and skill autocomplete above the composer.
// Layer: Desktop app view

import AppKit
import SwiftUI

struct DesktopComposerAutocompletePanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.veoAccent) private var veoAccent
    @ObservedObject var store: DesktopCodexStore
    @AppStorage(DesktopAppearancePreferences.composerMaterialKey) private var composerMaterialRaw =
        DesktopComposerMaterial.liquidGlass.rawValue

    private var composerMaterial: DesktopComposerMaterial {
        DesktopComposerMaterial(rawValue: composerMaterialRaw) ?? .liquidGlass
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.composerSuggestions) { suggestion in
                            suggestionRow(suggestion)
                                .id(suggestion.id)
                        }
                    }
                    .padding(5)
                }
                .scrollIndicators(.hidden)
                .onChange(of: store.selectedComposerSuggestionID) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .frame(maxHeight: 268)

            HStack(spacing: 13) {
                shortcut("↑↓", label: "Select")
                shortcut("Tab", label: "Run")
                Spacer(minLength: 0)
                if let paletteTitle {
                    Text(paletteTitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .overlay(alignment: .top) {
                Divider().opacity(0.55)
            }
        }
        .modifier(DesktopCommandPaletteSurface(material: composerMaterial))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composer autocomplete")
    }

    private func suggestionRow(_ suggestion: DesktopComposerSuggestion) -> some View {
        let isSelected = store.selectedComposerSuggestionID == suggestion.id
        let command = suggestion.kind == .command ? DesktopComposerCommand.named(suggestion.source) : nil
        let badgeColor = veoAccent
        let isCurrent = isCurrentSuggestion(suggestion)

        return Button {
            store.selectComposerSuggestion(suggestion)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol(for: suggestion))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color(for: suggestion))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.system(size: 11.5, weight: .semibold, design: suggestion.kind == .command ? .monospaced : .default))
                        .lineLimit(1)
                    Text(suggestion.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if command != nil || isCurrent {
                    Text(command != nil ? "Veo" : "Current")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            badgeColor.opacity(0.1),
                            in: Capsule()
                        )
                } else if suggestion.kind == .file || suggestion.kind == .skill {
                    Text(suggestion.kind == .file ? "File" : "Skill")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                isSelected ? veoAccent.opacity(composerMaterial == .liquidGlass ? 0.2 : 0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(veoAccent.opacity(0.24), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(suggestion.title), \(suggestion.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func symbol(for suggestion: DesktopComposerSuggestion) -> String {
        switch suggestion.kind {
        case .file: return "doc.text"
        case .skill: return "bolt.badge.checkmark"
        case .command: return DesktopComposerCommand.named(suggestion.source)?.systemImage ?? "command"
        case .model: return "cube"
        case .reasoning: return "brain"
        case .accessMode: return "shield"
        }
    }

    private func color(for suggestion: DesktopComposerSuggestion) -> Color {
        switch suggestion.kind {
        case .file: return veoAccent
        case .skill: return .orange
        case .command: return .secondary
        case .model, .reasoning, .accessMode: return .secondary
        }
    }

    private var paletteTitle: String? {
        switch store.composerPaletteContext {
        case .models: return "Models"
        case .reasoning: return "Reasoning"
        case .accessModes: return "Permissions"
        case nil:
            return store.composerSuggestions.contains(where: { $0.kind == .command })
                ? "Veo commands"
                : nil
        }
    }

    private func isCurrentSuggestion(_ suggestion: DesktopComposerSuggestion) -> Bool {
        switch suggestion.kind {
        case .model:
            return suggestion.source == store.selectedModelID
        case .reasoning:
            return suggestion.source == store.selectedReasoningEffort
        case .accessMode:
            return suggestion.source == store.accessMode.rawValue
        case .file, .skill, .command:
            return false
        }
    }

    private func shortcut(_ key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
    }
}

private struct DesktopCommandPaletteSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let material: DesktopComposerMaterial

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        switch material {
        case .solid:
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.stroke(Color.primary.opacity(0.11), lineWidth: 1))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.1), radius: 12, y: 6)

        case .mica:
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.1), radius: 14, y: 7)

        case .liquidGlass:
            liquidGlassSurface(content)
        }
    }

    @ViewBuilder
    private func liquidGlassSurface(_ content: Content) -> some View {
        // These symbols ship with the macOS 26 SDK. A runtime availability
        // check alone is not enough when CI compiles with Xcode 16.4.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: shape)
        } else {
            liquidGlassFallback(content)
        }
        #else
        liquidGlassFallback(content)
        #endif
    }

    private func liquidGlassFallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }
}
