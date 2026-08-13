// FILE: DesktopIntegrationModels.swift
// Purpose: Typed, forward-compatible models for app-server account, integration, tool, artifact, and realtime APIs.
// Layer: Desktop app model

import Foundation

// MARK: - Account

enum DesktopAccountLoginKind: Hashable {
    case apiKey
    case chatGPT
    case chatGPTDeviceCode
    case amazonBedrock
    case unknown(String)

    init(protocolValue: String) {
        switch protocolValue {
        case "apiKey": self = .apiKey
        case "chatgpt": self = .chatGPT
        case "chatgptDeviceCode": self = .chatGPTDeviceCode
        case "amazonBedrock": self = .amazonBedrock
        default: self = .unknown(protocolValue)
        }
    }
}

enum DesktopAccountLoginState: Hashable {
    case awaitingUser
    case completed
    case failed(String)
    case canceled
}

/// Represents public login-flow state only. Credentials and auth tokens deliberately
/// have no corresponding stored property in this model.
struct DesktopAccountLoginSession: Identifiable, Hashable {
    let id: String
    let kind: DesktopAccountLoginKind
    let authorizationURL: URL?
    let userCode: String?
    var state: DesktopAccountLoginState

    static func parse(_ response: [String: Any]) -> DesktopAccountLoginSession? {
        guard let rawType = DesktopProtocolValue.string(response, "type") else { return nil }
        let kind = DesktopAccountLoginKind(protocolValue: rawType)
        let loginID = DesktopProtocolValue.string(response, "loginId")
            ?? DesktopProtocolValue.string(response, "login_id")
        let rawURL = DesktopProtocolValue.string(response, "authUrl")
            ?? DesktopProtocolValue.string(response, "auth_url")
            ?? DesktopProtocolValue.string(response, "verificationUrl")
            ?? DesktopProtocolValue.string(response, "verification_url")
        let authorizationURL = rawURL.flatMap(URL.init(string:))

        return DesktopAccountLoginSession(
            id: loginID ?? "immediate:\(rawType)",
            kind: kind,
            authorizationURL: authorizationURL,
            userCode: DesktopProtocolValue.string(response, "userCode")
                ?? DesktopProtocolValue.string(response, "user_code"),
            state: loginID == nil ? .completed : .awaitingUser
        )
    }

    func applyingCompletion(_ notification: [String: Any]) -> DesktopAccountLoginSession {
        if let completedID = DesktopProtocolValue.string(notification, "loginId"), completedID != id {
            return self
        }
        var updated = self
        if DesktopProtocolValue.bool(notification, "success") == true {
            updated.state = .completed
        } else {
            updated.state = .failed(
                DesktopProtocolValue.string(notification, "error") ?? "Account login failed."
            )
        }
        return updated
    }
}

// MARK: - Skills

enum DesktopSkillScope: Hashable {
    case user
    case repo
    case system
    case admin
    case unknown(String)

    init(protocolValue: String) {
        switch protocolValue {
        case "user": self = .user
        case "repo": self = .repo
        case "system": self = .system
        case "admin": self = .admin
        default: self = .unknown(protocolValue)
        }
    }
}

struct DesktopSkillDependency: Identifiable, Hashable {
    let type: String
    let value: String
    let description: String?
    let command: String?
    let transport: String?
    let url: String?

    var id: String { "\(type):\(value)" }

    static func parse(_ object: [String: Any]) -> DesktopSkillDependency? {
        guard let type = DesktopProtocolValue.string(object, "type"),
              let value = DesktopProtocolValue.string(object, "value") else { return nil }
        return DesktopSkillDependency(
            type: type,
            value: value,
            description: DesktopProtocolValue.string(object, "description"),
            command: DesktopProtocolValue.string(object, "command"),
            transport: DesktopProtocolValue.string(object, "transport"),
            url: DesktopProtocolValue.string(object, "url")
        )
    }
}

