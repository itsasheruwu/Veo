// FILE: CodexAppServerCapabilities.swift
// Purpose: Captures the app-server identity negotiated during initialize and gates optional APIs.
// Layer: Desktop app model

import Foundation

enum CodexAPIMaturity: String, Hashable {
    case stable
    case experimental
}

/// Product-level capabilities used by Veo. Keeping method names here makes optional
/// protocol usage auditable and gives older app-server versions one fallback path.
enum CodexAppServerCapability: String, CaseIterable, Identifiable, Hashable {
    case turnSteering
    case queuedUserMessageIDs
    case threadSearch
    case threadContentSearch
    case threadManagement
    case manualCompaction
    case review
    case liveDiffs
    case account
    case accountLogin
    case accountLogout
    case skills
    case skillsManagement
    case plugins
    case pluginManagement
    case apps
    case appsLinking
    case mcpStatus
    case mcpOAuth
    case mcpReload
    case commandExec
    case realtimeVoice
    case collaborationModes
    case permissionProfiles
    case configManagement
    case experimentalFeatures
    case hooks
    case threadSubscriptions
    case integrationDetails
    case accountExtras

    var id: String { rawValue }

    var maturity: CodexAPIMaturity {
        switch self {
        case .threadSearch, .threadContentSearch, .apps, .appsLinking,
             .realtimeVoice, .collaborationModes, .permissionProfiles,
             .experimentalFeatures:
            return .experimental
        default:
            return .stable
        }
    }

    var methods: Set<String> {
        switch self {
        case .turnSteering:
            return ["turn/steer"]
        case .queuedUserMessageIDs:
            return ["turn/start", "turn/steer"]
        case .threadSearch:
            return ["thread/search"]
        case .threadContentSearch:
            return ["thread/searchOccurrences"]
        case .threadManagement:
            return [
                "thread/metadata/update", "thread/name/set", "thread/archive",
                "thread/unarchive", "thread/delete", "thread/fork",
            ]
        case .manualCompaction:
            return ["thread/compact/start"]
        case .review:
            return ["review/start"]
        case .liveDiffs:
            return ["turn/diff/updated", "item/fileChange/patchUpdated"]
        case .account:
            return ["account/read", "account/rateLimits/read", "account/usage/read"]
        case .accountLogin:
            return ["account/login/start", "account/login/cancel"]
        case .accountLogout:
            return ["account/logout"]
        case .skills:
            return ["skills/list"]
        case .skillsManagement:
            return ["skills/config/write", "skills/extraRoots/set"]
        case .plugins:
            return ["plugin/list", "plugin/read"]
        case .pluginManagement:
            return ["plugin/install", "plugin/uninstall", "plugin/installed"]
        case .apps:
            return ["app/list", "app/read"]
        case .appsLinking:
            return ["app/list", "app/read", "app/installed"]
        case .mcpStatus:
            return ["mcpServerStatus/list"]
        case .mcpOAuth:
            return ["mcpServer/oauth/login"]
        case .mcpReload:
            return ["config/mcpServer/reload"]
        case .commandExec:
            return [
                "command/exec", "command/exec/write",
                "command/exec/resize", "command/exec/terminate",
            ]
        case .realtimeVoice:
            return [
                "thread/realtime/start", "thread/realtime/appendAudio",
                "thread/realtime/appendText", "thread/realtime/appendSpeech",
                "thread/realtime/stop", "thread/realtime/listVoices",
            ]
        case .collaborationModes:
            return ["collaborationMode/list", "thread/settings/update"]
        case .permissionProfiles:
            return ["permissionProfile/list"]
        case .configManagement:
            return ["config/read", "config/value/write", "config/batchWrite", "configRequirements/read"]
        case .experimentalFeatures:
            return ["experimentalFeature/list", "experimentalFeature/enablement/set"]
        case .hooks:
            return ["hooks/list"]
        case .threadSubscriptions:
            return ["thread/loaded/list", "thread/unsubscribe"]
        case .integrationDetails:
            return ["plugin/read", "plugin/skill/read", "app/read", "app/installed",
                    "mcpServer/resource/read", "mcpServer/tool/call"]
        case .accountExtras:
            return ["account/workspaceMessages/read", "account/rateLimitResetCredit/consume",
                    "account/sendAddCreditsNudgeEmail"]
        }
    }

