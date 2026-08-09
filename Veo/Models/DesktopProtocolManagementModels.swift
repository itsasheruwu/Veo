// FILE: DesktopProtocolManagementModels.swift
// Purpose: Small view models for app-server review, policy, feature, hook, and notice surfaces.
// Layer: Desktop app model

import Foundation

enum DesktopReviewTargetKind: String, CaseIterable, Identifiable {
    case uncommittedChanges
    case baseBranch
    case commit
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .uncommittedChanges: return "Uncommitted changes"
        case .baseBranch: return "Compare with branch"
        case .commit: return "Specific commit"
        case .custom: return "Custom review"
        }
    }

    var prompt: String {
        switch self {
        case .uncommittedChanges: return ""
        case .baseBranch: return "Base branch"
        case .commit: return "Commit SHA"
        case .custom: return "Review instructions"
        }
    }
}

enum DesktopReviewDelivery: String, CaseIterable, Identifiable {
    case inline
    case detached

    var id: Self { self }
    var title: String { self == .inline ? "Current chat" : "New review chat" }
}

struct DesktopReviewRequest {
    var target: DesktopReviewTargetKind = .uncommittedChanges
    var value = ""
    var delivery: DesktopReviewDelivery = .inline

    var isValid: Bool {
        target == .uncommittedChanges || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var targetPayload: [String: Any] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .uncommittedChanges:
            return ["type": "uncommittedChanges"]
        case .baseBranch:
            return ["type": "baseBranch", "branch": trimmed]
        case .commit:
            return ["type": "commit", "sha": trimmed]
        case .custom:
            return ["type": "custom", "instructions": trimmed]
        }
    }
}

struct DesktopRuntimeNotice: Identifiable, Equatable {
    enum Severity: String {
        case info
        case warning
        case error
    }

    let id: String
    let severity: Severity
    let title: String
    let detail: String
    let createdAt: Date
}

struct DesktopPermissionProfile: Identifiable, Equatable {
    let id: String
    let description: String?
    let isAllowed: Bool

    static func parse(_ object: [String: Any]) -> DesktopPermissionProfile? {
        guard let id = object.string("id") else { return nil }
        return DesktopPermissionProfile(
            id: id,
            description: object.string("description"),
            isAllowed: object.bool("allowed") ?? false
        )
    }
}

struct DesktopManagedRequirements: Equatable {
    var allowedApprovalPolicies: [String] = []
    var allowedSandboxModes: [String] = []
    var allowedPermissionProfiles: [String: Bool] = [:]
    var featureRequirements: [String: Bool] = [:]
    var defaultPermissionProfile: String?

    var isEmpty: Bool {
        allowedApprovalPolicies.isEmpty
            && allowedSandboxModes.isEmpty
            && allowedPermissionProfiles.isEmpty
            && featureRequirements.isEmpty
            && defaultPermissionProfile == nil
    }

    static func parse(_ object: [String: Any]?) -> DesktopManagedRequirements {
        guard let object else { return DesktopManagedRequirements() }
        let approvalPolicies = (object["allowedApprovalPolicies"] as? [Any] ?? []).compactMap { value -> String? in
            if let value = value as? String { return value }
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
        return DesktopManagedRequirements(
            allowedApprovalPolicies: approvalPolicies,
            allowedSandboxModes: object.stringArray("allowedSandboxModes"),
            allowedPermissionProfiles: object["allowedPermissionProfiles"] as? [String: Bool] ?? [:],
            featureRequirements: object["featureRequirements"] as? [String: Bool] ?? [:],
            defaultPermissionProfile: object.string("defaultPermissions")
        )
    }
}

struct DesktopExperimentalFeature: Identifiable, Equatable {
    let id: String
    let displayName: String
    let description: String?
    let announcement: String?
    let stage: String
    let isEnabled: Bool
    let isEnabledByDefault: Bool

    static func parse(_ object: [String: Any]) -> DesktopExperimentalFeature? {
        guard let name = object.string("name") else { return nil }
        return DesktopExperimentalFeature(
            id: name,
            displayName: object.string("displayName") ?? name,
            description: object.string("description"),
            announcement: object.string("announcement"),
            stage: object.string("stage") ?? "unknown",
            isEnabled: object.bool("enabled") ?? false,
            isEnabledByDefault: object.bool("defaultEnabled") ?? false
        )
    }
}

struct DesktopHookRecord: Identifiable, Equatable {
    let id: String
    let eventName: String
    let handlerType: String
    let sourcePath: String
    let source: String
    let trustStatus: String
    let isEnabled: Bool
    let isManaged: Bool

    static func parse(_ object: [String: Any]) -> DesktopHookRecord? {
        guard let key = object.string("key"),
              let eventName = object.string("eventName"),
              let sourcePath = object.string("sourcePath") else { return nil }
        return DesktopHookRecord(
            id: key,
            eventName: eventName,
            handlerType: object.string("handlerType") ?? "hook",
            sourcePath: sourcePath,
            source: object.string("source") ?? "unknown",
            trustStatus: object.string("trustStatus") ?? "unknown",
            isEnabled: object.bool("enabled") ?? false,
            isManaged: object.bool("isManaged") ?? false
        )
    }
}

struct DesktopWorkspaceMessage: Identifiable, Equatable {
    let id: String
    let type: String
    let body: String
    let createdAt: Date?

    static func parse(_ object: [String: Any]) -> DesktopWorkspaceMessage? {
        guard let id = object.string("messageId"),
              let body = object.string("messageBody") else { return nil }
        return DesktopWorkspaceMessage(
            id: id,
            type: object.string("messageType") ?? "announcement",
            body: body,
            createdAt: object.number("createdAt").map(Date.init(timeIntervalSince1970:))
        )
    }
}