struct DesktopSkillRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let displayName: String
    let description: String
    let path: String?
    let scope: DesktopSkillScope
    let enabled: Bool
    let dependencies: [DesktopSkillDependency]

    static func parse(_ object: [String: Any]) -> DesktopSkillRecord? {
        guard let name = DesktopProtocolValue.string(object, "name") else { return nil }
        let path = DesktopProtocolValue.string(object, "path")
        let interface = object["interface"] as? [String: Any]
        let dependencyObject = object["dependencies"] as? [String: Any]
        let dependencies = (dependencyObject?["tools"] as? [[String: Any]] ?? [])
            .compactMap(DesktopSkillDependency.parse)
        let rawScope = DesktopProtocolValue.string(object, "scope") ?? "unknown"

        return DesktopSkillRecord(
            id: path ?? "skill:\(name)",
            name: name,
            displayName: interface.flatMap { DesktopProtocolValue.string($0, "displayName") } ?? name,
            description: interface.flatMap { DesktopProtocolValue.string($0, "shortDescription") }
                ?? DesktopProtocolValue.string(object, "shortDescription")
                ?? DesktopProtocolValue.string(object, "description")
                ?? "",
            path: path,
            scope: DesktopSkillScope(protocolValue: rawScope),
            enabled: DesktopProtocolValue.bool(object, "enabled") ?? true,
            dependencies: dependencies
        )
    }
}

// MARK: - Plugins and apps

struct DesktopPluginSelector: Hashable {
    let pluginName: String
    let marketplacePath: String?
    let remoteMarketplaceName: String?

    var requestParams: [String: Any] {
        var params: [String: Any] = ["pluginName": pluginName]
        if let marketplacePath { params["marketplacePath"] = marketplacePath }
        if let remoteMarketplaceName { params["remoteMarketplaceName"] = remoteMarketplaceName }
        return params
    }
}

enum DesktopPluginAuthPolicy: Hashable {
    case onInstall
    case onUse
    case unknown(String)

    init(protocolValue: String) {
        switch protocolValue {
        case "ON_INSTALL": self = .onInstall
        case "ON_USE": self = .onUse
        default: self = .unknown(protocolValue)
        }
    }
}

enum DesktopPluginInstallPolicy: Hashable {
    case unavailable
    case available
    case installedByDefault
    case unknown(String)

    init(protocolValue: String) {
        switch protocolValue {
        case "NOT_AVAILABLE": self = .unavailable
        case "AVAILABLE": self = .available
        case "INSTALLED_BY_DEFAULT": self = .installedByDefault
        default: self = .unknown(protocolValue)
        }
    }
}

enum DesktopPluginAvailability: Hashable {
    case available
    case disabledByAdmin
    case unknown(String)

    init(protocolValue: String) {
        switch protocolValue {
        case "AVAILABLE": self = .available
        case "DISABLED_BY_ADMIN": self = .disabledByAdmin
        default: self = .unknown(protocolValue)
        }
    }
}

enum DesktopPluginSource: Hashable {
    case local(path: String)
    case git(url: String, reference: String?, sha: String?)
    case npm(package: String, version: String?, registry: String?)
    case remote
    case unknown(String)

    static func parse(_ value: Any?) -> DesktopPluginSource {
        guard let object = value as? [String: Any],
              let type = DesktopProtocolValue.string(object, "type") else { return .unknown("missing") }
        switch type {
        case "local":
            return .local(path: DesktopProtocolValue.string(object, "path") ?? "")
        case "git":
            return .git(
                url: DesktopProtocolValue.string(object, "url") ?? "",
                reference: DesktopProtocolValue.string(object, "refName"),
                sha: DesktopProtocolValue.string(object, "sha")
            )
        case "npm":
            return .npm(
                package: DesktopProtocolValue.string(object, "package") ?? "",
                version: DesktopProtocolValue.string(object, "version"),
                registry: DesktopProtocolValue.string(object, "registry")
            )
        case "remote": return .remote
        default: return .unknown(type)
        }
    }
}

