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
    var selectionAfterUpdate: (text: String, offset: Int)? = nil
    /// Returns true when the Return keypress was consumed as a send; false inserts a newline.
    var onSubmit: () -> Bool
    /// Gives the send transition a weak reference for a snapshot before the draft clears.
    var onTextViewReady: (NSTextView) -> Void = { _ in }
    /// Moves the active autocomplete row. Returns false when no palette is open.
    var onMoveAutocomplete: (Int) -> Bool = { _ in false }
    var onSelection: (String, NSRange) -> Void = { _, _ in }
    var onOpenContext: (URL) -> Void = { _ in }
    var onRecallPrompt: (Int) -> Bool = { _ in false }
    /// Accepts the active autocomplete row. Returns false when no palette is open.
    var onAcceptAutocomplete: () -> Bool = { false }
    /// Closes autocomplete without changing the draft. Returns false when no palette is open.
    var onDismissAutocomplete: () -> Bool = { false }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.isAutomaticLinkDetectionEnabled = false
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
        onTextViewReady(textView)

        var needsDisplay = false
        let desiredFont = NSFont.systemFont(ofSize: fontSize)
        if textView.font?.isEqual(desiredFont) != true {
            textView.font = desiredFont
            needsDisplay = true
        }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            needsDisplay = true
        }
        if textView.placeholderColor.isEqual(placeholderColor) == false {
            textView.placeholderColor = placeholderColor
            needsDisplay = true
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
            if !isEditable, textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
            needsDisplay = true
        }
        if textView.isSelectable == false {
            textView.isSelectable = true
            needsDisplay = true
        }

        let previousSource = textView.sourceText()
        if (previousSource != text || !DesktopInlineContext.scan(textView.string).isEmpty) && !textView.hasMarkedText() {
            let selected = textView.sourceSelection()
            let limit = (text as NSString).length
            let oldLength = (previousSource as NSString).length
            let shouldAdvance = selected.location == oldLength || (text as NSString).substring(to: min(selected.location, limit))
                == (previousSource as NSString).substring(to: min(selected.location, oldLength))
            let offset = if let selectionAfterUpdate, selectionAfterUpdate.text == text, previousSource != text {
                selectionAfterUpdate.offset
            } else {
                shouldAdvance ? max(0, selected.location + limit - oldLength) : selected.location
            }
            let rendered = ComposerNSTextView.render(text, font: desiredFont)
            textView.textStorage?.setAttributedString(rendered)
            textView.setSelectedRange(NSRange(location: textView.visibleOffset(min(offset, limit)), length: 0))
            needsDisplay = true
        }
        textView.typingAttributes = [.font: desiredFont, .foregroundColor: NSColor.labelColor]
        if needsDisplay {
            textView.needsDisplay = true
        }

        if context.coordinator.handledFocusToken != focusToken {
            context.coordinator.handledFocusToken = focusToken
            if isEditable {
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, textView.isEditable else { return }
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
            guard let textView = notification.object as? ComposerNSTextView else { return }
            parent.text = textView.sourceText()
            parent.onSelection(parent.text, textView.sourceSelection())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? ComposerNSTextView else { return }
            parent.onSelection(textView.sourceText(), textView.sourceSelection())
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, ["veo-context", "veo-quote"].contains(url.scheme ?? "") else { return false }
            parent.onOpenContext(url)
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMoveAutocomplete(-1) || (!textView.hasMarkedText() && textView.selectedRange().length == 0 && parent.onRecallPrompt(-1))
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMoveAutocomplete(1) || (!textView.hasMarkedText() && textView.selectedRange().length == 0 && parent.onRecallPrompt(1))
            case #selector(NSResponder.insertTab(_:)):
                if parent.onMoveAutocomplete(1) { return true }
                guard textView.string.isEmpty || NSApp.isFullKeyboardAccessEnabled else { return false }
                textView.window?.selectNextKeyView(textView)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                if parent.onMoveAutocomplete(-1) { return true }
                textView.window?.selectPreviousKeyView(textView)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onDismissAutocomplete()
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
            if parent.onAcceptAutocomplete() {
                return true
            }
            return parent.onSubmit()
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var placeholder: String = ""
    var placeholderColor: NSColor = .tertiaryLabelColor

    static func render(_ source: String, font: NSFont) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let output = NSMutableAttributedString(string: source, attributes: attributes)
        for context in DesktopInlineContext.scan(source).reversed() {
            let chip = NSMutableAttributedString(attachment: DesktopComposerContextAttachment(context: context, fontSize: font.pointSize))
            chip.addAttributes([.link: context.url, .font: font], range: NSRange(location: 0, length: 1))
            output.replaceCharacters(in: context.range, with: chip)
        }
        return output
    }

    func sourceText(in range: NSRange? = nil) -> String {
        guard let storage = textStorage else { return string }
        let range = range ?? NSRange(location: 0, length: storage.length)
        let text = storage.string as NSString
        var result = ""
        storage.enumerateAttribute(.attachment, in: range) { attachment, range, _ in
            if let reference = (attachment as? DesktopComposerContextAttachment)?.context {
                result += reference.source
            } else {
                result += text.substring(with: range)
            }
        }
        return result
    }

    func sourceSelection() -> NSRange {
        let selection = selectedRange()
        guard selection.location != NSNotFound else { return NSRange(location: (sourceText() as NSString).length, length: 0) }
        let start = (sourceText(in: NSRange(location: 0, length: selection.location)) as NSString).length
        return NSRange(location: start, length: (sourceText(in: selection) as NSString).length)
    }

    func visibleOffset(_ sourceOffset: Int) -> Int {
        let text = sourceText()
        var offset = sourceOffset
        for context in DesktopInlineContext.scan(text) {
            if sourceOffset >= NSMaxRange(context.range) {
                offset -= context.range.length - 1
            } else if sourceOffset >= context.range.location {
                offset -= sourceOffset - context.range.location
                break
            } else {
                break
            }
        }
        return offset
    }

    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sourceText(in: selectedRange()), forType: .string)
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

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
