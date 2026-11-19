using System.Text.Json;
using System.Text.Json.Nodes;

namespace Veo.Infrastructure.Providers;

public sealed record ToolIdentity(string Name, string? Namespace, bool Custom);
public sealed class ToolRestore
{
    public Dictionary<string, ToolIdentity> Tools { get; } = new(StringComparer.Ordinal);
    public HashSet<string> HostedTools { get; } = new(StringComparer.Ordinal);
}
public sealed record AdaptedProviderRequest(JsonObject Body, ToolRestore Restore);

/// <summary>Convert Responses input without changing model IDs or losing custom-tool/namespace identity.</summary>
public static class ExternalRequestAdapter
{
    public static AdaptedProviderRequest Adapt(JsonElement request, ExternalProvider provider)
    {
        if (request.ValueKind != JsonValueKind.Object) throw new ArgumentException("A provider request must be a JSON object.");
        var body = JsonNode.Parse(request.GetRawText())!.AsObject(); var restore = new ToolRestore();
        var model = String(body["model"]) ?? throw new InvalidDataException("Choose a discovered model before sending a request.");
        if (model.StartsWith(provider.Id + "/", StringComparison.Ordinal)) model = model[(provider.Id.Length + 1)..];
        body["model"] = model; // Preserve upstream vendor/model paths, especially OpenRouter.
        var declared = new List<JsonObject>();
        if (body["tools"] is JsonArray tools) declared.AddRange(tools.OfType<JsonObject>());
        if (body["input"] is JsonArray input)
            foreach (var item in input.OfType<JsonObject>().Where(item => String(item["type"]) == "additional_tools"))
                if (item["tools"] is JsonArray extras) declared.AddRange(extras.OfType<JsonObject>());
        var wireTools = new JsonArray();
        foreach (var tool in declared)
        {
            if (String(tool["type"]) == "tool_search") continue;
            if (String(tool["type"]) == "namespace" && tool["tools"] is JsonArray children)
            {
                var ns = String(tool["name"]) ?? throw new InvalidDataException("A tool namespace needs a name.");
                foreach (var child in children.OfType<JsonObject>()) AddTool(child, ns, wireTools, restore);
            }
            else AddTool(tool, null, wireTools, restore);
        }
        if (wireTools.Count > 0) body["tools"] = wireTools;
        else { body.Remove("tools"); body.Remove("tool_choice"); body.Remove("parallel_tool_calls"); }
        if (body["reasoning"] is JsonObject reasoning && String(reasoning["effort"]) is { } effort) reasoning["effort"] = Effort(effort);
        if (body["tool_choice"] is JsonObject choice)
        {
            var name = String(choice["name"]) ?? String(choice["function"]?["name"]);
            var ns = String(choice["namespace"]);
            if (name is not null) body["tool_choice"] = new JsonObject { ["type"] = "function", ["name"] = ns is null ? name : ns + "__" + name };
        }
        if (String(body["reasoning_effort"]) is { } directEffort) body["reasoning_effort"] = Effort(directEffort);
        if (body["input"] is JsonArray items)
        {
            var sanitized = new JsonArray();
            foreach (var node in items.OfType<JsonObject>())
            {
                var item = node.DeepClone().AsObject(); var type = String(item["type"]);
                if (type is "additional_tools" or "tool_search") continue;
                if (String(item["role"]) == "developer") item["role"] = "system";
                if (type == "custom_tool_call")
                {
                    item["type"] = "function_call"; item["arguments"] = new JsonObject { ["input"] = String(item["input"]) ?? "" }.ToJsonString(); item.Remove("input");
                }
                if (type == "custom_tool_call_output") item["type"] = "function_call_output";
                if (type == "agent_message") { item["type"] = "message"; item["role"] = "user"; }
                if (String(item["namespace"]) is { } ns && String(item["name"]) is { } name)
                { item["name"] = ns + "__" + name; item.Remove("namespace"); }
                if (String(item["type"]) is "function_call" or "function_call_output" && String(item["id"]) is { } id && !id.StartsWith("fc", StringComparison.Ordinal)) item.Remove("id");
                if (item.ContainsKey("content") && item["content"] is null) item.Remove("content");
                sanitized.Add(item);
            }
            body["input"] = sanitized;
        }
        if (provider.WireApi == ProviderWireApi.Chat) body = ToChat(body);
        return new(body, restore);
    }

