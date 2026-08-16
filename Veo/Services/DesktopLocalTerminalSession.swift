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
    private let maxScrollbackBytes = 512_000
    private var scrollbackChunks: [Data] = []
    private var firstScrollbackChunkIndex = 0
    private var scrollbackByteCount = 0

    private var process: Process?
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var outputBuffer = DesktopTerminalOutputBuffer(maximumBytes: 256_000)
    private var flushScheduled = false
    private var pendingTerminationStatus: Int32?
    private var readerReachedEnd = false
    private var columns: UInt16 = 80
    private var rows: UInt16 = 24

    weak var outputSink: DesktopTerminalOutputSink?

    init() {
        // Resolve the full login-shell PATH before a later tab needs it, but never
        // block the main actor or first terminal launch on a user's shell startup.
        DesktopTerminalPATHResolver.shared.prewarm()
    }

    /// Last winsize applied to the PTY (for seeding new tabs).
    var ptyColumns: Int { Int(columns) }
    var ptyRows: Int { Int(rows) }

    var tabTitle: String {
        let name = URL(fileURLWithPath: workingDirectoryPath).lastPathComponent
        let base = name.isEmpty ? "/" : name
        return tabSuffix.isEmpty ? base : "\(base)\(tabSuffix)"
    }

    func ensureStarted(in directory: URL, columns: Int, rows: Int) {
        workingDirectoryPath = directory.path
        applySize(columns: columns, rows: rows)
        guard !isRunning, !isStarting else { return }
        startProcess()
    }

    func restart(in directory: URL, columns: Int, rows: Int) {
        terminate(clearScrollback: true)
        workingDirectoryPath = directory.path
        applySize(columns: columns, rows: rows)
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
        // Ignore pre-layout junk so TUIs never see a 1-column winsize.
        guard columns >= 10, rows >= 3 else { return }
        let nextCols = UInt16(clamping: columns)
        let nextRows = UInt16(clamping: rows)
        let changed = nextCols != self.columns || nextRows != self.rows
        self.columns = nextCols
        self.rows = nextRows
        guard changed, masterFD >= 0 else { return }
        var size = winsize(
            ws_row: self.rows,
            ws_col: self.columns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    private func applySize(columns: Int, rows: Int) {
        self.columns = UInt16(clamping: max(10, columns))
        self.rows = UInt16(clamping: max(3, rows))
    }

    func terminate(clearScrollback: Bool = false) {
        pendingTerminationStatus = nil
        readerReachedEnd = false
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
        outputBuffer.reset()
        outputBuffer = DesktopTerminalOutputBuffer(maximumBytes: 256_000)
        flushScheduled = false
        if clearScrollback {
            scrollbackChunks.removeAll(keepingCapacity: false)
            firstScrollbackChunkIndex = 0
            scrollbackByteCount = 0
            outputSink?.terminalReplaceAll(Data())
        }
    }

    func attach(sink: DesktopTerminalOutputSink) {
        outputSink = sink
        sink.terminalReplaceAll(scrollbackSnapshot())
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
        pendingTerminationStatus = nil
        readerReachedEnd = false

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
        let outputBuffer = self.outputBuffer
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self, outputBuffer] in
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(master, &buffer, buffer.count)
            guard count > 0 else {
                let errorCode = errno
                if count == 0 || (errorCode != EAGAIN && errorCode != EINTR) {
                    DispatchQueue.main.async {
                        self?.readerReachedEnd(master: master, buffer: outputBuffer)
                    }
                }
                return
            }
            let chunk = Data(buffer.prefix(count))
            guard outputBuffer.append(chunk) else { return }
            DispatchQueue.main.async {
                self?.scheduleOutputFlush(for: outputBuffer)
            }
        }
        source.setCancelHandler { }
        readSource = source
        source.resume()
    }

    private func readerReachedEnd(master: Int32, buffer: DesktopTerminalOutputBuffer) {
        guard masterFD == master, buffer === outputBuffer, !readerReachedEnd else { return }
        readerReachedEnd = true
        readSource?.cancel()
        readSource = nil
        if let status = pendingTerminationStatus {
            finalizeTermination(status: status)
        }
    }

    private func scheduleOutputFlush(for buffer: DesktopTerminalOutputBuffer) {
        guard buffer === outputBuffer, buffer.hasPendingOutput else { return }
        guard !flushScheduled else { return }
        flushScheduled = true
        // Coalesce PTY bursts so the text view isn't rewritten per byte.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.flushOutput(for: buffer)
        }
    }

    private func flushOutput(for buffer: DesktopTerminalOutputBuffer) {
        guard buffer === outputBuffer else { return }
        flushScheduled = false
        let data = buffer.drain()
        guard !data.isEmpty else { return }
        appendToScrollback(data)
        outputSink?.terminalAppend(data)
    }

    private func handleTermination(status: Int32) {
        process = nil
        isRunning = false
        isStarting = false
        exitStatus = status
        pendingTerminationStatus = status
        if readerReachedEnd || readSource == nil {
            finalizeTermination(status: status)
        }
    }

    private func finalizeTermination(status: Int32) {
        guard pendingTerminationStatus == status else { return }
        pendingTerminationStatus = nil
        // The reader has observed EOF/EIO, so all readable terminal bytes are in the
        // synchronized buffer before it is drained and the master descriptor is closed.
        flushOutput(for: outputBuffer)
        readSource?.cancel()
        readSource = nil
        if masterFD >= 0 {
            _ = Darwin.close(masterFD)
            masterFD = -1
        }
        outputBuffer.reset()
        outputBuffer = DesktopTerminalOutputBuffer(maximumBytes: 256_000)
        flushScheduled = false
        readerReachedEnd = false
        let notice = Data("\r\n[Process exited with status \(status)]\r\n".utf8)
        appendToScrollback(notice)
        outputSink?.terminalAppend(notice)
    }

    private func appendToScrollback(_ data: Data) {
        guard !data.isEmpty else { return }
        if data.count >= maxScrollbackBytes {
            let tail = Data(data.suffix(maxScrollbackBytes))
            scrollbackChunks = [tail]
            firstScrollbackChunkIndex = 0
            scrollbackByteCount = tail.count
            return
        }

        scrollbackChunks.append(data)
        scrollbackByteCount += data.count
        while scrollbackByteCount > maxScrollbackBytes,
              firstScrollbackChunkIndex < scrollbackChunks.count {
            let oldest = scrollbackChunks[firstScrollbackChunkIndex]
            firstScrollbackChunkIndex += 1
            scrollbackByteCount -= oldest.count
        }
        compactDiscardedScrollbackChunksIfNeeded()
    }

    private func scrollbackSnapshot() -> Data {
        guard firstScrollbackChunkIndex < scrollbackChunks.count else { return Data() }
        var snapshot = Data()
        snapshot.reserveCapacity(scrollbackByteCount)
        for chunk in scrollbackChunks[firstScrollbackChunkIndex...] {
            snapshot.append(chunk)
        }
        return snapshot
    }

    private func compactDiscardedScrollbackChunksIfNeeded() {
        guard firstScrollbackChunkIndex >= 64,
              firstScrollbackChunkIndex * 2 >= scrollbackChunks.count else { return }
        scrollbackChunks.removeFirst(firstScrollbackChunkIndex)
        firstScrollbackChunkIndex = 0
    }

    private static func shellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        var path = DesktopTerminalPATHResolver.shared.pathOrFallback()
        if let agentBin = DesktopTerminalPreferences.syncAgentCLIWrappers() {
            path = agentBin.path + ":" + path
        }
        env["PATH"] = path
        // GUI / agent launches often inherit NO_COLOR or FORCE_COLOR=0; strip those so
        // chalk/Ink TUIs (Claude Code, etc.) emit ANSI in the docked PTY.
        env.removeValue(forKey: "NO_COLOR")
        env.removeValue(forKey: "CLICOLOR")
        env["CLICOLOR_FORCE"] = "1"
        env["FORCE_COLOR"] = "3"
        // Never inherit stale size hints from the GUI process; winsize is authoritative.
        env.removeValue(forKey: "COLUMNS")
        env.removeValue(forKey: "LINES")
        return env
    }

}

