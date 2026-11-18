import AppKit
import SwiftUI

enum DesktopDaybreakMark {
    static let systemImage = "sun.horizon.fill"
}

/// A small addition to the existing studio; model rows remain owned by the studio.
struct DesktopAutoModelRow: View {
    @Bindable var store: DesktopCodexStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Auto")
                Spacer()
                Toggle("Auto", isOn: Binding(
                    get: { store.autoModelSelectionEnabled },
                    set: store.setAutoModelSelectionEnabled
                ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(store.isDaybreakOn)
                    .accessibilityLabel("Auto model selection")
                    .accessibilityHint(store.isDaybreakOn ? "Turn Daybreak off to use Auto." : "")
            }
            DesktopDaybreakRow(store: store)
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

struct DesktopDaybreakRow: View {
    @Bindable var store: DesktopCodexStore

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Daybreak", systemImage: DesktopDaybreakMark.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.canToggleDaybreak ? .primary : .secondary)
                if let detail = store.daybreakDetail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Toggle("Daybreak", isOn: Binding(get: { store.isDaybreakOn }, set: store.setDaybreakEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!store.canToggleDaybreak)
                .accessibilityLabel("Daybreak")
                .accessibilityHint(store.daybreakDetail ?? "Applies to new turns.")
        }
    }
}

/// The original NSMenu keeps native model rows, hover, keyboard handling and sizing.
final class DesktopModelMenuToggle: NSView {
    private enum Metrics {
        static let textInset: CGFloat = 28
        static let trailingInset: CGFloat = 14
        static let iconInset: CGFloat = 9
        static let iconSize: CGFloat = 14
        static let height: CGFloat = 30
        static let detailHeight: CGFloat = 43
    }

    private let toggle = NSSwitch()
    private let title: NSTextField
    private let detail: NSTextField?
    private let icon = NSImageView()
    private let onChange: (Bool) -> Void

    init(title: String, systemImage: String, accessibilityLabel: String, enabled: Bool,
         available: Bool, detail: String? = nil, onChange: @escaping (Bool) -> Void) {
        self.title = NSTextField(labelWithString: title)
        self.detail = detail.map(NSTextField.init(labelWithString:))
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 244,
                                 height: detail == nil ? Metrics.height : Metrics.detailHeight))
        autoresizingMask = [.width]
        self.title.font = .menuFont(ofSize: 0)
        self.title.textColor = available ? .labelColor : .secondaryLabelColor
        addSubview(self.title)
        if let detail = self.detail {
            detail.font = .systemFont(ofSize: 10.5)
            detail.textColor = .secondaryLabelColor
            detail.cell?.lineBreakMode = .byTruncatingTail
            addSubview(detail)
        }
        icon.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Metrics.iconSize, weight: .regular))
        icon.contentTintColor = available ? .labelColor : .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        addSubview(icon)
        toggle.controlSize = .small
        toggle.state = enabled ? .on : .off
        toggle.isEnabled = available
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.setAccessibilityLabel(accessibilityLabel)
        toggle.toolTip = detail
        if let detail { toggle.setAccessibilityHelp(detail) }
        addSubview(toggle)
    }

    override func layout() {
        super.layout()
        let rowCenter = bounds.midY + (detail == nil ? 0 : 6)
        let rowY = rowCenter - 10
        toggle.sizeToFit()
        let alignmentSize = toggle.alignmentRect(forFrame: toggle.frame).size
        toggle.frame = toggle.frame(forAlignmentRect: NSRect(
            x: bounds.width - Metrics.trailingInset - alignmentSize.width,
            y: rowCenter - alignmentSize.height / 2,
            width: alignmentSize.width, height: alignmentSize.height))
        title.frame = NSRect(x: Metrics.textInset, y: rowY,
                             width: max(0, toggle.frame.minX - Metrics.textInset - 8), height: 20)
        detail?.frame = NSRect(x: Metrics.textInset, y: rowY - 13,
                               width: max(0, bounds.width - Metrics.textInset - Metrics.trailingInset), height: 14)
        icon.frame = NSRect(x: Metrics.iconInset, y: rowCenter - Metrics.iconSize / 2,
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
