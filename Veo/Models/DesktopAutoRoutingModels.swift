// FILE: DesktopAutoRoutingModels.swift
// Purpose: Defines Veo's virtual GPT-5.6 Auto route and its frozen per-turn contract.
// Layer: Desktop app model

import Foundation

enum DesktopModelRoutingMode: String, Codable, Hashable {
    case direct
    case auto
}

struct DesktopAutoRouteLane: Codable, Hashable {
    let modelID: String
    let model: String
    let displayName: String
    let effort: String
}

struct DesktopAutoRoutePlan: Codable, Hashable {
    enum Availability: String, Codable, Hashable {
        case full
        case modelFallback
        case singleSol
    }

    let parent: DesktopAutoRouteLane
    let routineWorker: DesktopAutoRouteLane
    let escalationWorker: DesktopAutoRouteLane
    let reviewer: DesktopAutoRouteLane
    let availability: Availability
    let warnings: [String]

    var usesMultiAgent: Bool { availability != .singleSol }
    var isDegraded: Bool { availability != .full }

    var clientIDPrefix: String {
        switch availability {
        case .full: return "veo-auto-full-"
        case .modelFallback: return "veo-auto-model-fallback-"
        case .singleSol: return "veo-auto-single-sol-"
        }
    }

    var laneSummary: String {
        switch availability {
        case .full:
            return "Sol / High leads · Luna / Max implements · Terra / High escalates · Sol / High reviews"
        case .modelFallback:
            return "Sol / High leads with explicit Sol fallback lanes"
        case .singleSol:
            return "Sol / High works and verifies alone"
        }
    }

    static func resolve(
        models: [DesktopModelOption],
        experimentalFeatures: [DesktopExperimentalFeature]
    ) throws -> DesktopAutoRoutePlan {
        func variant(_ name: String) -> DesktopModelOption? {
            let needle = name.lowercased()
            return models.first { option in
                [option.id, option.model, option.displayName]
                    .map { $0.lowercased() }
                    .contains { value in
                        value == needle || value.hasSuffix("-\(needle)") || value.contains("5.6 \(needle)")
                    }
            }
        }

        func lane(_ option: DesktopModelOption, effort: String) -> DesktopAutoRouteLane? {
            guard option.supportedReasoningEfforts.contains(where: {
                $0.id.caseInsensitiveCompare(effort) == .orderedSame
            }) else { return nil }
            return DesktopAutoRouteLane(
                modelID: option.id,
                model: option.model,
                displayName: option.displayName,
                effort: effort
            )
        }

        guard let solModel = variant("sol"), let sol = lane(solModel, effort: "high") else {
            throw DesktopAutoRouteError.missingSolHigh
        }

        let multiAgentEnabled = experimentalFeatures.contains {
            $0.id.caseInsensitiveCompare("multi_agent") == .orderedSame && $0.isEnabled
        }
        guard multiAgentEnabled else {
            return DesktopAutoRoutePlan(
                parent: sol,
                routineWorker: sol,
                escalationWorker: sol,
                reviewer: sol,
                availability: .singleSol,
                warnings: ["Native multi-agent support is unavailable. Sol will work and verify alone; independent review is unavailable."]
            )
        }

        var warnings: [String] = []
        let luna = variant("luna").flatMap { lane($0, effort: "max") }
        let terra = variant("terra").flatMap { lane($0, effort: "high") }
        if luna == nil {
            warnings.append("Luna / Max is unavailable. A fresh Sol / High worker will handle routine implementation.")
        }
        if terra == nil {
            warnings.append("Terra / High is unavailable. A fresh Sol / High worker will handle escalation.")
        }

        return DesktopAutoRoutePlan(
            parent: sol,
            routineWorker: luna ?? sol,
            escalationWorker: terra ?? sol,
            reviewer: sol,
            availability: warnings.isEmpty ? .full : .modelFallback,
            warnings: warnings
        )
    }
}

enum DesktopAutoRouteError: LocalizedError {
    case missingSolHigh

