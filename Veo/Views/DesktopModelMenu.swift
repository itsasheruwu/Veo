// FILE: DesktopModelMenu.swift
// Purpose: Presents the live Codex model, reasoning, and service-tier catalog.
// Layer: Desktop app view

import AppKit
import SwiftUI

struct DesktopModelMenu: View {
    @ObservedObject var store: DesktopCodexStore
    @AppStorage(DesktopAppearancePreferences.modelPickerAppearanceKey) private var pickerAppearanceRaw =
        DesktopModelPickerAppearance.native.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false
    @State private var isTriggerHovered = false

    private var catalog: DesktopModelCatalogPresentation {
        DesktopModelCatalogPresentation(models: store.models)
    }

    private var selectedVariant: DesktopGPT56Variant? {
        store.routingMode == .auto ? .auto : store.selectedModel.flatMap(catalog.variant(for:))
    }

    private var collapsedModelTitle: String {
        guard let variant = selectedVariant else { return store.modelDisplayName }
        return "GPT-5.6 \(variant.title)"
    }

    private var sliderModelTitle: String {
        guard let variant = selectedVariant else { return store.modelDisplayName }
        return "5.6 \(variant.title)"
    }

    private var pickerAppearance: DesktopModelPickerAppearance {
        DesktopModelPickerAppearance(rawValue: pickerAppearanceRaw) ?? .native
    }

    private var isFastModeEnabled: Bool {
        guard store.routingMode == .direct else { return false }
        guard let model = store.selectedModel,
              let fastTier = model.serviceTiers.first(where: \.isFastModeTier) else {
            return false
        }
        return store.selectedServiceTier == fastTier.id
    }

    private var isSparkModel: Bool {
        store.routingMode == .direct && store.selectedModel?.isGPT53CodexSpark == true
    }

    private var isUltraFastModeEnabled: Bool {
        isSparkModel
    }

    private var speedAccessibilitySuffix: String {
        if isUltraFastModeEnabled { return ", Ultra Fast on" }
        if isFastModeEnabled { return ", Fast Mode on" }
        return ""
    }

