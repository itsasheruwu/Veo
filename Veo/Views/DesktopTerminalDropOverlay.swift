// FILE: DesktopTerminalDropOverlay.swift
// Purpose: Blur overlay and animated upload glyph shown while dragging onto a terminal.
// Layer: Desktop app view

import SwiftUI

struct DesktopTerminalDropOverlay: View {
    var isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.veoAccent) private var veoAccent

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Rectangle()
                .fill(Color.black.opacity(0.28))

            VStack(spacing: 12) {
                DesktopTerminalDropUploadGlyph(
                    isAnimating: isActive && !reduceMotion,
                    accent: veoAccent
                )
                Text("Drop to insert")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.92))
            }
            .scaleEffect(isActive ? 1 : 0.88)
            .opacity(isActive ? 1 : 0)
        }
        .compositingGroup()
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DesktopTerminalDropUploadGlyph: View {
    var isAnimating: Bool
    var accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.16))
                .frame(width: 76, height: 76)
                .scaleEffect(isAnimating ? 1 : 0.94)

            Circle()
                .strokeBorder(accent.opacity(0.5), lineWidth: 1)
                .frame(width: 76, height: 76)

            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(accent)
                .modifier(DesktopTerminalDropUploadMotion(isAnimating: isAnimating))
        }
    }

}

private struct DesktopTerminalDropUploadMotion: ViewModifier {
    var isAnimating: Bool

    func body(content: Content) -> some View {
        if isAnimating {
            content.phaseAnimator(UploadPhase.allCases) { view, phase in
                view
                    .offset(y: phase.offset)
                    .scaleEffect(phase.scale)
            } animation: { phase in
                switch phase {
                case .rest: .easeInOut(duration: 0.55)
                case .lift: .easeOut(duration: 0.4)
                case .peak: .easeIn(duration: 0.42)
                }
            }
        } else {
            content
        }
    }

    private enum UploadPhase: CaseIterable {
        case rest, lift, peak

        var offset: CGFloat {
            switch self {
            case .rest: 3
            case .lift: -5
            case .peak: -8
            }
        }

        var scale: CGFloat {
            switch self {
            case .rest: 0.96
            case .lift: 1.08
            case .peak: 1.02
            }
        }
    }
}