struct DesktopPluginRecord: Identifiable, Hashable {
    let id: String
    let selector: DesktopPluginSelector
    let displayName: String
    let description: String
    let marketplaceName: String?
    let installed: Bool
    let enabled: Bool
    let version: String?
    let localVersion: String?
    let authPolicy: DesktopPluginAuthPolicy
    let installPolicy: DesktopPluginInstallPolicy
    let availability: DesktopPluginAvailability
    let source: DesktopPluginSource
    let mustShowInstallationInterstitial: Bool
    let privacyPolicyURL: URL?
    let termsOfServiceURL: URL?
    let capabilityLabels: [String]

    var canInstall: Bool {
        guard !installed, case .available = availability else { return false }
        guard case .available = installPolicy else { return false }
        return true
    }

    var unavailableReason: String {
        if case .disabledByAdmin = availability { return "Disabled by administrator" }
        if case .unavailable = installPolicy { return "Unavailable" }
        return "Installation unavailable"
    }

    static func parse(
        _ object: [String: Any],
        marketplaceName: String? = nil,
        marketplacePath: String? = nil
    ) -> DesktopPluginRecord? {
        guard let name = DesktopProtocolValue.string(object, "name") else { return nil }
        let interface = object["interface"] as? [String: Any]
        let remoteMarketplaceName = marketplacePath == nil ? marketplaceName : nil
        return DesktopPluginRecord(
            id: DesktopProtocolValue.string(object, "id") ?? "plugin:\(name)",
            selector: DesktopPluginSelector(
                pluginName: name,
                marketplacePath: marketplacePath,
                remoteMarketplaceName: remoteMarketplaceName
            ),
            displayName: interface.flatMap { DesktopProtocolValue.string($0, "displayName") } ?? name,
            description: interface.flatMap { DesktopProtocolValue.string($0, "shortDescription") }
                ?? interface.flatMap { DesktopProtocolValue.string($0, "longDescription") }
                ?? "",
            marketplaceName: marketplaceName,
            installed: DesktopProtocolValue.bool(object, "installed") ?? false,
            enabled: DesktopProtocolValue.bool(object, "enabled") ?? false,
            version: DesktopProtocolValue.string(object, "version"),
            localVersion: DesktopProtocolValue.string(object, "localVersion"),
            authPolicy: DesktopPluginAuthPolicy(
                protocolValue: DesktopProtocolValue.protocolString(object["authPolicy"]) ?? "unknown"
            ),
            installPolicy: DesktopPluginInstallPolicy(
                protocolValue: DesktopProtocolValue.protocolString(object["installPolicy"]) ?? "unknown"
            ),
            availability: DesktopPluginAvailability(
                protocolValue: DesktopProtocolValue.protocolString(object["availability"]) ?? "unknown"
            ),
            source: DesktopPluginSource.parse(object["source"]),
            mustShowInstallationInterstitial: DesktopProtocolValue.bool(
                object,
                "mustShowInstallationInterstitial"
            ) ?? false,
            privacyPolicyURL: interface
                .flatMap { DesktopProtocolValue.string($0, "privacyPolicyUrl") }
                .flatMap(URL.init(string:)),
            termsOfServiceURL: interface
                .flatMap { DesktopProtocolValue.string($0, "termsOfServiceUrl") }
                .flatMap(URL.init(string:)),
            capabilityLabels: interface?["capabilities"] as? [String] ?? []
        )
    }
}

