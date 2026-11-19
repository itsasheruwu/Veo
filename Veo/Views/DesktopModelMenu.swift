// FILE: DesktopModelMenu.swift
// Purpose: Presents the live Codex model, reasoning, and service-tier catalog.
// Layer: Desktop app view

import AppKit
import SwiftUI

struct DesktopModelMenu: View {
    @Bindable var store: DesktopCodexStore
    @AppStorage(DesktopAppearancePreferences.modelPickerAppearanceKey) private var pickerAppearanceRaw =
        DesktopModelPickerAppearance.defaultAppearance.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false
    @State private var isTriggerHovered = false

    private var catalog: DesktopModelCatalogPresentation {
        DesktopModelCatalogPresentation(models: store.selectableModels)
    }

    private var selectedVariant: DesktopGPT56Variant? {
        store.routingMode == .auto
            ? .auto
            : (store.routingMode == .direct ? store.selectedModel.flatMap(catalog.variant(for:)) : nil)
    }

    private var collapsedModelTitle: String {
        if store.autoModelSelectionEnabled || store.hasLockedAutoModel { return store.modelDisplayName }
        guard let variant = selectedVariant else { return store.modelDisplayName }
        return variant == .astra ? "6 Astra" : "5.6 \(variant.title)"
    }

    private var composerVariant: DesktopGPT56Variant? {
        if let selectedVariant { return selectedVariant }
        guard store.routingMode == .direct, store.selectedModel?.pickerFamily != nil,
              let name = collapsedModelTitle.split(separator: " ").dropFirst().first else { return nil }
        return DesktopGPT56Variant(rawValue: name.lowercased())
    }

    private var isFamilyAutoSelected: Bool { store.routingMode.isFamilyAuto }

    private var modelPickerHelp: String {
        if let detail = store.autoModelRoutingDetail ?? store.autoModelRoutingStatus { return detail }
        if let family = store.routingMode.autoFamily {
            return "Veo routes work across the \(family.productName) family."
        }
        return store.selectedModel?.description ?? "Codex model"
    }

    private var modelPickerAccessibilityValue: String {
        if store.autoModelSelectionEnabled || store.hasLockedAutoModel {
            return (store.autoModelRoutingStatus ?? "Auto, chooses on first prompt") + speedAccessibilitySuffix
        }
        if let family = store.routingMode.autoFamily {
            return "\(family.title), \(store.resolvedAutoRoutePlan?.laneSummary ?? "route unavailable")"
        }
        return "\(collapsedModelTitle), \(store.reasoningDisplayName) reasoning" + speedAccessibilitySuffix
    }

    private var pickerAppearance: DesktopModelPickerAppearance {
        DesktopModelPickerAppearance(rawValue: pickerAppearanceRaw) ?? .defaultAppearance
    }

    private var isFastModeEnabled: Bool { store.selectedModelServiceTier?.isFastModeTier == true }

    private var isUltraFastModeEnabled: Bool {
        store.selectedModelServiceTier?.isUltrafastTier == true
            || (store.routingMode == .direct && store.selectedModel?.isGPT53CodexSpark == true)
    }

    private var speedAccessibilitySuffix: String {
        if store.autoModelSelectionEnabled || store.hasLockedAutoModel {
            return store.displayedAutoSpeedPolicy == .allow
                ? ", Auto may use Fast mode"
                : ", Auto cannot use Fast mode"
        }
        if isUltraFastModeEnabled { return ", Ultrafast on" }
        if isFastModeEnabled { return ", Fast Mode on" }
        return ""
    }

