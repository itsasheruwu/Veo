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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isActive, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                let period = 1.55
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                textView
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: Color.primary.opacity(0.28), location: 0),
                                .init(color: Color.primary.opacity(0.55), location: 0.42),
                                .init(color: Color.primary.opacity(0.95), location: 0.5),
                                .init(color: Color.primary.opacity(0.55), location: 0.58),
                                .init(color: Color.primary.opacity(0.28), location: 1),
                            ],
                            startPoint: UnitPoint(x: phase - 0.55, y: 0.5),
                            endPoint: UnitPoint(x: phase + 0.55, y: 0.5)
                        )
                    )
            }
        } else {
            textView
                .foregroundStyle(baseStyle)
        }
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
