// FILE: CodexAppServerClient.swift
// Purpose: Owns one local `codex app-server` subprocess and its newline-delimited JSON-RPC stream.
// Layer: Desktop app service
// Depends on: Foundation, the locally installed Codex CLI

import Darwin
@preconcurrency import Foundation

enum CodexAppServerClientError: LocalizedError {
    case executableMissing
    case processUnavailable(String)
    case malformedResponse(String)
    case rpc(code: Int?, message: String)
    case unsupportedCapability(String)
    case timeout(String)
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            return "Codex CLI was not found. Install Codex or set CODEX_EXECUTABLE to its path."
        case .processUnavailable(let message):
            return message
        case .malformedResponse(let method):
            return "Codex returned an unreadable response for \(method)."
        case .rpc(_, let message):
            return message
        case .unsupportedCapability(let capability):
            return "This Codex runtime does not support \(capability)."
        case .timeout(let method):
            return "Codex did not respond to \(method) in time."
        case .invalidInput(let message):
            return message
        }
    }
}

private enum ParsedCodexStdoutEvent: @unchecked Sendable {
    case objects([[String: Any]])
    case terminated(status: Int32, processIdentity: ObjectIdentifier)
}

@MainActor
final class CodexAppServerClient {
    typealias JSONObject = [String: Any]

    var eventHandler: ((JSONObject, CodexAppServerRoute) -> Void)?
    var serverRequestHandler: ((JSONObject, CodexAppServerRoute) -> Bool)?
    var terminationHandler: ((String?) -> Void)?
    var capabilitiesHandler: ((CodexAppServerCapabilities) -> Void)?

    private struct PendingClientRequest {
        let route: CodexAppServerRoute
        let completion: (Result<JSONObject, Error>) -> Void
        var timeoutTask: Task<Void, Never>?
    }

    private static let maximumStderrDiagnosticBytes = 64 * 1_024
    private static let maximumStdoutEventsPerActorSlice = 32