/// Caches a login-shell PATH without ever making terminal startup wait on a
/// user's shell configuration. It intentionally lives outside the main-actor
/// session so the resolver can own its background work safely.
private final class DesktopTerminalPATHResolver: @unchecked Sendable {
    static let shared = DesktopTerminalPATHResolver()

    private let lock = NSLock()
    private var cachedPath: String?
    private var isResolving = false

    func prewarm() {
        lock.lock()
        guard cachedPath == nil, !isResolving else {
            lock.unlock()
            return
        }
        isResolving = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let fallback = Self.defaultPATH()
            let resolved = self.resolveUserPATH(fallback: fallback)
            self.lock.lock()
            self.cachedPath = resolved
            self.isResolving = false
            self.lock.unlock()
        }
    }

    func pathOrFallback() -> String {
        lock.lock()
        let cached = cachedPath
        lock.unlock()
        return cached ?? Self.defaultPATH()
    }

    private func resolveUserPATH(fallback: String) -> String {
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

        do {
            try process.run()
            // This resolver is off-main; cap broken shell configuration without
            // delaying the terminal UI or process startup.
            let deadline = Date().addingTimeInterval(1.5)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.terminate()
                return fallback
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? fallback : Self.mergePATH(preferred: text, fallback: fallback)
        } catch {
            return fallback
        }
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
        return mergePATH(
            preferred: extras.joined(separator: ":"),
            fallback: ProcessInfo.processInfo.environment["PATH"] ?? ""
        )
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

/// Bounded producer-side coalescing for a PTY read source. The read queue only
/// posts one main-queue wakeup per burst, preventing high-output commands from
/// filling the main queue with one task per 16 KiB read.
private final class DesktopTerminalOutputBuffer: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var firstChunkIndex = 0
    private var byteCount = 0
    private var flushRequested = false
    private var didTruncate = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(1, maximumBytes)
    }

    var hasPendingOutput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstChunkIndex < chunks.count
    }

    /// Returns `true` only when this append needs a new main-queue wakeup.
    func append(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }

        chunks.append(data)
        byteCount += data.count
        while byteCount > maximumBytes, firstChunkIndex < chunks.count - 1 {
            let oldest = chunks[firstChunkIndex]
            firstChunkIndex += 1
            byteCount -= oldest.count
            didTruncate = true
        }
        if byteCount > maximumBytes, let newest = chunks.last {
            let tail = Data(newest.suffix(maximumBytes))
            chunks = [tail]
            firstChunkIndex = 0
            byteCount = tail.count
            didTruncate = true
        }
        compactDiscardedChunksIfNeeded()

        guard !flushRequested else { return false }
        flushRequested = true
        return true
    }

    func drain() -> Data {
        lock.lock()
        defer { lock.unlock() }

        flushRequested = false
        guard firstChunkIndex < chunks.count else {
            didTruncate = false
            return Data()
        }
        var output = Data()
        let notice = didTruncate
            ? Data("\r\n\u{001B}[0m[Terminal output truncated while Veo was catching up]\r\n".utf8)
            : Data()
        output.reserveCapacity(byteCount + notice.count)
        output.append(notice)
        for chunk in chunks[firstChunkIndex...] {
            output.append(chunk)
        }
        chunks.removeAll(keepingCapacity: true)
        firstChunkIndex = 0
        byteCount = 0
        didTruncate = false
        return output
    }

    func reset() {
        lock.lock()
        chunks.removeAll(keepingCapacity: false)
        firstChunkIndex = 0
        byteCount = 0
        flushRequested = false
        didTruncate = false
        lock.unlock()
    }

    private func compactDiscardedChunksIfNeeded() {
        guard firstChunkIndex >= 64, firstChunkIndex * 2 >= chunks.count else { return }
        chunks.removeFirst(firstChunkIndex)
        firstChunkIndex = 0
    }
}

