import SwiftUI

struct DesktopPickerUpgradeNotice: View {
    @Bindable var store: DesktopCodexStore
    let restore: () -> Void
    let keep: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VeoPrismView()
                DesktopModelSliderAdvancedPicker(store: store)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.38), radius: 14, y: 5)
                    .padding(.vertical, 26)
            }
            .frame(minHeight: 165)
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Text("Your model picker has a new look")
                    .font(.system(size: 23, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text("Try the slider to change reasoning effort. Open Advanced to choose a model or adjust its settings.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: 360)
                Text("Change picker styles anytime in Settings → Appearance.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Switch back to Native", action: restore)
                    Button("Keep Slider / Advanced", action: keep)
                        .tourButtons(primary: true).keyboardShortcut(.defaultAction)
                }.tourButtons().tourControlGroup().padding(.top, 8)
            }.padding(22)
        }
        .frame(width: 480).tourSheet()
    }
}