    private static void AddTool(JsonObject tool, string? ns, JsonArray output, ToolRestore restore)
    {
        var nested = tool["function"] as JsonObject;
        var type = String(tool["type"]) ?? "function";
        if (type is "web_search" or "x_search" or "code_execution" or "code_interpreter" or "file_search" or "mcp")
        {
            if (!restore.HostedTools.Add(type)) return;
            output.Add(new JsonObject { ["type"] = type == "code_interpreter" ? "code_execution" : type }); return;
        }
        var name = String(tool["name"]) ?? String(nested?["name"]) ?? throw new InvalidDataException("A declared tool needs a name.");
        var wireName = ns is null ? name : ns + "__" + name;
        if (!restore.Tools.TryAdd(wireName, new(name, ns, type == "custom")))
            throw new InvalidDataException("Tool names collide after provider adaptation.");
        var description = String(tool["description"]) ?? String(nested?["description"]);
        JsonObject schema;
        if (type == "custom")
        {
            schema = JsonNode.Parse("""{"type":"object","properties":{"input":{"type":"string","description":"The complete raw freeform tool input, preserved verbatim."}},"required":["input"],"additionalProperties":false}""")!.AsObject();
            if (tool["format"] is JsonObject format && String(format["definition"]) is { } grammar)
                description = (description is null ? "" : description + "\n\n") + "The input string is freeform text and must follow this grammar:\n\n" + grammar;
        }
        else schema = ObjectSchema(tool["parameters"] ?? tool["input_schema"] ?? tool["inputSchema"] ?? nested?["parameters"]);
        var declared = new JsonObject { ["type"] = "function", ["name"] = wireName, ["parameters"] = schema, ["strict"] = false };
        if (description is not null) declared["description"] = description;
        output.Add(declared);
    }

    private static JsonObject ObjectSchema(JsonNode? raw)
    {
        if (raw is JsonObject wrapper && wrapper["jsonSchema"] is { } wrapped) return ObjectSchema(wrapped);
        if (raw is not JsonObject original) return new() { ["type"] = "object", ["properties"] = new JsonObject() };
        var schema = original.DeepClone().AsObject(); schema.Remove("format");
        var unions = new[] { "anyOf", "oneOf", "allOf" }.Where(key => schema[key] is JsonArray).ToArray();
        if (unions.Length > 0)
        {
            var properties = schema["properties"]?.DeepClone() as JsonObject ?? new();
            HashSet<string>? shared = null;
            foreach (var key in unions)
                foreach (var branch in schema[key]!.AsArray().OfType<JsonObject>())
                {
                    if (branch["properties"] is JsonObject extra)
                        foreach (var pair in extra) if (!properties.ContainsKey(pair.Key)) properties[pair.Key] = pair.Value?.DeepClone();
                    var required = branch["required"] is JsonArray fields ? fields.Select(String).Where(v => v is not null).Cast<string>().ToHashSet(StringComparer.Ordinal) : [];
                    if (shared is null) shared = required; else shared.IntersectWith(required);
                }
            if (schema["required"] is JsonArray rootRequired) (shared ??= []).UnionWith(rootRequired.Select(String).Where(v => v is not null).Cast<string>());
            var merged = new JsonObject { ["type"] = "object", ["properties"] = properties, ["additionalProperties"] = true };
            foreach (var key in new[] { "$schema", "$defs", "description" }) if (schema[key] is { } node) merged[key] = node.DeepClone();
            if (shared?.Count > 0) merged["required"] = new JsonArray(shared.Order(StringComparer.Ordinal).Select(v => JsonValue.Create(v) as JsonNode).ToArray());
            return merged;
        }
        if (schema["type"] is JsonArray types && types.Any(node => String(node) == "object")) schema["type"] = "object";
        if (String(schema["type"]) is null || String(schema["type"]) == "object")
        { schema["type"] = "object"; schema["properties"] ??= new JsonObject(); return schema; }
        return new() { ["type"] = "object", ["properties"] = new JsonObject { ["value"] = schema } };
    }

