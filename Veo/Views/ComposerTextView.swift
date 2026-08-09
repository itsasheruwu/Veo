// FILE: ComposerTextView.swift
// Purpose: Multi-line composer field that sends on Return and inserts a newline on Shift-Return.
// Layer: Desktop app view
// Depends on: AppKit, SwiftUI

import AppKit
import SwiftUI

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var placeholderColor: NSColor = .tertiaryLabelColor
    var fontSize: CGFloat
    var minHeight: CGFloat
    var maxHeight: CGFloat
    var isEditable: Bool
    /// Increment to move keyboard focus into the field.
    var focusToken: Int
    /// Returns true when the Return keypress was consumed as a send; false inserts a newline.
    var onSubmit: () -> Bool
    /// Moves the active autocomplete row. Returns false when no palette is open.
    var onMoveAutocomplete: (Int) -> Bool = { _ in false }
    /// Accepts the active autocomplete row. Returns false when no palette is open.
    var onAcceptAutocomplete: () -> Bool = { false }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 5, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .allowed
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }

        context.coordinator.parent = self

        textView.font = .systemFont(ofSize: fontSize)
        textView.placeholder = placeholder
        textView.placeholderColor = placeholderColor
        textView.isEditable = isEditable
        textView.isSelectable = true

        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let limit = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, limit), length: 0))
        }
        textView.needsDisplay = true

        if context.coordinator.handledFocusToken != focusToken {
            context.coordinator.handledFocusToken = focusToken
            if isEditable {
                DispatchQueue.main.async {
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? ComposerNSTextView,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager else { return nil }

        let width = proposal.width ?? nsView.bounds.width
        guard width > 0 else { return nil }

        let contentWidth = max(width - textView.textContainerInset.width * 2, 1)
        if container.size.width != contentWidth {
            container.size = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
        return CGSize(width: width, height: min(max(used, minHeight), maxHeight))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var handledFocusToken: Int

        init(_ parent: ComposerTextView) {
            self.parent = parent
            self.handledFocusToken = parent.focusToken
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMoveAutocomplete(-1)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMoveAutocomplete(1)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onAcceptAutocomplete()
            case #selector(NSResponder.insertNewline(_:)):
                break
            default:
                return false
            }
            // Shift-Return keeps the newline; a bare Return submits when a send is possible,
            // and otherwise falls through to a newline rather than doing nothing at all.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            return parent.onSubmit()
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var placeholder: String = ""
    var placeholderColor: NSColor = .tertiaryLabelColor

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: placeholderColor,
        ]
        let origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}