struct DesktopAppRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let isAccessible: Bool
    let isEnabled: Bool
    let installURL: URL?
    let privacyPolicyURL: URL?
    let termsOfServiceURL: URL?
    let distributionChannel: String?
    let pluginDisplayNames: [String]

    static func parse(_ object: [String: Any]) -> DesktopAppRecord? {
        guard let id = DesktopProtocolValue.string(object, "id"),
              let name = DesktopProtocolValue.string(object, "name") else { return nil }
        let branding = object["branding"] as? [String: Any]

        return DesktopAppRecord(
            id: id,
            name: name,
            description: DesktopProtocolValue.string(object, "description") ?? "",
            isAccessible: DesktopProtocolValue.bool(object, "isAccessible") ?? false,
            isEnabled: DesktopProtocolValue.bool(object, "isEnabled") ?? true,
            installURL: httpsURL(DesktopProtocolValue.string(object, "installUrl")),
            privacyPolicyURL: httpsURL(branding.flatMap {
                DesktopProtocolValue.string($0, "privacyPolicy")
            }),
            termsOfServiceURL: httpsURL(branding.flatMap {
                DesktopProtocolValue.string($0, "termsOfService")
            }),
            distributionChannel: DesktopProtocolValue.string(object, "distributionChannel"),
            pluginDisplayNames: object["pluginDisplayNames"] as? [String] ?? []
        )
    }
}

// MARK: - MCP

enum DesktopMCPAuthStatus: Hashable {
    case unsupported
    case notLoggedIn
    case bearerToken
    case oauth
    case unknown(String)

    init(protocolValue: String) {
        switch protocolValue {
        case "unsupported": self = .unsupported
        case "notLoggedIn": self = .notLoggedIn
        case "bearerToken": self = .bearerToken
        case "oAuth": self = .oauth
        default: self = .unknown(protocolValue)
        }
    }
}

enum DesktopMCPStartupState: Hashable {
    case starting
    case ready
    case failed
    case cancelled
    case unknown(String)

    init(protocolValue: String) {
        switch protocolValue {
        case "starting": self = .starting
        case "ready": self = .ready
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unknown(protocolValue)
        }
    }
}

struct DesktopMCPServerStatus: Identifiable, Hashable {
    let id: String
    let name: String
    let title: String
    let description: String
    let authStatus: DesktopMCPAuthStatus
    let startupState: DesktopMCPStartupState?
    let error: String?
    let requiresReauthentication: Bool
    let toolNames: [String]
    let resourceCount: Int
    let resourceTemplateCount: Int

    static func parse(_ object: [String: Any]) -> DesktopMCPServerStatus? {
        guard let name = DesktopProtocolValue.string(object, "name") else { return nil }
        let info = object["serverInfo"] as? [String: Any]
        let tools = object["tools"] as? [String: Any] ?? [:]
        return DesktopMCPServerStatus(
            id: name,
            name: name,
            title: info.flatMap { DesktopProtocolValue.string($0, "title") } ?? name,
            description: info.flatMap { DesktopProtocolValue.string($0, "description") } ?? "",
            authStatus: DesktopMCPAuthStatus(
                protocolValue: DesktopProtocolValue.string(object, "authStatus") ?? "unknown"
            ),
            startupState: nil,
            error: nil,
            requiresReauthentication: false,
            toolNames: tools.keys.sorted(),
            resourceCount: (object["resources"] as? [Any])?.count ?? 0,
            resourceTemplateCount: (object["resourceTemplates"] as? [Any])?.count ?? 0
        )
    }

    func applyingStartupNotification(_ object: [String: Any]) -> DesktopMCPServerStatus {
        guard DesktopProtocolValue.string(object, "name") == name else { return self }
        return DesktopMCPServerStatus(
            id: id,
            name: name,
            title: title,
            description: description,
            authStatus: authStatus,
            startupState: DesktopMCPStartupState(
                protocolValue: DesktopProtocolValue.string(object, "status") ?? "unknown"
            ),
            error: DesktopProtocolValue.string(object, "error"),
            requiresReauthentication: DesktopProtocolValue.string(object, "failureReason")
                == "reauthenticationRequired",
            toolNames: toolNames,
            resourceCount: resourceCount,
            resourceTemplateCount: resourceTemplateCount
        )
    }
}

// MARK: - Tool metadata, artifacts, and citations

