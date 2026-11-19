import AppKit

final class DesktopComposerContextAttachment: NSTextAttachment {
    var context: DesktopInlineContext?

    convenience init(context: DesktopInlineContext, fontSize: CGFloat) {
        self.init(data: nil, ofType: nil)
        self.context = context
        let font = NSFont.systemFont(ofSize: fontSize - 1, weight: .medium)
        let label = context.label.count > 48 ? String(context.label.prefix(45)) + "…" : context.label
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let size = NSSize(width: ceil(textSize.width) + 14, height: ceil(textSize.height) + 2)
        let image = NSImage(size: size, flipped: false) { frame in
            NSColor.quaternaryLabelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5).fill()
            (label as NSString).draw(at: NSPoint(x: 7, y: 1), withAttributes: attributes)
            return true
        }
        image.accessibilityDescription = context.label
        attachmentCell = NSTextAttachmentCell(imageCell: image)
    }
}