@MainActor
protocol DesktopTerminalOutputSink: AnyObject {
    func terminalReplaceAll(_ data: Data)
    func terminalAppend(_ data: Data)
}

struct DesktopAgentCLIPermissionPrompt: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let commandLine: String

    init(sessionID: UUID, commandLine: String) {
        self.id = UUID()
        self.sessionID = sessionID
        self.commandLine = commandLine
    }

    var commandName: String {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
        return token.split(separator: "/").last.map(String.init) ?? token
    }
}

/// Owns one or more docked terminal tabs for the workspace panel.
@MainActor
final class DesktopLocalTerminalHub: ObservableObject {
    @Published private(set) var tabs: [DesktopLocalTerminalSession] = []
    @Published var selectedTabID: UUID?
    @Published private(set) var agentCLIPermissionPrompt: DesktopAgentCLIPermissionPrompt?

    var selectedSession: DesktopLocalTerminalSession? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first(where: { $0.id == selectedTabID }) ?? tabs.first
    }

    var isAgentCLIPermissionPromptPresented: Bool {
        agentCLIPermissionPrompt != nil
    }

    func requestAgentCLIPermission(sessionID: UUID, commandLine: String) {
        guard agentCLIPermissionPrompt == nil else { return }
        agentCLIPermissionPrompt = DesktopAgentCLIPermissionPrompt(
            sessionID: sessionID,
            commandLine: commandLine
        )
    }

    func allowAgentCLIsFromPrompt() {
        guard let prompt = agentCLIPermissionPrompt else { return }
        DesktopTerminalPreferences.setAgentCLIsEnabled(true)
        _ = DesktopTerminalPreferences.syncAgentCLIWrappers()
        agentCLIPermissionPrompt = nil
        session(for: prompt.sessionID)?.write("\r")
    }

    func denyAgentCLIsFromPrompt() {
        guard let prompt = agentCLIPermissionPrompt else { return }
        agentCLIPermissionPrompt = nil
        // Cancel the pending line so the shell returns to a clean prompt.
        session(for: prompt.sessionID)?.write("\u{03}")
    }

    private func session(for id: UUID) -> DesktopLocalTerminalSession? {
        tabs.first(where: { $0.id == id })
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
        if agentCLIPermissionPrompt?.sessionID == id {
            agentCLIPermissionPrompt = nil
        }
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
        agentCLIPermissionPrompt = nil
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
