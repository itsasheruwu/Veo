// FILE: DesktopExternalRequestAdapter.swift
// Purpose: Rewrites Codex Responses requests into the subset Grok/xAI accept,
//          and restores Codex custom-tool calls on the way back.
// Layer: Desktop app service

import Foundation

struct DesktopExternalToolRestore: Sendable {
    var customNames: Set<String>
    var grokToCodexName: [String: String]
    var namespaceByWireName: [String: NamespaceName]

    struct NamespaceName: Sendable {
        var namespace: String
        var name: String
    }
    var hostedSearchNames: Set<String>

    static let none = DesktopExternalToolRestore(
        customNames: [],
        grokToCodexName: [:],
        namespaceByWireName: [:],
        hostedSearchNames: []
    )

    var needsResponseRewrite: Bool {
        !customNames.isEmpty || !grokToCodexName.isEmpty
            || !namespaceByWireName.isEmpty || !hostedSearchNames.isEmpty
    }
}

struct DesktopExternalSanitizedRequest: Sendable {
    var body: Data
    var restore: DesktopExternalToolRestore
}

enum DesktopExternalRequestAdapter {
    private static let allowedInputTypes: Set<String> = [
        "message",
        "reasoning",
        "function_call",
        "function_call_output",
        "shell_call",
        "shell_call_output",
        "web_search_call",
        "file_search_call",
        "code_interpreter_call",
        "mcp_call",
        "custom_tool_call",
        "image_generation_call",
        "compaction",
        "compaction_summary",
        "context_compaction",
    ]

    private static let hostedToolTypes: Set<String> = [
        "web_search",
        "x_search",
        "code_execution",
        "code_interpreter",
        "file_search",
        "mcp",
    ]

    private static let hostedSearchTools: [[String: Any]] = [
        ["type": "web_search"],
        ["type": "x_search"],
    ]

    private static let emptyObjectSchema: [String: Any] = [
        "type": "object",
        "properties": [String: Any](),
    ]