    @ViewBuilder
    private var speedIndicator: some View {
        if isFastModeEnabled || isUltraFastModeEnabled {
            if isUltraFastModeEnabled {
                SparkBoltPair(
                    color: SliderPickerPalette.peakText(colorScheme),
                    fontSize: 10
                )
            } else {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.yellow)
            }
        }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            if pickerAppearance == .native {
                ViewThatFits(in: .horizontal) {
                    nativeModelLabel(showsReasoning: store.routingMode == .direct)
                    nativeModelLabel(showsReasoning: false)
                }
            } else {
                sliderModelLabel(showsReasoning: store.routingMode == .direct)
            }
        }
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .disabled(store.models.isEmpty)
        .help(store.routingMode == .auto ? "Veo routes work across the GPT-5.6 family." : (store.selectedModel?.description ?? "Codex model"))
        .accessibilityLabel("Model settings")
        .accessibilityValue(
            store.routingMode == .auto
                ? "GPT-5.6 Auto, Sol High orchestration"
                : "\(collapsedModelTitle), \(store.reasoningDisplayName) reasoning"
                    + speedAccessibilitySuffix
        )
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            if pickerAppearance == .native {
                DesktopModelStudioPicker(store: store, catalog: catalog)
            } else {
                DesktopModelSliderAdvancedPicker(store: store, catalog: catalog)
            }
        }
    }

    private func nativeModelLabel(showsReasoning: Bool) -> some View {
        HStack(spacing: 6) {
            speedIndicator

            Image(systemName: "cube")
                .font(.system(size: 11, weight: .medium))
                .accessibilityHidden(true)

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
            HStack(spacing: 5) {
                speedIndicator

                Text(sliderModelTitle)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .layoutPriority(2)

                if showsReasoning {
                    Text(store.reasoningDisplayName)
                        .foregroundStyle(
                            isPeakReasoningSelected
                                ? SliderPickerPalette.peakText(colorScheme)
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
    /// Blue → violet → magenta ramp shared by the track fill and the peak caption.
    static func fill(isPeak: Bool) -> LinearGradient {
        let stops: [Gradient.Stop] = isPeak
            ? [
                .init(color: Color(red: 0.29, green: 0.35, blue: 0.91), location: 0),
                .init(color: Color(red: 0.55, green: 0.30, blue: 0.98), location: 0.55),
                .init(color: Color(red: 0.76, green: 0.31, blue: 0.94), location: 1),
            ]
            : [
                .init(color: Color(red: 0.07, green: 0.34, blue: 0.77), location: 0),
                .init(color: Color(red: 0.12, green: 0.35, blue: 0.84), location: 0.62),
                .init(color: Color(red: 0.36, green: 0.31, blue: 0.93), location: 1),
            ]
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    static func peakText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.72, green: 0.56, blue: 1.0)
            : Color(red: 0.40, green: 0.13, blue: 0.84)
    }

    static var track: Color { Color.primary.opacity(0.09) }
    static var unreachedTick: Color { Color.primary.opacity(0.28) }
    static var reachedTick: Color { Color.white.opacity(0.38) }
}

private struct DesktopModelSliderAdvancedPicker: View {
    @ObservedObject var store: DesktopCodexStore
    let catalog: DesktopModelCatalogPresentation

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .compact
    @State private var isSliderEngaged = false
    @State private var previewReasoningIndex: Int?

    private enum Page {
        case compact
        case advanced
    }

    private var selectedVariant: DesktopGPT56Variant? {
        store.routingMode == .auto ? .auto : store.selectedModel.flatMap(catalog.variant(for:))
    }

    private var compactModelTitle: String {
        guard let variant = selectedVariant else { return store.modelDisplayName }
        return "5.6 \(variant.title)"
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

    private var fastTier: DesktopModelServiceTier? {
        guard store.routingMode == .direct else { return nil }
        return store.selectedModel?.serviceTiers.first(where: \.isFastModeTier)
    }

    private var isSparkModel: Bool {
        store.routingMode == .direct && store.selectedModel?.isGPT53CodexSpark == true
    }

    private var isFastModeEnabled: Bool {
        guard let fastTier else { return false }
        return store.selectedServiceTier == fastTier.id
    }

    private var isUltraFastModeEnabled: Bool {
        isSparkModel
    }

    private var speedTitle: String {
        guard store.routingMode == .direct else { return "Auto" }
        if isSparkModel { return "Ultrafast" }
        guard let selectedServiceTier = store.selectedServiceTier,
              let tier = store.selectedModel?.serviceTiers.first(where: { $0.id == selectedServiceTier }) else {
            return standardTierName
        }
        return tier.name
    }

    private var standardTierName: String {
        store.selectedModel?.serviceTiers.first(where: { !$0.isFastModeTier })?.name ?? "Standard"
    }

    private var canReset: Bool {
        guard store.routingMode == .direct, let model = store.selectedModel else { return false }
        let effortChanged = (store.selectedReasoningEffort ?? model.defaultReasoningEffort) != model.defaultReasoningEffort
        let tierChanged = store.selectedServiceTier != model.defaultServiceTier
        return effortChanged || tierChanged
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

                if isSparkModel || fastTier != nil {
                    SliderPickerQuietButton {
                        guard !isSparkModel, let fastTier else { return }
                        store.selectServiceTier(isFastModeEnabled ? store.selectedModel?.defaultServiceTier : fastTier.id)
                    } label: {
                        if isSparkModel {
                            SparkBoltPair(
                                color: SliderPickerPalette.peakText(colorScheme),
                                fontSize: 12
                            )
                        } else {
                            Image(systemName: isFastModeEnabled ? "bolt.fill" : "bolt")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(
                                    isFastModeEnabled
                                        ? (isPeakSelected
                                            ? SliderPickerPalette.peakText(colorScheme)
                                            : Color(red: 0.11, green: 0.40, blue: 0.85))
                                        : Color.secondary
                                )
                                .frame(width: 14, height: 16)
                        }
                    }
                    .help(
                        isSparkModel
                            ? "Ultra Fast is always on for 5.3 Spark."
                            : (isFastModeEnabled
                                ? "Turn off Fast Mode"
                                : "Turn on Fast Mode: \(fastTier?.description.isEmpty == false ? fastTier!.description : "faster, uses more of your limits")")
                    )
                    .accessibilityLabel(isSparkModel ? "Ultra Fast" : "Fast Mode")
                    .accessibilityValue(isSparkModel || isFastModeEnabled ? "On" : "Off")
                }
            }
            .opacity(isSliderEngaged ? 0 : 1)

            Group {
                if let peakCaption {
                    Text(peakCaption)
                        .foregroundStyle(SliderPickerPalette.peakText(colorScheme))
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
        if reasoningOptions.count > 1 {
            DesktopReasoningSlider(
                options: reasoningOptions,
                selectedIndex: selectedReasoningIndex,
                isEngaged: $isSliderEngaged,
                previewIndex: $previewReasoningIndex
            ) { index in
                guard reasoningOptions.indices.contains(index) else { return }
                store.selectReasoningEffort(reasoningOptions[index].id)
            }
            .frame(height: SliderPickerMetrics.knobDiameter)
        } else {
            Text(store.routingMode == .auto ? "Auto picks the effort for each turn" : "This model has one effort level")
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
            }
            .frame(height: SliderPickerMetrics.rowHeight)
        }
        .padding(SliderPickerMetrics.rowInset)
    }

    private var modelRow: some View {
        DesktopAdvancedMenuRow(
            title: "Model",
            value: compactModelTitle,
            isEnabled: !store.models.isEmpty,
            header: "Model",
            items: { modelMenuItems }
        )
    }

    private var modelMenuItems: [DesktopMenuItemSpec] {
        var items: [DesktopMenuItemSpec] = []

        if catalog.preferredGPT56Model != nil {
            items.append(
                DesktopMenuItemSpec(
                    title: "5.6 Auto",
                    subtitle: "Veo routes across the GPT-5.6 family",
                    isSelected: store.routingMode == .auto,
                    action: store.selectAutoRouting
                )
            )

            for option in catalog.variantModels {
                items.append(
                    DesktopMenuItemSpec(
                        title: "5.6 \(option.variant.title)",
                        isSelected: store.routingMode == .direct && store.selectedModelID == option.model.id,
                        action: { store.selectModel(option.model.id) }
                    )
                )
            }
        }

        if !catalog.otherModels.isEmpty {
            if !items.isEmpty { items.append(.separator) }
            for model in catalog.otherModels {
                items.append(
                    DesktopMenuItemSpec(
                        title: model.displayName,
                        isSelected: store.routingMode == .direct && store.selectedModelID == model.id,
                        action: { store.selectModel(model.id) }
                    )
                )
            }
        }

        return items
    }

    private var effortRow: some View {
        DesktopAdvancedMenuRow(
            title: "Effort",
            value: store.routingMode == .auto ? "Auto" : store.reasoningDisplayName,
            valueTint: isPeakSelected ? SliderPickerPalette.peakText(colorScheme) : nil,
            isEnabled: !reasoningOptions.isEmpty,
            header: "Effort",
            items: {
                reasoningOptions.map { option in
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
        )
    }

    private var speedRow: some View {
        DesktopAdvancedMenuRow(
            title: "Speed",
            value: speedTitle,
            valueTint: isUltraFastModeEnabled ? SliderPickerPalette.peakText(colorScheme) : nil,
            isEnabled: store.routingMode == .direct && store.selectedModel != nil,
            header: "Speed",
            items: { speedMenuItems }
        )
    }

    private var speedMenuItems: [DesktopMenuItemSpec] {
        let standardTier = store.selectedModel?.serviceTiers.first(where: {
            !$0.isFastModeTier
        })

        if isSparkModel {
            return [
                DesktopMenuItemSpec(
                    title: standardTierName,
                    subtitle: standardTier?.description.isEmpty == false ? standardTier!.description : "Default speed",
                    isEnabled: false
                ),
                DesktopMenuItemSpec(
                    title: "Fast",
                    subtitle: "1.5x speed, increased usage",
                    isEnabled: false
                ),
                DesktopMenuItemSpec(
                    title: "Ultrafast",
                    subtitle: "Up to 14x faster using Cerebras.",
                    isEnabled: false,
                    isSelected: true
                )
            ]
        }

        var items: [DesktopMenuItemSpec] = []

        items.append(
            DesktopMenuItemSpec(
                title: standardTierName,
                subtitle: standardTier?.description.isEmpty == false ? standardTier!.description : "Default speed",
                isSelected: !isFastModeEnabled,
                action: { store.selectServiceTier(store.selectedModel?.defaultServiceTier) }
            )
        )

        if let fastTier {
            items.append(
                DesktopMenuItemSpec(
                    title: fastTier.name,
                    subtitle: fastTier.description.isEmpty ? "Faster, uses more of your limits" : fastTier.description,
                    isSelected: isFastModeEnabled,
                    action: { store.selectServiceTier(fastTier.id) }
                )
            )
        }

        return items
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
            anchor.present(header: header, items: items())
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
    var subtitle: String = ""
    var isEnabled: Bool = true
    var isSelected: Bool = false
    var isSeparator: Bool = false
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

    func present(header: String?, items: [DesktopMenuItemSpec]) {
        guard let view, !items.isEmpty else { return }

        actions = []
        let menu = NSMenu()
        menu.autoenablesItems = false

        if let header, !header.isEmpty {
            menu.addItem(.sectionHeader(title: header))
        }

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
            item.target = self
            item.tag = actions.count
            item.isEnabled = spec.isEnabled
            item.state = spec.isSelected ? .on : .off
            if !spec.subtitle.isEmpty {
                item.attributedTitle = Self.attributedTitle(spec.title, subtitle: spec.subtitle)
            }
            actions.append(spec.action)
            menu.addItem(item)
        }

        let rowOnScreen = view.window?.convertToScreen(view.convert(view.bounds, to: nil))
        let menuHeight = menu.size.height

        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            guard let rowOnScreen, let screen = view.window?.screen ?? NSScreen.main else {
                menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX + 10, y: view.bounds.midY), in: view)
                return
            }

            let visible = screen.visibleFrame
            var origin = NSPoint(x: rowOnScreen.maxX + 8, y: rowOnScreen.maxY + 6)
            origin.y = min(max(origin.y, visible.minY + menuHeight + 8), visible.maxY - 8)
            menu.popUp(positioning: nil, at: origin, in: nil)
        }
    }

    @objc private func handleMenuSelection(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    private static func attributedTitle(_ title: String, subtitle: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        result.append(
            NSAttributedString(
                string: "\n" + subtitle,
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
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
                    .fill(SliderPickerPalette.fill(isPeak: isPeak))
                    .frame(width: width, height: SliderPickerMetrics.trackHeight)
                    .overlay {
                        if isPeak {
                            DesktopSliderStarfield(
                                size: CGSize(width: width, height: SliderPickerMetrics.trackHeight)
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

    private static let stars: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
        (0.06, 0.34, 1.6, 0.55), (0.11, 0.68, 1.1, 0.34), (0.18, 0.24, 1.3, 0.42),
        (0.24, 0.72, 2.0, 0.62), (0.30, 0.44, 1.2, 0.30), (0.37, 0.20, 1.7, 0.50),
        (0.43, 0.66, 1.3, 0.38), (0.49, 0.36, 2.1, 0.66), (0.55, 0.76, 1.2, 0.32),
        (0.61, 0.28, 1.5, 0.46), (0.67, 0.58, 1.1, 0.30), (0.73, 0.38, 1.9, 0.58),
        (0.79, 0.70, 1.3, 0.36), (0.86, 0.30, 1.5, 0.44), (0.93, 0.60, 1.2, 0.32),
    ]

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
            for star in Self.stars {
                let rect = CGRect(
                    x: star.x * canvasSize.width - star.size / 2,
                    y: star.y * canvasSize.height - star.size / 2,
                    width: star.size,
                    height: star.size
                )
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(star.opacity)))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(Capsule())
        .allowsHitTesting(false)
    }
}

/// Spark's speed treatment is intentionally a visual composite. It does not
/// represent a service tier or alter the model payload.
private struct SparkBoltPair: View {
    let color: Color
    let fontSize: CGFloat

    var body: some View {
        ZStack {
            Image(systemName: "bolt.fill")
                .offset(x: -1.5)
            Image(systemName: "bolt.fill")
                .offset(x: 1.5)
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(color)
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
    @ObservedObject var store: DesktopCodexStore
    let catalog: DesktopModelCatalogPresentation
    @Environment(\.veoAccent) private var veoAccent
    @State private var page: Page = .details

    private enum Page {
        case details
        case modelList
    }

    private var isGPT56Selected: Bool {
        store.routingMode == .auto || store.selectedModel.map(catalog.isGPT56) == true
    }

    private var selectedVariant: DesktopGPT56Variant? {
        store.routingMode == .auto ? .auto : store.selectedModel.flatMap(catalog.variant(for:))
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

                        if store.routingMode == .auto {
                            sectionDivider
                            autoLaneSection
                        } else if let model = store.selectedModel {
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
                    title: model.userFacingDisplayName,
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
                    Text("Live routing with parent verification and fresh Sol review.")
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
        .accessibilityLabel("GPT-5.6 Auto route")
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
            return "Veo-owned orchestration: Sol leads, workers implement, the parent verifies, and fresh Sol review gates code changes."
        }
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
        if store.routingMode == .auto {
            return "Veo coordinates the GPT-5.6 family and keeps the exact route visible."
        }
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
            title: model.userFacingDisplayName,
            description: model.description,
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
        [id, name].contains { value in
            let normalized = value.lowercased()
                .replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            return normalized == "fast" || normalized == "fast-mode"
        }
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
    case auto
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
        modelSearchText(model).contains("gpt-5.6")
    }

    func variant(for model: DesktopModelOption) -> DesktopGPT56Variant? {
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