    private var process: Process?
    private var standardInput: FileHandle?
    /// Retain enough of stderr to explain a crash without retaining an unbounded
    /// diagnostic stream for the lifetime of a chatty runtime.
    private var stderrTail = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingClientRequest] = [:]
    private var inboundServerRoutes: [DesktopRPCRequestID: CodexAppServerRoute] = [:]
    private var stoppedIntentionally = false
    private var generation = UUID()
    private var stdoutReader: CodexStdoutReader?
    private var stdoutChannel: CodexStdoutChannel?
    private var stdoutDrainGeneration: UUID?
    private var stdoutDrainTask: Task<Void, Never>?

    private(set) var capabilities = CodexAppServerCapabilities.unavailable

    var isRunning: Bool { process?.isRunning == true }

    func start(overlay: CodexAppServerLaunchOverlay? = nil) async throws {
        if isRunning, standardInput != nil { return }

        guard let executableURL = Self.resolveCodexExecutable() else {
            throw CodexAppServerClientError.executableMissing
        }

        if process != nil || !pendingRequests.isEmpty {
            stop()
        }
        stoppedIntentionally = false
        let generation = UUID()
        self.generation = generation
        cancelAndClearStdoutDrain()
        stderrTail.removeAll(keepingCapacity: false)

        let stdoutChannel = AsyncStream.makeStream(of: ParsedCodexStdoutEvent.self)
        let stdoutStream = stdoutChannel.stream
        let channel = CodexStdoutChannel(continuation: stdoutChannel.continuation)
        self.stdoutChannel = channel
        stdoutDrainGeneration = generation
        stdoutDrainTask = Task { @MainActor [weak self, stdoutStream] in
            guard let self else { return }
            await self.drainParsedStdout(stdoutStream, channel: channel, generation: generation)
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        var arguments = ["app-server", "--stdio"]
        if let overlay {
            arguments.append(contentsOf: overlay.arguments)
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in overlay.environment {
                environment[key] = value
            }
            process.environment = environment
        }
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stdoutReader = CodexStdoutReader(
            handle: outputPipe.fileHandleForReading,
            channel: channel
        )
        self.stdoutReader = stdoutReader
        outputPipe.fileHandleForReading.readabilityHandler = { _ in
            stdoutReader.readAvailableData()
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let client = self
            Task { @MainActor [client, data, generation] in
                client?.appendStderr(data, generation: generation)
            }
        }

        process.terminationHandler = { process in
            stdoutReader.finish(
                status: process.terminationStatus,
                processIdentity: ObjectIdentifier(process)
            )
        }

        do {
            try process.run()
        } catch {
            stdoutReader.cancel()
            self.generation = UUID()
            cancelAndClearStdoutDrain()
            throw CodexAppServerClientError.processUnavailable("Codex could not start: \(error.localizedDescription)")
        }

        self.process = process
        standardInput = inputPipe.fileHandleForWriting

        do {
            let initializeResponse = try await request(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "veo-macos",
                        "title": "Veo",
                        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                    ],
                    "capabilities": [
                        "experimentalApi": true,
                        // Veo supports the protocol's typed form mode. Keep the
                        // provider-specific opaque OpenAI form extension disabled.
                        "mcpServerOpenaiFormElicitation": false,
                    ],
                ]
            )
            guard self.generation == generation, isRunning else {
                throw CodexAppServerClientError.processUnavailable("The local Codex runtime stopped during initialization.")
            }
            capabilities = .negotiated(
                initializeResponse: initializeResponse,
                experimentalAPIEnabled: true,
                mcpFormElicitationEnabled: false
            )
            try sendNotification(method: "initialized")
        } catch {
            if self.generation == generation {
                stop()
            }
            throw error
        }
    }

    func stop() {
        stoppedIntentionally = true
        let input = standardInput
        let process = process
        generation = UUID()
        cancelAndClearStdoutDrain()
        standardInput = nil
        self.process = nil
        capabilities = .unavailable
        inboundServerRoutes.removeAll()
        stderrTail.removeAll(keepingCapacity: false)

        let error = CodexAppServerClientError.processUnavailable("The local Codex runtime restarted.")
        completeAllPendingRequests(with: error)

        input?.closeFile()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    func request(
        method: String,
        params: JSONObject? = nil,
        maturity: CodexAPIMaturity = .stable,
        timeoutSeconds: Double? = 60
    ) async throws -> JSONObject {
        guard isRunning, standardInput != nil else {
            throw CodexAppServerClientError.processUnavailable("The local Codex runtime is not running.")
        }
        guard method == "initialize" || capabilities.supports(method: method, maturity: maturity) else {
            throw CodexAppServerClientError.unsupportedCapability(method)
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let route = CodexAppServerRoute(
            direction: .clientRequest,
            method: method,
            threadID: params?.string("threadId"),
            rpcID: .number(requestID)
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = PendingClientRequest(
                route: route,
                completion: { result in continuation.resume(with: result) },
                timeoutTask: nil
            )

            do {
                var request: JSONObject = [
                    "id": requestID,
                    "method": method,
                ]
                if let params { request["params"] = params }
                try send(request)
            } catch {
                takePendingRequest(requestID)?.completion(.failure(error))
                return
            }

            if let timeoutSeconds {
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled,
                          let pending = self?.takePendingRequest(requestID) else { return }
                    pending.completion(.failure(CodexAppServerClientError.timeout(method)))
                }
                if var pending = pendingRequests[requestID] {
                    pending.timeoutTask = timeoutTask
                    pendingRequests[requestID] = pending
                } else {
                    timeoutTask.cancel()
                }
            }
        }
    }

    func request(
        method: String,
        params: JSONObject? = nil,
        requiring capability: CodexAppServerCapability,
        timeoutSeconds: Double? = 60
    ) async throws -> JSONObject {
        guard capabilities.supports(capability) else {
            throw CodexAppServerClientError.unsupportedCapability(capability.rawValue)
        }
        return try await request(
            method: method,
            params: params,
            maturity: capability.maturity,
            timeoutSeconds: timeoutSeconds
        )
    }

    func sendNotification(method: String, params: JSONObject? = nil) throws {
        var notification: JSONObject = ["method": method]
        if let params {
            notification["params"] = params
        }
        try send(notification)
    }

    func respond(to requestID: DesktopRPCRequestID, result: JSONObject) throws {
        try send([
            "id": requestID.rawValue,
            "result": result,
        ])
        inboundServerRoutes.removeValue(forKey: requestID)
    }

    private func send(_ object: JSONObject) throws {
        guard let standardInput else {
            throw CodexAppServerClientError.processUnavailable("The local Codex runtime is not running.")
        }

        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try standardInput.write(contentsOf: data)
    }

    private func drainParsedStdout(
        _ stream: AsyncStream<ParsedCodexStdoutEvent>,
        channel: CodexStdoutChannel,
        generation: UUID
    ) async {
        var eventsInActorSlice = 0
        for await event in stream {
            defer { channel.didConsumeEvent() }
            guard !Task.isCancelled,
                  self.generation == generation,
                  stdoutDrainGeneration == generation else { return }

            let objects: [JSONObject]
            switch event {
            case .objects(let batch):
                objects = batch
            case .terminated(let status, let processIdentity):
                processDidTerminate(
                    status: status,
                    processIdentity: processIdentity,
                    generation: generation
                )
                return
            }

            for object in objects {
                if eventsInActorSlice == Self.maximumStdoutEventsPerActorSlice {
                    eventsInActorSlice = 0
                    await Task.yield()
                }
                // Routing callbacks can synchronously stop or replace the process.
                guard !Task.isCancelled,
                      self.generation == generation,
                      stdoutDrainGeneration == generation else { return }
                route(object)
                eventsInActorSlice += 1
            }
            // Release each parsed batch before waiting for more stdout. Natural
            // termination shares this FIFO so final responses reach their callers.
        }
    }

    private func cancelAndClearStdoutDrain() {
        // Wake blocked producers before retiring their reader. No protocol data is
        // dropped during normal operation; cancellation deliberately retires it.
        stdoutChannel?.finish()
        stdoutChannel = nil
        stdoutReader?.cancel()
        stdoutReader = nil
        stdoutDrainTask?.cancel()
        stdoutDrainTask = nil
        stdoutDrainGeneration = nil
    }

    private func appendStderr(_ data: Data, generation: UUID) {
        guard self.generation == generation else { return }
        stderrTail.append(data)
        let excess = stderrTail.count - Self.maximumStderrDiagnosticBytes
        if excess > 0 {
            stderrTail.removeFirst(excess)
        }
    }

    private func route(_ object: JSONObject) {
        if let requestID = Self.jsonRPCRequestID(object["id"]),
           object["method"] == nil,
           let pending = takePendingRequest(requestID) {
            if let rpcError = object["error"] as? JSONObject {
                let code = (rpcError["code"] as? NSNumber)?.intValue
                let message = rpcError.string("message") ?? "Codex request failed."
                if code == -32601
                    || message.localizedCaseInsensitiveContains("requires experimentalApi capability") {
                    capabilities.recordUnavailable(method: pending.route.method)
                    capabilitiesHandler?(capabilities)
                }
                pending.completion(.failure(CodexAppServerClientError.rpc(
                    code: code,
                    message: message
                )))
            } else if let result = object["result"] as? JSONObject {
                pending.completion(.success(result))
            } else if object["result"] is NSNull {
                pending.completion(.success([:]))
            } else {
                pending.completion(.success([:]))
            }
            return
        }

        guard let route = CodexAppServerRoute.incoming(object) else { return }
        if route.method == "serverRequest/resolved",
           let params = object["params"] as? [String: Any],
           let requestID = DesktopRPCRequestID(params["requestId"]) {
            inboundServerRoutes.removeValue(forKey: requestID)
        }
        if let requestID = route.rpcID {
            inboundServerRoutes[requestID] = route
        }
        if route.direction == .serverRequest {
            if serverRequestHandler?(object, route) == true {
                return
            }
            respondToUnhandledServerRequest(object)
        } else {
            eventHandler?(object, route)
        }
    }

    private func respondToUnhandledServerRequest(_ object: JSONObject) {
        guard let id = object["id"], let method = object.string("method") else { return }
        defer {
            if let requestID = DesktopRPCRequestID(id) {
                inboundServerRoutes.removeValue(forKey: requestID)
            }
        }

        let result: JSONObject
        if method == "item/permissions/requestApproval" {
            result = [
                "permissions": [:],
                "scope": "turn",
            ]
        } else if method == "item/commandExecution/requestApproval"
            || method == "item/fileChange/requestApproval" {
            result = ["decision": "decline"]
        } else if method == "item/tool/requestUserInput" {
            result = ["answers": [:]]
        } else if method == "mcpServer/elicitation/request" {
            result = ["action": "decline"]
        } else if method == "currentTime/read" {
            result = ["currentTimeAt": Int(Date().timeIntervalSince1970)]
        } else if method == "item/tool/call" {
            result = ["contentItems": [], "success": false]
        } else {
            try? send([
                "id": id,
                "error": [
                    "code": -32601,
                    "message": "Veo does not handle \(method) yet.",
                ],
            ])
            return
        }

        try? send(["id": id, "result": result])
    }

    private func processDidTerminate(
        status: Int32,
        processIdentity: ObjectIdentifier,
        generation: UUID
    ) {
        guard self.generation == generation else { return }
        guard let activeProcess = process, ObjectIdentifier(activeProcess) == processIdentity else { return }
        self.generation = UUID()
        cancelAndClearStdoutDrain()
        self.process = nil
        standardInput = nil
        capabilities = .unavailable
        inboundServerRoutes.removeAll()

        let detail = String(decoding: stderrTail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .suffix(3)
            .joined(separator: "\n")
            .nilIfEmpty
        stderrTail.removeAll(keepingCapacity: false)
        let message = stoppedIntentionally
            ? nil
            : (detail ?? "Codex exited with status \(status).")

        let error = CodexAppServerClientError.processUnavailable(message ?? "Codex stopped.")
        completeAllPendingRequests(with: error)
        terminationHandler?(message)
    }

    private func takePendingRequest(_ requestID: Int) -> PendingClientRequest? {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return nil }
        pending.timeoutTask?.cancel()
        return pending
    }

    private func completeAllPendingRequests(with error: Error) {
        let pending = Array(pendingRequests.values)
        pendingRequests.removeAll()
        for request in pending {
            request.timeoutTask?.cancel()
            request.completion(.failure(error))
        }
    }

    private static func jsonRPCRequestID(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        return nil
    }

    nonisolated static func resolveCodexExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []

        if let explicit = environment["CODEX_EXECUTABLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            candidates.append(explicit)
        }

        candidates += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/codex" }
        candidates += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }
}

