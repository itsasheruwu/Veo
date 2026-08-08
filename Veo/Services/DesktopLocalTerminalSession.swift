// FILE: DesktopLocalTerminalSession.swift
// Purpose: Owns a local PTY-backed zsh session for the docked terminal panel.
// Layer: Desktop app service

import AppKit
import Darwin
import Foundation

@MainActor
final class DesktopLocalTerminalSession: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var workingDirectoryPath = ""
    @Published private(set) var exitStatus: Int32?
    @Published private(set) var startupError: String?
    /// Optional disambiguator when multiple tabs share a project name.
    @Published var tabSuffix: String = ""

    /// Retained raw PTY bytes so the view can restore after the panel is hidden.
    private(set) var scrollback = Data()
    private let maxScrollbackBytes = 512_000

    private var process: Process?
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var pendingOutput = Data()
    private var flushScheduled = false
    private var columns: UInt16 = 100
    private var rows: UInt16 = 24

    weak var outputSink: DesktopTerminalOutputSink?

    var tabTitle: String {
        let name = URL(fileURLWithPath: workingDirectoryPath).lastPathComponent
        let base = name.isEmpty ? "/" : name
        return tabSuffix.isEmpty ? base : "\(base)\(tabSuffix)"
    }

    func ensureStarted(in directory: URL, columns: Int, rows: Int) {
        workingDirectoryPath = directory.path
        self.columns = UInt16(clamping: max(20, columns))
        self.rows = UInt16(clamping: max(5, rows))
        guard !isRunning, !isStarting else { return }
        startProcess()
    }

    func restart(in directory: URL, columns: Int, rows: Int) {
        terminate(clearScrollback: true)
        workingDirectoryPath = directory.path
        self.columns = UInt16(clamping: max(20, columns))
        self.rows = UInt16(clamping: max(5, rows))
        startProcess()
    }

    func write(_ data: Data) {
        guard isRunning, masterFD >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = Darwin.write(masterFD, base, buffer.count)
        }
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    func resize(columns: Int, rows: Int) {
        self.columns = UInt16(clamping: max(20, columns))
        self.rows = UInt16(clamping: max(5, rows))
        guard masterFD >= 0 else { return }
        var size = winsize(
            ws_row: self.rows,
            ws_col: self.columns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    func terminate(clearScrollback: Bool = false) {
        readSource?.cancel()
        readSource = nil
        if masterFD >= 0 {
            _ = Darwin.close(masterFD)
            masterFD = -1
        }
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
        isRunning = false
        isStarting = false
        pendingOutput.removeAll(keepingCapacity: false)
        flushScheduled = false
        if clearScrollback {
            scrollback = Data()
            outputSink?.terminalReplaceAll(Data())
        }
    }

    func attach(sink: DesktopTerminalOutputSink) {
        outputSink = sink
        sink.terminalReplaceAll(scrollback)
    }

    func detach(sink: DesktopTerminalOutputSink) {
        if outputSink === sink {
            outputSink = nil
        }
    }

    private func startProcess() {
        startupError = nil
        exitStatus = nil
        isStarting = true

        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            isStarting = false
            startupError = "Could not open a terminal device."
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login + interactive so ~/.zprofile and ~/.zshrc PATH hooks apply (nvm, brew, etc.).
        process.arguments = ["-il"]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
        process.environment = Self.shellEnvironment()

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                self?.handleTermination(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            _ = Darwin.close(master)
            _ = Darwin.close(slave)
            isStarting = false
            startupError = error.localizedDescription
            return
        }

        // Parent keeps the master; slave belongs to the child.
        _ = Darwin.close(slave)
        masterFD = master
        self.process = process
        isRunning = true
        isStarting = false
        startReader(master: master)
    }

    private func startReader(master: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(master, &buffer, buffer.count)
            guard count > 0 else { return }
            let chunk = Data(buffer.prefix(count))
            DispatchQueue.main.async {
                self?.enqueueOutput(chunk)
            }
        }
        source.setCancelHandler { }
        readSource = source
        source.resume()
    }

    private func enqueueOutput(_ data: Data) {
        pendingOutput.append(data)
        guard !flushScheduled else { return }
        flushScheduled = true
        // Coalesce PTY bursts so the text view isn't rewritten per byte.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.flushOutput()
        }
    }

    private func flushOutput() {
        flushScheduled = false
        guard !pendingOutput.isEmpty else { return }
        let data = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        scrollback.append(data)
        if scrollback.count > maxScrollbackBytes {
            scrollback = Data(scrollback.suffix(maxScrollbackBytes))
        }
        outputSink?.terminalAppend(data)
    }

    private func handleTermination(status: Int32) {
        readSource?.cancel()
        readSource = nil
        if masterFD >= 0 {
            _ = Darwin.close(masterFD)
            masterFD = -1
        }
        process = nil
        isRunning = false
        isStarting = false
        exitStatus = status
        let notice = Data("\r\n[Process exited with status \(status)]\r\n".utf8)
        scrollback.append(notice)
        outputSink?.terminalAppend(notice)
    }

    private static func shellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = resolvedUserPATH()
        // Help TUIs and CLIs detect an interactive color terminal.
        env["FORCE_COLOR"] = env["FORCE_COLOR"] ?? "1"
        return env
    }

    private static var cachedUserPATH: String?
    private static let pathLock = NSLock()

    /// Prefer the user's real login-shell PATH so Homebrew/nvm/local CLIs resolve.
    private static func resolvedUserPATH() -> String {
        pathLock.lock()
        if let cachedUserPATH {
            pathLock.unlock()
            return cachedUserPATH
        }
        pathLock.unlock()

        let fallback = defaultPATH()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "print -r -- $PATH"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.environment = [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "PATH": fallback,
            "TERM": "dumb",
        ]

        let resolved: String
        do {
            try process.run()
            // Don't hang the UI if the user's shell init is slow/broken.
            let deadline = Date().addingTimeInterval(1.5)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.terminate()
                resolved = fallback
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                resolved = text.isEmpty ? fallback : mergePATH(preferred: text, fallback: fallback)
            }
        } catch {
            resolved = fallback
        }

        pathLock.lock()
        cachedUserPATH = resolved
        pathLock.unlock()
        return resolved
    }

    private static func defaultPATH() -> String {
        let home = NSHomeDirectory()
        let extras = [
            "\(home)/.local/bin",
            "\(home)/.composio",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        return mergePATH(preferred: extras.joined(separator: ":"), fallback: ProcessInfo.processInfo.environment["PATH"] ?? "")
    }

    private static func mergePATH(preferred: String, fallback: String) -> String {
        var parts: [String] = []
        var seen = Set<String>()
        for part in (preferred.split(separator: ":") + fallback.split(separator: ":")).map(String.init) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            parts.append(trimmed)
        }
        return parts.joined(separator: ":")
    }
}

