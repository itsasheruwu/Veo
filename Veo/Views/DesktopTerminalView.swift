// FILE: DesktopTerminalView.swift
// Purpose: SwiftTerm-backed terminal surface for full VT/xterm apps (codex, claude, etc.).
// Layer: Desktop app view

import AppKit
import SwiftTerm
import SwiftUI

struct DesktopTerminalView: NSViewRepresentable {
    @ObservedObject var session: DesktopLocalTerminalSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
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
        if context.coordinator.session !== session {
            context.coordinator.session.detach(sink: context.coordinator)
            context.coordinator.session = session
            context.coordinator.terminalView = terminalView
            session.attach(sink: context.coordinator)
        }
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.session.detach(sink: coordinator)
        coordinator.terminalView = nil
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate, DesktopTerminalOutputSink {
        var session: DesktopLocalTerminalSession
        weak var terminalView: TerminalView?

        init(session: DesktopLocalTerminalSession) {
            self.session = session
        }

        func focus() {
            guard let terminalView, let window = terminalView.window else { return }
            window.makeFirstResponder(terminalView)
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
            session.resize(columns: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // Tab titles stay project-based; OSC titles are ignored for now.
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.write(Data(data))
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