/// A bounded, lossless bridge from the parser queue to the main actor. Blocking is
/// limited to background producers, which lets the OS pipe apply backpressure.
private final class CodexStdoutChannel: @unchecked Sendable {
    private let continuation: AsyncStream<ParsedCodexStdoutEvent>.Continuation
    private let condition = NSCondition()
    private let maximumPendingEvents = 8
    private var pendingEvents = 0
    private var finished = false

    init(continuation: AsyncStream<ParsedCodexStdoutEvent>.Continuation) {
        self.continuation = continuation
    }

    @discardableResult
    func send(_ event: ParsedCodexStdoutEvent) -> Bool {
        condition.lock()
        while !finished && pendingEvents >= maximumPendingEvents {
            condition.wait()
        }
        guard !finished else {
            condition.unlock()
            return false
        }
        pendingEvents += 1
        continuation.yield(event)
        condition.unlock()
        return true
    }

    func didConsumeEvent() {
        condition.lock()
        pendingEvents = max(0, pendingEvents - 1)
        condition.signal()
        condition.unlock()
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        continuation.finish()
        condition.unlock()
    }
}

/// Serializes bounded pipe reads with the final buffered read, keeping process
/// termination behind every response without scheduling one actor task per chunk.
private final class CodexStdoutReader: @unchecked Sendable {
    // Darwin FIONREAD is _IOR('f', 127, int); Swift cannot import that C macro.
    private static let bytesAvailableRequest = UInt(IOC_OUT)
        | (UInt(MemoryLayout<CInt>.size) << 16)
        | (UInt(UInt8(ascii: "f")) << 8)
        | 127
    private static let maximumReadBytes = 64 * 1_024
    private static let maximumObjectsPerBatch = 128

