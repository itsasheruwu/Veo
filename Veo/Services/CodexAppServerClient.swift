// FILE: CodexAppServerClient.swift
// Purpose: Owns one local `codex app-server` subprocess and its newline-delimited JSON-RPC stream.
// Layer: Desktop app service
// Depends on: Foundation, the locally installed Codex CLI

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
    private let stdoutSplitter = NDJSONStreamSplitter()
    private let stdoutQueue = DispatchQueue(label: "com.ash.veo.codex-stdout", qos: .userInitiated)

    private(set) var capabilities = CodexAppServerCapabilities.unavailable

    var isRunning: Bool { process?.isRunning == true }

    func start() async throws {
        if isRunning, standardInput != nil { return }

        guard let executableURL = Self.resolveCodexExecutable() else {
            throw CodexAppServerClientError.executableMissing
        }

        stoppedIntentionally = false
        let generation = UUID()
        self.generation = generation
        stderrTail.removeAll(keepingCapacity: false)
        stdoutSplitter.reset()

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let splitter = stdoutSplitter
        let queue = stdoutQueue
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Split + JSON-parse off the main actor. Flooding Task { @MainActor }
            // with every pipe chunk was beachballing the UI under chatty traffic.
            queue.async {
                let objects = splitter.append(data)
                guard !objects.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.routeParsedStdout(objects, generation: generation)
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let client = self
            Task { @MainActor [client, data, generation] in
                client?.appendStderr(data, generation: generation)
            }
        }

        process.terminationHandler = { [weak self] process in
            let client = self
            let status = process.terminationStatus
            let processIdentity = ObjectIdentifier(process)
            Task { @MainActor [client, status, processIdentity, generation] in
                client?.processDidTerminate(
                    status: status,
                    processIdentity: processIdentity,
                    generation: generation
                )
            }
        }

        do {
            try process.run()
        } catch {
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
            capabilities = .negotiated(
                initializeResponse: initializeResponse,
                experimentalAPIEnabled: true,
                mcpFormElicitationEnabled: false
            )
            try sendNotification(method: "initialized")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        stoppedIntentionally = true
        let input = standardInput
        let process = process
        generation = UUID()
        standardInput = nil
        self.process = nil
        capabilities = .unavailable
        inboundServerRoutes.removeAll()
        stdoutSplitter.reset()
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

    private func routeParsedStdout(_ objects: [JSONObject], generation: UUID) {
        guard self.generation == generation else { return }
        if objects.count <= 64 {
            for object in objects {
                route(object)
            }
            return
        }
        // Large bursts (thread lists, tool streams) should not monopolize the UI turn.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, object) in objects.enumerated() {
                guard self.generation == generation else { return }
                self.route(object)
                if index % 32 == 31 {
                    await Task.yield()
                }
            }
        }
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

    private static func resolveCodexExecutable() -> URL? {
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

/// Thread-safe newline splitter + JSON parser for app-server stdout.
/// Keeps heavy scanning off the main actor.
private final class NDJSONStreamSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    /// Large enough for chatty `thread/list` pages (~1–2 MiB each). The no-newline
    /// fast path below avoids CPU spin while an incomplete line is buffered.
    private let maxBufferBytes = 32 * 1024 * 1024

    func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func append(_ data: Data) -> [[String: Any]] {
        guard !data.isEmpty else { return [] }

        lock.lock()
        // Incomplete JSON can arrive in large chunks. If this chunk has no newline,
        // no line can complete — just buffer and skip a full rescan.
        let chunkHasNewline = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            for index in 0..<raw.count where base[index] == 0x0A {
                return true
            }
            return false
        }

        buffer.append(data)
        if buffer.count > maxBufferBytes {
            // Drop only truly runaway unterminated payloads (not valid large RPC lines).
            buffer.removeAll(keepingCapacity: false)
            lock.unlock()
            return []
        }

        guard chunkHasNewline else {
            lock.unlock()
            return []
        }

        let snapshot = buffer
        var lines: [Data] = []
        var remainderStart = 0

        snapshot.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            var lineStart = 0
            var index = 0
            while index < count {
                if base[index] == 0x0A {
                    if index > lineStart {
                        lines.append(Data(bytes: base + lineStart, count: index - lineStart))
                    }
                    lineStart = index + 1
                }
                index += 1
            }
            remainderStart = lineStart
        }

        if remainderStart >= snapshot.count {
            buffer.removeAll(keepingCapacity: true)
        } else if remainderStart > 0 {
            buffer = Data(snapshot.suffix(from: remainderStart))
        }
        lock.unlock()

        var objects: [[String: Any]] = []
        objects.reserveCapacity(lines.count)
        for line in lines {
            guard
                let raw = try? JSONSerialization.jsonObject(with: line),
                let object = raw as? [String: Any]
            else {
                continue
            }
            objects.append(object)
        }
        return objects
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
