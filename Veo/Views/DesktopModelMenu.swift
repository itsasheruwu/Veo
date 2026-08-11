// FILE: DesktopModelMenu.swift
// Purpose: Presents the live Codex model, reasoning, and service-tier catalog.
// Layer: Desktop app view

import AppKit
import SwiftUI

struct DesktopModelMenu: View {
    @ObservedObject var store: DesktopCodexStore
    @State private var isPresented = false

    private var catalog: DesktopModelCatalogPresentation {
        DesktopModelCatalogPresentation(models: store.models)
    }

    private var selectedVariant: DesktopGPT56Variant? {
        store.selectedModel.flatMap(catalog.variant(for:))
    }

    private var collapsedModelTitle: String {
        guard let variant = selectedVariant else { return store.modelDisplayName }
        return "GPT-5.6 \(variant.title)"
    }

    private var isFastModeEnabled: Bool {
        guard let model = store.selectedModel,
              let fastTier = model.serviceTiers.first(where: \.isFastModeTier) else {
            return false
        }
        return store.selectedServiceTier == fastTier.id
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                if isFastModeEnabled {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }

                Image(systemName: "cube")
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityHidden(true)

                Text(collapsedModelTitle)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text("·")
                    .foregroundStyle(.tertiary)

                Text(store.reasoningDisplayName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(store.models.isEmpty)
        .help(store.selectedModel?.description ?? "Codex model")
        .accessibilityLabel("Model settings")
        .accessibilityValue(
            "\(collapsedModelTitle), \(store.reasoningDisplayName) reasoning"
                + (isFastModeEnabled ? ", Fast Mode on" : "")
        )
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            DesktopModelStudioPicker(store: store, catalog: catalog)
        }
    }
}

private struct DesktopModelStudioPicker: View {
    @ObservedObject var store: DesktopCodexStore
    let catalog: DesktopModelCatalogPresentation
    @Environment(\.veoAccent) private var veoAccent
    @State private var page: Page = .details

    private enum Page {
        case details
        case modelList
    }

    private var isGPT56Selected: Bool {
        store.selectedModel.map(catalog.isGPT56) == true
    }

    private var selectedVariant: DesktopGPT56Variant? {
        store.selectedModel.flatMap(catalog.variant(for:))
    }

    var body: some View {
        ScrollView {
            Group {
                switch page {
                case .details:
                    VStack(alignment: .leading, spacing: 0) {
                        selectedModelSection

                        if isGPT56Selected, !catalog.variantModels.isEmpty {
                            sectionDivider
                            variantSection
                        }

                        if let model = store.selectedModel {
                            sectionDivider
                            reasoningSection(for: model)

                            if let fastTier = fastTier(for: model) {
                                sectionDivider
                                fastModeSection(tier: fastTier)
                            }
                        }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))

                case .modelList:
                    VStack(alignment: .leading, spacing: 0) {
                        modelListSection
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .id(page)
            .padding(11)
        }
        .frame(width: 332, height: 430)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model studio")
        .onAppear { page = .details }
    }

    private var selectedModelSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                sectionTitle("Model")
                Spacer()

                if !catalog.otherModels.isEmpty {
                    pageButton(systemName: "arrow.right", label: "Show all models") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            page = .modelList
                        }
                    }
                }
            }

            if isGPT56Selected, let familyModel = catalog.preferredGPT56Model {
                StudioSelectionRow(
                    title: "GPT-5.6",
                    description: familyDescription(fallback: familyModel),
                    isSelected: true,
                    action: {}
                )
                .accessibilityHint("Choose a GPT-5.6 variant below")
            } else if let model = store.selectedModel {
                StudioSelectionRow(
                    title: model.displayName,
                    description: model.description,
                    isSelected: true,
                    action: {}
                )
            } else {
                unavailableLabel("No model selected")
            }
        }
    }

    private var modelListSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                pageButton(systemName: "arrow.left", label: "Back to model options") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        page = .details
                    }
                }

                sectionTitle("Models")
                Spacer()
            }

            if let familyModel = catalog.preferredGPT56Model {
                StudioSelectionRow(
                    title: "GPT-5.6",
                    description: familyDescription(fallback: familyModel),
                    isSelected: isGPT56Selected
                ) {
                    selectModelAndShowDetails(familyModel.id)
                }
            }

            ForEach(catalog.otherModels) { model in
                modelRow(model)
            }
        }
    }

    @ViewBuilder
    private func pageButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 25, height: 25)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pageButtonForeground)
        .shadow(color: pageButtonShadow, radius: 0.5, y: 0.5)
        .accessibilityLabel(label)
        .help(label)

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            button
                .glassEffect(.regular.tint(veoAccent).interactive(), in: Circle())
        } else {
            pageButtonFallback(button)
        }
        #else
        pageButtonFallback(button)
        #endif
    }

    private func pageButtonFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(veoAccent.opacity(0.82), in: Circle())
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var pageButtonForeground: Color {
        isLightAccent ? .black.opacity(0.82) : .white
    }

    private var pageButtonShadow: Color {
        isLightAccent ? .white.opacity(0.2) : .black.opacity(0.28)
    }

    private var isLightAccent: Bool {
        guard let color = NSColor(veoAccent).usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * linearized(color.redComponent)
            + 0.7152 * linearized(color.greenComponent)
            + 0.0722 * linearized(color.blueComponent)
        return luminance > 0.42
    }

    private func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private var variantSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Variant")

            Picker("GPT-5.6 variant", selection: variantSelection) {
                ForEach(catalog.variantModels, id: \.variant) { option in
                    Text(option.variant.title)
                        .tag(Optional(option.variant))
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel("GPT-5.6 variant")

            if let description = selectedVariantDescription, !description.isEmpty {
                Text(description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reasoningSection(for model: DesktopModelOption) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Reasoning")

            if model.supportedReasoningEfforts.isEmpty {
                unavailableLabel("No reasoning choices for this model")
            } else {
                ForEach(model.supportedReasoningEfforts) { option in
                    StudioSelectionRow(
                        title: option.title,
                        description: reasoningDescription(for: option),
                        isSelected: store.selectedReasoningEffort == option.id
                    ) {
                        store.selectReasoningEffort(option.id)
                    }
                }
            }
        }
    }

    private func fastModeSection(tier: DesktopModelServiceTier) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Speed")

            Toggle("Fast Mode", isOn: fastModeBinding(tier: tier))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12.5, weight: .medium))
                .help(fastModeHelp(tier: tier))
                .accessibilityLabel("Fast Mode")
                .accessibilityHint(fastModeHelp(tier: tier))
        }
    }

    private var variantSelection: Binding<DesktopGPT56Variant?> {
        Binding(
            get: { selectedVariant },
            set: { variant in
                guard let variant,
                      let model = catalog.variantModels.first(where: { $0.variant == variant })?.model else {
                    return
                }
                store.selectModel(model.id)
            }
        )
    }

    private var selectedVariantDescription: String? {
        guard let selectedVariant else { return nil }
        return catalog.variantModels.first(where: { $0.variant == selectedVariant })?.model.description
    }

    private func fastTier(for model: DesktopModelOption) -> DesktopModelServiceTier? {
        model.serviceTiers.first(where: \.isFastModeTier)
    }

    private func fastModeBinding(tier: DesktopModelServiceTier) -> Binding<Bool> {
        Binding(
            get: { store.selectedServiceTier == tier.id },
            set: { store.selectServiceTier($0 ? tier.id : nil) }
        )
    }

    private func fastModeHelp(tier: DesktopModelServiceTier) -> String {
        tier.description.isEmpty ? "Use the faster service tier." : tier.description
    }

    private func familyDescription(fallback: DesktopModelOption) -> String {
        guard isGPT56Selected, let selected = store.selectedModel, !selected.description.isEmpty else {
            return fallback.description
        }
        return selected.description
    }

    private func reasoningDescription(for option: DesktopReasoningOption) -> String {
        guard option.id.caseInsensitiveCompare("ultra") == .orderedSame else { return "" }
        return option.description.isEmpty
            ? "Maximum reasoning with automatic task delegation."
            : option.description
    }

    private func modelRow(_ model: DesktopModelOption) -> some View {
        StudioSelectionRow(
            title: model.displayName,
            description: model.description,
            isSelected: store.selectedModelID == model.id
        ) {
            selectModelAndShowDetails(model.id)
        }
    }

    private func selectModelAndShowDetails(_ modelID: String) {
        if store.selectedModelID != modelID {
            store.selectModel(modelID)
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            page = .details
        }
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 8)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func unavailableLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
    }
}

