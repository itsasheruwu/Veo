// FILE: DesktopTerminalView.swift
// Purpose: SwiftTerm-backed terminal surface for full VT/xterm apps (codex, claude, etc.).
// Layer: Desktop app view

import AppKit
import SwiftTerm
import SwiftUI

struct DesktopTerminalView: NSViewRepresentable {
    @ObservedObject var session: DesktopLocalTerminalSession
    @ObservedObject var hub: DesktopLocalTerminalHub
    /// Pixel size from a GeometryReader. SwiftUI does not reliably call
    /// `NSView.setFrameSize` on every layout pass, so we push size explicitly.
    var viewportSize: CGSize
    /// Full terminal workspace panes should take keyboard focus when activated.
    /// Docked terminals remain click-to-focus so they do not steal composer focus.
    var requestsFocus = false
    var onAddContext: ((String) -> Void)?
    @Binding var isFileDropTargeted: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, hub: hub, isFileDropTargeted: $isFileDropTargeted)
    }

    func makeNSView(context: Context) -> DesktopTerminalDropHostView {
        let terminalView = ContextTerminalView(frame: .zero)
        terminalView.onAddContext = onAddContext
        terminalView.terminalDelegate = context.coordinator
        terminalView.configureNativeColors()
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminalView.clipsToBounds = true
        terminalView.wantsLayer = true
        terminalView.layer?.masksToBounds = true
        let host = DesktopTerminalDropHostView(terminalView: terminalView)
        host.onTargetedChange = { targeted in
            context.coordinator.setFileDropTargeted(targeted)
        }
        host.onPerformDrop = { urls, text in
            context.coordinator.handleDroppedInput(urls: urls, text: text)
        }
        context.coordinator.terminalView = terminalView
        session.attach(sink: context.coordinator)
        // Focus on click — avoid stealing composer focus on appear.
        return host
    }

    func updateNSView(_ host: DesktopTerminalDropHostView, context: Context) {
        (host.terminalView as? ContextTerminalView)?.onAddContext = onAddContext
        context.coordinator.hub = hub
        context.coordinator.isFileDropTargeted = $isFileDropTargeted
        if context.coordinator.session !== session {
            context.coordinator.session.detach(sink: context.coordinator)
            context.coordinator.session = session
            context.coordinator.terminalView = host.terminalView
            context.coordinator.resetLineBuffer()
            session.attach(sink: context.coordinator)
        }
        context.coordinator.syncPermissionPromptState()
        host.terminalView.clipsToBounds = true
        host.terminalView.wantsLayer = true
        host.terminalView.layer?.masksToBounds = true
        context.coordinator.applyViewportSize(viewportSize)
        context.coordinator.applyFocusRequest(requestsFocus)
    }

    static func dismantleNSView(_ nsView: DesktopTerminalDropHostView, coordinator: Coordinator) {
        coordinator.session.detach(sink: coordinator)
        coordinator.setFileDropTargeted(false)
        coordinator.terminalView = nil
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate, DesktopTerminalOutputSink {
        var session: DesktopLocalTerminalSession
        var hub: DesktopLocalTerminalHub
        var isFileDropTargeted: Binding<Bool>
        weak var terminalView: TerminalView?
        private var lastViewportSize: CGSize = .zero
        private var wasFocusRequested = false

        /// Best-effort reconstruction of the current shell input line for Agent CLI gating.
        private var lineBuffer = ""
        private var isParsingEscape = false
        private var wasPermissionPromptPresented = false

        init(
            session: DesktopLocalTerminalSession,
            hub: DesktopLocalTerminalHub,
            isFileDropTargeted: Binding<Bool>
        ) {
            self.session = session
            self.hub = hub
            self.isFileDropTargeted = isFileDropTargeted
        }

        func setFileDropTargeted(_ targeted: Bool) {
            guard isFileDropTargeted.wrappedValue != targeted else { return }
            let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil
                : .easeOut(duration: 0.2)
            withAnimation(animation) {
                isFileDropTargeted.wrappedValue = targeted
            }
        }

        @discardableResult
        func handleDroppedInput(urls: [URL], text: String?) -> Bool {
            guard !hub.isAgentCLIPermissionPromptPresented else { return false }
            hub.focusWorkspaceSession(session.id)
            focus()

            if !urls.isEmpty {
                let payload = DesktopLocalTerminalSession.droppedPathPayload(from: urls)
                guard !payload.isEmpty else { return false }
                lineBuffer += payload
                session.write(payload)
                return true
            }

            guard let text, !text.isEmpty else { return false }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if UUID(uuidString: trimmed) != nil { return false }

            if text.contains("\n") || text.contains("\r") {
                let normalized = text
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                session.write("\u{1b}[200~" + normalized + "\u{1b}[201~")
                lineBuffer = normalized.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            } else {
                lineBuffer += text
                session.write(text)
            }
            return true
        }

        func focus() {
            guard let terminalView, let window = terminalView.window else { return }
            window.makeFirstResponder(terminalView)
        }

        func applyFocusRequest(_ requested: Bool) {
            guard requested else {
                wasFocusRequested = false
                return
            }
            guard !wasFocusRequested else { return }
            wasFocusRequested = true
            // updateNSView can run before AppKit has attached the replacement
            // terminal to its window during the docked -> workspace transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.focus()
            }
        }

        func resetLineBuffer() {
            lineBuffer = ""
            isParsingEscape = false
        }

        func syncPermissionPromptState() {
            let presented = hub.isAgentCLIPermissionPromptPresented
            if wasPermissionPromptPresented, !presented {
                // Allow submits Enter outside send(); Deny interrupts. Either way the line is done.
                resetLineBuffer()
            }
            wasPermissionPromptPresented = presented
        }

        /// Force SwiftTerm's grid + the PTY winsize to match the SwiftUI viewport.
        func applyViewportSize(_ size: CGSize) {
            guard let terminalView else { return }
            guard size.width >= 40, size.height >= 40 else { return }

            let viewportChanged =
                lastViewportSize == .zero
                || abs(size.width - lastViewportSize.width) >= 0.5
                || abs(size.height - lastViewportSize.height) >= 0.5
            let frameMismatch =
                abs(terminalView.frame.width - size.width) >= 0.5
                || abs(terminalView.frame.height - size.height) >= 0.5

            if viewportChanged || frameMismatch {
                lastViewportSize = size
                // SwiftTerm only recomputes cols/rows from setFrameSize → processSizeChange.
                // SwiftUI layout alone is not reliable for that path.
                terminalView.setFrameSize(size)
            }

            // Keep the PTY aligned with whatever SwiftTerm is actually rendering.
            let terminal = terminalView.getTerminal()
            session.resize(columns: terminal.cols, rows: terminal.rows)
        }

        func terminalReplaceAll(_ data: Data) {
            guard let terminalView else { return }
            terminalView.terminal.resetToInitialState()
            if !data.isEmpty {
                terminalView.feed(byteArray: ArraySlice(data))
            }
        }

        func terminalAppend(_ data: Data) {
            guard let terminalView, !data.isEmpty else { return }
            terminalView.feed(byteArray: ArraySlice(data))
        }

        // MARK: TerminalViewDelegate

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Ignore pre-layout junk (zero / 1-col frames) so we don't desync the PTY.
            guard newCols >= 10, newRows >= 3 else { return }
            session.resize(columns: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // Tab titles stay project-based; OSC titles are ignored for now.
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Freeze keystrokes while the Agent CLIs consent sheet is up.
            guard !hub.isAgentCLIPermissionPromptPresented else { return }
            hub.focusWorkspaceSession(session.id)

            var outbound = Data()
            outbound.reserveCapacity(data.count)

            for byte in data {
                if isParsingEscape {
                    outbound.append(byte)
                    // CSI/SS3 finals are in @–~
                    if (0x40...0x7E).contains(byte) {
                        isParsingEscape = false
                    }
                    continue
                }

                switch byte {
                case 0x1B:
                    isParsingEscape = true
                    outbound.append(byte)

                case 0x0D, 0x0A:
                    if !DesktopTerminalPreferences.agentCLIsEnabled,
                       DesktopTerminalPreferences.commandInvokesAgentCLI(lineBuffer) {
                        session.recordSubmittedCommand(lineBuffer)
                        if !outbound.isEmpty {
                            session.write(outbound)
                        }
                        hub.requestAgentCLIPermission(
                            sessionID: session.id,
                            commandLine: lineBuffer
                        )
                        return
                    }
                    session.recordSubmittedCommand(lineBuffer)
                    let rewrittenLine = DesktopTerminalPreferences.commandLineApplyingYoloMode(lineBuffer)
                    if rewrittenLine != lineBuffer {
                        if !outbound.isEmpty {
                            session.write(outbound)
                            outbound.removeAll(keepingCapacity: true)
                        }
                        // The shell already received the typed line. Clear it and submit the
                        // rewritten command so login-shell PATH changes cannot bypass yolo mode.
                        session.write("\u{15}\(rewrittenLine)\r")
                        lineBuffer = ""
                        continue
                    }
                    outbound.append(byte)
                    lineBuffer = ""

                case 0x7F, 0x08:
                    if !lineBuffer.isEmpty {
                        lineBuffer.removeLast()
                    }
                    outbound.append(byte)

                case 0x03, 0x15: // Ctrl-C, Ctrl-U
                    lineBuffer = ""
                    outbound.append(byte)

                case 0x17: // Ctrl-W — drop trailing word from local buffer
                    while lineBuffer.last?.isWhitespace == true {
                        lineBuffer.removeLast()
                    }
                    while let last = lineBuffer.last, !last.isWhitespace {
                        lineBuffer.removeLast()
                    }
                    outbound.append(byte)

                default:
                    if byte >= 0x20, byte != 0x7F {
                        lineBuffer.append(Character(UnicodeScalar(byte)))
                    }
                    outbound.append(byte)
                }
            }

            if !outbound.isEmpty {
                session.write(outbound)
            }
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        func clipboardRead(source: TerminalView) -> Data? {
            NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Hosts SwiftTerm and owns AppKit drag-and-drop so Finder files land on the PTY
/// even though the cursor is over an `NSViewRepresentable`.
final class DesktopTerminalDropHostView: NSView {
    let terminalView: TerminalView
    var onTargetedChange: ((Bool) -> Void)?
    var onPerformDrop: (([URL], String?) -> Bool)?

    private static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .string,
    ]

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        autoresizesSubviews = true
        terminalView.autoresizingMask = [.width, .height]
        addSubview(terminalView)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        if terminalView.superview === self, terminalView.frame != bounds {
            terminalView.frame = bounds
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else { return [] }
        onTargetedChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else {
            onTargetedChange?(false)
            return []
        }
        onTargetedChange?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetedChange?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetedChange?(false)
        let pasteboard = sender.draggingPasteboard
        let fileURLs = Self.fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return onPerformDrop?(fileURLs, nil) ?? false
        }
        if let text = Self.textPayload(from: pasteboard) {
            return onPerformDrop?([], text) ?? false
        }
        return false
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.availableType(from: [.fileURL, .URL]) != nil {
            return true
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return UUID(uuidString: trimmed) == nil
        }
        return false
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var collected: [URL] = []

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            collected.append(contentsOf: urls)
        }

        if collected.isEmpty,
           let paths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
           ) as? [String] {
            collected.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
        }

        if collected.isEmpty, let items = pasteboard.pasteboardItems {
            for item in items {
                guard let raw = item.string(forType: .fileURL) else { continue }
                if let url = URL(string: raw), url.isFileURL {
                    collected.append(url)
                } else if raw.hasPrefix("/") {
                    collected.append(URL(fileURLWithPath: raw))
                }
            }
        }

        var seen = Set<String>()
        var unique: [URL] = []
        for url in collected where url.isFileURL {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                unique.append(standardized)
            }
        }
        return unique
    }

    private static func textPayload(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let remote = urls.filter { !$0.isFileURL }
            if !remote.isEmpty {
                return remote.map(\.absoluteString).joined(separator: " ")
            }
        }
        guard let string = pasteboard.string(forType: .string), !string.isEmpty else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: trimmed) != nil { return nil }
        return string
    }
}

private final class ContextTerminalView: TerminalView {
    var onAddContext: ((String) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard getSelection()?.isEmpty == false, onAddContext != nil else { return super.menu(for: event) }
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: "Add selection to chat", action: #selector(addSelectionToChat), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func addSelectionToChat() {
        if let selection = getSelection() { onAddContext?(selection) }
    }
}
