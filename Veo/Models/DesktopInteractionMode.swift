// FILE: DesktopInteractionMode.swift
// Purpose: Defines Veo's mutually exclusive composer interaction modes and Debug policy.
// Layer: Desktop app model

import Foundation

enum DesktopInteractionMode: String, CaseIterable, Codable, Identifiable {
    case agentic
    case plan
    case debug
    case ask
    case roblox

    var id: Self { self }

    var title: String {
        switch self {
        case .agentic: return "Agentic"
        case .plan: return "Plan"
        case .debug: return "Debug"
        case .ask: return "Ask"
        case .roblox: return "Roblox"
        }
    }

    var detail: String {
        switch self {
        case .agentic:
            return "Let Codex investigate and implement changes normally."
        case .plan:
            return "Plan the approach before implementation."
        case .debug:
            return "Diagnose defects with an evidence-first workflow."
        case .ask:
            return "Investigate and answer with read-only access."
        case .roblox:
            return "Use the Roblox and Luau development workflow."
        }
    }

    var systemImage: String {
        switch self {
        case .agentic: return "sparkles"
        case .plan: return "list.bullet.clipboard"
        case .debug: return "ladybug"
        case .ask: return "questionmark.circle"
        case .roblox: return "veo.roblox"

        }
    }

    var marker: String { "<veo_mode_\(rawValue)>" }

    func turnGuidance(wild: Bool, skill: URL?) -> String? {
        var guidance: [String] = []
        if self == .ask {
            guidance.append("Investigate and answer using read-only actions. Do not write files, request additional permissions, delegate execution, or call tools that modify external state.")
        }
        if let skill, self == .roblox {
            guidance.append("Read the Roblox Dev Skill at \(skill.path) and follow its routing to the relevant references. Use Roblox Studio MCP only if already configured and available.")
        }
        if wild {
            guidance.append("Research existing implementations and design references within the task’s scope and current permissions. Respect third-party licenses.")
            if self == .roblox {
                guidance.append("Focus on Roblox and Luau implementations, suitable Creator Store assets, and visual references for the experience.")
            }
            if self == .ask || self == .plan {
                guidance.append("Keep the research read-only. Do not generate files or implement changes.")
            } else if self == .agentic || self == .roblox {
                guidance.append("Use image generation for visual references when available. Include requested deliverables in the reply and keep incidental reference images in activity.")
            } else {
                guidance.append("Keep the evidence-first debugging workflow and use research to confirm hypotheses.")
            }
        }
        guard !guidance.isEmpty else { return nil }
        return ([marker] + guidance).joined(separator: "\n\n")
    }

    static let debugDeveloperInstructions = """
    <veo_debug_mode>
    You are operating in Veo Debug mode. Diagnose the reported defect using this evidence-first loop: observe -> reproduce -> investigate -> fix -> verify.

    - Inspect the real current state before editing. Reproduce locally when possible and collect relevant logs, errors, and stack traces.
    - Form testable hypotheses and use evidence to narrow them. Fix the smallest root cause rather than masking symptoms.
    - Add or update a regression test when practical. Run an appropriate verification and confirm the original symptom before declaring the bug resolved. Never claim success without verification.
    - Preserve the current runtime permission mode. Debug does not grant extra access and is not Plan mode.
    - If reproduction requires the user, give exact steps and say what must remain open. When a structured user-input tool is available, ask one reproduction question with the choices "Reproduced", "Could not reproduce", and "Cancel". If the provider cannot pause for structured input, send the same instructions as normal text, end the turn, and continue only after the user's next message.
    - Do not imply Veo can observe external actions. If browser state, terminal output, logs, or another required signal is inaccessible, ask the user for that evidence.
    - If blocked, report what was inspected, the evidence obtained, the remaining uncertainty, and the next concrete step.
    </veo_debug_mode>
    """

    static func applyingDebugInstructions(to text: String) -> String {
        guard !text.hasPrefix(debugDeveloperInstructions) else { return text }
        return text.isEmpty
            ? debugDeveloperInstructions
            : "\(debugDeveloperInstructions)\n\n\(text)"
    }
}
