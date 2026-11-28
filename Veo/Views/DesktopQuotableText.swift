import AppKit
import SwiftUI

/// TextKit supplies both the exact passage and the screen rect of the glyph nearest the pointer.
struct DesktopQuotableText: NSViewRepresentable {
    let text: AttributedString
    let size: CGFloat
    var code = false
    let quote: (String) -> Void
    @Environment(\.openURL) private var openURL

    init(_ text: AttributedString, size: CGFloat, code: Bool = false, quote: @escaping (String) -> Void) {
        self.text = text
        self.size = size
        self.code = code
        self.quote = quote
    }

    func makeNSView(context: Context) -> QuoteTextView {
        let view = QuoteTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.delegate = view
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: QuoteTextView, context: Context) {
        view.quote = quote
        view.openLink = { _ = openURL($0) }
        guard view.source != text || view.pointSize != size || view.code != code else { return }
        view.source = text
        view.pointSize = size
        view.code = code
        view.measuredSize = nil
        view.dismissQuote()
        let rendered = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = code ? 0 : 3
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = code || intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            if let link = run.link { attrs[.link] = link }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            rendered.append(NSAttributedString(string: String(text[run.range].characters), attributes: attrs))
        }
        view.textStorage?.setAttributedString(rendered)
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: QuoteTextView, context: Context) -> CGSize? {
        guard let manager = view.layoutManager, let container = view.textContainer else { return nil }
        let width = code ? CGFloat.greatestFiniteMagnitude : max(1, proposal.width ?? 800)
        if let (cachedWidth, measured) = view.measuredSize, cachedWidth == width, container.containerSize.width == width {
            return measured
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let measured = CGSize(width: code ? ceil(used.width) : width, height: max(ceil(size + 3), ceil(used.height)))
        view.measuredSize = (width, measured)
        return measured
    }

    static func dismantleNSView(_ view: QuoteTextView, coordinator: ()) { view.dismissQuote() }
}

final class QuoteTextView: NSTextView, NSTextViewDelegate, NSPopoverDelegate {
    var measuredSize: (CGFloat, CGSize)?
    var source: AttributedString?
    var pointSize: CGFloat = 14
    var code = false
    var quote: ((String) -> Void)?
    var openLink: ((URL) -> Void)?
    private var quotePopover: NSPopover?
    private var monitor: Any?

    // The representable fills the transcript column, even for a one-word line.
    // Let the surrounding view own the pointer outside the laid-out text.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let manager = layoutManager, let container = textContainer,
              let parent = superview else { return super.hitTest(point) }
        let local = convert(point, from: parent)
        let location = NSPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: location, in: container)
        guard glyph < manager.numberOfGlyphs,
              manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).contains(location)
        else { return nil }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        guard let manager = layoutManager, let container = textContainer else { return }
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, _ in
            let rect = used.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            self.addCursorRect(rect.intersection(self.visibleRect), cursor: .iBeam)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dismissQuote()
        super.mouseDown(with: event)
        if NSEvent.pressedMouseButtons == 0 { presentQuote(nearPointer: true) }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        presentQuote(nearPointer: true)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard selectedRange().length > 0 else {
            dismissQuote()
            return
        }
        if NSEvent.pressedMouseButtons == 0, window?.firstResponder === self {
            presentQuote(nearPointer: false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissQuote() }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { openLink?(url) }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if selectedRange().length > 0 {
            let item = NSMenuItem(title: "Quote selection", action: #selector(insertSelection), keyEquivalent: "")
            item.target = self
            menu?.insertItem(item, at: 0)
        }
        return menu
    }

    @objc private func insertSelection() {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return }
        let excerpt = (string as NSString).substring(with: range)
        dismissQuote()
        quote?(excerpt)
    }

    func dismissQuote() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        quotePopover?.close()
        quotePopover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === quotePopover else { return }
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        quotePopover = nil
    }

    private func presentQuote(nearPointer: Bool) {
        dismissQuote()
        let range = selectedRange()
        guard let window, range.length > 0,
              NSMaxRange(range) <= (string as NSString).length else { return }
        let pointer = window.mouseLocationOutsideOfEventStream
        let index = nearPointer ? characterIndexForInsertion(at: convert(pointer, from: nil)) : NSMaxRange(range) - 1
        let location = max(range.location, min(index, NSMaxRange(range) - 1))
        let glyph = firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil)
        guard !glyph.isEmpty else { return }
        let excerpt = (string as NSString).substring(with: range)
        let controller = NSHostingController(rootView: DesktopSelectionQuoteButton { [weak self] in
            self?.dismissQuote()
            self?.quote?(excerpt)
        })
        let popover = NSPopover()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        let anchor = convert(window.convertFromScreen(glyph), from: nil)
        quotePopover = popover
        popover.show(relativeTo: anchor, of: self, preferredEdge: isFlipped ? .minY : .maxY)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            if event.type == .scrollWheel || event.keyCode == 53 { self?.dismissQuote() }
            return event
        }
    }
}

private struct DesktopSelectionQuoteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Quote", systemImage: "text.quote")
                .font(.system(size: 12, weight: .semibold))
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                Capsule().fill(.clear).glassEffect(.regular.interactive(), in: Capsule())
            } else {
                Capsule().fill(.regularMaterial)
            }
            #else
            Capsule().fill(.regularMaterial)
            #endif
        }
        .accessibilityLabel("Quote selection")
        .padding(4)
        .fixedSize()
    }
}
