// FILE: DesktopContextWindowUsageView.swift
// Purpose: Shows live context-window usage beside the composer send button.
// Layer: Desktop app view

import SwiftUI

struct DesktopContextWindowUsageView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.veoAccent) private var veoAccent

    let usage: DesktopTokenUsage
    let style: DesktopContextWindowUsageStyle
    let modelName: String
    let isCompacting: Bool

    @State private var isPopoverPresented = false
    @State private var displayedFraction: Double
    @State private var isFinishingCompactionAnimation = false
    @State private var compactionAnimationGeneration = 0

    init(
        usage: DesktopTokenUsage,
        style: DesktopContextWindowUsageStyle,
        modelName: String,
        isCompacting: Bool
    ) {
        self.usage = usage
        self.style = style
        self.modelName = modelName
        self.isCompacting = isCompacting
        _displayedFraction = State(initialValue: usage.fractionUsed ?? 0)
    }

    private var fraction: Double {
        usage.fractionUsed ?? 0
    }

    private var usageColor: Color {
        switch usage.warningLevel {
        case 2: return .red
        case 1: return .orange
        default: return veoAccent
        }
    }

    private var displayedPercent: Int {
        Int((displayedFraction * 100).rounded())
    }

    private var actualPercent: Int {
        Int((fraction * 100).rounded())
    }

    private var showsCompactionSurge: Bool {
        isCompacting || isFinishingCompactionAnimation
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            indicator
                .overlay {
                    if showsCompactionSurge {
                        DesktopContextCompactionSurge(isAnimated: !reduceMotion)
                            .mask(surgeMask)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onChange(of: fraction) { oldFraction, newFraction in
            animateDisplayedFraction(
                to: newFraction,
                isCompactionDrop: showsCompactionSurge || newFraction < oldFraction
            )
        }
        .onChange(of: isCompacting) { _, compacting in
            handleCompactionStateChange(compacting)
        }
        .help(isCompacting ? "Codex is compacting context" : helpText)
        .accessibilityLabel("Context window usage")
        .accessibilityValue(isCompacting ? "Compacting, \(displayedPercent) percent used" : "\(actualPercent) percent used")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            contextPopover
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch style {
        case .percent:
            Text("\(displayedPercent)%")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: displayedFraction))
                .foregroundStyle(usageColor)
                .frame(minWidth: 30, alignment: .trailing)

        case .circle:
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.12), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: displayedFraction)
                    .stroke(
                        usageColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 17, height: 17)

        case .bar:
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.12))
                    Capsule()
                        .fill(usageColor)
                        .frame(width: proxy.size.width * displayedFraction)
                }
            }
            .frame(width: 40, height: 5)
        }
    }

    @ViewBuilder
    private var surgeMask: some View {
        switch style {
        case .percent:
            Text("\(displayedPercent)%")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 30, alignment: .trailing)
        case .circle:
            Circle()
                .stroke(lineWidth: 2.5)
                .frame(width: 17, height: 17)
        case .bar:
            Capsule()
                .frame(width: 40, height: 5)
        }
    }

    private var estimatedAutoCompactLimit: Int? {
        guard let contextWindow = usage.contextWindow else { return nil }
        return Int((Double(contextWindow) * 0.9).rounded(.down))
    }

    private var estimatedTokensUntilCompaction: Int? {
        guard let limit = estimatedAutoCompactLimit else { return nil }
        return max(limit - usage.currentContextTokens, 0)
    }

    private var contextPopover: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: isCompacting ? "arrow.triangle.2.circlepath" : "gauge.with.dots.needle.33percent")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isCompacting ? .blue : usageColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text(isCompacting ? "Compacting context" : "Context window")
                        .font(.system(size: 13, weight: .semibold))
                    Text(modelName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(formattedTokens(usage.currentContextTokens)) of \(formattedTokens(usage.contextWindow ?? 0)) tokens")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(displayedPercent)%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: displayedFraction))
                        .foregroundStyle(usageColor)
                }

                ProgressView(value: displayedFraction)
                    .tint(showsCompactionSurge ? .blue : usageColor)
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text("Until auto-compact")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(compactionCountdownText)
                    .font(.system(size: 11, weight: .semibold))
            }

            Text("Current context reported by Codex. Auto-compact timing can vary by model or configuration.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 286)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context window details")
    }

    private var compactionCountdownText: String {
        if isCompacting { return "Now" }
        guard let remaining = estimatedTokensUntilCompaction else { return "Unavailable" }
        if remaining == 0 { return "Due now" }
        return "About \(formattedTokens(remaining)) tokens"
    }

    private var helpText: String {
        guard let contextWindow = usage.contextWindow else {
            return "Context window: \(formattedTokens(usage.currentContextTokens)) tokens used"
        }
        return "Context window: \(actualPercent)% used (\(formattedTokens(usage.currentContextTokens)) of \(formattedTokens(contextWindow)) tokens)"
    }

    private func animateDisplayedFraction(to newFraction: Double, isCompactionDrop: Bool) {
        guard !reduceMotion else {
            displayedFraction = newFraction
            return
        }
        let duration = isCompactionDrop ? 1.15 : 0.28
        withAnimation(.easeInOut(duration: duration)) {
            displayedFraction = newFraction
        }
    }

    private func handleCompactionStateChange(_ compacting: Bool) {
        compactionAnimationGeneration += 1
        let generation = compactionAnimationGeneration

        if compacting {
            isFinishingCompactionAnimation = false
            return
        }

        isFinishingCompactionAnimation = true
        animateDisplayedFraction(to: fraction, isCompactionDrop: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 1_200))
            guard generation == compactionAnimationGeneration, !isCompacting else { return }
            isFinishingCompactionAnimation = false
        }
    }

    private func formattedTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

private struct DesktopContextCompactionSurge: View {
    let isAnimated: Bool

    @State private var offset: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, .blue.opacity(0.7), .cyan, .blue.opacity(0.9), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(proxy.size.width * 0.7, 18))
            .offset(x: isAnimated ? offset * proxy.size.width : proxy.size.width * 0.15)
            .onAppear {
                guard isAnimated else { return }
                offset = -1
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    offset = 1.35
                }
            }
        }
        .allowsHitTesting(false)
    }
}
