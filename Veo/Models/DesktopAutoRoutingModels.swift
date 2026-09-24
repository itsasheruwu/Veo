// FILE: DesktopAutoRoutingModels.swift
// Purpose: Defines Veo's virtual GPT-family Auto routes and their frozen per-turn contracts.
// Layer: Desktop app model

import Foundation

enum DesktopModelRoutingMode: String, Codable, Hashable {
    case direct
    case auto
    case autoGPT6

    var autoFamily: DesktopAutoRouteFamily? {
        switch self {
        case .direct: return nil
        case .auto: return .gpt56
        case .autoGPT6: return .gpt6
        }
    }

    var isFamilyAuto: Bool { autoFamily != nil }
}

enum DesktopAutoRouteFamily: Hashable {
    case gpt56
    case gpt6

    var title: String { self == .gpt56 ? "5.6 Auto" : "6 Auto" }
    var productName: String { self == .gpt56 ? "GPT-5.6" : "GPT-6" }
    var parentVariant: String { self == .gpt56 ? "sol" : "astra" }
    var escalationVariant: String { self == .gpt56 ? "terra" : "sol" }

    func contains(_ model: DesktopModelOption) -> Bool {
        self == .gpt56 ? model.isGPT56Family : model.isGPT6Family
    }
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

    var family: DesktopAutoRouteFamily {
        parent.model.localizedCaseInsensitiveContains("gpt-6") ? .gpt6 : .gpt56
    }

    var title: String { family.title }

    var usesMultiAgent: Bool { availability != .singleSol }
    var isDegraded: Bool { availability != .full }

    var clientIDPrefix: String {
        let familyPrefix = family == .gpt56 ? "veo-auto-" : "veo-auto-gpt6-"
        switch availability {
        case .full: return "\(familyPrefix)full-"
        case .modelFallback: return "\(familyPrefix)model-fallback-"
        case .singleSol: return "\(familyPrefix)single-sol-"
        }
    }

    var laneSummary: String {
        let parentName = Self.shortName(parent.displayName)
        let workerName = Self.shortName(routineWorker.displayName)
        let escalationName = Self.shortName(escalationWorker.displayName)
        let reviewerName = Self.shortName(reviewer.displayName)
        switch availability {
        case .full:
            return "\(parentName) / \(parent.effort.capitalized) leads · \(workerName) / \(routineWorker.effort.capitalized) implements · \(escalationName) / \(escalationWorker.effort.capitalized) escalates · \(reviewerName) / \(reviewer.effort.capitalized) reviews"
        case .modelFallback:
            return "\(parentName) / \(parent.effort.capitalized) leads with explicit \(parentName) fallback lanes"
        case .singleSol:
            return "\(parentName) / \(parent.effort.capitalized) works and verifies alone"
        }
    }

    private static func shortName(_ value: String) -> String {
        for name in ["Astra", "Luna", "Terra", "Sol"] where value.localizedCaseInsensitiveContains(name) {
            return name
        }
        return value
    }

