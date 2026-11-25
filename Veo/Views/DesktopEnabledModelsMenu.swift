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
  var embedded = false
  @Environment(\.veoAccent) private var veoAccent

  @State private var search = ""
  private func matches(_ title: String) -> Bool {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty || title.localizedCaseInsensitiveContains(query)
  }

  @ViewBuilder private var groups: some View {
    let native = store.enabledModelsGroups.compactMap { group -> DesktopEnabledModelGroup? in
      let rows = group.rows.filter { matches($0.title) || matches(group.title) }
      return rows.isEmpty ? nil : DesktopEnabledModelGroup(id: group.id, title: group.title, rows: rows)
    }
    let agents = VeoAgent.catalog.filter { agent in
      store.agents.connections[agent.id]?.models.contains { matches($0.name) || matches(agent.name) } == true
    }
    LazyVStack(alignment: .leading, spacing: 16) {
      ForEach(native) { group in
        groupTitle(group.title)
        SettingsPanel {
          ForEach(group.rows) { row in
            if row.id != group.rows.first?.id { Divider().padding(.leading, 12) }
            modelRow(row.title, enabled: store.modelEnabledBinding(row.id))
              .disabled(row.isLastEnabled || (group.id == "5.6" && !store.includeGPT56Models))
              .help(row.isLastEnabled ? "Keep at least one model enabled." : row.title)
          }
        }.padding(.top, -9)
      }
      ForEach(agents) { agent in
        if let connection = store.agents.connections[agent.id] {
          let models = connection.pickerModels.filter { matches($0.name) || matches(agent.name) }
          groupTitle(agent.name)
          SettingsPanel {
            ForEach(models) { model in
              if model.id != models.first?.id { Divider().padding(.leading, 12) }
              modelRow(model.name, enabled: Binding(
                get: { !connection.hidden.contains(model.id) },
                set: { store.agents.toggle(model.id, agent: agent.id, enabled: $0) }))
                .disabled(!connection.hidden.contains(model.id) && connection.pickerModels.filter { !connection.hidden.contains($0.id) }.count == 1)
            }
          }.padding(.top, -9)
        }
      }
      if native.isEmpty && agents.isEmpty { Text("No matching models").font(.callout).foregroundStyle(.secondary) }
    }
  }

  private func groupTitle(_ title: String) -> some View {
    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
  }

  private func modelRow(_ name: String, enabled: Binding<Bool>) -> some View {
    Toggle(isOn: enabled) {
      Text(name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
    }.toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
      .padding(.horizontal, 12).frame(minHeight: 34)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !embedded { Text("Enabled models").font(.headline) }
      ProviderSearchField(prompt: "Find a model", text: $search)
      if embedded { groups } else { ScrollView { groups } }
    }.padding(embedded ? 0 : 14)
      .frame(width: embedded ? nil : 320)
      .frame(maxHeight: embedded ? nil : 420)
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