    private static JsonObject ToChat(JsonObject responses)
    {
        var chat = new JsonObject { ["model"] = responses["model"]!.DeepClone(), ["stream"] = true };
        var messages = new JsonArray();
        if (String(responses["instructions"]) is { } instructions) messages.Add(new JsonObject { ["role"] = "system", ["content"] = instructions });
        if (responses["input"] is JsonValue scalar && scalar.TryGetValue<string>(out var prompt)) messages.Add(new JsonObject { ["role"] = "user", ["content"] = prompt });
        if (responses["input"] is JsonArray input)
        {
            foreach (var item in input.OfType<JsonObject>())
            {
                var type = String(item["type"]) ?? "message";
                if (type == "message") messages.Add(new JsonObject { ["role"] = String(item["role"]) ?? "user", ["content"] = ChatContent(item["content"]) });
                else if (type == "function_call")
                    messages.Add(new JsonObject { ["role"] = "assistant", ["content"] = null, ["tool_calls"] = new JsonArray(new JsonObject { ["id"] = String(item["call_id"]), ["type"] = "function", ["function"] = new JsonObject { ["name"] = String(item["name"]), ["arguments"] = String(item["arguments"]) ?? "{}" } }) });
                else if (type == "function_call_output") messages.Add(new JsonObject { ["role"] = "tool", ["tool_call_id"] = String(item["call_id"]), ["content"] = item["output"] is JsonValue value && value.TryGetValue<string>(out var output) ? JsonValue.Create(output) : item["output"]?.ToJsonString() });
                else if (type == "reasoning")
                {
                    if (item["encrypted_content"] is not null) throw new NotSupportedException("Encrypted Responses reasoning cannot be sent to a Chat Completions provider.");
                    var thinking = item["summary"] is JsonArray summaries ? string.Concat(summaries.OfType<JsonObject>().Select(row => String(row["text"]))) : String(item["content"]) ?? "";
                    messages.Add(new JsonObject { ["role"] = "assistant", ["content"] = "", ["reasoning_content"] = thinking });
                }
                else throw new NotSupportedException("This Responses item cannot be represented by the selected Chat Completions provider: " + type);
            }
        }
        chat["messages"] = messages;
        if (responses["tools"] is JsonArray tools)
        {
            var converted = new JsonArray();
            foreach (var tool in tools.OfType<JsonObject>())
            {
                if (String(tool["type"]) != "function") throw new NotSupportedException("Hosted Responses tools are unavailable through Chat Completions.");
                var function = tool.DeepClone().AsObject(); function.Remove("type"); converted.Add(new JsonObject { ["type"] = "function", ["function"] = function });
            }
            chat["tools"] = converted;
        }
        foreach (var key in new[] { "temperature", "top_p", "parallel_tool_calls", "reasoning_effort" }) if (responses[key] is { } node) chat[key] = node.DeepClone();
        if (responses["tool_choice"] is JsonValue choiceValue) chat["tool_choice"] = choiceValue.DeepClone();
        else if (responses["tool_choice"] is JsonObject choice && String(choice["type"]) == "function")
            chat["tool_choice"] = new JsonObject { ["type"] = "function", ["function"] = new JsonObject { ["name"] = String(choice["name"]) } };
        else if (responses["tool_choice"] is not null) throw new NotSupportedException("This tool-choice policy cannot be represented by Chat Completions.");
        if (responses["reasoning"] is JsonObject reasoning && reasoning["effort"] is { } effort) chat["reasoning_effort"] = effort.DeepClone();
        if (responses["max_output_tokens"] is { } maximum) chat["max_completion_tokens"] = maximum.DeepClone();
        return chat;
    }
    private static JsonNode? ChatContent(JsonNode? content)
    {
        if (content is not JsonArray parts) return content?.DeepClone();
        var result = new JsonArray();
        foreach (var part in parts.OfType<JsonObject>())
        {
            var type = String(part["type"]);
            if (type is "input_text" or "output_text" or "text") result.Add(new JsonObject { ["type"] = "text", ["text"] = String(part["text"]) ?? "" });
            else if (type == "input_image") result.Add(new JsonObject { ["type"] = "image_url", ["image_url"] = new JsonObject { ["url"] = String(part["image_url"]) } });
            else throw new NotSupportedException("This content part is unavailable through Chat Completions: " + type);
        }
        return result;
    }
    public static string? String(JsonNode? value) => value is JsonValue scalar && scalar.TryGetValue<string>(out var text) ? text : null;
    private static string Effort(string effort) => effort is "extra" or "ultra" or "max" ? "xhigh" : effort;
}
