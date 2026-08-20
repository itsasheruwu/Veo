// FILE: DesktopUtilityInferenceCoordinator.swift
// Purpose: Runs small model-powered UI tasks on ephemeral Codex threads.
// Layer: Desktop app service

import Foundation

@MainActor
final class DesktopUtilityInferenceCoordinator {
    enum InferenceError: LocalizedError {
        case emptyResponse
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "The utility model returned no result."
            case .failed(let message): return message
            }
        }
    }

    private final class PendingRequest {
        let inferenceID: UUID
        let continuation: CheckedContinuation<String, Error>
        var latestAgentMessage = ""
        var timeoutTask: Task<Void, Never>?
        var turnStartTask: Task<Void, Never>?
        var turnID: String?

        init(inferenceID: UUID, continuation: CheckedContinuation<String, Error>) {
            self.inferenceID = inferenceID
            self.continuation = continuation
        }
    }

    private let client: CodexAppServerClient
    private var pendingByThreadID: [String: PendingRequest] = [:]
    /// Absorb late lifecycle events from closed ephemeral threads instead of letting
    /// them reach the visible chat timeline.
    private var closingThreadIDs = Set<String>()

    init(client: CodexAppServerClient) {
        self.client = client
    }

    func infer(
        prompt: String,
        outputSchema: [String: Any],
        model: String,
        effort: String = "low",
        cwd: String
    ) async throws -> String {
        try await infer(
            input: [["type": "text", "text": prompt]],
            outputSchema: outputSchema,
            model: model,
            effort: effort,
            cwd: cwd
        )
    }

    /// Runs an isolated utility turn over application-provided multimodal input.
    /// Callers must keep the input limited to the current workspace and validate
    /// their own structured response before using it in the visible chat.
    func infer(
        input: [[String: Any]],
        outputSchema: [String: Any],
        model: String,
        effort: String = "low",
        cwd: String
    ) async throws -> String {
        let inferenceID = UUID()
        return try await withTaskCancellationHandler(operation: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.startInference(
                inferenceID: inferenceID,
                input: input,
                outputSchema: outputSchema,
                model: model,
                effort: effort,
                cwd: cwd
            )
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelInference(inferenceID: inferenceID)
            }
        })
    }

    private func startInference(
        inferenceID: UUID,
        input: [[String: Any]],
        outputSchema: [String: Any],
        model: String,
        effort: String,
        cwd: String
    ) async throws -> String {
        try Task.checkCancellation()
        let response = try await client.request(
            method: "thread/start",
            params: [
                "cwd": cwd,
                "model": model,
                "ephemeral": true,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "baseInstructions": "You perform a private Veo utility task. Do not use tools. Return only the JSON required by the output schema.",
                "developerInstructions": "Never inspect files, run commands, browse, or modify state. Analyze only input supplied directly by the application.",
                "threadSource": "veoUtility",
            ]
        )
        guard let thread = response["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw CodexAppServerClientError.malformedResponse("ephemeral thread/start")
        }
        guard !Task.isCancelled else {
            close(threadID)
            throw CancellationError()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let pending = PendingRequest(inferenceID: inferenceID, continuation: continuation)
            pendingByThreadID[threadID] = pending
            pending.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled else { return }
                self?.finish(
                    threadID: threadID,
                    result: .failure(CodexAppServerClientError.timeout("utility inference")),
                    interruptActiveTurn: true
                )
            }

            pending.turnStartTask = Task { [weak self] in
                await self?.startTurn(
                    threadID: threadID,
                    input: input,
                    outputSchema: outputSchema,
                    model: model,
                    effort: effort
                )
            }
        }
    }

    private func startTurn(
        threadID: String,
        input: [[String: Any]],
        outputSchema: [String: Any],
        model: String,
        effort: String
    ) async {
        do {
            let response = try await client.request(
                method: "turn/start",
                params: [
                    "threadId": threadID,
                    "input": input,
                    "model": model,
                    "effort": effort,
                    "summary": "none",
                    "approvalPolicy": "never",
                    "sandboxPolicy": ["type": "readOnly", "networkAccess": false],
                    "outputSchema": outputSchema,
                ]
            )
            let turn = response["turn"] as? [String: Any]
            let turnID = turn?["id"] as? String
            guard !Task.isCancelled else {
                // A cancellation can race the request itself. Repeat the targeted
                // close once its turn-start RPC has returned so no utility thread
                // remains alive behind the caller's cancellation.
                close(threadID, interrupting: turnID, force: true)
                return
            }
            recordStartedTurn(threadID: threadID, turnID: turnID)
        } catch {
            guard !Task.isCancelled else {
                close(threadID, force: true)
                return
            }
            finish(threadID: threadID, result: .failure(error))
        }
    }

    /// Returns true when an event belongs to an internal ephemeral thread and must not reach chat UI state.
    func handle(_ event: [String: Any], route: CodexAppServerRoute) -> Bool {
        let params = event["params"] as? [String: Any] ?? [:]
        let eventThread = params["thread"] as? [String: Any]
        let isEphemeralStart = route.method == "thread/started"
            && (eventThread?["ephemeral"] as? Bool == true)
        if isEphemeralStart { return true }

        guard let threadID = route.threadID ?? params["threadId"] as? String else {
            return false
        }
        if closingThreadIDs.contains(threadID) {
            if route.method == "thread/closed" || route.method == "thread/deleted" {
                closingThreadIDs.remove(threadID)
            }
            return true
        }
        guard let pending = pendingByThreadID[threadID] else { return false }

        if route.method == "turn/started" {
            let turn = params["turn"] as? [String: Any]
            pending.turnID = turn?["id"] as? String ?? params["turnId"] as? String
            return true
        }

        if route.method == "item/completed",
           let item = params["item"] as? [String: Any],
           item["type"] as? String == "agentMessage",
           let text = item["text"] as? String,
           !text.isEmpty {
            pending.latestAgentMessage = text
        }

        if route.method == "turn/completed" {
            let turn = params["turn"] as? [String: Any]
            if let error = turn?["error"] as? [String: Any] {
                finish(
                    threadID: threadID,
                    result: .failure(InferenceError.failed(error["message"] as? String ?? "Utility inference failed."))
                )
                return true
            }
            let items = turn?["items"] as? [[String: Any]] ?? []
            let completedText = items.last(where: {
                $0["type"] as? String == "agentMessage" && ($0["text"] as? String)?.isEmpty == false
            })?["text"] as? String
            let output = completedText ?? pending.latestAgentMessage
            finish(
                threadID: threadID,
                result: output.isEmpty ? .failure(InferenceError.emptyResponse) : .success(output)
            )
        } else if route.method == "error" {
            let error = params["error"] as? [String: Any]
            finish(
                threadID: threadID,
                result: .failure(InferenceError.failed(
                    error?["message"] as? String ?? params["message"] as? String ?? "Utility inference failed."
                ))
            )
        }
        return true
    }

    func handleServerRequest(_ event: [String: Any], route: CodexAppServerRoute) -> Bool {
        guard let threadID = route.threadID,
              pendingByThreadID[threadID] != nil || closingThreadIDs.contains(threadID),
              let requestID = route.rpcID else { return false }

        let result: [String: Any]
        switch route.method {
        case "item/permissions/requestApproval":
            result = ["permissions": [:], "scope": "turn"]
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            result = ["decision": "decline"]
        case "item/tool/requestUserInput":
            result = ["answers": [:]]
        case "mcpServer/elicitation/request":
            result = ["action": "decline"]
        case "item/tool/call":
            result = ["contentItems": [], "success": false]
        default:
            result = [:]
        }
        try? client.respond(to: requestID, result: result)
        return true
    }

    func cancelAll() {
        let pendingThreadIDs = Array(pendingByThreadID.keys)
        for threadID in pendingThreadIDs {
            finish(
                threadID: threadID,
                result: .failure(CancellationError()),
                interruptActiveTurn: true
            )
        }
    }

    private func cancelInference(inferenceID: UUID) {
        guard let entry = pendingByThreadID.first(where: { $0.value.inferenceID == inferenceID }) else {
            return
        }
        finish(
            threadID: entry.key,
            result: .failure(CancellationError()),
            interruptActiveTurn: true
        )
    }

    private func recordStartedTurn(threadID: String, turnID: String?) {
        guard let pending = pendingByThreadID[threadID] else {
            close(threadID, force: true)
            return
        }
        pending.turnID = turnID
    }

    private func finish(
        threadID: String,
        result: Result<String, Error>,
        interruptActiveTurn: Bool = false
    ) {
        guard let pending = pendingByThreadID.removeValue(forKey: threadID) else { return }
        pending.timeoutTask?.cancel()
        pending.turnStartTask?.cancel()
        pending.continuation.resume(with: result)
        close(threadID, interrupting: interruptActiveTurn ? pending.turnID : nil)
    }

    private func close(
        _ threadID: String,
        interrupting turnID: String? = nil,
        force: Bool = false
    ) {
        let inserted = closingThreadIDs.insert(threadID).inserted
        guard inserted || force else { return }
        Task { [weak self, client] in
            if let turnID {
                _ = try? await client.request(
                    method: "turn/interrupt",
                    params: ["threadId": threadID, "turnId": turnID]
                )
            }
            _ = try? await client.request(method: "thread/close", params: ["threadId": threadID])
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.closingThreadIDs.remove(threadID)
        }
    }
}