    @ViewBuilder
    private var speedIndicator: some View {
        if store.autoModelSelectionEnabled || store.hasLockedAutoModel {
            DesktopAutoSpeedPermissionIndicator(policy: store.displayedAutoSpeedPolicy)
        } else if isFastModeEnabled || isUltraFastModeEnabled {
            if isUltraFastModeEnabled {
                UltrafastBoltPair(fontSize: 10)
            } else {
                Text(Image(systemName: "bolt.fill"))
                    .font(.system(size: 10, weight: .semibold))
                    .baselineOffset(
                        (NSFont.systemFont(ofSize: 12, weight: .medium).capHeight
                         - NSFont.systemFont(ofSize: 10, weight: .semibold).capHeight) / 2
                    )
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
            }
        }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            if pickerAppearance == .native {
                ViewThatFits(in: .horizontal) {
                    nativeModelLabel(showsReasoning: store.routingMode == .direct && !store.autoModelSelectionEnabled)
                    nativeModelLabel(showsReasoning: false)
                }
            } else {
                sliderModelLabel(showsReasoning: store.routingMode == .direct && !store.autoModelSelectionEnabled)
            }
        }
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .disabled(store.selectableModels.isEmpty && store.selectedModel == nil)
        .help(modelPickerHelp)
        .accessibilityLabel("Model settings")
        .accessibilityValue(modelPickerAccessibilityValue)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Group {
                if pickerAppearance == .native {
                    DesktopModelStudioPicker(store: store, catalog: catalog)
                } else {
                    DesktopModelSliderAdvancedPicker(store: store, catalog: catalog)
                }
            }
            .textSelection(.disabled)
        }
    }

    private func nativeModelLabel(showsReasoning: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            speedIndicator

            composerIdentity(showsFallback: true)

            Text(collapsedModelTitle)
                .fontWeight(.medium)
                .lineLimit(1)

            if showsReasoning {
                Text("·")
                    .foregroundStyle(.tertiary)

                Text(store.reasoningDisplayName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func composerIdentity(showsFallback: Bool) -> some View {
        if store.autoModelSelectionEnabled || store.hasLockedAutoModel {
            Image(systemName: store.autoModelRoutingDetail == nil ? "sparkles" : "exclamationmark.triangle")
                .accessibilityHidden(true)
        } else if isFamilyAutoSelected {
            Image(systemName: "sparkles").accessibilityHidden(true)
        } else if store.selectedModel?.isGrok == true {
            DesktopGrokMark(fontSize: 12)
        } else if let composerVariant {
            DesktopGPT56VariantIcon(variant: composerVariant, fontSize: 12)
        } else if showsFallback {
            Image(systemName: "cube")
                .font(.system(size: 11, weight: .medium))
                .accessibilityHidden(true)
        }
    }

    private var reasoningOptions: [DesktopReasoningOption] {
        guard store.routingMode == .direct else { return [] }
        return store.selectedModel?.supportedReasoningEfforts ?? []
    }

    private var isPeakReasoningSelected: Bool {
        guard reasoningOptions.count > 1, let peak = reasoningOptions.last else { return false }
        return store.selectedReasoningEffort == peak.id
    }

    private func sliderModelLabel(showsReasoning: Bool) -> some View {
        ZStack {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                speedIndicator

                composerIdentity(showsFallback: false)

                Text(collapsedModelTitle)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .layoutPriority(2)

                if showsReasoning {
                    Text(store.reasoningDisplayName)
                        .foregroundStyle(
                            isPeakReasoningSelected
                                ? SliderPickerPalette.peakText(colorScheme, usesBlueTheme: store.selectedModel?.usesAstraBluePickerStyle == true)
                                : Color.secondary
                        )
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, 12)
            .padding(.trailing, 26)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.trailing, 9)
        }
        .font(.system(size: 12))
        .frame(width: SliderPickerMetrics.triggerWidth, height: SliderPickerMetrics.triggerHeight)
        .background(
            Color.primary.opacity(isTriggerHovered || isPresented ? 0.085 : 0.05),
            in: Capsule()
        )
        .onHover { isTriggerHovered = $0 }
    }
}

// MARK: - Slider / Advanced appearance

/// Geometry measured off the reference picker. Keeping it in one place is what
/// lets the compact panel, the advanced panel, and the composer trigger agree.
private enum SliderPickerMetrics {
    static let panelWidth: CGFloat = 224
    static let contentInset: CGFloat = 12
    static let rowInset: CGFloat = 4
    static let headerHeight: CGFloat = 26
    static let trackHeight: CGFloat = 24
    static let knobDiameter: CGFloat = 28
    static let rowHeight: CGFloat = 28
    static let labelSize: CGFloat = 13
    static let triggerWidth: CGFloat = 178
    static let triggerHeight: CGFloat = 26
}

private enum SliderPickerPalette {
    /// Midnight blue and icy starlight drawn from the GPT-6 reference.
    static func fill(isPeak: Bool, usesBlueTheme: Bool) -> LinearGradient {
        if !usesBlueTheme {
            let colors = isPeak
                ? [Color(red: 0.29, green: 0.35, blue: 0.91), Color(red: 0.55, green: 0.30, blue: 0.98), Color(red: 0.76, green: 0.31, blue: 0.94)]
                : [Color(red: 0.07, green: 0.34, blue: 0.77), Color(red: 0.12, green: 0.35, blue: 0.84), Color(red: 0.36, green: 0.31, blue: 0.93)]
            return LinearGradient(stops: [
                .init(color: colors[0], location: 0),
                .init(color: colors[1], location: isPeak ? 0.55 : 0.62),
                .init(color: colors[2], location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
        let stops: [Gradient.Stop] = isPeak
            ? [
                .init(color: Color(red: 0.015, green: 0.07, blue: 0.24), location: 0),
                .init(color: Color(red: 0.025, green: 0.18, blue: 0.46), location: 0.55),
                .init(color: Color(red: 0.08, green: 0.36, blue: 0.68), location: 1),
            ]
            : [
                .init(color: Color(red: 0.07, green: 0.34, blue: 0.77), location: 0),
                .init(color: Color(red: 0.12, green: 0.35, blue: 0.84), location: 0.62),
                .init(color: Color(red: 0.18, green: 0.52, blue: 0.88), location: 1),
            ]
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    static func peakText(_ scheme: ColorScheme, usesBlueTheme: Bool) -> Color {
        if !usesBlueTheme {
            return ultrafastText(scheme)
        }
        return scheme == .dark
            ? Color(red: 0.57, green: 0.81, blue: 1.0)
            : Color(red: 0.07, green: 0.32, blue: 0.65)
    }

    static func ultrafastText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.72, green: 0.56, blue: 1.0)
            : Color(red: 0.40, green: 0.13, blue: 0.84)
    }

    static var track: Color { Color.primary.opacity(0.09) }
    static var unreachedTick: Color { Color.primary.opacity(0.28) }
    static var reachedTick: Color { Color.white.opacity(0.38) }
}

private extension DesktopModelOption {
    var usesAstraBluePickerStyle: Bool { isGPT6Astra || isGPT6Sol || isGPT61Sol }
}

private struct DesktopModelSliderAdvancedPicker: View {
    @State private var showsModelDetails = false
    @Bindable var store: DesktopCodexStore
    let catalog: DesktopModelCatalogPresentation

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .compact
    @State private var isSliderEngaged = false
    @State private var previewReasoningIndex: Int?
    @StateObject private var speedMenuAnchor = DesktopMenuAnchor()

    private enum Page {
        case compact
        case advanced
    }

    private var selectedVariant: DesktopGPT56Variant? {
        store.routingMode == .auto
            ? .auto
            : (store.routingMode == .direct ? store.selectedModel.flatMap(catalog.variant(for:)) : nil)
    }

    private var compactModelTitle: String {
        if store.autoModelSelectionEnabled || store.hasLockedAutoModel { return store.modelDisplayName }
        guard let variant = selectedVariant else { return store.modelDisplayName }
        return variant == .astra ? "6 Astra" : "5.6 \(variant.title)"
    }

    private var reasoningOptions: [DesktopReasoningOption] {
        guard store.routingMode == .direct else { return [] }
        return store.selectedModel?.supportedReasoningEfforts ?? []
    }

    private var selectedReasoningIndex: Int {
        guard let selection = store.selectedReasoningEffort,
              let index = reasoningOptions.firstIndex(where: { $0.id == selection }) else { return 0 }
        return index
    }

    /// Follows the slider's uncommitted stop while a drag is in flight so the
    /// header caption and Fast Mode tint track the pointer.
    private var displayedReasoningIndex: Int {
        previewReasoningIndex ?? selectedReasoningIndex
    }

    private var isPeakSelected: Bool {
        reasoningOptions.count > 1 && displayedReasoningIndex == reasoningOptions.count - 1
    }

    /// The caption the reference shows in place of "Faster / Smarter" once the
    /// slider reaches its most expensive stop.
    private var peakCaption: String? {
        guard isPeakSelected else { return nil }
        return "Uses your limits faster"
    }

    private var speedChoices: [DesktopPickerSpeed] {
        guard store.routingMode == .direct, let model = store.selectedModel else { return [] }
        return DesktopPickerSpeed.choices(for: model)
    }

    private var isSparkModel: Bool {
        store.routingMode == .direct && store.selectedModel?.isGPT53CodexSpark == true
    }

    private var isFastModeEnabled: Bool { store.selectedModelServiceTier?.isFastModeTier == true }

    private var isUltraFastModeEnabled: Bool {
        isSparkModel || store.selectedModelServiceTier?.isUltrafastTier == true
    }

    private var isAutoRouteSelected: Bool {
        store.autoModelSelectionEnabled || store.hasLockedAutoModel
    }

    private var canEditAutoRoute: Bool {
        store.autoModelSelectionEnabled && !store.hasLockedAutoModel
    }

    private var speedTitle: String {
        if isAutoRouteSelected { return store.displayedAutoSpeedPolicy.title }
        guard store.routingMode == .direct else { return "Auto" }
        if isUltraFastModeEnabled { return "Ultrafast" }
        if isFastModeEnabled { return "Fast Mode" }
        return "Standard"
    }

    private var canReset: Bool {
        guard store.routingMode == .direct, let model = store.selectedModel else { return false }
        let effortChanged = (store.selectedReasoningEffort ?? model.defaultReasoningEffort) != model.defaultReasoningEffort
        let tierChanged = store.selectedServiceTier != model.defaultServiceTier
        return effortChanged || tierChanged || store.selectedContextChoice.kind != .default
    }

    var body: some View {
        Group {
            switch page {
            case .compact: compactPage
            case .advanced: advancedPage
            }
        }
        .frame(width: SliderPickerMetrics.panelWidth)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model, effort, and speed")
        .onAppear { page = .compact }
        .onExitCommand { handleEscape() }
    }

    // MARK: Compact

    private var compactPage: some View {
        VStack(spacing: 11) {
            compactHeader
                .frame(height: SliderPickerMetrics.headerHeight)
                .padding(.horizontal, SliderPickerMetrics.contentInset - 6)

            reasoningControl
                .padding(.horizontal, SliderPickerMetrics.contentInset)

            if !isAutoRouteSelected, reasoningOptions.count > 1,
               reasoningOptions.indices.contains(displayedReasoningIndex) {
                HStack {
                    Text("Reasoning")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(reasoningOptions[displayedReasoningIndex].title)
                        .fontWeight(.medium)
                }
                .font(.system(size: 11))
                .padding(.horizontal, SliderPickerMetrics.contentInset)
                .accessibilityHidden(true)
            }
        }
        .padding(.top, 7)
        .padding(.bottom, 13)
    }

    private var compactHeader: some View {
        ZStack {
            HStack(spacing: 0) {
                SliderPickerQuietButton {
                    setPage(.advanced)
                } label: {
                    HStack(spacing: 4) {
                        Text("Advanced")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: SliderPickerMetrics.labelSize))
                    .foregroundStyle(.secondary)
                }
                .help("Show model, effort, and speed")

                Spacer(minLength: 0)

                if !isAutoRouteSelected {
                    if isSparkModel {
                        UltrafastBoltPair(fontSize: 12)
                            .frame(width: 16, height: 16)
                            .help("Ultrafast is always on for 5.3 Spark.")
                    } else if !speedChoices.isEmpty {
                        compactSpeedButton
                    }
                }
            }
            .opacity(isSliderEngaged ? 0 : 1)

            Group {
                if let peakCaption {
                    Text(peakCaption)
                        .foregroundStyle(SliderPickerPalette.peakText(colorScheme, usesBlueTheme: store.selectedModel?.usesAstraBluePickerStyle == true))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 0) {
                        Text("Faster")
                        Spacer(minLength: 8)
                        Text("Smarter")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: SliderPickerMetrics.labelSize))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .opacity(isSliderEngaged ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: isSliderEngaged)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: isPeakSelected)
    }

    @ViewBuilder
    private var reasoningControl: some View {
        if store.autoModelSelectionEnabled && !store.hasLockedAutoModel {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("Speed")
                    Spacer(minLength: 4)
                    Picker("Auto speed", selection: $store.autoSpeedPolicy) {
                        ForEach(DesktopAutoSpeedPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 126)
                    .accessibilityLabel("Allow Auto to use Fast mode")
                }

                HStack(spacing: 8) {
                    Text("Allow Ultra")
                    Spacer(minLength: 4)
                    Toggle("Allow Ultra reasoning", isOn: $store.autoRouterAllowsUltraReasoning)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("Allow Auto router to pick Ultra reasoning")
                }
            }
            .font(.system(size: 11.5, weight: .medium))
        } else if store.hasLockedAutoModel {
            Text(store.autoModelRoutingStatus ?? "Auto route locked for this chat")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .frame(minHeight: SliderPickerMetrics.trackHeight)
                .background(SliderPickerPalette.track, in: Capsule())
        } else if reasoningOptions.count > 1 {
            DesktopReasoningSlider(
                options: reasoningOptions,
                selectedIndex: selectedReasoningIndex,
                usesBlueTheme: store.selectedModel?.usesAstraBluePickerStyle == true,
                isFastModeEnabled: isFastModeEnabled,
                isEngaged: $isSliderEngaged,
                previewIndex: $previewReasoningIndex
            ) { index in
                guard reasoningOptions.indices.contains(index) else { return }
                store.selectReasoningEffort(reasoningOptions[index].id)
            }
            .frame(height: SliderPickerMetrics.knobDiameter)
        } else {
            Text(store.routingMode.isFamilyAuto ? "Auto picks the effort for each turn" : "This model has one effort level")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: SliderPickerMetrics.trackHeight)
                .background(SliderPickerPalette.track, in: Capsule())
        }
    }

    // MARK: Advanced

    private var advancedPage: some View {
        VStack(spacing: 0) {
            modelRow
            DesktopContextControl(store: store, style: .advanced)
            effortRow
            speedRow

            Divider()
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 1)

            HStack(spacing: 4) {
                SliderPickerQuietButton {
                    setPage(.compact)
                } label: {
                    HStack(spacing: 4) {
                        Text("Advanced")
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: SliderPickerMetrics.labelSize))
                    .foregroundStyle(.secondary)
                }
                .help("Back to the effort slider")

                Spacer(minLength: 0)

                if canReset {
                    SliderPickerQuietButton {
                        resetCurrentModelControls()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 16)
                    }
                    .help("Reset to default")
                    .accessibilityLabel("Reset to default")
                }

                SliderPickerQuietButton {
                    showsModelDetails = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 16)
                }
                .help("Model details and personality")
                .accessibilityLabel("Model details and personality")
                .popover(isPresented: $showsModelDetails) { DesktopModelDetailsView(store: store) }
            }
            .frame(height: SliderPickerMetrics.rowHeight)
        }
        .padding(SliderPickerMetrics.rowInset)
    }

    private var modelRow: some View {
        DesktopAdvancedMenuRow(
            title: "Model",
            value: compactModelTitle,
            isEnabled: !store.selectableModels.isEmpty || store.selectedModel != nil,
            header: "Model",
            items: { modelMenuItems }
        )
    }

    private var modelMenuItems: [DesktopMenuItemSpec] {
        var items: [DesktopMenuItemSpec] = []
        for family in catalog.recentGPT6Families {
            if !items.isEmpty { items.append(.separator) }
            items.append(contentsOf: catalog.models(in: family).map { model in
                directModelMenuItem(model, systemImage: catalog.identitySystemImage(for: model) ?? "cube")
            })
        }
        if !catalog.gpt6Models.isEmpty {
            if !items.isEmpty { items.append(.separator) }
            items.append(
                DesktopMenuItemSpec(
                    title: "6 Auto",
                    subtitle: "Veo routes across the GPT-6 family",
                    isEnabled: !store.isDaybreakOn,
                    isSelected: store.routingMode == .autoGPT6,
                    action: { store.selectAutoRouting(family: .gpt6) }
                )
            )
            items.append(contentsOf: catalog.gpt6Models.map { model in
                directModelMenuItem(model, systemImage: catalog.identitySystemImage(for: model) ?? "star.fill")
            })
        }

        if catalog.preferredGPT56Model != nil {
            if !items.isEmpty { items.append(.separator) }
            items.append(
                DesktopMenuItemSpec(
                    title: "5.6 Auto",
                    subtitle: "Veo routes across the 5.6 family",
                    isEnabled: !store.isDaybreakOn,
                    isSelected: store.routingMode == .auto,
                    action: store.selectAutoRouting
                )
            )
            for option in catalog.variantModels {
                items.append(
                    directModelMenuItem(
                        option.model,
                        title: "5.6 \(option.variant.title)",
                        systemImage: option.variant.systemImage
                    )
                )
            }
        }

        if !catalog.otherModels.isEmpty {
            if !items.isEmpty { items.append(.separator) }
            for model in catalog.otherModels {
                items.append(
                    directModelMenuItem(
                        model,
                        systemImage: catalog.identitySystemImage(for: model),
                        assetImage: catalog.identityAssetImage(for: model)
                    )
                )
            }
        }

        items = items.map { item in
            var item = item
            item.visibility = .manual
            return item
        }
        return [
            DesktopMenuItemSpec(
                title: "Auto", systemImage: "sparkles",
                isEnabled: !store.isDaybreakOn,
                toggleValue: store.autoModelSelectionEnabled,
                toggleKind: .auto,
                toggleAction: store.setAutoModelSelectionEnabled
            ),
            DesktopMenuItemSpec(
                title: "Daybreak", systemImage: DesktopDaybreakMark.systemImage,
                isEnabled: store.canToggleDaybreak,
                toggleValue: store.isDaybreakOn,
                toggleKind: .daybreak,
                toggleAction: store.setDaybreakEnabled
            ),
            .separator,
            DesktopMenuItemSpec(title: store.autoModelRoutingStatus ?? "Auto mode is on",
                                subtitle: store.autoModelRoutingDetail ?? "Chooses once for this thread.",
                                isEnabled: false, visibility: .automatic)
        ] + items
    }

    private func directModelMenuItem(
        _ model: DesktopModelOption, title: String? = nil, systemImage: String?, assetImage: String? = nil
    ) -> DesktopMenuItemSpec {
        let available = store.canSelectModel(model)
        return DesktopMenuItemSpec(
            title: title ?? model.userFacingDisplayName,
            systemImage: systemImage,
            assetImage: assetImage,
            isEnabled: available,
            isSelected: store.routingMode == .direct && store.selectedModelID == model.id,
            action: { store.selectModel(model.id) }
        )
    }

    private var effortRow: some View {
        DesktopAdvancedMenuRow(
            title: "Effort",
            value: isAutoRouteSelected
                ? (store.autoRouterAllowsUltraReasoning ? "Ultra allowed" : "Ultra disallowed")
                : (store.routingMode.isFamilyAuto ? "Auto" : store.reasoningDisplayName),
            valueTint: !isAutoRouteSelected && isPeakSelected
                ? SliderPickerPalette.peakText(colorScheme, usesBlueTheme: store.selectedModel?.usesAstraBluePickerStyle == true)
                : nil,
            isEnabled: canEditAutoRoute || (!isAutoRouteSelected && !reasoningOptions.isEmpty),
            header: "Effort",
            items: { effortMenuItems }
        )
    }

    private var effortMenuItems: [DesktopMenuItemSpec] {
        if isAutoRouteSelected {
            return [
                DesktopMenuItemSpec(
                    title: "Disallow Ultra",
                    subtitle: "Auto will never select Ultra reasoning.",
                    isSelected: !store.autoRouterAllowsUltraReasoning,
                    action: { store.autoRouterAllowsUltraReasoning = false }
                ),
                DesktopMenuItemSpec(
                    title: "Allow Ultra",
                    subtitle: "Auto may select Ultra for the rare tasks that need it.",
                    isSelected: store.autoRouterAllowsUltraReasoning,
                    action: { store.autoRouterAllowsUltraReasoning = true }
                ),
            ]
        }
        return reasoningOptions.map { option in
            DesktopMenuItemSpec(
                title: option.title,
                subtitle: option.id.caseInsensitiveCompare("ultra") == .orderedSame
                    ? (option.description.isEmpty
                        ? "Maximum reasoning with automatic task delegation."
                        : option.description)
                    : "",
                isSelected: store.selectedReasoningEffort == option.id,
                action: { store.selectReasoningEffort(option.id) }
            )
        }
    }

    private var compactSpeedButton: some View {
        SliderPickerQuietButton {
            if speedChoices.contains(where: { $0.kind == .ultrafast }) {
                speedMenuAnchor.present(header: nil, items: { speedMenuItems })
            } else if let next = speedChoices.first(where: { $0.kind == (isFastModeEnabled ? .standard : .fast) }) {
                store.selectServiceTier(next.tierID)
            }
        } label: {
            Group {
                if isUltraFastModeEnabled {
                    UltrafastBoltPair(fontSize: 12)
                } else {
                    Image(systemName: isFastModeEnabled ? "bolt.fill" : "bolt")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            isFastModeEnabled
                                ? (isPeakSelected
                                    ? SliderPickerPalette.peakText(colorScheme, usesBlueTheme: store.selectedModel?.usesAstraBluePickerStyle == true)
                                    : Color(red: 0.11, green: 0.40, blue: 0.85))
                                : Color.secondary
                        )
                }
            }
            .frame(width: 16, height: 16)
        }
        .background(DesktopMenuAnchorView(anchor: speedMenuAnchor))
        .help(speedChoices.contains(where: { $0.kind == .ultrafast })
            ? "Choose Standard, Fast Mode, or Ultrafast"
            : (isFastModeEnabled ? "Turn off Fast Mode" : "Turn on Fast Mode"))
        .accessibilityLabel("Speed")
        .accessibilityValue(speedTitle)
    }

    private var speedRow: some View {
        DesktopAdvancedMenuRow(
            title: "Speed",
            value: speedTitle,
            valueTint: !isAutoRouteSelected && isUltraFastModeEnabled ? SliderPickerPalette.ultrafastText(colorScheme) : nil,
            isEnabled: canEditAutoRoute || (!isAutoRouteSelected && !speedChoices.isEmpty),
            header: "Speed",
            items: { speedMenuItems }
        )
    }

    private var speedMenuItems: [DesktopMenuItemSpec] {
        if isAutoRouteSelected {
            return [
                DesktopMenuItemSpec(
                    title: "Disallow",
                    subtitle: "Auto will not choose Fast or Ultrafast routes.",
                    isSelected: store.displayedAutoSpeedPolicy == .disallow,
                    action: { store.autoSpeedPolicy = .disallow }
                ),
                DesktopMenuItemSpec(
                    title: "Allow",
                    subtitle: "Auto may spend more usage for speed when it helps.",
                    isSelected: store.displayedAutoSpeedPolicy == .allow,
                    action: { store.autoSpeedPolicy = .allow }
                ),
            ]
        }
        return speedChoices.map { speed in
            DesktopMenuItemSpec(
                title: speed.title,
                systemImage: speed.systemImage,
                subtitle: speed.detail,
                isSelected: speed.isSelected(in: store),
                usesUltrafastBolts: speed.kind == .ultrafast,
                action: { store.selectServiceTier(speed.tierID) }
            )
        }
    }

    private func handleEscape() {
        if page == .advanced {
            setPage(.compact)
        } else {
            dismiss()
        }
    }

    private func setPage(_ next: Page) {
        isSliderEngaged = false
        if reduceMotion {
            page = next
        } else {
            withAnimation(.easeInOut(duration: 0.16)) { page = next }
        }
    }

    private func resetCurrentModelControls() {
        guard let model = store.selectedModel else { return }
        store.selectReasoningEffort(model.defaultReasoningEffort)
        store.selectServiceTier(model.defaultServiceTier)
        store.selectContextChoice(.default)
    }
}

