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
        let continuation: CheckedContinuation<String, Error>
        var latestAgentMessage = ""
        var timeoutTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<String, Error>) {
            self.continuation = continuation
        }
    }

    private let client: CodexAppServerClient
    private var pendingByThreadID: [String: PendingRequest] = [:]

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
        let response = try await client.request(
            method: "thread/start",
            params: [
                "cwd": cwd,
                "model": model,
                "ephemeral": true,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "baseInstructions": "You perform a private UI classification task. Do not use tools. Return only the JSON required by the output schema.",
                "developerInstructions": "Never inspect files, run commands, browse, or modify state. Analyze only the text supplied by the application.",
                "threadSource": "veoUtility",
            ]
        )
        guard let thread = response["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw CodexAppServerClientError.malformedResponse("ephemeral thread/start")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let pending = PendingRequest(continuation: continuation)
            pendingByThreadID[threadID] = pending
            pending.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled else { return }
                self?.finish(
                    threadID: threadID,
                    result: .failure(CodexAppServerClientError.timeout("utility inference"))
                )
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await client.request(
                        method: "turn/start",
                        params: [
                            "threadId": threadID,
                            "input": [["type": "text", "text": prompt]],
                            "model": model,
                            "effort": effort,
                            "summary": "none",
                            "approvalPolicy": "never",
                            "sandboxPolicy": ["type": "readOnly", "networkAccess": false],
                            "outputSchema": outputSchema,
                        ]
                    )
                } catch {
                    finish(threadID: threadID, result: .failure(error))
                }
            }
        }
    }

    /// Returns true when an event belongs to an internal ephemeral thread and must not reach chat UI state.
    func handle(_ event: [String: Any], route: CodexAppServerRoute) -> Bool {
        let params = event["params"] as? [String: Any] ?? [:]
        let eventThread = params["thread"] as? [String: Any]
        let isEphemeralStart = route.method == "thread/started"
            && (eventThread?["ephemeral"] as? Bool == true)
        if isEphemeralStart { return true }

        guard let threadID = route.threadID ?? params["threadId"] as? String,
              let pending = pendingByThreadID[threadID] else { return false }

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
              pendingByThreadID[threadID] != nil,
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
        let pending = pendingByThreadID
        pendingByThreadID = [:]
        for (threadID, request) in pending {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: CancellationError())
            close(threadID)
        }
    }

    private func finish(threadID: String, result: Result<String, Error>) {
        guard let pending = pendingByThreadID.removeValue(forKey: threadID) else { return }
        pending.timeoutTask?.cancel()
        pending.continuation.resume(with: result)
        close(threadID)
    }

    private func close(_ threadID: String) {
        Task { [client] in
            _ = try? await client.request(method: "thread/close", params: ["threadId": threadID])
        }
    }
}