@MainActor
protocol DesktopTerminalOutputSink: AnyObject {
    func terminalReplaceAll(_ data: Data)
    func terminalAppend(_ data: Data)
}

/// Owns one or more docked terminal tabs for the workspace panel.
@MainActor
final class DesktopLocalTerminalHub: ObservableObject {
    @Published private(set) var tabs: [DesktopLocalTerminalSession] = []
    @Published var selectedTabID: UUID?

    var selectedSession: DesktopLocalTerminalSession? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first(where: { $0.id == selectedTabID }) ?? tabs.first
    }

    func ensureActiveTab(in directory: URL, columns: Int, rows: Int) {
        if tabs.isEmpty {
            _ = addTab(in: directory, columns: columns, rows: rows)
            return
        }
        selectedSession?.ensureStarted(in: directory, columns: columns, rows: rows)
        refreshTabTitles()
    }

    @discardableResult
    func addTab(in directory: URL, columns: Int, rows: Int) -> DesktopLocalTerminalSession {
        let session = DesktopLocalTerminalSession()
        tabs.append(session)
        selectedTabID = session.id
        session.ensureStarted(in: directory, columns: columns, rows: rows)
        refreshTabTitles()
        objectWillChange.send()
        return session
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    /// Closes one tab. Returns `true` when the panel should stay open.
    @discardableResult
    func closeTab(_ id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return !tabs.isEmpty
        }
        let session = tabs[index]
        session.terminate(clearScrollback: true)
        tabs.remove(at: index)
        if selectedTabID == id {
            if tabs.indices.contains(index) {
                selectedTabID = tabs[index].id
            } else {
                selectedTabID = tabs.last?.id
            }
        }
        refreshTabTitles()
        objectWillChange.send()
        return !tabs.isEmpty
    }

    func restartSelected(in directory: URL, columns: Int, rows: Int) {
        selectedSession?.restart(in: directory, columns: columns, rows: rows)
        refreshTabTitles()
    }

    func resizeAll(columns: Int, rows: Int) {
        for tab in tabs {
            tab.resize(columns: columns, rows: rows)
        }
    }

    func relocateAll(to directory: URL, columns: Int, rows: Int) {
        for tab in tabs {
            if tab.isRunning || tab.isStarting {
                tab.restart(in: directory, columns: columns, rows: rows)
            } else {
                tab.ensureStarted(in: directory, columns: columns, rows: rows)
            }
        }
        refreshTabTitles()
    }

    func terminateAll() {
        for tab in tabs {
            tab.terminate(clearScrollback: true)
        }
        tabs.removeAll()
        selectedTabID = nil
        objectWillChange.send()
    }

    private func refreshTabTitles() {
        var counts: [String: Int] = [:]
        for tab in tabs {
            counts[tabBaseName(tab), default: 0] += 1
        }
        var assigned: [String: Int] = [:]
        for tab in tabs {
            let base = tabBaseName(tab)
            if counts[base, default: 0] <= 1 {
                tab.tabSuffix = ""
                continue
            }
            let next = assigned[base, default: 0] + 1
            assigned[base] = next
            tab.tabSuffix = " \(next)"
        }
    }

    private func tabBaseName(_ tab: DesktopLocalTerminalSession) -> String {
        let path = tab.workingDirectoryPath.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : tab.workingDirectoryPath
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "/" : name
    }
}