// MARK: - Advanced rows

/// A full-width row whose entire surface is the button that opens the row's menu.
/// The label is the button's own content, so there is no transparent overlay to
/// hit-test against.
private struct DesktopAdvancedMenuRow: View {
    let title: String
    let value: String
    var valueTint: Color?
    let isEnabled: Bool
    let header: String?
    /// Built on click, not on every render — the specs carry capture-heavy closures.
    let items: () -> [DesktopMenuItemSpec]

    @State private var isHovered = false
    @StateObject private var anchor = DesktopMenuAnchor()

    var body: some View {
        Button {
            anchor.present(header: header, items: items)
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))

                Spacer(minLength: 8)

                Text(value)
                    .foregroundStyle(valueTint ?? (isHovered ? Color.primary : Color.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 8)
            }
            .font(.system(size: SliderPickerMetrics.labelSize))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: SliderPickerMetrics.rowHeight)
            .background(
                isHovered && isEnabled ? Color.primary.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .background(DesktopMenuAnchorView(anchor: anchor))
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("Opens the \(title.lowercased()) options")
    }
}

private struct DesktopMenuItemSpec {
    var title: String
    var systemImage: String? = nil
    var assetImage: String? = nil
    var subtitle: String = ""
    var isEnabled: Bool = true
    var isSelected: Bool = false
    var isSeparator: Bool = false
    var usesUltrafastBolts: Bool = false
    enum Visibility { case always, manual, automatic }
    enum ToggleKind: Equatable { case auto, daybreak }
    var visibility: Visibility = .always
    var toggleValue: Bool? = nil
    var toggleKind: ToggleKind? = nil
    var toggleAction: ((Bool) -> Void)? = nil
    var action: () -> Void = {}

