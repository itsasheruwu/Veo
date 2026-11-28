import SwiftUI

enum DesktopComposerPickerKind: Equatable {
    case model, permissions
}

@MainActor
@Observable
final class DesktopComposerPickerGroup {
    var active: DesktopComposerPickerKind?
}

private struct DesktopComposerPickerGroupKey: EnvironmentKey {
    static let defaultValue: DesktopComposerPickerGroup? = nil
}

extension EnvironmentValues {
    var desktopComposerPickerGroup: DesktopComposerPickerGroup? {
        get { self[DesktopComposerPickerGroupKey.self] }
        set { self[DesktopComposerPickerGroupKey.self] = newValue }
    }
}

struct DesktopComposerPickerPill<Value: Equatable, Label: View>: View {
    @Environment(\.desktopComposerPickerGroup) private var group
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heldValue: Value?
    @State private var face = DesktopComposerPillFace.Front.label
    @State private var hovered = false
    @State private var transition: Task<Void, Never>?

    let kind: DesktopComposerPickerKind
    let value: Value
    @Binding var isOpen: Bool
    var tint: (Value) -> Color = { _ in .primary }
    var spokenValue: (Value) -> String
    @ViewBuilder var label: (Value) -> Label

    var body: some View {
        let displayed = heldValue ?? value
        Button {
            if !isOpen {
                heldValue = heldValue ?? value
                group?.active = kind
            }
            isOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                label(displayed)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(tint(displayed))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .modifier(DesktopComposerPillFace(front: reduceMotion ? (isOpen ? .obscured : .label) : face))
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(.quaternary, in: Capsule())
            .overlay { Capsule().fill(Color.primary.opacity(hovered ? 0.04 : 0)).allowsHitTesting(false) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(spokenValue(displayed))
        .onHover { hovered = $0 }
        .onChange(of: group?.active, initial: true) { _, active in
            if active != nil, heldValue == nil { heldValue = value }
            if active == nil, !isOpen, transition == nil { heldValue = nil }
        }
        .onChange(of: isOpen) { _, opened in
            if opened {
                heldValue = heldValue ?? value
                group?.active = kind
            }
            flip(opened: opened)
        }
        .onDisappear {
            transition?.cancel()
            transition = nil
            if group?.active == kind { group?.active = nil }
        }
    }

    private func flip(opened: Bool) {
        transition?.cancel()
        transition = nil
        if reduceMotion {
            finishFlip(opened: opened)
            return
        }
        face = .edge
        transition = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(105)) }
            catch { return }
            guard isOpen == opened else { return }
            if opened { finishFlip(opened: true) }
            else { withAnimation(.easeOut(duration: 0.18)) { finishFlip(opened: false) } }
        }
    }

    private func finishFlip(opened: Bool) {
        transition = nil
        face = opened ? .obscured : .label
        guard !opened else { return }
        if group?.active == kind { group?.active = nil }
        if group?.active == nil { heldValue = nil }
    }
}

private struct DesktopComposerPillFace: ViewModifier {
    enum Front { case label, edge, obscured }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var front: Front

    func body(content: Content) -> some View {
        content
            .blur(radius: front == .label ? 0 : 7)
            .scaleEffect(x: 1, y: front == .label ? 1 : 0.06)
            .opacity(front == .label ? 1 : 0)
            .overlay {
                Capsule()
                    .fill(.primary.opacity(0.40))
                    .padding(.horizontal, 1)
                    .padding(.vertical, 3)
                    .blur(radius: 4)
                    .scaleEffect(x: 1, y: front == .obscured ? 1 : 0.06)
                    .opacity(front == .obscured ? 1 : 0)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : animation, value: front)
    }

    private var animation: Animation {
        switch front {
        case .edge: .easeIn(duration: 0.105)
        case .obscured: .easeOut(duration: 0.135)
        case .label: .easeOut(duration: 0.18)
        }
    }
}
