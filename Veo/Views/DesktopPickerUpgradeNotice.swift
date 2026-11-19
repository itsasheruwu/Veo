import SwiftUI

struct DesktopPickerUpgradeNotice: View {
    @Environment(\.veoAccent) private var accent
    let restore: () -> Void
    let keep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            preview
            VStack(alignment: .leading, spacing: 7) {
                Text("Your model picker has a new look")
                    .font(.system(size: 25, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Veo switched you to Slider / Advanced. Slide to change reasoning effort, or open Advanced for model, speed, and context controls.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can switch back anytime in Settings → Appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
            }
            HStack {
                Spacer()
                Button("Switch back to Native", action: restore)
                    .buttonStyle(.bordered)
                Button("Keep Slider / Advanced", action: keep)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 480)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(accent)
                Text("Reasoning effort").font(.system(size: 12, weight: .semibold))
                Spacer()
                Label("Advanced", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let progress = geometry.size.width * 0.7
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.10))
                    Capsule()
                        .fill(.linearGradient(colors: [accent.opacity(0.58), accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: progress)
                    Circle()
                        .fill(accent)
                        .overlay { Circle().strokeBorder(.white.opacity(0.8), lineWidth: 2) }
                        .frame(width: 14, height: 14)
                        .offset(x: progress - 7)
                }
            }
            .frame(height: 5)
            HStack {
                Text("Light")
                Spacer()
                Text("High").foregroundStyle(accent)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(17)
        .background {
            RoundedRectangle(cornerRadius: 13)
                .fill(.linearGradient(colors: [accent.opacity(0.15), accent.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13).strokeBorder(accent.opacity(0.25))
        }
        .accessibilityHidden(true)
    }
}