    static var separator: DesktopMenuItemSpec {
        DesktopMenuItemSpec(title: "", isSeparator: true)
    }
}

/// Narrow AppKit bridge: SwiftUI cannot draw a menu outside the popover it lives
/// in, and `Menu` cannot show a secondary description line, so the row's options
/// are presented as a real `NSMenu` hung off the row's trailing edge.
private final class DesktopMenuAnchor: NSObject, ObservableObject {
    weak var view: NSView?
    private var actions: [() -> Void] = []

    func present(header: String?, items makeItems: @escaping () -> [DesktopMenuItemSpec]) {
        let items = makeItems()
        guard let view, !items.isEmpty else { return }

        actions = []
        let menu = NSMenu()
        menu.autoenablesItems = false

        if let header, !header.isEmpty {
            menu.addItem(.sectionHeader(title: header))
        }

        let headerCount = menu.items.count
        for spec in items {
            guard !spec.isSeparator else {
                menu.addItem(.separator())
                continue
            }

            let item = NSMenuItem(
                title: spec.title,
                action: #selector(handleMenuSelection(_:)),
                keyEquivalent: ""
            )
            if spec.usesUltrafastBolts {
                item.image = Self.ultrafastMenuImage
            } else if let assetImage = spec.assetImage, let named = NSImage(named: assetImage) {
                let image = named.copy() as? NSImage ?? named
                image.size = NSSize(width: 14, height: 14)
                image.isTemplate = true
                item.image = image
            } else {
                item.image = spec.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            }
            item.target = self
            item.tag = actions.count
            if let enabled = spec.toggleValue, let kind = spec.toggleKind {
                item.view = DesktopModelMenuToggle(
                    title: spec.title,
                    systemImage: spec.systemImage ?? "",
                    accessibilityLabel: kind == .auto ? "Auto model selection" : "Daybreak",
                    enabled: enabled,
                    available: spec.isEnabled
                ) { [weak self, weak menu] enabled in
                    spec.toggleAction?(enabled)
                    guard let self, let menu else { return }
                    self.updateMenu(menu, specs: makeItems(), headerCount: headerCount)
                }
            }
            actions.append(spec.action)
            menu.addItem(item)
        }

        let rowOnScreen = view.window?.convertToScreen(view.convert(view.bounds, to: nil))
        updateMenu(menu, specs: items, headerCount: headerCount)
        let menuHeight = menu.size.height

        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            guard let rowOnScreen, let screen = view.window?.screen ?? NSScreen.main else {
                menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX + 10, y: view.bounds.midY), in: view)
                return
            }

            let visible = screen.visibleFrame
            var origin = NSPoint(x: rowOnScreen.maxX + 8, y: rowOnScreen.maxY + 6)
            origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - menu.size.width - 8))
            origin.y = min(max(origin.y, visible.minY + menuHeight + 8), visible.maxY - 8)
            menu.popUp(positioning: nil, at: origin, in: nil)
        }
    }

    private func updateMenu(_ menu: NSMenu, specs: [DesktopMenuItemSpec], headerCount: Int) {
        let rows = menu.items.dropFirst(headerCount)
        guard rows.count == specs.count else { return }
        let autoEnabled = specs.first(where: { $0.toggleKind == .auto })?.toggleValue ?? false
        for (row, spec) in zip(rows, specs) {
            let isHidden = spec.visibility == .manual ? autoEnabled : spec.visibility == .automatic ? !autoEnabled : false
            if row.isHidden != isHidden { row.isHidden = isHidden }
            guard !spec.isSeparator else { continue }

            if row.isEnabled != spec.isEnabled { row.isEnabled = spec.isEnabled }
            let state: NSControl.StateValue = spec.isSelected ? .on : .off
            if row.state != state { row.state = state }
            if spec.subtitle.isEmpty {
                if row.attributedTitle != nil { row.attributedTitle = nil }
                if row.title != spec.title { row.title = spec.title }
            } else {
                let title = Self.attributedTitle(spec.title, subtitle: spec.subtitle, isEnabled: spec.isEnabled)
                if row.attributedTitle != title { row.attributedTitle = title }
            }
            let toolTip = spec.subtitle.isEmpty ? nil : spec.subtitle
            if row.toolTip != toolTip { row.toolTip = toolTip }
            if let toggle = row.view as? DesktopModelMenuToggle, let value = spec.toggleValue {
                toggle.update(enabled: value, available: spec.isEnabled)
            }
            if actions.indices.contains(row.tag) { actions[row.tag] = spec.action }
        }
    }

    private static var ultrafastMenuImage: NSImage? {
        let tint = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(SliderPickerPalette.ultrafastText(dark ? .dark : .light))
        }
        guard let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [tint])) else { return nil }
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            for x in [CGFloat(0), 5] {
                symbol.draw(in: NSRect(x: x, y: 1, width: 13, height: 14))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func handleMenuSelection(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    private static func attributedTitle(_ title: String, subtitle: String, isEnabled: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
                .paragraphStyle: paragraph,
            ]
        )
        result.append(
            NSAttributedString(
                string: "\n" + subtitle,
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor,
                    .paragraphStyle: paragraph,
                ]
            )
        )
        return result
    }
}

