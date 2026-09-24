import AppKit
import SwiftUI

/// A small addition to the existing studio; model rows remain owned by the studio.
struct DesktopAutoModelRow: View {
    @Bindable var store: DesktopCodexStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Auto")
                Spacer()
                Toggle("Auto", isOn: $store.autoModelSelectionEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("Auto model selection")
            }
            if store.autoModelSelectionEnabled {
                Text(store.autoModelRoutingStatus ?? "Auto mode is on")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                if let issue = store.autoModelRoutingDetail {
                    Text(issue).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }.lineLimit(nil)
    }
}

/// The original NSMenu keeps native model rows, hover, keyboard handling and sizing.
final class DesktopAutoMenuToggle: NSView {
    private enum Metrics {
        static let textInset: CGFloat = 28
        static let trailingInset: CGFloat = 14
        static let iconInset: CGFloat = 9
        static let iconSize: CGFloat = 14
        static let height: CGFloat = 30
    }

    private let toggle = NSSwitch()
    private let title = NSTextField(labelWithString: "Auto")
    private let icon = NSImageView()
    private let onChange: (Bool) -> Void

    init(enabled: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 244, height: Metrics.height))
        autoresizingMask = [.width]
        title.font = .menuFont(ofSize: 0)
        addSubview(title)
        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Metrics.iconSize, weight: .regular))
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        addSubview(icon)
        toggle.controlSize = .small
        toggle.state = enabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.setAccessibilityLabel("Auto model selection")
        addSubview(toggle)
    }

    override func layout() {
        super.layout()
        let rowY = (bounds.height - 20) / 2
        toggle.sizeToFit()
        let alignmentSize = toggle.alignmentRect(forFrame: toggle.frame).size
        toggle.frame = toggle.frame(forAlignmentRect: NSRect(
            x: bounds.width - Metrics.trailingInset - alignmentSize.width,
            y: (bounds.height - alignmentSize.height) / 2,
            width: alignmentSize.width, height: alignmentSize.height))
        title.frame = NSRect(x: Metrics.textInset, y: rowY,
                             width: max(0, toggle.frame.minX - Metrics.textInset - 8), height: 20)
        icon.frame = NSRect(x: Metrics.iconInset, y: (bounds.height - Metrics.iconSize) / 2,
                            width: Metrics.iconSize, height: Metrics.iconSize)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func changed() { onChange(toggle.state == .on) }
}

struct DesktopJevKeySettings: View {
    @State private var key = ""
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jev routing").font(.headline)
            Text("Auto sends the first prompt to TypeSafe AI to choose a model. Your API key is stored in Keychain.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("Jev API key", text: $key).textFieldStyle(.roundedBorder)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save key") {
                    if DesktopProviderCredentialStore.setKey(key, providerID: DesktopJevRouter.credentialID) {
                        key = ""
                        dismiss()
                    } else { message = "Could not save the key to Keychain." }
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 340)
    }
}