enum DesktopToolKind: Hashable {
    case command
    case fileChange
    case mcp(server: String)
    case dynamic(namespace: String?)
    case collaboration
    case unknown(String)
}

enum DesktopToolStatus: Hashable {
    case inProgress
    case completed
    case failed
    case declined
    case unknown(String)

    init(protocolValue: String) {
        switch protocolValue {
        case "inProgress": self = .inProgress
        case "completed": self = .completed
        case "failed": self = .failed
        case "declined": self = .declined
        default: self = .unknown(protocolValue)
        }
    }
}

struct DesktopToolMetadata: Identifiable, Hashable {
    let id: String
    let kind: DesktopToolKind
    let name: String
    let status: DesktopToolStatus
    let durationMilliseconds: Int?
    let exitCode: Int?
    let processID: String?
    let workingDirectory: String?
    let argumentsJSON: String?
    let errorMessage: String?
    var progressMessage: String?

    static func parse(_ item: [String: Any]) -> DesktopToolMetadata? {
        guard let id = DesktopProtocolValue.string(item, "id"),
              let type = DesktopProtocolValue.string(item, "type") else { return nil }
        let status = DesktopToolStatus(
            protocolValue: DesktopProtocolValue.protocolString(item["status"]) ?? "unknown"
        )
        let errorObject = item["error"] as? [String: Any]

        switch type {
        case "commandExecution":
            return DesktopToolMetadata(
                id: id,
                kind: .command,
                name: DesktopProtocolValue.string(item, "command") ?? "Command",
                status: status,
                durationMilliseconds: DesktopProtocolValue.int(item, "durationMs"),
                exitCode: DesktopProtocolValue.int(item, "exitCode"),
                processID: DesktopProtocolValue.string(item, "processId"),
                workingDirectory: DesktopProtocolValue.string(item, "cwd"),
                argumentsJSON: nil,
                errorMessage: nil,
                progressMessage: nil
            )
        case "fileChange":
            return DesktopToolMetadata(
                id: id,
                kind: .fileChange,
                name: "File changes",
                status: status,
                durationMilliseconds: nil,
                exitCode: nil,
                processID: nil,
                workingDirectory: nil,
                argumentsJSON: DesktopProtocolValue.jsonString(item["changes"]),
                errorMessage: nil,
                progressMessage: nil
            )
        case "mcpToolCall":
            let server = DesktopProtocolValue.string(item, "server") ?? "MCP"
            return DesktopToolMetadata(
                id: id,
                kind: .mcp(server: server),
                name: DesktopProtocolValue.string(item, "tool") ?? "Tool",
                status: status,
                durationMilliseconds: DesktopProtocolValue.int(item, "durationMs"),
                exitCode: nil,
                processID: nil,
                workingDirectory: nil,
                argumentsJSON: DesktopProtocolValue.jsonString(item["arguments"]),
                errorMessage: errorObject.flatMap { DesktopProtocolValue.string($0, "message") },
                progressMessage: nil
            )
        case "dynamicToolCall":
            return DesktopToolMetadata(
                id: id,
                kind: .dynamic(namespace: DesktopProtocolValue.string(item, "namespace")),
                name: DesktopProtocolValue.string(item, "tool") ?? "Tool",
                status: status,
                durationMilliseconds: DesktopProtocolValue.int(item, "durationMs"),
                exitCode: nil,
                processID: nil,
                workingDirectory: nil,
                argumentsJSON: DesktopProtocolValue.jsonString(item["arguments"]),
                errorMessage: DesktopProtocolValue.bool(item, "success") == false ? "Tool failed." : nil,
                progressMessage: nil
            )
        case "collabAgentToolCall":
            var inputs: [String: Any] = [:]
            for key in ["prompt", "model", "reasoningEffort", "senderThreadId", "receiverThreadIds"] {
                if let value = item[key] { inputs[key] = value }
            }
            let stateMessages = (item["agentsStates"] as? [String: Any] ?? [:])
                .compactMap { _, value in
                    (value as? [String: Any]).flatMap { DesktopProtocolValue.string($0, "message") }
                }
            return DesktopToolMetadata(
                id: id,
                kind: .collaboration,
                name: DesktopProtocolValue.string(item, "tool") ?? "Subagent",
                status: status,
                durationMilliseconds: DesktopProtocolValue.int(item, "durationMs"),
                exitCode: nil,
                processID: nil,
                workingDirectory: nil,
                argumentsJSON: inputs.isEmpty ? nil : DesktopProtocolValue.jsonString(inputs),
                errorMessage: stateMessages.isEmpty ? nil : stateMessages.joined(separator: "\n"),
                progressMessage: nil
            )
        default:
            return DesktopToolMetadata(
                id: id,
                kind: .unknown(type),
                name: type,
                status: status,
                durationMilliseconds: DesktopProtocolValue.int(item, "durationMs"),
                exitCode: nil,
                processID: nil,
                workingDirectory: nil,
                argumentsJSON: nil,
                errorMessage: nil,
                progressMessage: nil
            )
        }
    }