private struct DesktopMenuAnchorView: NSViewRepresentable {
    let anchor: DesktopMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    /// Never takes a click; it only exists so the menu has a coordinate space.
    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isOpaque: Bool { false }
    }
}

// MARK: - Reasoning slider

private struct DesktopReasoningSlider: View {
    let options: [DesktopReasoningOption]
    let selectedIndex: Int
    let usesBlueTheme: Bool
    let isFastModeEnabled: Bool
    @Binding var isEngaged: Bool
    /// Stop the pointer is currently over, before it is committed to the store.
    @Binding var previewIndex: Int?
    let onSelect: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var usesKeyboard = false

    private var stopCount: Int { max(options.count, 1) }

    /// Committing every stop the pointer crosses republishes the whole workspace
    /// and fires a `thread/settings/update` per step, which is what made dragging
    /// stutter. The drag renders from this preview and commits once, on release.
    private var activeIndex: Int {
        min(max(previewIndex ?? selectedIndex, 0), stopCount - 1)
    }

    private var isDragging: Bool { previewIndex != nil }
    private var isPeak: Bool { stopCount > 1 && activeIndex == stopCount - 1 }

    private var currentTitle: String {
        options.indices.contains(activeIndex) ? options[activeIndex].title : "Default"
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let radius = SliderPickerMetrics.knobDiameter / 2
            let travel = max(width - SliderPickerMetrics.knobDiameter, 1)
            let step = travel / CGFloat(max(stopCount - 1, 1))
            let knobX = radius + step * CGFloat(activeIndex)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(SliderPickerPalette.track)
                    .frame(height: SliderPickerMetrics.trackHeight)

                Capsule()
                    .fill(SliderPickerPalette.fill(isPeak: isPeak, usesBlueTheme: usesBlueTheme))
                    .frame(width: width, height: SliderPickerMetrics.trackHeight)
                    .overlay {
                        if isPeak {
                            DesktopSliderStarfield(
                                size: CGSize(width: width, height: SliderPickerMetrics.trackHeight),
                                usesBlueTheme: usesBlueTheme,
                                isFastModeEnabled: isFastModeEnabled
                            )
                        }
                    }
                    .mask(alignment: .leading) {
                        Capsule()
                            .frame(width: knobX, height: SliderPickerMetrics.trackHeight)
                    }

                ForEach(options.indices, id: \.self) { index in
                    let reached = index < activeIndex
                    if index != activeIndex, reached ? isEngaged : true {
                        Circle()
                            .fill(reached ? SliderPickerPalette.reachedTick : SliderPickerPalette.unreachedTick)
                            .frame(width: 3, height: 3)
                            .position(x: radius + step * CGFloat(index), y: SliderPickerMetrics.knobDiameter / 2)
                    }
                }

                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: 2.5, y: 1)
                    .frame(width: SliderPickerMetrics.knobDiameter, height: SliderPickerMetrics.knobDiameter)
                    .offset(x: knobX - radius)
            }
            .frame(width: width, height: SliderPickerMetrics.knobDiameter)
            .overlay {
                if isFocused, usesKeyboard {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.32), lineWidth: 2)
                        .frame(height: SliderPickerMetrics.trackHeight + 5)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        usesKeyboard = false
                        previewIndex = stop(at: value.location.x, radius: radius, step: step)
                    }
                    .onEnded { value in
                        let index = stop(at: value.location.x, radius: radius, step: step)
                        previewIndex = nil
                        guard index != selectedIndex else { return }
                        onSelect(index)
                    }
            )
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.85), value: activeIndex)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isPeak)
        }
        .onHover { isHovered = $0 }
        .onChange(of: isHovered) { updateEngaged() }
        .onChange(of: isDragging) { updateEngaged() }
        .onDisappear { previewIndex = nil }
        .onAppear {
            // Keep the slider the picker's first responder so the arrow keys work
            // as soon as the panel opens, or comes back from Advanced.
            DispatchQueue.main.async { isFocused = true }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { usesKeyboard = true; move(-1); return .handled }
        .onKeyPress(.rightArrow) { usesKeyboard = true; move(1); return .handled }
        .help("Drag left for faster answers, right for more reasoning.")
        .accessibilityElement()
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(currentTitle)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
    }

    private func updateEngaged() {
        let engaged = isHovered || isDragging
        guard engaged != isEngaged else { return }
        isEngaged = engaged
    }

    private func stop(at x: CGFloat, radius: CGFloat, step: CGFloat) -> Int {
        guard stopCount > 1 else { return 0 }
        let raw = (x - radius) / max(step, 0.001)
        return min(max(Int(raw.rounded()), 0), stopCount - 1)
    }

    private func move(_ delta: Int) {
        let index = min(max(activeIndex + delta, 0), stopCount - 1)
        guard index != selectedIndex else { return }
        previewIndex = nil
        onSelect(index)
    }
}

/// The faint starfield the reference paints into the fill at its top stop.
/// One `Canvas` rather than a stack of shapes, so the animating fill mask does not
/// drag a dozen views through layout on every frame.
private struct DesktopSliderStarfield: View {
    let size: CGSize
    let usesBlueTheme: Bool
    let isFastModeEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phaseOrigin = Date.now
    @State private var accumulatedTravel: CGFloat = 0

    // Points per second: about 50 seconds across the track, or 17 in Fast Mode.
    private func speed(fast: Bool) -> CGFloat { fast ? 12 : 4 }

    private func travel(at date: Date) -> CGFloat {
        accumulatedTravel + (reduceMotion ? 0 : CGFloat(date.timeIntervalSince(phaseOrigin)) * speed(fast: isFastModeEnabled))
    }

    private static let stars: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
        (0.06, 0.34, 1.6, 0.55), (0.11, 0.68, 1.1, 0.34), (0.18, 0.24, 1.3, 0.42),
        (0.24, 0.72, 2.0, 0.62), (0.30, 0.44, 1.2, 0.30), (0.37, 0.20, 1.7, 0.50),
        (0.43, 0.66, 1.3, 0.38), (0.49, 0.36, 2.1, 0.66), (0.55, 0.76, 1.2, 0.32),
        (0.61, 0.28, 1.5, 0.46), (0.67, 0.58, 1.1, 0.30), (0.73, 0.38, 1.9, 0.58),
        (0.79, 0.70, 1.3, 0.36), (0.86, 0.30, 1.5, 0.44), (0.93, 0.60, 1.2, 0.32),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
                let period = canvasSize.width + 8
                let offset = travel(at: timeline.date).truncatingRemainder(dividingBy: period)
                for star in Self.stars {
                    let x = (star.x * period + offset).truncatingRemainder(dividingBy: period) - 4
                    let rect = CGRect(
                        x: x - star.size / 2,
                        y: star.y * canvasSize.height - star.size / 2,
                        width: star.size,
                        height: star.size
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(star.opacity)))
                    if star.size >= 1.9 {
                        let center = CGPoint(x: rect.midX, y: rect.midY)
                        context.fill(Path(ellipseIn: rect.insetBy(dx: -2.5, dy: -2.5)), with: .radialGradient(
                            Gradient(colors: [(usesBlueTheme ? Color.cyan : Color.purple).opacity(0.65), .clear]),
                            center: center, startRadius: 0, endRadius: 4
                        ))
                        var rays = Path()
                        rays.move(to: CGPoint(x: center.x - 3.5, y: center.y))
                        rays.addLine(to: CGPoint(x: center.x + 3.5, y: center.y))
                        rays.move(to: CGPoint(x: center.x, y: center.y - 4))
                        rays.addLine(to: CGPoint(x: center.x, y: center.y + 4))
                        context.stroke(rays, with: .color(.white.opacity(0.85)), lineWidth: 0.6)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .onChange(of: isFastModeEnabled) { oldValue, _ in
            let now = Date.now
            if !reduceMotion {
                accumulatedTravel += CGFloat(now.timeIntervalSince(phaseOrigin)) * speed(fast: oldValue)
            }
            phaseOrigin = now
        }
        .onChange(of: reduceMotion) { oldValue, _ in
            let now = Date.now
            if !oldValue {
                accumulatedTravel += CGFloat(now.timeIntervalSince(phaseOrigin)) * speed(fast: isFastModeEnabled)
            }
            phaseOrigin = now
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
    }
}

private struct DesktopAutoSpeedPermissionIndicator: View {
    let policy: DesktopAutoSpeedPolicy