    private let handle: FileHandle
    private let splitter = NDJSONStreamSplitter()
    // A replacement runtime never waits behind an old generation's parser work.
    private let queue = DispatchQueue(label: "com.ash.veo.codex-stdout", qos: .userInitiated)
    private let channel: CodexStdoutChannel
    private let pendingReads = DispatchSemaphore(value: 4)
    private let lock = NSLock()
    private var finished = false

    init(handle: FileHandle, channel: CodexStdoutChannel) {
        self.handle = handle
        self.channel = channel
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    func readAvailableData() {
        // Bound raw queued bytes as well as parsed actor events. Never wait while
        // holding the reader lock: Stop must be able to cancel a saturated stream.
        pendingReads.wait()
        lock.lock()
        guard !finished else {
            lock.unlock()
            pendingReads.signal()
            return
        }
        let data = readBufferedData(maximumBytes: Self.maximumReadBytes)
        guard !data.isEmpty else {
            lock.unlock()
            pendingReads.signal()
            return
        }
        queue.async { [self, data] in
            defer { pendingReads.signal() }
            publish(data)
        }
        lock.unlock()
    }

    func finish(status: Int32, processIdentity: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        handle.readabilityHandler = nil
        // Fence every already queued read before the final parser work. Descendants
        // may retain stdout, so drain the current byte count instead of waiting for EOF.
        queue.async { [self] in
            drainBufferedTail()
            channel.send(.terminated(status: status, processIdentity: processIdentity))
            channel.finish()
            try? handle.close()
        }
    }

    private func publish(_ data: Data) {
        let objects = splitter.append(data)
        for start in stride(from: 0, to: objects.count, by: Self.maximumObjectsPerBatch) {
            let end = min(start + Self.maximumObjectsPerBatch, objects.count)
            guard channel.send(.objects(Array(objects[start..<end]))) else { return }
        }
    }

    private func readBufferedData(maximumBytes: Int) -> Data {
        let descriptor = handle.fileDescriptor
        var available: Int32 = 0
        guard ioctl(descriptor, Self.bytesAvailableRequest, &available) == 0, available > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: min(maximumBytes, Int(available)))
        var count: Int
        repeat {
            count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!, buffer.count)
            }
        } while count < 0 && errno == EINTR
        guard count > 0 else { return Data() }
        return bytes.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: count) }
    }

    private func drainBufferedTail() {
        let descriptor = handle.fileDescriptor
        var remaining: Int32 = 0
        guard ioctl(descriptor, Self.bytesAvailableRequest, &remaining) == 0, remaining > 0 else { return }
        // A snapshot prevents a surviving descendant from extending the final drain.
        while remaining > 0 {
            let data = readBufferedData(maximumBytes: min(Self.maximumReadBytes, Int(remaining)))
            guard !data.isEmpty else { return }
            remaining -= Int32(data.count)
            publish(data)
        }
    }

    func cancel() {
        // This releases a parser blocked on backpressure, including reads waiting
        // on its semaphore, before acquiring the short-lived pipe-read lock.
        channel.finish()
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        handle.readabilityHandler = nil
        queue.async { [handle] in try? handle.close() }
    }
}