    var errorDescription: String? {
        switch self {
        case .missingSolHigh:
            return "GPT-5.6 Auto requires GPT-5.6 Sol with High reasoning. Refresh the model catalog or choose Luna, Terra, or Sol directly."
        }
    }
}

enum DesktopAutoOrchestrationPolicy {
    static func instructions(
        plan: DesktopAutoRoutePlan,
        interactionMode: DesktopInteractionMode
    ) -> String {
        let fallbackNotice = plan.warnings.isEmpty
            ? "The full Auto route is available."
            : plan.warnings.joined(separator: " ")

        if interactionMode == .plan {
            return """
            You are the GPT-5.6 Auto parent running as \(plan.parent.model) with \(plan.parent.effort) reasoning.
            This is Plan mode. Investigate as needed and produce a plan only. Do not edit files, delegate implementation, spawn a reviewer, or claim that implementation or independent review occurred.
            \(fallbackNotice)
            """
        }

        let debugInstructions = interactionMode == .debug
            ? "\nThis is Debug mode. Diagnose from concrete evidence, reproduce where safe, and make the smallest verified correction."
            : ""

        if !plan.usesMultiAgent {
            return """
            You are the GPT-5.6 Auto parent running as \(plan.parent.model) with \(plan.parent.effort) reasoning.
            Answer-only, explanation, and advisory requests stay with you. For requested code changes, inspect, implement, and rerun relevant checks yourself while preserving the user's permissions and existing dirty work.
            Native multi-agent support is unavailable, so do not attempt delegation and do not claim an independent review. State briefly in the final response that Sol completed and verified the work alone and independent review was unavailable.\(debugInstructions)
            """
        }

        return """
        You are the GPT-5.6 Auto parent running as \(plan.parent.model) with \(plan.parent.effort) reasoning. Veo owns this route; do not modify global Codex configuration or install agents, skills, or plugins.

        Answer-only, explanation, and advisory requests stay with you. For a requested code-changing Agentic or Debug task, you own intent, architecture, decomposition, permissions, and final verification. Delegate routine implementation to a fresh worker using model \(plan.routineWorker.model) at \(plan.routineWorker.effort) effort. Use a fresh escalation worker using model \(plan.escalationWorker.model) at \(plan.escalationWorker.effort) effort when complexity, risk, ambiguity, or a failed routine attempt justifies escalation.

        Every implementation or escalation task must include these five labeled parts:
        1. OBJECTIVE — the concrete outcome and acceptance criteria.
        2. FILES AND OWNERSHIP — exact files or narrow directories owned by that worker; it must not edit outside them.
        3. INTERFACES — contracts, callers, dependencies, and integration boundaries it must preserve.
        4. CONSTRAINTS — repository instructions, permissions, dirty-work preservation, non-goals, and prohibited destructive or scope-broadening actions.
        5. VERIFICATION — proportionate checks to run and the structured evidence to return.

        Require each worker to report changed files, checks and results, unresolved risks, and whether it stayed inside ownership. After a worker returns, inspect the actual diff and rerun the relevant checks yourself. Then spawn a fresh \(plan.reviewer.model) reviewer at \(plan.reviewer.effort) effort with no implementation ownership. Give it the objective, constraints, diff, and verification evidence. Require exactly one structured verdict: VERDICT: ship, VERDICT: fix-first, or VERDICT: rethink, followed by concise findings. Never treat the implementing worker as the reviewer. Any fix invalidates the verdict: inspect and verify the fix, then use a fresh reviewer again before completion. Do not claim a phase that the event history does not prove.

        \(fallbackNotice)\(debugInstructions)
        """
    }
}