    /// Some capabilities describe a workflow rather than a collection of optional
    /// operations. A workflow must not be advertised after any required method is
    /// proven unavailable. Inventory-style groups remain available while at least
    /// one of their methods can still be used.
    var requiresAllMethods: Bool {
        switch self {
        case .accountLogin, .appsLinking, .commandExec, .realtimeVoice,
             .collaborationModes, .threadSubscriptions:
            return true
        default:
            return false
        }
    }
}

struct CodexServerVersion: Comparable, Hashable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: CodexServerVersion, rhs: CodexServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    static func parse(userAgent: String) -> CodexServerVersion? {
        guard let expression = try? NSRegularExpression(pattern: #"/(\d+)\.(\d+)\.(\d+)"#),
              let match = expression.firstMatch(
                in: userAgent,
                range: NSRange(userAgent.startIndex..., in: userAgent)
              ) else { return nil }

        let values = (1...3).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: userAgent) else { return nil }
            return Int(userAgent[range])
        }
        guard values.count == 3 else { return nil }
        return CodexServerVersion(major: values[0], minor: values[1], patch: values[2])
    }
}

struct CodexAppServerCapabilities: Equatable {
    let userAgent: String
    let codexHome: String?
    let platformFamily: String?
    let platformOS: String?
    let serverVersion: CodexServerVersion?
    let experimentalAPIEnabled: Bool
    let mcpFormElicitationEnabled: Bool
    private(set) var unavailableMethods: Set<String>

    static let unavailable = CodexAppServerCapabilities(
        userAgent: "",
        codexHome: nil,
        platformFamily: nil,
        platformOS: nil,
        serverVersion: nil,
        experimentalAPIEnabled: false,
        mcpFormElicitationEnabled: false,
        unavailableMethods: []
    )

    static func negotiated(
        initializeResponse: [String: Any],
        experimentalAPIEnabled: Bool,
        mcpFormElicitationEnabled: Bool
    ) -> CodexAppServerCapabilities {
        let userAgent = initializeResponse.string("userAgent") ?? ""
        return CodexAppServerCapabilities(
            userAgent: userAgent,
            codexHome: initializeResponse.string("codexHome"),
            platformFamily: initializeResponse.string("platformFamily"),
            platformOS: initializeResponse.string("platformOs"),
            serverVersion: CodexServerVersion.parse(userAgent: userAgent),
            experimentalAPIEnabled: experimentalAPIEnabled,
            mcpFormElicitationEnabled: mcpFormElicitationEnabled,
            unavailableMethods: []
        )
    }

    func supports(_ capability: CodexAppServerCapability) -> Bool {
        if capability.maturity == .experimental, !experimentalAPIEnabled {
            return false
        }
        if capability.requiresAllMethods {
            return capability.methods.allSatisfy { !unavailableMethods.contains($0) }
        }
        return !capability.methods.allSatisfy(unavailableMethods.contains)
    }

    func supports(method: String, maturity: CodexAPIMaturity = .stable) -> Bool {
        if maturity == .experimental, !experimentalAPIEnabled {
            return false
        }
        return !unavailableMethods.contains(method)
    }

    mutating func recordUnavailable(method: String) {
        unavailableMethods.insert(method)
    }
}

struct CodexAppServerRoute: Hashable {
    enum Direction: Hashable {
        case clientRequest
        case serverRequest
        case notification
    }

    let direction: Direction
    let method: String
    let threadID: String?
    let rpcID: DesktopRPCRequestID?

    static func incoming(_ object: [String: Any]) -> CodexAppServerRoute? {
        guard let method = object.string("method") else { return nil }
        let params = object["params"] as? [String: Any]
        let threadID = params?.string("threadId")
            ?? (params?["thread"] as? [String: Any])?.string("id")
        let rpcID = DesktopRPCRequestID(object["id"])
        return CodexAppServerRoute(
            direction: rpcID == nil ? .notification : .serverRequest,
            method: method,
            threadID: threadID,
            rpcID: rpcID
        )
    }
}