/// Thread-safe newline splitter + JSON parser for app-server stdout.
/// Keeps framing and JSON decoding off the main actor.
private final class NDJSONStreamSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var discardingOversizedLine = false
    private let maximumLineBytes: Int

    init(maximumLineBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumLineBytes = maximumLineBytes
    }

    func append(_ data: Data) -> [[String: Any]] {
        guard !data.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        var objects: [[String: Any]] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let newline = memchr(base + offset, 0x0A, raw.count - offset)
                let segmentEnd = newline.map { UnsafeRawPointer($0) - base } ?? raw.count
                let segmentCount = segmentEnd - offset
                if !discardingOversizedLine {
                    if segmentCount <= maximumLineBytes - buffer.count {
                        buffer.append(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: segmentCount)
                    } else {
                        // Discard through this line's delimiter, not the next frame.
                        // Otherwise an oversized payload can corrupt a later response.
                        buffer.removeAll(keepingCapacity: false)
                        discardingOversizedLine = true
                    }
                }
                guard newline != nil else { break }
                if !discardingOversizedLine, !buffer.isEmpty,
                   let rawObject = try? JSONSerialization.jsonObject(with: buffer),
                   let object = rawObject as? [String: Any] {
                    objects.append(object)
                }
                buffer.removeAll(keepingCapacity: true)
                discardingOversizedLine = false
                offset = segmentEnd + 1
            }
        }
        return objects
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
