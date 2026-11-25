import SwiftUI

struct DesktopComposerPermissionsPicker: View {
    @Environment(\.veoAccent) private var accent
    @State private var isPresented = false
    let store: DesktopCodexStore

    private var mode: DesktopAccessMode { store.accessMode }

    var body: some View {
        DesktopComposerPickerPill(kind: .permissions, value: mode, isOpen: $isPresented,
                                  tint: { $0 == .fullAccess ? .orange : .primary },
                                  spokenValue: { $0.title }) { selected in
            Image(systemName: selected.symbolName).font(.system(size: 11, weight: .medium))
            Text(selected.title)
        }
        .accessibilityLabel("Permissions")
        .help(store.activeAgent == nil ? mode.detail : "This provider manages its own permissions.")
        .disabled(store.activeAgent != nil)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Permissions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 3)
                ForEach(DesktopAccessMode.allCases) { option in
                    let reason = store.accessModeUnavailableReason(option)
                    Button {
                        store.updateAccessMode(option)
                        isPresented = false
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: option.symbolName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(option == .fullAccess ? .orange : .secondary)
                                .frame(width: 17)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).font(.system(size: 12, weight: .medium))
                                Text(reason ?? option.detail)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            if mode == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(accent)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mode == option ? .isSelected : [])
                    .disabled(reason != nil)
                }
            }
            .padding(10)
            .frame(width: 260)
        }
    }
}

struct DesktopComposerToolbarLayout: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let left = subviews[0].sizeThatFits(.unspecified)
        let right = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? left.width + spacing + right.width
        if left.width + spacing + right.width <= width {
            return CGSize(width: width, height: max(left.height, right.height))
        }
        let wrapped = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: wrapped.height + spacing + right.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let left = subviews[0].sizeThatFits(.unspecified)
        let right = subviews[1].sizeThatFits(.unspecified)
        if left.width + spacing + right.width <= bounds.width {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        } else {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.maxY), anchor: .bottomTrailing, proposal: .unspecified)
        }
    }
}
