// FILE: DesktopExternalRequestAdapter.swift
// Purpose: Rewrites Codex Responses requests into the subset Grok/xAI accept.
// Layer: Desktop app service

import Foundation

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
    ]

    private static let hostedToolTypes: Set<String> = [
        "web_search",
        "x_search",
        "code_execution",
        "code_interpreter",
        "file_search",
        "mcp",
    ]

    private static let emptyObjectSchema: [String: Any] = [
        "type": "object",
        "properties": [String: Any](),
    ]

    static func sanitize(body: Data, path: String, providerID: String) -> Data {
        guard path.hasSuffix("/responses") || path.hasSuffix("/chat/completions"),
              var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return body
        }
        if let model = object["model"] as? String {
            object["model"] = unprefixedModel(model, providerID: providerID)
        }
        if path.hasSuffix("/responses") {
            object = sanitizeResponses(object)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return body
        }
        return data
    }

    private static func sanitizeResponses(_ object: [String: Any]) -> [String: Any] {
        var next = object
        var collectedTools = next["tools"] as? [[String: Any]] ?? []
        if let items = next["input"] as? [[String: Any]] {
            for item in items where (item["type"] as? String) == "additional_tools" {
                if let extra = item["tools"] as? [[String: Any]] {
                    collectedTools.append(contentsOf: extra)
                }
            }
            next["input"] = items.compactMap(sanitizeInputItem)
        }
        let tools = collectedTools.compactMap(sanitizeTool)
        if tools.isEmpty {
            next.removeValue(forKey: "tools")
            next.removeValue(forKey: "tool_choice")
            next.removeValue(forKey: "parallel_tool_calls")
        } else {
            next["tools"] = tools
            if let choice = next["tool_choice"] {
                next["tool_choice"] = flattenToolChoice(choice)
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

    private static func sanitizeInputItem(_ item: [String: Any]) -> [String: Any]? {
        var next = item
        if let role = next["role"] as? String, role == "developer" {
            next["role"] = "system"
        }
        if let type = next["type"] as? String {
            switch type {
            case "additional_tools":
                return nil
            case "custom_tool_call":
                next["type"] = "function_call"
                if next["arguments"] == nil { next["arguments"] = "{}" }
                return next
            case "custom_tool_call_output":
                next["type"] = "function_call_output"
                return next
            default:
                guard allowedInputTypes.contains(type) else { return nil }
                return next
            }
        }
        if next["role"] != nil { return next }
        return nil
    }

    private static func sanitizeTool(_ tool: [String: Any]) -> [String: Any]? {
        let nested = tool["function"] as? [String: Any]
        let type = ((tool["type"] as? String) ?? (nested != nil ? "function" : nil))?.lowercased() ?? "function"
        if hostedToolTypes.contains(type) {
            var hosted: [String: Any] = ["type": type == "code_interpreter" ? "code_execution" : type]
            if let name = tool["name"] as? String { hosted["name"] = name }
            return hosted
        }

        let name = (tool["name"] as? String) ?? (nested?["name"] as? String)
        guard let name, !name.isEmpty else { return nil }
        let description = (tool["description"] as? String) ?? (nested?["description"] as? String)
        let rawParameters = tool["parameters"] ?? tool["input_schema"] ?? tool["inputSchema"]
            ?? nested?["parameters"] ?? nested?["input_schema"] ?? nested?["inputSchema"]
        var functionTool: [String: Any] = [
            "type": "function",
            "name": name,
            "parameters": objectParameters(rawParameters),
            "strict": false,
        ]
        if let description, !description.isEmpty {
            functionTool["description"] = description
        }
        return functionTool
    }

    private static func objectParameters(_ raw: Any?) -> [String: Any] {
        guard let raw else { return emptyObjectSchema }
        if let schema = raw as? [String: Any] {
            if let wrapped = schema["jsonSchema"] as? [String: Any] {
                return objectParameters(wrapped)
            }
            let type = schema["type"] as? String
            if type == "object" || schema["properties"] != nil || schema["$defs"] != nil {
                var copy = schema
                if copy["type"] == nil { copy["type"] = "object" }
                if copy["properties"] == nil { copy["properties"] = [String: Any]() }
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

    private static func flattenToolChoice(_ choice: Any) -> Any {
        guard var object = choice as? [String: Any] else { return choice }
        if let nested = object["function"] as? [String: Any], let name = nested["name"] as? String {
            object.removeValue(forKey: "function")
            object["type"] = object["type"] ?? "function"
            object["name"] = name
        }
        return object
    }

    private static func mappedEffort(_ effort: String) -> String {
        switch effort.lowercased() {
        case "extra", "ultra", "max": return "xhigh"
        default: return effort
        }
    }
}