private extension DesktopModelServiceTier {
    var isFastModeTier: Bool {
        id.caseInsensitiveCompare("fast") == .orderedSame
            || name.caseInsensitiveCompare("fast") == .orderedSame
    }
}

private struct StudioSelectionRow: View {
    let title: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.veoAccent) private var veoAccent
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? veoAccent : Color.secondary)
                    .frame(width: 14, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, description.isEmpty ? 4 : 3)
            .background(
                (isHovered ? Color.primary.opacity(0.065) : Color.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(description)
    }
}

private enum DesktopGPT56Variant: String, CaseIterable, Hashable {
    case luna
    case terra
    case sol

    var title: String { rawValue.capitalized }
}

private struct DesktopModelCatalogPresentation {
    struct VariantModel {
        let variant: DesktopGPT56Variant
        let model: DesktopModelOption
    }

    let models: [DesktopModelOption]

    var gpt56Models: [DesktopModelOption] {
        models.filter(isGPT56)
    }

    var otherModels: [DesktopModelOption] {
        models.filter { !isGPT56($0) }
    }

    var variantModels: [VariantModel] {
        DesktopGPT56Variant.allCases.compactMap { variant in
            let candidates = gpt56Models.filter { self.variant(for: $0) == variant }
            guard let model = canonicalModel(for: variant, from: candidates) else { return nil }
            return VariantModel(variant: variant, model: model)
        }
    }

    var preferredGPT56Model: DesktopModelOption? {
        let visibleModels = variantModels.map(\.model)
        return visibleModels.first(where: \.isDefault)
            ?? gpt56Models.first(where: \.isDefault)
            ?? visibleModels.first
            ?? gpt56Models.first
    }

    func isGPT56(_ model: DesktopModelOption) -> Bool {
        modelSearchText(model).contains("gpt-5.6")
    }

    func variant(for model: DesktopModelOption) -> DesktopGPT56Variant? {
        guard isGPT56(model) else { return nil }
        let text = modelSearchText(model)
        return DesktopGPT56Variant.allCases.first(where: { text.contains("-\($0.rawValue)") })
    }

    private func canonicalModel(
        for variant: DesktopGPT56Variant,
        from candidates: [DesktopModelOption]
    ) -> DesktopModelOption? {
        let canonicalName = "gpt-5.6-\(variant.rawValue)"
        return candidates.first(where: {
            normalized($0.model) == canonicalName || normalized($0.id) == canonicalName
        }) ?? candidates.first(where: \.isDefault) ?? candidates.first
    }

    private func modelSearchText(_ model: DesktopModelOption) -> String {
        [model.id, model.model, model.displayName]
            .map(normalized)
            .joined(separator: "-")
    }

    private func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }
}