    private static let customInputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "input": [
                "type": "string",
                "description": "The complete raw freeform input for this tool, preserved verbatim.",
            ] as [String: Any],
        ],
        "required": ["input"],
        "additionalProperties": false,
    ]

    static func sanitize(body: Data, path: String, providerID: String) -> DesktopExternalSanitizedRequest {
        guard path.hasSuffix("/responses") || path.hasSuffix("/chat/completions")
                || path.contains("/responses/") || path.contains("/chat/completions"),
              var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return DesktopExternalSanitizedRequest(body: body, restore: .none)
        }
        var restore = DesktopExternalToolRestore.none
        if let model = object["model"] as? String {
            object["model"] = unprefixedModel(model, providerID: providerID)
        }
        if path.contains("/responses") {
            let grok = providerID == DesktopExternalProviderPreset.grokOAuth.rawValue
                || providerID.hasPrefix("grok")
            object = sanitizeResponses(object, grok: grok, restore: &restore)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return DesktopExternalSanitizedRequest(body: body, restore: .none)
        }
        return DesktopExternalSanitizedRequest(body: data, restore: restore)
    }

    private static func sanitizeResponses(
        _ object: [String: Any],
        grok: Bool,
        restore: inout DesktopExternalToolRestore
    ) -> [String: Any] {
        var next = object
        let model = (next["model"] as? String) ?? ""
        let viewImageAlias = grok && model.contains("grok-4.6")
        if viewImageAlias {
            restore.grokToCodexName["inspect_image"] = "view_image"
        }

        var collectedTools: [[String: Any]] = []
        collectedTools.append(contentsOf: flattenDeclaredTools(next["tools"] as? [[String: Any]] ?? [], restore: &restore))
        if let items = next["input"] as? [[String: Any]] {
            for item in items where (item["type"] as? String) == "additional_tools" {
                if let extra = item["tools"] as? [[String: Any]] {
                    collectedTools.append(contentsOf: flattenDeclaredTools(extra, restore: &restore))
                }
            }
            next["input"] = items.compactMap { sanitizeInputItem($0, restore: restore) }
        }

        var tools = collectedTools.compactMap { sanitizeTool($0, restore: &restore) }
        tools = dedupeTools(tools)
        if grok {
            tools = mergeHostedSearch(tools, restore: &restore)
        }
        if tools.isEmpty {
            next.removeValue(forKey: "tools")
            next.removeValue(forKey: "tool_choice")
            next.removeValue(forKey: "parallel_tool_calls")
        } else {
            next["tools"] = tools
            if let choice = next["tool_choice"] {
                next["tool_choice"] = flattenToolChoice(choice, restore: restore)
            }
        }
        if let reasoning = next["reasoning"] as? [String: Any] {
            var copy = reasoning
            if let effort = copy["effort"] as? String {
                copy["effort"] = mappedEffort(effort)
            }
            next["reasoning"] = copy
        }
        if let effort = next["reasoning_effort"] as? String {
            next["reasoning_effort"] = mappedEffort(effort)
        }
        return next
    }

    private static func flattenDeclaredTools(
        _ tools: [[String: Any]],
        restore: inout DesktopExternalToolRestore
    ) -> [[String: Any]] {
        var flattened: [[String: Any]] = []
        for tool in tools {
            let type = (tool["type"] as? String)?.lowercased()
            if type == "tool_search" { continue }
            if type == "namespace",
               let namespace = tool["name"] as? String,
               let children = tool["tools"] as? [[String: Any]] {
                for child in children {
                    guard let childName = child["name"] as? String, !childName.isEmpty else { continue }
                    var copy = child
                    let wire = "\(namespace)__\(childName)"
                    copy["name"] = wire
                    restore.namespaceByWireName[wire] = DesktopExternalToolRestore.NamespaceName(
                        namespace: namespace,
                        name: childName
                    )
                    if (copy["type"] as? String)?.lowercased() == "custom" {
                        restore.customNames.insert(wire)
                        restore.customNames.insert(childName)
                    }
                    flattened.append(copy)
                }
                continue
            }
            flattened.append(tool)
        }
        return flattened
    }

    private static func sanitizeInputItem(
        _ item: [String: Any],
        restore: DesktopExternalToolRestore
    ) -> [String: Any]? {
        var next = item
        if let role = next["role"] as? String, role == "developer" {
            next["role"] = "system"
        }
        if let type = next["type"] as? String {
            switch type {
            case "additional_tools", "tool_search":
                return nil
            case "custom_tool_call":
                next["type"] = "function_call"
                if let input = next["input"] as? String {
                    next["arguments"] = jsonString(["input": input]) ?? "{}"
                    next.removeValue(forKey: "input")
                } else if next["arguments"] == nil {
                    next["arguments"] = "{}"
                }
                dropIncompatibleFunctionID(&next)
            case "custom_tool_call_output":
                next["type"] = "function_call_output"
                dropIncompatibleFunctionID(&next)
            case "agent_message":
                next["type"] = "message"
                next["role"] = "user"
            default:
                guard allowedInputTypes.contains(type) else { return nil }
            }
        } else if next["role"] == nil {
            return nil
        }
        if let name = next["name"] as? String {
            next["name"] = toolNameForGrok(name, restore: restore)
        }
        dropNullContentChannel(&next)
        return next
    }

    private static func sanitizeTool(
        _ tool: [String: Any],
        restore: inout DesktopExternalToolRestore
    ) -> [String: Any]? {
        let nested = tool["function"] as? [String: Any]
        let type = ((tool["type"] as? String) ?? (nested != nil ? "function" : nil))?.lowercased() ?? "function"
        if hostedToolTypes.contains(type) {
            var hosted: [String: Any] = ["type": type == "code_interpreter" ? "code_execution" : type]
            if let name = tool["name"] as? String { hosted["name"] = name }
            return hosted
        }

        let rawName = (tool["name"] as? String) ?? (nested?["name"] as? String)
        guard var name = rawName, !name.isEmpty else { return nil }
        name = toolNameForGrok(name, restore: restore)
        let isCustom = type == "custom"
        if isCustom {
            restore.customNames.insert(name)
        }

        let description: String?
        let parameters: [String: Any]
        if isCustom {
            description = bridgedCustomDescription(tool)
            parameters = customInputSchema
        } else {
            description = (tool["description"] as? String) ?? (nested?["description"] as? String)
            let rawParameters = tool["parameters"] ?? tool["input_schema"] ?? tool["inputSchema"]
                ?? nested?["parameters"] ?? nested?["input_schema"] ?? nested?["inputSchema"]
            parameters = objectRootToolSchema(objectParameters(rawParameters))
        }

        var functionTool: [String: Any] = [
            "type": "function",
            "name": name,
            "parameters": parameters,
            "strict": false,
        ]
        if let description, !description.isEmpty {
            functionTool["description"] = description
        }
        return functionTool
    }

    private static func bridgedCustomDescription(_ tool: [String: Any]) -> String? {
        var sections: [String] = []
        if let description = tool["description"] as? String {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sections.append(trimmed) }
        }
        if let format = tool["format"] as? [String: Any],
           let definition = format["definition"] as? String {
            let grammar = definition.trimmingCharacters(in: .whitespacesAndNewlines)
            if !grammar.isEmpty {
                let syntax = (format["syntax"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let label = (syntax?.isEmpty == false) ? syntax! : "grammar"
                sections.append(
                    "The `input` string is freeform text, not JSON, and must parse against this \(label) grammar:\n\n\(grammar)"
                )
            }
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    private static func objectParameters(_ raw: Any?) -> [String: Any] {
        guard let raw else { return emptyObjectSchema }
        if let schema = raw as? [String: Any] {
            if let wrapped = schema["jsonSchema"] as? [String: Any] {
                return objectParameters(wrapped)
            }
            let type = schema["type"] as? String
            if type == "object" || schema["properties"] != nil || schema["$defs"] != nil
                || schema["anyOf"] != nil || schema["oneOf"] != nil || schema["allOf"] != nil {
                var copy = schema
                if copy["type"] == nil { copy["type"] = "object" }
                if copy["properties"] == nil, copy["anyOf"] == nil, copy["oneOf"] == nil {
                    copy["properties"] = [String: Any]()
                }
                copy.removeValue(forKey: "format")
                return copy
            }
            return [
                "type": "object",
                "properties": ["value": schema],
            ]
        }
        return emptyObjectSchema
    }

    /// xAI rejects a union or nullable-object parameter root. Merge object
    /// branches so the whole request is not 400'd by one Codex app tool.
    private static func objectRootToolSchema(_ schema: [String: Any]) -> [String: Any] {
        let unionKeys = ["anyOf", "oneOf", "allOf"]
        let hasUnion = unionKeys.contains { schema[$0] is [Any] }
        if let types = schema["type"] as? [Any], types.contains(where: { ($0 as? String) == "object" }), !hasUnion {
            var copy = schema
            copy["type"] = "object"
            return copy
        }
        let isObject = (schema["type"] as? String) == "object"
            || (schema["type"] == nil && schema["properties"] != nil)
        if !hasUnion && isObject { return schema }

        var properties: [String: Any] = (schema["properties"] as? [String: Any]) ?? [:]
        var branchRequired: [[String]] = []
        for key in unionKeys {
            guard let branches = schema[key] as? [Any] else { continue }
            for branch in branches {
                guard let object = branch as? [String: Any] else { continue }
                if let extra = object["properties"] as? [String: Any] {
                    for (name, value) in extra where properties[name] == nil {
                        properties[name] = value
                    }
                }
                if let required = object["required"] as? [String] {
                    branchRequired.append(required)
                }
            }
        }
        var required = (schema["required"] as? [String]) ?? []
        if !branchRequired.isEmpty {
            var shared = Set(branchRequired[0])
            for next in branchRequired.dropFirst() {
                shared.formIntersection(next)
            }
            required = Array(Set(required).union(shared))
        }
        var merged: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": true,
        ]
        if let schemaURI = schema["$schema"] { merged["$schema"] = schemaURI }
        if let defs = schema["$defs"] { merged["$defs"] = defs }
        if let description = schema["description"] { merged["description"] = description }
        if !required.isEmpty { merged["required"] = required }
        return merged
    }

    private static func mergeHostedSearch(
        _ tools: [[String: Any]],
        restore: inout DesktopExternalToolRestore
    ) -> [[String: Any]] {
        restore.hostedSearchNames = ["web_search", "x_search"]
        let functions = tools.filter { tool in
            let type = tool["type"] as? String
            let name = tool["name"] as? String
            if type == "web_search" || type == "x_search" { return false }
            if name == "web_search" || name == "x_search" { return false }
            return true
        }
        var merged = functions
        let existingTypes = Set(functions.compactMap { $0["type"] as? String })
        for hosted in hostedSearchTools where !existingTypes.contains(hosted["type"] as? String ?? "") {
            merged.append(hosted)
        }
        return merged
    }

    private static func dedupeTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<String>()
        return tools.filter { tool in
            let key = (tool["type"] as? String ?? "") + "/" + (tool["name"] as? String ?? "")
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private static func unprefixedModel(_ model: String, providerID: String) -> String {
        let prefix = providerID + "/"
        if model.hasPrefix(prefix) {
            return String(model.dropFirst(prefix.count))
        }
        if let slash = model.lastIndex(of: "/") {
            return String(model[model.index(after: slash)...])
        }
        return model
    }

    /// xAI rejects a reasoning item with `"content": null` and mislabels it as a
    /// compaction-blob failure. The blob is intact; dropping only the null key
    /// is lossless. Keep arrays and `encrypted_content` untouched.
    private static func dropNullContentChannel(_ item: inout [String: Any]) {
        if item["content"] is NSNull {
            item.removeValue(forKey: "content")
        }
    }

    private static func dropIncompatibleFunctionID(_ item: inout [String: Any]) {
        if let id = item["id"] as? String, !id.hasPrefix("fc") {
            item.removeValue(forKey: "id")
        }
    }

    private static func toolNameForGrok(_ name: String, restore: DesktopExternalToolRestore) -> String {
        if restore.grokToCodexName["inspect_image"] == "view_image", name == "view_image" {
            return "inspect_image"
        }
        return name
    }

    private static func flattenToolChoice(
        _ choice: Any,
        restore: DesktopExternalToolRestore
    ) -> Any {
        guard var object = choice as? [String: Any] else { return choice }
        if object["type"] as? String == "custom" {
            object["type"] = "function"
        }
        if let nested = object["function"] as? [String: Any], let name = nested["name"] as? String {
            object.removeValue(forKey: "function")
            object["type"] = object["type"] ?? "function"
            object["name"] = toolNameForGrok(name, restore: restore)
        } else if let name = object["name"] as? String {
            object["name"] = toolNameForGrok(name, restore: restore)
        }
        if let tools = object["tools"] as? [Any] {
            object["tools"] = tools.map { flattenToolChoice($0, restore: restore) }
        }
        return object
    }

    private static func mappedEffort(_ effort: String) -> String {
        switch effort.lowercased() {
        case "extra", "ultra", "max": return "xhigh"
        default: return effort
        }
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum DesktopExternalResponseAdapter {
    static func restoreJSON(_ data: Data, restore: DesktopExternalToolRestore) -> Data {
        guard restore.needsResponseRewrite,
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return data
        }
        object = restoreObject(object, restore: restore)
        return (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? data
    }

    static func restoreObject(_ object: [String: Any], restore: DesktopExternalToolRestore) -> [String: Any] {
        var next = object
        if let item = next["item"] as? [String: Any] {
            if let restored = restoreItem(item, restore: restore) {
                next["item"] = restored
            } else {
                next["item"] = item
            }
        }
        if let items = next["output"] as? [[String: Any]] {
            next["output"] = items.compactMap { restoreItem($0, restore: restore) }
        }
        if var response = next["response"] as? [String: Any] {
            if let items = response["output"] as? [[String: Any]] {
                response["output"] = items.compactMap { restoreItem($0, restore: restore) }
            }
            next["response"] = response
        }
        if let name = next["name"] as? String {
            next["name"] = toolNameForCodex(name, restore: restore)
        }
        return restoreEventPayload(next, restore: restore)
    }

    static func restoreItem(_ item: [String: Any], restore: DesktopExternalToolRestore) -> [String: Any]? {
        var next = item
        var name = next["name"] as? String
        if let current = name {
            let mapped = toolNameForCodex(current, restore: restore)
            if mapped != current {
                next["name"] = mapped
                name = mapped
            }
        }
        if let wire = name, restore.hostedSearchNames.contains(wire),
           (next["type"] as? String) == "function_call" {
            return nil
        }
        if let wire = name, let pair = restore.namespaceByWireName[wire] {
            next["namespace"] = pair.namespace
            next["name"] = pair.name
            name = pair.name
        }
        let type = next["type"] as? String
        let isCustom = (name.map { restore.customNames.contains($0) } ?? false)
            || restore.customNames.contains(item["name"] as? String ?? "")
        if type == "function_call", isCustom {
            next["type"] = "custom_tool_call"
            if let arguments = next["arguments"] as? String {
                next["input"] = customInput(fromArguments: arguments)
            } else if next["input"] == nil {
                next["input"] = ""
            }
            next.removeValue(forKey: "arguments")
        }
        if type == "function_call_output", isCustom {
            next["type"] = "custom_tool_call_output"
        }
        return next
    }

    static func customInput(fromArguments arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return arguments
        }
        if let input = object["input"] as? String { return input }
        if let content = object["content"] as? String { return content }
        return arguments
    }

    static func toolNameForCodex(_ name: String, restore: DesktopExternalToolRestore) -> String {
        restore.grokToCodexName[name] ?? name
    }

    private static func restoreEventPayload(
        _ object: [String: Any],
        restore: DesktopExternalToolRestore
    ) -> [String: Any] {
        var next = object
        let type = next["type"] as? String
        if type == "response.function_call_arguments.done" {
            let itemID = next["item_id"] as? String
            let name = trackedCustomName(itemID: itemID, object: next, restore: restore)
            if name != nil || isCustomItem(next, restore: restore) {
                if let arguments = next["arguments"] as? String {
                    next["type"] = "response.custom_tool_call_input.done"
                    next["input"] = customInput(fromArguments: arguments)
                    next.removeValue(forKey: "arguments")
                }
            }
        }
        return next
    }

    private static func isCustomItem(_ object: [String: Any], restore: DesktopExternalToolRestore) -> Bool {
        if let name = object["name"] as? String {
            let mapped = toolNameForCodex(name, restore: restore)
            return restore.customNames.contains(name) || restore.customNames.contains(mapped)
        }
        return false
    }

    private static func trackedCustomName(
        itemID: String?,
        object: [String: Any],
        restore: DesktopExternalToolRestore
    ) -> String? {
        if let name = object["name"] as? String, restore.customNames.contains(name) { return name }
        _ = itemID
        return nil
    }
}

final class DesktopExternalSSERestorer {
    private var buffer = Data()
    private let restore: DesktopExternalToolRestore
    private var customItemIDs: Set<String> = []
    private var argumentBuffers: [String: String] = [:]

    init(restore: DesktopExternalToolRestore) {
        self.restore = restore
    }

    func append(_ data: Data) -> Data {
        guard restore.needsResponseRewrite else { return data }
        buffer.append(data)
        var output = Data()
        while let range = nextEventRange() {
            let raw = buffer.subdata(in: range)
            buffer.removeSubrange(range)
            if let rewritten = rewriteEvent(raw) {
                output.append(rewritten)
            }
        }
        return output
    }

    func flush() -> Data {
        guard restore.needsResponseRewrite, !buffer.isEmpty else {
            let leftover = buffer
            buffer.removeAll()
            return leftover
        }
        let leftover = buffer
        buffer.removeAll()
        return rewriteEvent(leftover) ?? leftover
    }

    private func nextEventRange() -> Range<Int>? {
        if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
            return 0..<(range.upperBound)
        }
        if let range = buffer.range(of: Data("\n\n".utf8)) {
            return 0..<(range.upperBound)
        }
        return nil
    }

    private func rewriteEvent(_ raw: Data) -> Data? {
        guard let text = String(data: raw, encoding: .utf8) else { return raw }
        var eventName: String?
        var dataLines: [String] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                dataLines.append(value)
            }
        }
        guard !dataLines.isEmpty else { return raw }
        let payloadText = dataLines.joined(separator: "\n")
        guard let payloadData = payloadText.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return raw
        }

        let type = (object["type"] as? String) ?? eventName
        if let item = object["item"] as? [String: Any] {
            rememberCustomItem(item)
            if let restored = DesktopExternalResponseAdapter.restoreItem(item, restore: restore) {
                object["item"] = restored
            } else if shouldDrop(item) {
                return nil
            }
        }
        if type == "response.function_call_arguments.delta" {
            let itemID = object["item_id"] as? String
            if let itemID, customItemIDs.contains(itemID) {
                if let delta = object["delta"] as? String {
                    argumentBuffers[itemID, default: ""] += delta
                }
                return nil
            }
        }
        if type == "response.function_call_arguments.done" {
            let itemID = object["item_id"] as? String
            if let itemID, customItemIDs.contains(itemID) {
                let arguments = (object["arguments"] as? String)
                    ?? argumentBuffers[itemID]
                    ?? ""
                argumentBuffers.removeValue(forKey: itemID)
                object["type"] = "response.custom_tool_call_input.done"
                object["input"] = DesktopExternalResponseAdapter.customInput(fromArguments: arguments)
                object.removeValue(forKey: "arguments")
                eventName = "response.custom_tool_call_input.done"
            }
        }

        object = DesktopExternalResponseAdapter.restoreObject(object, restore: restore)
        if let restoredType = object["type"] as? String {
            eventName = restoredType
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: []),
              let json = String(data: encoded, encoding: .utf8) else {
            return raw
        }
        var frame = ""
        if let eventName {
            frame += "event: \(eventName)\n"
        }
        frame += "data: \(json)\n\n"
        return Data(frame.utf8)
    }

    private func rememberCustomItem(_ item: [String: Any]) {
        let rawName = item["name"] as? String
        let name = rawName.map { DesktopExternalResponseAdapter.toolNameForCodex($0, restore: restore) }
        let isCustom = name.map { restore.customNames.contains($0) } == true
            || rawName.map { restore.customNames.contains($0) } == true
        if isCustom, let id = item["id"] as? String {
            customItemIDs.insert(id)
        }
    }

    private func shouldDrop(_ item: [String: Any]) -> Bool {
        let name = item["name"] as? String
        return name.map { restore.hostedSearchNames.contains($0) } == true
            && (item["type"] as? String) == "function_call"
    }
}