    func applyingProgress(_ notification: [String: Any]) -> DesktopToolMetadata {
        guard DesktopProtocolValue.string(notification, "itemId") == id else { return self }
        var updated = self
        updated.progressMessage = DesktopProtocolValue.string(notification, "message")
        return updated
    }
}

struct DesktopToolArtifact: Identifiable, Hashable {
    enum Kind: Hashable {
        case text
        case localFile
        case inlineImage
        case inlineAudio
        case remoteImage
        case remoteAudio
        case resource
        case unknown(String)
    }

    let id: String
    let kind: Kind
    let source: String
    let mimeType: String?
    let displayName: String

    static func parseContentItem(
        _ object: [String: Any],
        parentID: String,
        index: Int
    ) -> DesktopToolArtifact? {
        guard let type = DesktopProtocolValue.string(object, "type") else { return nil }
        switch type {
        case "inputText", "text":
            guard let text = DesktopProtocolValue.string(object, "text") else { return nil }
            return DesktopToolArtifact(
                id: "\(parentID):\(index)", kind: .text, source: text,
                mimeType: "text/plain", displayName: "Text result"
            )
        case "inputImage", "image":
            let mimeType = DesktopProtocolValue.string(object, "mimeType")
            if let data = DesktopProtocolValue.string(object, "data") {
                return DesktopToolArtifact(
                    id: "\(parentID):\(index)", kind: .inlineImage, source: data,
                    mimeType: mimeType, displayName: "Image"
                )
            }
            guard let url = DesktopProtocolValue.string(object, "imageUrl")
                    ?? DesktopProtocolValue.string(object, "url") else { return nil }
            return DesktopToolArtifact(
                id: "\(parentID):\(index)", kind: .remoteImage, source: url,
                mimeType: mimeType, displayName: "Image"
            )
        case "inputAudio", "audio":
            let mimeType = DesktopProtocolValue.string(object, "mimeType")
            if let data = DesktopProtocolValue.string(object, "data") {
                return DesktopToolArtifact(
                    id: "\(parentID):\(index)", kind: .inlineAudio, source: data,
                    mimeType: mimeType, displayName: "Audio"
                )
            }
            guard let url = DesktopProtocolValue.string(object, "audioUrl")
                    ?? DesktopProtocolValue.string(object, "url") else { return nil }
            return DesktopToolArtifact(
                id: "\(parentID):\(index)", kind: .remoteAudio, source: url,
                mimeType: mimeType, displayName: "Audio"
            )
        case "resource":
            let resource = object["resource"] as? [String: Any] ?? object
            let mimeType = DesktopProtocolValue.string(resource, "mimeType")
            let displayName = DesktopProtocolValue.string(object, "name")
                ?? DesktopProtocolValue.string(resource, "uri")
                ?? "Resource"
            if let text = DesktopProtocolValue.string(resource, "text") {
                return DesktopToolArtifact(
                    id: "\(parentID):\(index)", kind: .text, source: text,
                    mimeType: mimeType ?? "text/plain", displayName: displayName
                )
            }
            if let blob = DesktopProtocolValue.string(resource, "blob"),
               mimeType?.lowercased().hasPrefix("image/") == true {
                return DesktopToolArtifact(
                    id: "\(parentID):\(index)", kind: .inlineImage, source: blob,
                    mimeType: mimeType, displayName: displayName
                )
            }
            guard let source = DesktopProtocolValue.string(resource, "uri") else { return nil }
            return DesktopToolArtifact(
                id: "\(parentID):\(index)", kind: .resource, source: source,
                mimeType: mimeType, displayName: displayName
            )
        case "resource_link", "resourceLink":
            guard let source = DesktopProtocolValue.string(object, "uri") else { return nil }
            return DesktopToolArtifact(
                id: "\(parentID):\(index)", kind: .resource, source: source,
                mimeType: DesktopProtocolValue.string(object, "mimeType"),
                displayName: DesktopProtocolValue.string(object, "name") ?? "Resource"
            )
        default:
            let source = DesktopProtocolValue.string(object, "url")
                ?? DesktopProtocolValue.string(object, "path")
                ?? DesktopProtocolValue.jsonString(object)
                ?? ""
            return DesktopToolArtifact(
                id: "\(parentID):\(index)", kind: .unknown(type), source: source,
                mimeType: DesktopProtocolValue.string(object, "mimeType"), displayName: type
            )
        }
    }

