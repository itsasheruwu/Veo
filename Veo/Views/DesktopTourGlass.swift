import SwiftUI

/// Keep the tour's material scoped to its controls, so the workspace can keep its own appearance.
extension View {
    @ViewBuilder
    func tourButtons(primary: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            if primary {
                buttonStyle(.glassProminent).tint(Color(red: 0.07, green: 0.44, blue: 0.95))
                    .buttonBorderShape(.capsule)
                    .overlay {
                        Capsule().fill(LinearGradient(colors: [.white.opacity(0.19), .clear, .black.opacity(0.13)],
                                                       startPoint: .top, endPoint: .bottom))
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
            } else {
                buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        } else {
            modifier(TourMaterialButtonStyle(primary: primary))
        }
        #else
        modifier(TourMaterialButtonStyle(primary: primary))
        #endif
    }

    @ViewBuilder
    func tourControlGroup() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 6) { self }
        } else { self }
        #else
        self
        #endif
    }

    @ViewBuilder
    func tourPanel(radius: CGFloat = 20, tint: Color = .clear) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            glassEffect(.clear.tint(tint), in: shape)
        } else {
            background(.regularMaterial, in: shape).background(tint, in: shape)
        }
        #else
        background(.regularMaterial, in: shape).background(tint, in: shape)
        #endif
    }

    @ViewBuilder
    func tourSheet(_ enabled: Bool = true) -> some View {
        if enabled {
            tourButtons()
                .background { TourSheetBackdrop() }
                .presentationBackground(.clear)
        } else { self }
    }
}

private struct TourSheetBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                // A sheet has its own native window. Give the glass artwork to sample here too.
                Color.clear.overlay { Image("VeoPrism").resizable().scaledToFill().blur(radius: 9) }
                (scheme == .dark ? Color.black.opacity(0.57) : Color.white.opacity(0.85))
                Color.clear.tourPanel(radius: 22, tint: scheme == .dark ? .black.opacity(0.16) : .white.opacity(0.28))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape).accessibilityHidden(true).allowsHitTesting(false)
    }
}

private struct TourMaterialButtonStyle: ViewModifier {
    let primary: Bool
    func body(content: Content) -> some View {
        if primary {
            content.buttonStyle(TourFallbackButton(primary: true))
        } else {
            content.buttonStyle(TourFallbackButton(primary: false))
        }
    }
}


private struct TourFallbackButton: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 11).padding(.vertical, 4)
            .foregroundStyle(primary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                Capsule().fill(.thinMaterial)
                    .overlay { Capsule().fill(primary ? Color.blue.opacity(0.77) : .clear) }
                    .overlay { Capsule().strokeBorder(.primary.opacity(configuration.isPressed ? 0.25 : 0.15)) }
            }
            .brightness(configuration.isPressed ? -0.07 : 0).opacity(enabled ? 1 : 0.48)
            .contentShape(Capsule())
    }
}
