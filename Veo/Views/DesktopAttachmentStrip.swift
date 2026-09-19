// Purpose: Shared composer, sent-message, and queued attachment presentation.

import AppKit
import SwiftUI

struct DesktopAttachmentStrip: View {
    let attachments: [DesktopComposerAttachment]
    var onRemove: ((String) -> Void)? = nil
    var sendRole: DesktopMessageSendTransition.Role = .none

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    DesktopAttachmentPreview(attachment: attachment, onRemove: onRemove)
                        .modifier(DesktopSendGeometry(part: .attachment(index), role: sendRole))
                }
            }
        }
        .modifier(DesktopSendGeometry(part: .attachmentViewport, role: sendRole))
    }
}

struct DesktopAttachmentPreview: View {
    let attachment: DesktopComposerAttachment
    let onRemove: ((String) -> Void)?
    var cachedImage: NSImage? = nil

    var body: some View {
        HStack(spacing: 7) {
            preview
            Text(attachment.name)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            if let onRemove {
                Button {
                    onRemove(attachment.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .help(attachment.source)
    }

    @ViewBuilder
    private var preview: some View {
        if attachment.kind == .localImage,
           let image = cachedImage ?? NSImage(contentsOfFile: attachment.source) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
    }

    private var symbolName: String {
        switch attachment.kind {
        case .localImage, .image: return "photo"
        case .localAudio, .audio: return "waveform"
        case .fileMention: return "doc.text"
        case .skill: return "bolt.badge.checkmark"
        }
    }
}