    private var markerColor: Color {
        policy == .allow ? .green : .red
    }

    private var markerSymbol: String {
        policy == .allow ? "checkmark" : "xmark"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.yellow)

            ZStack {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 8, height: 8)
                Image(systemName: markerSymbol)
                    .font(.system(size: 6, weight: .black))
                    .foregroundStyle(markerColor)
            }
            .offset(x: 3, y: 2)
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}

private struct DesktopPickerSpeed: Identifiable {
    enum Kind: String {
        case standard, fast, ultrafast
    }

    let kind: Kind
    let tier: DesktopModelServiceTier?

    var id: Kind { kind }
    var tierID: String? { tier?.id }

    var title: String {
        switch kind {
        case .standard: "Standard"
        case .fast: "Fast Mode"
        case .ultrafast: "Ultrafast"
        }
    }

    var systemImage: String? {
        switch kind {
        case .standard: nil
        case .fast: "bolt.fill"
        case .ultrafast: nil
        }
    }

    var detail: String {
        if let description = tier?.description, !description.isEmpty { return description }
        switch kind {
        case .standard: return "Default speed"
        case .fast, .ultrafast: return "Faster, uses more of your limits"
        }
    }

    @MainActor
    func isSelected(in store: DesktopCodexStore) -> Bool {
        let selected = store.selectedModelServiceTier
        switch kind {
        case .standard: return selected?.isFastModeTier != true && selected?.isUltrafastTier != true
        case .fast, .ultrafast: return selected?.id == tierID
        }
    }

    static func choices(for model: DesktopModelOption) -> [Self] {
        guard !model.isGPT53CodexSpark,
              model.fastServiceTier != nil || model.ultrafastServiceTier != nil else { return [] }
        var choices = [Self(kind: .standard, tier: model.standardServiceTier)]
        if let fast = model.fastServiceTier { choices.append(Self(kind: .fast, tier: fast)) }
        if let ultrafast = model.ultrafastServiceTier { choices.append(Self(kind: .ultrafast, tier: ultrafast)) }
        return choices
    }
}

private struct UltrafastBoltPair: View {
    let fontSize: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Image(systemName: "bolt.fill")
                .offset(x: -2.5)
            Image(systemName: "bolt.fill")
                .offset(x: 2.5)
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(SliderPickerPalette.ultrafastText(colorScheme))
        .frame(width: fontSize + 4, height: fontSize + 5)
        .accessibilityHidden(true)
    }
}

