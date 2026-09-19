// FILE: DesktopEnabledModelsMenu.swift
// Purpose: General-settings popover that toggles which models appear in Veo's picker.
// Layer: Desktop app view

import SwiftUI

struct DesktopEnabledModelsSummary: View {
    let enabledCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("\(enabledCount) of \(totalCount)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 86, alignment: .trailing)
        .accessibilityHidden(true)
    }
}

struct DesktopEnabledModelsPopover: View {
    @Bindable var store: DesktopCodexStore
    @Environment(\.veoAccent) private var veoAccent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(store.enabledModelsGroups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        VStack(spacing: 0) {
                            ForEach(group.rows) { row in
                                Toggle(isOn: store.modelEnabledBinding(row.id)) {
                                    Text(row.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                }
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .disabled(row.isLastEnabled)
                                .help(row.isLastEnabled ? "Keep at least one model enabled." : row.title)
                            }
                        }
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 320)
        .frame(maxHeight: 420)
        .accessibilityLabel("Enabled models")
    }
}

struct DesktopEnabledModelGroup: Identifiable {
    let id: String
    let title: String
    let rows: [DesktopEnabledModelRow]
}

struct DesktopEnabledModelRow: Identifiable {
    let id: String
    let title: String
    let isLastEnabled: Bool
}
