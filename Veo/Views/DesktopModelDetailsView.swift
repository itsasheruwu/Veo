// FILE: DesktopModelDetailsView.swift
// Purpose: Presents live model metadata and supported personality settings.
// Layer: Desktop app view

import SwiftUI

struct DesktopModelDetailsView: View {
    @Bindable var store: DesktopCodexStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.routingMode == .auto {
                    autoDetails
                } else if let model = store.selectedModel {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.userFacingDisplayName).font(.headline)
                        Text(model.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let notice = model.availabilityNotice, !notice.isEmpty {
                        Label(notice, systemImage: "info.circle").font(.callout)
                    }
                    if model.supportsPersonality {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Personality").font(.subheadline.weight(.medium))
                            Picker("Personality", selection: Binding(
                                get: { store.selectedPersonality },
                                set: { store.selectPersonality($0) }
                            )) {
                                Text("None").tag("none")
                                Text("Friendly").tag("friendly")
                                Text("Pragmatic").tag("pragmatic")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            Text("Changes apply to the next turn.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let specialty = model.modelSpecialty, !specialty.isEmpty {
                        LabeledContent("Specialty", value: specialty)
                    }
                    if let version = model.multiAgentVersion, version != "disabled" {
                        LabeledContent("Multi-agent support", value: version.uppercased())
                    }
                    let provider = store.appServer0153.modelProviderCapabilities
                    if provider.isAvailable {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Provider tools").font(.subheadline.weight(.medium))
                            if provider.webSearch { Label("Web search", systemImage: "globe") }
                            if provider.imageGeneration { Label("Image generation", systemImage: "photo") }
                            if !provider.webSearch && !provider.imageGeneration {
                                Text("No additional tools reported.").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if model.upgrade != nil || model.upgradeCopy != nil || model.retirementAt != nil {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            if let copy = model.upgradeCopy {
                                Text(copy)
                            } else if let upgrade = model.upgrade {
                                Text("Suggested upgrade: \(upgrade)")
                            }
                            if let retirement = model.retirementAt {
                                LabeledContent("Scheduled retirement", value: retirement.formatted(date: .abbreviated, time: .omitted))
                            }
                            if let migration = model.migrationMarkdown, !migration.isEmpty {
                                Text(.init(migration)).foregroundStyle(.secondary)
                            }
                            if let link = model.upgradeLink, let url = URL(string: link), url.scheme == "https" {
                                Link("Upgrade information", destination: url)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No model selected", systemImage: "cube")
                }
            }
            .font(.callout)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .frame(width: 308, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
        }
        .frame(width: 340, height: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model details")
    }

    private var autoDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("5.6 Auto").font(.headline)
                Text("Veo coordinates models for the task, with separate implementation and review when multi-agent support is available.")
                    .foregroundStyle(.secondary)
            }
            if let plan = store.resolvedAutoRoutePlan {
                routeRow("Lead", lane: plan.parent)
                if plan.usesMultiAgent {
                    routeRow("Implementation", lane: plan.routineWorker)
                    routeRow("Escalation", lane: plan.escalationWorker)
                    routeRow("Review", lane: plan.reviewer)
                }
                if !plan.warnings.isEmpty {
                    Divider()
                    ForEach(plan.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("The route is fixed when you send a message. Planning requests stay with the lead model.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label(store.autoRouteErrorMessage ?? "Auto routing is unavailable.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func routeRow(_ title: String, lane: DesktopAutoRouteLane) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            Text("\(lane.displayName) · \(lane.effort.capitalized)")
                .foregroundStyle(.secondary)
        }
    }

}