/// Quiet square-ish button used for the header, the collapse control, and reset.
private struct SliderPickerQuietButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 6)
                .frame(height: SliderPickerMetrics.headerHeight)
                .background(
                    isHovered ? Color.primary.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct DesktopModelStudioPicker: View {
    @Bindable var store: DesktopCodexStore
    let catalog: DesktopModelCatalogPresentation
    @Environment(\.veoAccent) private var veoAccent
    @State private var page: Page = .details

    private enum Page {
        case details
        case modelList
    }

    private var isGPT56Selected: Bool {
        store.routingMode == .auto
            || (store.routingMode == .direct && store.selectedModel.map(catalog.isGPT56) == true)
    }

    private var selectedVariant: DesktopGPT56Variant? {
        store.routingMode == .auto
            ? .auto
            : (store.routingMode == .direct ? store.selectedModel.flatMap(catalog.variant(for:)) : nil)
    }

    var body: some View {
        ScrollView {
            Group {
                switch page {
                case .details:
                    VStack(alignment: .leading, spacing: 0) {
                        DesktopAutoModelRow(store: store)
                        if store.autoModelSelectionEnabled {
                            sectionDivider
                            autoRouterControlsSection
                            sectionDivider
                            DesktopContextControl(store: store, style: .studio)
                        } else {
                            sectionDivider
                            selectedModelSection

                            sectionDivider
                            DesktopContextControl(store: store, style: .studio)

                            if isGPT56Selected, !catalog.variantModels.isEmpty {
                                sectionDivider
                                variantSection
                            }

                            if store.routingMode.isFamilyAuto {
                                sectionDivider
                                autoLaneSection
                            } else if let model = store.selectedModel {
                                sectionDivider
                                reasoningSection(for: model)

                                let speeds = DesktopPickerSpeed.choices(for: model)
                                if !speeds.isEmpty {
                                    sectionDivider
                                    speedSection(speeds)
                                }

                                if model.supportsPersonality {
                                    sectionDivider
                                    personalitySection
                                }

                                if model.availabilityNotice != nil || model.upgrade != nil
                                    || model.modelSpecialty != nil || model.multiAgentVersion != nil {
                                    sectionDivider
                                    richModelDetails(model)
                                }
                            }
                        }

                        if let liveStatus = store.appServer0153.liveSettingsState.label {
                            sectionDivider
                            Label(liveStatus, systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
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

                if !catalog.models.isEmpty {
                    pageButton(systemName: "arrow.right", label: "Show all models") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            page = .modelList
                        }
                    }
                }
            }

            if store.routingMode == .autoGPT6, let familyModel = catalog.preferredGPT6Model {
                StudioSelectionRow(
                    title: "6 Auto",
                    description: familyDescription(fallback: familyModel, family: .gpt6),
                    systemImage: "sparkles",
                    isSelected: true,
                    action: {}
                )
                .accessibilityHint("Veo routes across the GPT-6 family")
            } else if isGPT56Selected, let familyModel = catalog.preferredGPT56Model {
                StudioSelectionRow(
                    title: "5.6",
                    description: familyDescription(fallback: familyModel, family: .gpt56),
                    isSelected: true,
                    action: {}
                )
                .accessibilityHint("Choose a 5.6 variant below")
            } else if let model = store.selectedModel {
                StudioSelectionRow(
                    title: model.userFacingDisplayName,
                    description: model.description,
                    systemImage: catalog.identitySystemImage(for: model),
                    assetImage: catalog.identityAssetImage(for: model),
                    isSelected: true,
                    action: {}
                )
            } else {
                unavailableLabel("No model selected")
            }
        }
    }

    private var autoRouterControlsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Auto options")

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed")
                        .font(.system(size: 12.5, weight: .medium))
                    Text(store.autoSpeedPolicy == .allow
                         ? "May use Fast when worth the extra usage."
                         : "Fast and Ultrafast routes are excluded.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Picker("Auto speed", selection: $store.autoSpeedPolicy) {
                    ForEach(DesktopAutoSpeedPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 146)
                .accessibilityLabel("Allow Auto to use Fast mode")
            }

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Effort")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Ultra remains rare even when allowed.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Toggle("Allow Ultra", isOn: $store.autoRouterAllowsUltraReasoning)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11.5, weight: .medium))
                    .accessibilityLabel("Allow Auto router to pick Ultra reasoning")
            }
        }
        .disabled(store.hasLockedAutoModel)
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

            DesktopAutoModelRow(store: store)
            if !store.autoModelSelectionEnabled {
                ForEach(catalog.recentGPT6Families, id: \.self) { family in
                    if family != catalog.recentGPT6Families.first { sectionDivider }
                    ForEach(catalog.models(in: family)) { model in
                        modelRow(model)
                    }
                }

                if !catalog.gpt6Models.isEmpty {
                    if !catalog.recentGPT6Families.isEmpty { sectionDivider }
                    autoRouteRow(family: .gpt6)
                    ForEach(catalog.gpt6Models) { model in
                        modelRow(model)
                    }
                }

                if catalog.preferredGPT56Model != nil {
                    if !catalog.gpt6Models.isEmpty || !catalog.recentGPT6Families.isEmpty { sectionDivider }
                    autoRouteRow(family: .gpt56)
                    ForEach(catalog.variantModels, id: \.variant) { option in
                        StudioSelectionRow(
                            title: "5.6 \(option.variant.title)",
                            description: store.canSelectModel(option.model) ? option.model.description : "Unavailable while Daybreak is on.",
                            systemImage: option.variant.systemImage,
                            isEnabled: store.canSelectModel(option.model),
                            isSelected: store.routingMode == .direct && store.selectedModelID == option.model.id
                        ) {
                            selectModelAndShowDetails(option.model.id)
                        }
                    }
                }

                if (!catalog.recentGPT6Families.isEmpty || !catalog.gpt6Models.isEmpty || catalog.preferredGPT56Model != nil), !catalog.otherModels.isEmpty {
                    sectionDivider
                }

                ForEach(catalog.otherModels) { model in
                    modelRow(model)
                }
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

            if store.isDaybreakOn {
                ForEach(catalog.variantModels, id: \.variant) { option in
                    let available = store.canSelectModel(option.model)
                    StudioSelectionRow(
                        title: option.variant.title,
                        description: available ? "" : "Unavailable while Daybreak is on.",
                        systemImage: option.variant.systemImage,
                        isEnabled: available,
                        isSelected: selectedVariant == option.variant,
                        action: { store.selectModel(option.model.id) }
                    )
                }
            } else {
                Picker("5.6 variant", selection: variantSelection) {
                    Text(DesktopGPT56Variant.auto.title)
                        .tag(Optional(DesktopGPT56Variant.auto))
                    ForEach(catalog.variantModels, id: \.variant) { option in
                        Text(option.variant.title)
                            .tag(Optional(option.variant))
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("5.6 variant")
            }

            if let description = selectedVariantDescription, !description.isEmpty {
                Text(description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var autoLaneSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Auto lane")

            if let plan = store.resolvedAutoRoutePlan {
                Label(plan.laneSummary, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if plan.isDegraded {
                    ForEach(plan.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Live routing with parent verification and fresh \(plan.reviewer.displayName) review.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label(store.autoRouteErrorMessage ?? "Auto routing is unavailable.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(store.routingMode.autoFamily?.title ?? "Auto route")
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

    private func speedSection(_ speeds: [DesktopPickerSpeed]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Speed")

            ForEach(speeds) { speed in
                StudioSelectionRow(
                    title: speed.title,
                    description: speed.detail,
                    systemImage: speed.systemImage,
                    usesUltrafastBolts: speed.kind == .ultrafast,
                    isSelected: speed.isSelected(in: store)
                ) {
                    store.selectServiceTier(speed.tierID)
                }
            }
        }
    }

    private var personalitySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Personality")
            Picker("Personality", selection: Binding(
                get: { store.selectedPersonality },
                set: { store.selectPersonality($0) }
            )) {
                Text("None").tag("none")
                Text("Friendly").tag("friendly")
                Text("Pragmatic").tag("pragmatic")
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .help("Supported by this model. During a running turn, personality changes apply to the next turn.")
        }
    }

    private func richModelDetails(_ model: DesktopModelOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Model details")
            if let notice = model.availabilityNotice {
                Label(notice, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            if let specialty = model.modelSpecialty {
                Label(specialty, systemImage: "scope").foregroundStyle(.secondary)
            }
            if let version = model.multiAgentVersion, version != "disabled" {
                Label("Multi-agent runtime \(version.uppercased())", systemImage: "person.3").foregroundStyle(.secondary)
            }
            if let upgrade = model.upgrade {
                Label(model.upgradeCopy ?? "Upgrade available: \(upgrade)", systemImage: "arrow.up.circle")
                    .foregroundStyle(.orange)
            }
            let provider = store.appServer0153.modelProviderCapabilities
            if provider.isAvailable {
                let capabilityText = [
                    provider.webSearch ? "Web search" : nil,
                    provider.imageGeneration ? "Image generation" : nil,
                    provider.namespaceTools ? "Namespaced tools" : nil,
                ].compactMap { $0 }.joined(separator: " · ")
                Text(capabilityText.isEmpty ? "No additional provider capabilities reported" : capabilityText)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var variantSelection: Binding<DesktopGPT56Variant?> {
        Binding(
            get: { selectedVariant },
            set: { variant in
                guard let variant else { return }
                if variant == .auto {
                    store.selectAutoRouting()
                    return
                }
                guard let model = catalog.variantModels.first(where: { $0.variant == variant })?.model else {
                    return
                }
                store.selectModel(model.id)
            }
        )
    }

    private var selectedVariantDescription: String? {
        guard let selectedVariant else { return nil }
        if selectedVariant == .auto {
            return store.resolvedAutoRoutePlan?.laneSummary
                ?? "Veo-owned orchestration across the 5.6 family."
        }
        return catalog.variantModels.first(where: { $0.variant == selectedVariant })?.model.description
    }

    private func familyDescription(fallback: DesktopModelOption, family: DesktopAutoRouteFamily) -> String {
        if store.routingMode.autoFamily == family {
            return "Veo coordinates the \(family.productName) family and keeps the exact route visible."
        }
        if family == .gpt56, isGPT56Selected, let selected = store.selectedModel, !selected.description.isEmpty {
            return selected.description
        }
        return fallback.description
    }

    private func reasoningDescription(for option: DesktopReasoningOption) -> String {
        guard option.id.caseInsensitiveCompare("ultra") == .orderedSame else { return "" }
        return option.description.isEmpty
            ? "Maximum reasoning with automatic task delegation."
            : option.description
    }

    private func modelRow(_ model: DesktopModelOption) -> some View {
        let available = store.canSelectModel(model)
        return StudioSelectionRow(
            title: model.userFacingDisplayName,
            description: available ? model.description : "Unavailable while Daybreak is on.",
            systemImage: catalog.identitySystemImage(for: model),
            assetImage: catalog.identityAssetImage(for: model),
            isEnabled: available,
            isSelected: store.selectedModelID == model.id
        ) {
            selectModelAndShowDetails(model.id)
        }
    }

    private func selectModelAndShowDetails(_ modelID: String) {
        store.selectModel(modelID)
        withAnimation(.easeInOut(duration: 0.2)) {
            page = .details
        }
    }

    private func autoRouteRow(family: DesktopAutoRouteFamily) -> some View {
        return StudioSelectionRow(
            title: family.title,
            description: store.isDaybreakOn ? "Turn Daybreak off to use Auto." : "Veo routes across the \(family.productName) family.",
            systemImage: "sparkles",
            isEnabled: !store.isDaybreakOn,
            isSelected: store.routingMode.autoFamily == family
        ) {
            store.selectAutoRouting(family: family)
            withAnimation(.easeInOut(duration: 0.2)) {
                page = .details
            }
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

private struct StudioSelectionRow: View {
    let title: String
    let description: String
    var systemImage: String? = nil
    var assetImage: String? = nil
    var isEnabled: Bool = true
    var usesUltrafastBolts = false
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
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if usesUltrafastBolts {
                            UltrafastBoltPair(fontSize: 11)
                        } else if systemImage == "star.fill" {
                            DesktopGPT56VariantIcon(variant: .astra, fontSize: 12.5)
                        } else if assetImage == DesktopGrokMark.assetName {
                            DesktopGrokMark(fontSize: 12.5)
                        } else if let systemImage {
                            Image(systemName: systemImage)
                        }
                        Text(title)
                    }
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
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(description)
    }
}

private struct DesktopContextControl: View {
    enum Style { case advanced, studio }

    @Bindable var store: DesktopCodexStore
    let style: Style
    @State private var isEditing = false
    @State private var editingModelID: String?
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    private var choice: DesktopContextWindowChoice { store.selectedContextChoice }
    private var limits: DesktopContextWindowLimits? { store.selectedContextLimits }
    private var canChoose: Bool { store.canSelectContextOverride }

    private var unavailableReason: String? {
        if store.autoModelSelectionEnabled || store.hasLockedAutoModel || store.routingMode.isFamilyAuto {
            return "Auto uses model defaults."
        }
        if limits == nil { return "Provider context limit unavailable." }
        return nil
    }

    var body: some View {
        Group {
            switch style {
            case .advanced: advancedControl
            case .studio: studioControl
            }
        }
        .onChange(of: store.selectedModelID) { _, _ in cancelEditing() }
        .onChange(of: fieldFocused) { _, focused in
            if !focused && isEditing { commitCustom() }
        }
    }

    @ViewBuilder
    private var advancedControl: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isEditing {
                HStack(spacing: 8) {
                    Text("Context")
                    Spacer(minLength: 8)
                    inlineField
                        .frame(width: 132)
                }
                .font(.system(size: SliderPickerMetrics.labelSize))
                .padding(.horizontal, 8)
                .frame(height: SliderPickerMetrics.rowHeight)
            } else {
                DesktopAdvancedMenuRow(
                    title: "Context",
                    value: choice.title,
                    isEnabled: store.selectedModel != nil,
                    header: "Context",
                    items: { menuItems }
                )
            }
            if let message = error ?? unavailableReason {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .padding(.horizontal, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var studioControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("CONTEXT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            StudioSelectionRow(
                title: "Default",
                description: limits?.suggested.map { "Model default · \(DesktopContextWindowChoice.formatted($0))" }
                    ?? "Use the model's runtime default",
                isSelected: choice.kind == .default
            ) {
                store.selectContextChoice(.default)
                error = nil
            }

            ForEach(DesktopContextWindowChoice.presets, id: \.tokens) { preset in
                let supported = canChoose && (limits.map { preset.tokens <= $0.maximum } ?? false)
                StudioSelectionRow(
                    title: preset.title,
                    description: presetDescription(for: preset.tokens),
                    isEnabled: supported,
                    isSelected: choice.kind == .preset && choice.tokens == preset.tokens
                ) {
                    store.selectContextChoice(.init(kind: .preset, tokens: preset.tokens))
                    error = nil
                }
            }

            if isEditing {
                HStack(spacing: 7) {
                    Image(systemName: "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Custom")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 8)
                    inlineField
                        .frame(width: 124)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
            } else {
                StudioSelectionRow(
                    title: "Custom",
                    description: choice.kind == .custom ? choice.title : "Enter a token count inline",
                    isEnabled: canChoose,
                    isSelected: choice.kind == .custom
                ) { beginCustom() }
            }

            if let message = error ?? unavailableReason {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .padding(.leading, 5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var inlineField: some View {
        TextField("e.g. 1.25M", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .onSubmit(commitCustom)
            .onKeyPress(.escape) {
                cancelEditing()
                return .handled
            }
            .accessibilityLabel("Custom context window in tokens")
    }

    private var menuItems: [DesktopMenuItemSpec] {
        var items = [DesktopMenuItemSpec(
            title: "Default",
            subtitle: limits?.suggested.map { "Model default · \(DesktopContextWindowChoice.formatted($0))" } ?? "Use the model's runtime default",
            isSelected: choice.kind == .default,
            action: {
                store.selectContextChoice(.default)
                error = nil
            }
        )]
        items += DesktopContextWindowChoice.presets.map { preset in
            DesktopMenuItemSpec(
                title: preset.title,
                subtitle: presetDescription(for: preset.tokens),
                isEnabled: canChoose && (limits.map { preset.tokens <= $0.maximum } ?? false),
                isSelected: choice.kind == .preset && choice.tokens == preset.tokens,
                action: {
                    store.selectContextChoice(.init(kind: .preset, tokens: preset.tokens))
                    error = nil
                }
            )
        }
        items.append(DesktopMenuItemSpec(
            title: "Custom",
            subtitle: "Enter a token count inline",
            isEnabled: canChoose,
            isSelected: choice.kind == .custom,
            action: beginCustom
        ))
        return items
    }

    private func presetDescription(for tokens: Int) -> String {
        if let maximum = limits?.maximum, tokens > maximum {
            return "Above this model's maximum of \(DesktopContextWindowChoice.formatted(maximum))"
        }
        return unavailableReason ?? ""
    }

    private func beginCustom() {
        guard canChoose else { return }
        editingModelID = store.selectedModelID
        draft = choice.kind == .custom ? choice.tokens.map(String.init) ?? "" : ""
        error = nil
        isEditing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitCustom() {
        guard isEditing, editingModelID == store.selectedModelID else { return }
        guard let tokens = DesktopContextWindowChoice.parse(draft) else {
            error = "Enter a positive whole number of tokens, such as 250K or 1.25M."
            fieldFocused = true
            return
        }
        if let maximum = limits?.maximum, tokens > maximum {
            error = "Maximum for this model: \(DesktopContextWindowChoice.formatted(maximum))."
            fieldFocused = true
            return
        }
        guard store.selectContextChoice(.init(kind: .custom, tokens: tokens)) else {
            error = "Context is unavailable for this model."
            fieldFocused = true
            return
        }
        error = nil
        isEditing = false
        fieldFocused = false
    }

    private func cancelEditing() {
        isEditing = false
        fieldFocused = false
        editingModelID = nil
        error = nil
    }
}

private enum DesktopGPT56Variant: String, CaseIterable, Hashable {
    case auto
    case sol
    case terra
    case luna
    case astra

    var title: String { rawValue.capitalized }

    var systemImage: String? {
        switch self {
        case .auto: return nil
        case .luna: return "moon.fill"
        case .terra: return "globe.americas.fill"
        case .sol: return "sun.max.fill"
        case .astra: return "star.fill"
        }
    }
}

/// A compact identity mark for the GPT-5.6 family. Individual variants match
/// the adjacent label's point size; Auto combines all three without displacing
/// the independent Fast Mode indicator that can sit before it in the trigger.
private struct DesktopGPT56VariantIcon: View {
    let variant: DesktopGPT56Variant
    let fontSize: CGFloat

    var body: some View {
        Group {
            if variant == .astra {
                Text(Image(systemName: "star.fill"))
                    .font(.system(size: fontSize, weight: .medium))
            } else if let systemImage = variant.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: fontSize, weight: .medium))
                    .frame(width: fontSize + 1, height: fontSize + 2)
                } else {
                    HStack(spacing: -2.5) {
                    Image(systemName: "sun.max.fill")
                    Image(systemName: "globe.americas.fill")
                    Image(systemName: "moon.fill")
                }
                .font(.system(size: fontSize * 0.62, weight: .semibold))
                .frame(width: fontSize + 6, height: fontSize + 2)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Official Grok product mark (black-hole G), tinted like the GPT-5.6 glyphs.
private struct DesktopGrokMark: View {
    static let assetName = "GrokMark"
    let fontSize: CGFloat

    var body: some View {
        Image(Self.assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: fontSize + 1, height: fontSize + 1)
            .alignmentGuide(.firstTextBaseline) { dimensions in
                dimensions.height * 0.82
            }
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
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

    var recentGPT6Families: [String] {
        DesktopModelOption.pickerFamilyOrder.prefix(2).filter { family in
            models.contains(where: { $0.pickerFamily == family })
        }
    }

    func models(in family: String) -> [DesktopModelOption] {
        models.filter { $0.pickerFamily == family }
    }

    var gpt6Models: [DesktopModelOption] {
        let order: (DesktopModelOption) -> Int = { model in
            if model.isGPT6Astra { return 0 }
            if model.isGPT6Sol { return 1 }
            if model.isGPT6Luna { return 2 }
            return 3
        }
        return models.enumerated()
            .filter { $0.element.pickerFamily == "6" }
            .sorted { lhs, rhs in
                let leftOrder = order(lhs.element)
                let rightOrder = order(rhs.element)
                return leftOrder == rightOrder ? lhs.offset < rhs.offset : leftOrder < rightOrder
            }
            .map(\.element)
    }

    var preferredGPT6Model: DesktopModelOption? {
        gpt6Models.first(where: \.isGPT6Astra) ?? gpt6Models.first
    }

    var otherModels: [DesktopModelOption] {
        models.filter { $0.pickerFamily == nil }
    }

    var variantModels: [VariantModel] {
        DesktopGPT56Variant.allCases.filter { $0 != .auto }.compactMap { variant in
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
        model.pickerFamily == "5.6"
    }

    func identitySystemImage(for model: DesktopModelOption) -> String? {
        if model.isGrok { return nil }
        if model.isGPT61Sol || model.isGPT6Sol { return "sun.max.fill" }
        if model.isGPT6Luna { return "moon.fill" }
        return variant(for: model)?.systemImage
    }

    func identityAssetImage(for model: DesktopModelOption) -> String? {
        model.isGrok ? DesktopGrokMark.assetName : nil
    }

    func variant(for model: DesktopModelOption) -> DesktopGPT56Variant? {
        if model.isGPT6Astra { return .astra }
        guard isGPT56(model) else { return nil }
        let text = modelSearchText(model)
        return DesktopGPT56Variant.allCases
            .filter { $0 != .auto }
            .first(where: { text.contains("-\($0.rawValue)") })
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