    static func resolve(
        models: [DesktopModelOption],
        experimentalFeatures: [DesktopExperimentalFeature],
        family: DesktopAutoRouteFamily = .gpt56
    ) throws -> DesktopAutoRoutePlan {
        let familyModels = models.filter(family.contains)
        func variant(_ name: String) -> DesktopModelOption? {
            let needle = name.lowercased()
            return familyModels.first { option in
                [option.id, option.model, option.displayName]
                    .map { $0.lowercased() }
                    .contains { value in
                        value == needle || value.hasSuffix("-\(needle)")
                            || value.contains("5.6 \(needle)") || value.contains("6 \(needle)")
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

        guard let parentModel = variant(family.parentVariant),
              let parent = lane(parentModel, effort: "high") else {
            throw family == .gpt56 ? DesktopAutoRouteError.missingSolHigh : DesktopAutoRouteError.missingAstraHigh
        }

        let multiAgentEnabled = experimentalFeatures.contains {
            $0.id.caseInsensitiveCompare("multi_agent") == .orderedSame && $0.isEnabled
        }
        guard multiAgentEnabled else {
            return DesktopAutoRoutePlan(
                parent: parent,
                routineWorker: parent,
                escalationWorker: parent,
                reviewer: parent,
                availability: .singleSol,
                warnings: ["Native multi-agent support is unavailable. \(parent.displayName) will work and verify alone; independent review is unavailable."]
            )
        }

        var warnings: [String] = []
        let luna = variant("luna").flatMap { lane($0, effort: "max") }
        let escalationVariant = family.escalationVariant
        let escalationModel = variant(escalationVariant)
        let escalationLane = escalationModel.flatMap { lane($0, effort: "high") }
        if luna == nil {
            warnings.append("Luna / Max is unavailable. A fresh \(parent.displayName) / High worker will handle routine implementation.")
        }
        if escalationLane == nil {
            let escalationName = family == .gpt56 ? "Terra" : "Sol"
            warnings.append("\(escalationName) / High is unavailable. A fresh \(parent.displayName) / High worker will handle escalation.")
        }

        return DesktopAutoRoutePlan(
            parent: parent,
            routineWorker: luna ?? parent,
            escalationWorker: escalationLane ?? parent,
            reviewer: parent,
            availability: warnings.isEmpty ? .full : .modelFallback,
            warnings: warnings
        )
    }
}

enum DesktopAutoRouteError: LocalizedError {
    case missingSolHigh
    case missingAstraHigh

    var errorDescription: String? {
        switch self {
        case .missingSolHigh:
            return "5.6 Auto requires 5.6 Sol with High reasoning. Refresh the model catalog or choose Luna, Terra, or Sol directly."
        case .missingAstraHigh:
            return "6 Auto requires GPT-6 Astra with High reasoning. Refresh the model catalog or choose Astra, Sol, or Luna directly."
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
            You are the \(plan.family.productName) Auto parent running as \(plan.parent.model) with \(plan.parent.effort) reasoning.
            This is Plan mode. Investigate as needed and produce a plan only. Do not edit files, delegate implementation, spawn a reviewer, or claim that implementation or independent review occurred.
            \(fallbackNotice)
            """
        }

        let debugInstructions = interactionMode == .debug
            ? "\nThis is Debug mode. Diagnose from concrete evidence, reproduce where safe, and make the smallest verified correction."
            : ""

        if !plan.usesMultiAgent {
            return """
            You are the \(plan.family.productName) Auto parent running as \(plan.parent.model) with \(plan.parent.effort) reasoning.
            Answer-only, explanation, and advisory requests stay with you. For requested code changes, inspect, implement, and rerun relevant checks yourself while preserving the user's permissions and existing dirty work.
            Native multi-agent support is unavailable, so do not attempt delegation and do not claim an independent review. State briefly in the final response that \(plan.parent.displayName) completed and verified the work alone and independent review was unavailable.\(debugInstructions)
            """
        }

        return """
        You are the \(plan.family.productName) Auto parent running as \(plan.parent.model) with \(plan.parent.effort) reasoning. Veo owns this route; do not modify global Codex configuration or install agents, skills, or plugins.

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
    let modelTitle: String
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
        let modelTitle = selectedPlan?.title
            ?? (latestAutoIndex.flatMap { timeline[$0].clientID?.contains("gpt6") == true } == true ? "6 Auto" : "5.6 Auto")

        guard let autoIndex = latestAutoIndex, !isHistorical else {
            let warnings = selectedPlan?.warnings ?? []
            return DesktopAutoWorkflowState(
                stageTitle: selectedPlan == nil ? "Route unavailable" : "Ready",
                modelTitle: modelTitle,
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
        func matchesLane(_ invocation: DesktopCollaborationInvocation, _ lane: DesktopAutoRouteLane?) -> Bool {
            guard let model = invocation.model?.lowercased(), let lane else { return false }
            return [lane.model, lane.displayName, lane.modelID].contains { candidate in
                let normalized = candidate.lowercased()
                return !normalized.isEmpty && (model.contains(normalized) || normalized.contains(model))
            }
        }
        func isReview(_ invocation: DesktopCollaborationInvocation) -> Bool {
            guard let prompt = invocation.prompt,
                  prompt.localizedCaseInsensitiveContains("VERDICT:") else { return false }
            let opening = prompt.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            // Worker briefs can mention the later review and its verdict contract.
            // Only a review assignment at the start of this invocation marks a reviewer.
            let reviewAssignment = #"^(?:you are (?:an? |the )?(?:fresh |independent |code )*reviewer\b|(?:your role is|role\s*[:—–-])\s*(?:an? |the )?(?:fresh |independent |code )*reviewer\b|(?:objective|task)\s*[:—–-]\s*(?:independently\s+)?review\b|(?:independently\s+)?review\b)"#
            return opening.range(of: reviewAssignment, options: [.regularExpression, .caseInsensitive]) != nil
        }
        func active(_ invocation: DesktopCollaborationInvocation) -> Bool {
            invocation.agentStates.values.contains(where: \.isActive)
        }
        func completed(_ invocation: DesktopCollaborationInvocation) -> Bool {
            !invocation.agentStates.isEmpty
                && invocation.agentStates.values.allSatisfy { !$0.isActive }
        }

        let implementation = invocations.last { _, invocation in
            !isReview(invocation)
                && (matchesLane(invocation, selectedPlan?.routineWorker)
                    || (selectedPlan?.family == .gpt56 && containsVariant(invocation, "sol")))
        }
        let escalation = invocations.last { _, invocation in
            matchesLane(invocation, selectedPlan?.escalationWorker) && !isReview(invocation)
                || (selectedPlan == nil && containsVariant(invocation, "terra") && !isReview(invocation))
        }
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

        let parentName = selectedPlan.map { shortName($0.parent.displayName) } ?? "Model"
        let routineName = selectedPlan.map { shortName($0.routineWorker.displayName) } ?? "Worker"
        let escalationName = selectedPlan.map { shortName($0.escalationWorker.displayName) } ?? "Worker"
        let reviewName = selectedPlan.map { shortName($0.reviewer.displayName) } ?? parentName
        let stageTitle: String
        if let invocation = review?.1, active(invocation) {
            stageTitle = "\(reviewName) reviewing"
        } else if reviewActivity != nil && isTurnRunning {
            stageTitle = "Review agent working"
        } else if let invocation = escalation?.1, active(invocation) {
            stageTitle = "\(escalationName) escalating"
        } else if let invocation = implementation?.1, active(invocation) {
            stageTitle = "\(routineName) implementing"
        } else if implementationActivity != nil && isTurnRunning && !verificationEvidence {
            stageTitle = "Implementation agent working"
        } else if verificationEvidence && isTurnRunning {
            stageTitle = "\(parentName) verifying"
        } else if isTurnRunning {
            stageTitle = invocations.isEmpty ? "\(parentName) working" : "Back with \(parentName)"
        } else if let verdict {
            stageTitle = "Review: \(verdict)"
        } else {
            stageTitle = "Complete"
        }

        var steps = [
            Step(
                id: "architect",
                title: "Architect",
                detail: "\(parentName) / \(selectedPlan?.parent.effort.capitalized ?? "High") parent",
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
                    : (reportedVerificationEvidence ? "Parent verification reported" : "Back with \(parentName)"),
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
                detail: "\(parentName) / \(selectedPlan?.parent.effort.capitalized ?? "High") parent only",
                status: isTurnRunning ? .active : .complete,
                receiverThreadIDs: []
            )
        }

        return DesktopAutoWorkflowState(
            stageTitle: stageTitle,
            modelTitle: modelTitle,
            steps: steps,
            warnings: routeWarnings,
            verdict: verdict,
            isHistoricalTurn: isHistorical
        )
    }

    private static func setupSteps(plan: DesktopAutoRoutePlan?) -> [Step] {
        guard let plan else { return [] }
        let parentName = shortName(plan.parent.displayName)
        return [
            Step(id: "architect", title: "Architect", detail: "\(parentName) / \(plan.parent.effort.capitalized) parent", status: .pending, receiverThreadIDs: []),
            Step(id: "implementation", title: "Implementation", detail: "\(shortName(plan.routineWorker.displayName)) / \(plan.routineWorker.effort.capitalized)", status: plan.usesMultiAgent ? .pending : .unavailable, receiverThreadIDs: []),
            Step(id: "verification", title: "Verification", detail: "\(parentName) / \(plan.parent.effort.capitalized) parent", status: .pending, receiverThreadIDs: []),
            Step(id: "review", title: "Review", detail: "\(shortName(plan.reviewer.displayName)) / \(plan.reviewer.effort.capitalized) fresh reviewer", status: plan.usesMultiAgent ? .pending : .unavailable, receiverThreadIDs: []),
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
        for name in ["Astra", "Luna", "Terra", "Sol"] where value.localizedCaseInsensitiveContains(name) {
            return name
        }
        return value
    }

    private static func warnings(forClientID clientID: String?, selectedPlan: DesktopAutoRoutePlan?) -> [String] {
        if clientID?.contains("single-sol") == true {
            let parent = selectedPlan.map { shortName($0.parent.displayName) } ?? "The lead model"
            return ["Multi-agent support was unavailable. \(parent) worked alone; independent review was unavailable."]
        }
        if clientID?.contains("model-fallback") == true {
            if let warnings = selectedPlan?.warnings, !warnings.isEmpty { return warnings }
            let parent = selectedPlan.map { shortName($0.parent.displayName) } ?? "The lead model"
            return ["This turn used an explicit \(parent) fallback because a requested worker model was unavailable."]
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