struct DesktopAutoWorkflowState: Equatable {
    enum StepStatus: Equatable {
        case pending
        case active
        case complete
        case unavailable
    }

    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let status: StepStatus
        let receiverThreadIDs: [String]
    }

    let stageTitle: String
    let steps: [Step]
    let warnings: [String]
    let verdict: String?
    let isHistoricalTurn: Bool

    static func derive(
        timeline: [DesktopTimelineItem],
        isTurnRunning: Bool,
        selectedPlan: DesktopAutoRoutePlan?,
        isAutoSelected: Bool
    ) -> DesktopAutoWorkflowState? {
        let userIndices = timeline.indices.filter { timeline[$0].kind == .user || timeline[$0].clientID?.hasPrefix("auto-continue-") == true }
        let latestUserIndex = userIndices.last
        let latestAutoIndex = userIndices.last(where: { index in
            timeline[index].clientID?.contains("veo-auto-") == true
        })

        guard isAutoSelected || latestAutoIndex != nil else { return nil }
        let isHistorical = latestAutoIndex != latestUserIndex
        if isHistorical, !isAutoSelected { return nil }

        guard let autoIndex = latestAutoIndex, !isHistorical else {
            let warnings = selectedPlan?.warnings ?? []
            return DesktopAutoWorkflowState(
                stageTitle: selectedPlan == nil ? "Route unavailable" : "Ready",
                steps: setupSteps(plan: selectedPlan),
                warnings: warnings,
                verdict: nil,
                isHistoricalTurn: false
            )
        }

        let autoTurnID = timeline[autoIndex].turnID
        let turnItems = timeline.enumerated().filter { index, item in
            index >= autoIndex && (autoTurnID == nil || item.turnID == nil || item.turnID == autoTurnID)
        }
        let invocations = turnItems.compactMap { index, item -> (Int, DesktopCollaborationInvocation)? in
            item.collaborationInvocation.map { (index, $0) }
        }
        let subAgentActivities = turnItems.compactMap { index, item -> (Int, DesktopSubAgentActivity)? in
            item.subAgentActivity.map { (index, $0) }
        }

        func containsVariant(_ invocation: DesktopCollaborationInvocation, _ name: String) -> Bool {
            invocation.model?.localizedCaseInsensitiveContains(name) == true
        }
        func isReview(_ invocation: DesktopCollaborationInvocation) -> Bool {
            guard containsVariant(invocation, "sol") else { return false }
            return invocation.prompt?.localizedCaseInsensitiveContains("review") == true
                || invocation.prompt?.localizedCaseInsensitiveContains("VERDICT:") == true
        }
        func active(_ invocation: DesktopCollaborationInvocation) -> Bool {
            invocation.agentStates.values.contains(where: \.isActive)
        }
        func completed(_ invocation: DesktopCollaborationInvocation) -> Bool {
            !invocation.agentStates.isEmpty
                && invocation.agentStates.values.allSatisfy { !$0.isActive }
        }

        let implementation = invocations.last { _, invocation in
            containsVariant(invocation, "luna") || (containsVariant(invocation, "sol") && !isReview(invocation))
        }
        let escalation = invocations.last { _, invocation in containsVariant(invocation, "terra") }
        let review = invocations.last { _, invocation in isReview(invocation) }
        let implementationActivity = subAgentActivities.last { _, activity in !activity.isReview }
        let reviewActivity = subAgentActivities.last { _, activity in activity.isReview }
        let latestWorkerIndex = [implementation?.0, escalation?.0, implementationActivity?.0].compactMap { $0 }.max()
        let observedVerificationEvidence = latestWorkerIndex.map { workerIndex in
            turnItems.contains { index, item in
                index > workerIndex && (item.kind == .command || item.kind == .fileChange)
            }
        } ?? false
        let reportedVerificationEvidence = latestWorkerIndex.map { workerIndex in
            turnItems.contains { index, item in
                index > workerIndex
                    && item.kind == .assistant
                    && reportsVerification(item.body)
            }
        } ?? false
        let verificationEvidence = observedVerificationEvidence || reportedVerificationEvidence

        let invocationVerdict = review.flatMap { _, invocation in
            invocation.agentStates.values.compactMap(\.message).compactMap(parseVerdict).last
        }
        let reportedVerdict = turnItems.compactMap { _, item in
            item.kind == .assistant ? parseVerdict(item.body) : nil
        }.last
        let verdict = invocationVerdict ?? reportedVerdict
        let routeWarnings = warnings(forClientID: timeline[autoIndex].clientID, selectedPlan: selectedPlan)

        let architectureComplete = implementation != nil
            || escalation != nil
            || review != nil
            || implementationActivity != nil
            || reviewActivity != nil
            || !isTurnRunning
        let implementationStatus: StepStatus
        if let invocation = implementation?.1 {
            implementationStatus = active(invocation) ? .active : (completed(invocation) ? .complete : .pending)
        } else if implementationActivity != nil {
            implementationStatus = reviewActivity != nil || verificationEvidence || !isTurnRunning ? .complete : .active
        } else if selectedPlan?.usesMultiAgent == false {
            implementationStatus = .unavailable
        } else {
            implementationStatus = .pending
        }
        let verificationStatus: StepStatus = verificationEvidence
            ? .complete
            : (!isTurnRunning && implementationStatus == .complete ? .unavailable : .pending)
        let reviewStatus: StepStatus
        if let invocation = review?.1 {
            reviewStatus = active(invocation) ? .active : (completed(invocation) ? .complete : .pending)
        } else if reviewActivity != nil {
            reviewStatus = isTurnRunning ? .active : .complete
        } else if timeline[autoIndex].clientID?.contains("single-sol") == true {
            reviewStatus = .unavailable
        } else {
            reviewStatus = .pending
        }

        let stageTitle: String
        if let invocation = review?.1, active(invocation) {
            stageTitle = "Sol reviewing"
        } else if reviewActivity != nil && isTurnRunning {
            stageTitle = "Review agent working"
        } else if let invocation = escalation?.1, active(invocation) {
            stageTitle = "Terra escalating"
        } else if let invocation = implementation?.1, active(invocation) {
            stageTitle = containsVariant(invocation, "luna") ? "Luna implementing" : "Sol fallback working"
        } else if implementationActivity != nil && isTurnRunning && !verificationEvidence {
            stageTitle = "Implementation agent working"
        } else if verificationEvidence && isTurnRunning {
            stageTitle = "Sol verifying"
        } else if isTurnRunning {
            stageTitle = invocations.isEmpty ? "Sol working" : "Back with Sol"
        } else if let verdict {
            stageTitle = "Review: \(verdict)"
        } else {
            stageTitle = "Complete"
        }

        var steps = [
            Step(
                id: "architect",
                title: "Architect",
                detail: "Sol / High parent",
                status: architectureComplete ? .complete : (isTurnRunning ? .active : .complete),
                receiverThreadIDs: []
            ),
            Step(
                id: "implementation",
                title: escalation == nil ? "Implementation" : "Implementation + escalation",
                detail: observedLaneDetail(implementation?.1, activity: implementationActivity?.1, fallback: selectedPlan?.routineWorker),
                status: escalation.map { active($0.1) ? .active : .complete } ?? implementationStatus,
                receiverThreadIDs: uniqueThreadIDs(
                    (implementation?.1.receiverThreadIDs ?? [])
                        + (escalation?.1.receiverThreadIDs ?? [])
                        + [implementationActivity?.1.agentThreadID].compactMap { $0 }
                )
            ),
            Step(
                id: "verification",
                title: "Verification",
                detail: observedVerificationEvidence
                    ? "Parent checks observed"
                    : (reportedVerificationEvidence ? "Parent verification reported" : "Back with Sol"),
                status: verificationStatus,
                receiverThreadIDs: []
            ),
            Step(
                id: "review",
                title: "Review",
                detail: observedLaneDetail(review?.1, activity: reviewActivity?.1, fallback: selectedPlan?.reviewer),
                status: reviewStatus,
                receiverThreadIDs: uniqueThreadIDs(
                    (review?.1.receiverThreadIDs ?? [])
                        + [reviewActivity?.1.agentThreadID].compactMap { $0 }
                )
            ),
        ]
        if timeline[autoIndex].clientID?.contains("single-sol") == true {
            steps[1] = Step(
                id: "implementation",
                title: "Implementation",
                detail: "Sol / High parent only",
                status: isTurnRunning ? .active : .complete,
                receiverThreadIDs: []
            )
        }

        return DesktopAutoWorkflowState(
            stageTitle: stageTitle,
            steps: steps,
            warnings: routeWarnings,
            verdict: verdict,
            isHistoricalTurn: isHistorical
        )
    }

    private static func setupSteps(plan: DesktopAutoRoutePlan?) -> [Step] {
        guard let plan else { return [] }
        return [
            Step(id: "architect", title: "Architect", detail: "Sol / High parent", status: .pending, receiverThreadIDs: []),
            Step(id: "implementation", title: "Implementation", detail: "\(shortName(plan.routineWorker.displayName)) / \(plan.routineWorker.effort.capitalized)", status: plan.usesMultiAgent ? .pending : .unavailable, receiverThreadIDs: []),
            Step(id: "verification", title: "Verification", detail: "Sol / High parent", status: .pending, receiverThreadIDs: []),
            Step(id: "review", title: "Review", detail: "Sol / High fresh reviewer", status: plan.usesMultiAgent ? .pending : .unavailable, receiverThreadIDs: []),
        ]
    }

    private static func laneDetail(
        _ invocation: DesktopCollaborationInvocation?,
        fallback: DesktopAutoRouteLane?
    ) -> String {
        if let invocation {
            let model = shortName(invocation.model ?? "Agent")
            return "\(model) / \((invocation.reasoningEffort ?? "").capitalized)"
        }
        guard let fallback else { return "Waiting for event data" }
        return "\(shortName(fallback.displayName)) / \(fallback.effort.capitalized)"
    }

    private static func observedLaneDetail(
        _ invocation: DesktopCollaborationInvocation?,
        activity: DesktopSubAgentActivity?,
        fallback: DesktopAutoRouteLane?
    ) -> String {
        if let invocation { return laneDetail(invocation, fallback: fallback) }
        if activity != nil, let fallback {
            return "\(shortName(fallback.displayName)) / \(fallback.effort.capitalized) route · model not reported by event"
        }
        return laneDetail(nil, fallback: fallback)
    }

    private static func uniqueThreadIDs(_ threadIDs: [String]) -> [String] {
        var seen = Set<String>()
        return threadIDs.filter { seen.insert($0).inserted }
    }

    private static func shortName(_ value: String) -> String {
        for name in ["Luna", "Terra", "Sol"] where value.localizedCaseInsensitiveContains(name) {
            return name
        }
        return value
    }

    private static func warnings(forClientID clientID: String?, selectedPlan: DesktopAutoRoutePlan?) -> [String] {
        if clientID?.contains("single-sol") == true {
            return ["Multi-agent support was unavailable. Sol worked alone; independent review was unavailable."]
        }
        if clientID?.contains("model-fallback") == true {
            if let warnings = selectedPlan?.warnings, !warnings.isEmpty { return warnings }
            return ["This turn used an explicit Sol fallback because a requested worker model was unavailable."]
        }
        return []
    }

    private static func parseVerdict(_ message: String) -> String? {
        let lowercased = message.lowercased()
        for verdict in ["ship", "fix-first", "rethink"] where lowercased.contains("verdict: \(verdict)") {
            return verdict
        }
        return nil
    }

    private static func reportsVerification(_ message: String) -> Bool {
        let normalized = message.lowercased()
        let reportsPassingCheck = normalized.contains(" passed")
            || normalized.contains("checks passed")
            || normalized.contains("verification passed")
        let reportsDiffInspection = normalized.contains("final diff")
            || normalized.contains("inspected the diff")
            || normalized.contains("verified the diff")
        return reportsPassingCheck && reportsDiffInspection
    }
}