    static func parseKnownItem(_ item: [String: Any]) -> DesktopToolArtifact? {
        guard let id = DesktopProtocolValue.string(item, "id"),
              let type = DesktopProtocolValue.string(item, "type") else { return nil }
        switch type {
        case "imageView":
            guard let path = DesktopProtocolValue.string(item, "path") else { return nil }
            return DesktopToolArtifact(
                id: id, kind: .localFile, source: path, mimeType: nil,
                displayName: URL(fileURLWithPath: path).lastPathComponent
            )
        case "imageGeneration":
            guard let path = DesktopProtocolValue.string(item, "savedPath") else { return nil }
            return DesktopToolArtifact(
                id: id, kind: .localFile, source: path, mimeType: nil,
                displayName: URL(fileURLWithPath: path).lastPathComponent
            )
        default:
            return nil
        }
    }
}

struct DesktopCitationEntry: Identifiable, Hashable {
    let path: String
    let lineStart: Int
    let lineEnd: Int
    let note: String

    var id: String { "\(path):\(lineStart):\(lineEnd)" }

    static func parse(_ object: [String: Any]) -> DesktopCitationEntry? {
        guard let path = DesktopProtocolValue.string(object, "path"),
              let lineStart = DesktopProtocolValue.int(object, "lineStart"),
              let lineEnd = DesktopProtocolValue.int(object, "lineEnd") else { return nil }
        return DesktopCitationEntry(
            path: path,
            lineStart: lineStart,
            lineEnd: lineEnd,
            note: DesktopProtocolValue.string(object, "note") ?? ""
        )
    }
}

struct DesktopMemoryCitation: Identifiable, Hashable {
    let id: String
    let entries: [DesktopCitationEntry]
    let threadIDs: [String]

    static func parse(_ object: [String: Any], itemID: String) -> DesktopMemoryCitation? {
        let entries = (object["entries"] as? [[String: Any]] ?? [])
            .compactMap(DesktopCitationEntry.parse)
        let threadIDs = object["threadIds"] as? [String] ?? []
        guard !entries.isEmpty || !threadIDs.isEmpty else { return nil }
        return DesktopMemoryCitation(id: itemID, entries: entries, threadIDs: threadIDs)
    }
}

