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
