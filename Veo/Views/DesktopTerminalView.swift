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

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, hub: hub)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminalView = TerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator
        terminalView.configureNativeColors()
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        context.coordinator.terminalView = terminalView
        session.attach(sink: context.coordinator)
        // Focus on click — avoid stealing composer focus on appear.
        return terminalView
    }

    func updateNSView(_ terminalView: TerminalView, context: Context) {
        context.coordinator.hub = hub
        if context.coordinator.session !== session {
            context.coordinator.session.detach(sink: context.coordinator)
            context.coordinator.session = session
            context.coordinator.terminalView = terminalView
            context.coordinator.resetLineBuffer()
            session.attach(sink: context.coordinator)
        }
        context.coordinator.syncPermissionPromptState()
        context.coordinator.applyViewportSize(viewportSize)
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.session.detach(sink: coordinator)
        coordinator.terminalView = nil
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate, DesktopTerminalOutputSink {
        var session: DesktopLocalTerminalSession
        var hub: DesktopLocalTerminalHub
        weak var terminalView: TerminalView?
        private var lastViewportSize: CGSize = .zero

        /// Best-effort reconstruction of the current shell input line for Agent CLI gating.
        private var lineBuffer = ""
        private var isParsingEscape = false
        private var wasPermissionPromptPresented = false

        init(session: DesktopLocalTerminalSession, hub: DesktopLocalTerminalHub) {
            self.session = session
            self.hub = hub
        }

        func focus() {
            guard let terminalView, let window = terminalView.window else { return }
            window.makeFirstResponder(terminalView)
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
                        if !outbound.isEmpty {
                            session.write(outbound)
                        }
                        hub.requestAgentCLIPermission(
                            sessionID: session.id,
                            commandLine: lineBuffer
                        )
                        return
                    }
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