struct DesktopInteractiveTerminalState: Identifiable, Hashable {
    let id: String
    let command: String
    let workingDirectory: String
    var output: String
    var isRunning: Bool
    var isTerminating: Bool
    var exitCode: Int?
    var errorMessage: String?
    var outputWasCapped: Bool
}

// MARK: - Realtime voice

struct DesktopVoiceOption: Identifiable, Hashable {
    let id: String
    let displayName: String

    static func parse(_ value: String) -> DesktopVoiceOption {
        DesktopVoiceOption(
            id: value,
            displayName: value.replacingOccurrences(of: "_", with: " ").capitalized
        )
    }
}

enum DesktopRealtimeOutputModality: Hashable {
    case text
    case audio
    case unknown(String)

    init(protocolValue: String) {
        switch protocolValue {
        case "text": self = .text
        case "audio": self = .audio
        default: self = .unknown(protocolValue)
        }
    }
}

enum DesktopRealtimeConnectionState: Hashable {
    case starting
    case active
    case stopping
    case closed(reason: String?)
    case failed(String)
}

struct DesktopRealtimeSessionState: Identifiable, Hashable {
    let threadID: String
    var realtimeSessionID: String?
    var version: String?
    var outputModality: DesktopRealtimeOutputModality
    var voice: DesktopVoiceOption?
    var connectionState: DesktopRealtimeConnectionState

    var id: String { realtimeSessionID ?? threadID }

    static func starting(
        threadID: String,
        outputModality: String,
        voice: String? = nil
    ) -> DesktopRealtimeSessionState {
        DesktopRealtimeSessionState(
            threadID: threadID,
            realtimeSessionID: nil,
            version: nil,
            outputModality: DesktopRealtimeOutputModality(protocolValue: outputModality),
            voice: voice.map(DesktopVoiceOption.parse),
            connectionState: .starting
        )
    }

    func applyingStarted(_ notification: [String: Any]) -> DesktopRealtimeSessionState {
        guard DesktopProtocolValue.string(notification, "threadId") == threadID else { return self }
        var updated = self
        updated.realtimeSessionID = DesktopProtocolValue.string(notification, "realtimeSessionId")
        updated.version = DesktopProtocolValue.protocolString(notification["version"])
        updated.connectionState = .active
        return updated
    }

    func applyingClosed(_ notification: [String: Any]) -> DesktopRealtimeSessionState {
        guard DesktopProtocolValue.string(notification, "threadId") == threadID else { return self }
        var updated = self
        updated.connectionState = .closed(reason: DesktopProtocolValue.string(notification, "reason"))
        return updated
    }

    func applyingError(_ notification: [String: Any]) -> DesktopRealtimeSessionState {
        guard DesktopProtocolValue.string(notification, "threadId") == threadID else { return self }
        var updated = self
        updated.connectionState = .failed(
            DesktopProtocolValue.string(notification, "message") ?? "Realtime voice failed."
        )
        return updated
    }
}

// MARK: - Parsing helpers

private enum DesktopProtocolValue {
    static func string(_ object: [String: Any], _ key: String) -> String? {
        if let value = object[key] as? String { return value }
        if let value = object[key] as? NSNumber { return value.stringValue }
        return nil
    }

    static func bool(_ object: [String: Any], _ key: String) -> Bool? {
        if let value = object[key] as? Bool { return value }
        if let value = object[key] as? NSNumber { return value.boolValue }
        return nil
    }

    static func int(_ object: [String: Any], _ key: String) -> Int? {
        if let value = object[key] as? Int { return value }
        if let value = object[key] as? NSNumber { return value.intValue }
        return nil
    }

    static func protocolString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let object = value as? [String: Any] { return string(object, "type") }
        return nil
    }

    static func jsonString(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys]
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private func httpsURL(_ rawValue: String?) -> URL? {
    guard let rawValue,
          let url = URL(string: rawValue),
          url.scheme?.lowercased() == "https" else { return nil }
    return url
}
