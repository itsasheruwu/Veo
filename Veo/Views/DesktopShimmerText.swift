// FILE: DesktopShimmerText.swift
// Purpose: Animated text shimmer for active thinking / mid-turn labels.
// Layer: Desktop app view
// Depends on: SwiftUI

import SwiftUI

struct DesktopShimmerText: View {
    let text: String
    var font: Font = .body
    var weight: Font.Weight? = nil
    var baseStyle: AnyShapeStyle = AnyShapeStyle(.secondary)
    var isActive = true

    var body: some View {
        textView.modifier(DesktopShimmerStyle(baseStyle: baseStyle, isActive: isActive))
    }

    private var textView: Text {
        var value = Text(text)
            .font(font)
        if let weight {
            value = value.fontWeight(weight)
        }
        return value
    }
}

struct DesktopShimmerStyle: ViewModifier {
    var baseStyle: AnyShapeStyle = AnyShapeStyle(.secondary)
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isActive, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let period = 1.8
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                let center = phase * 1.5 - 0.25
                content.foregroundStyle(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.58), Color.primary, Color.primary.opacity(0.58)],
                        startPoint: UnitPoint(x: center - 0.22, y: 0.5),
                        endPoint: UnitPoint(x: center + 0.22, y: 0.5)
                    )
                )
            }
        } else {
            content.foregroundStyle(baseStyle)
        }
    }
}
