using System.Text.Json.Nodes;

namespace Veo.Infrastructure.Providers;

/// <summary>Per-request identity restoration; state is never shared between providers or conversations.</summary>
public sealed class ExternalResponseAdapter(ToolRestore restore)
{
    private readonly Dictionary<string, ToolIdentity> customItems = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> argumentBuffers = new(StringComparer.Ordinal);
    private static string? Text(JsonNode? value) => ExternalRequestAdapter.String(value);

    public JsonObject? RestoreEvent(JsonObject source)
    {
        var value = source.DeepClone().AsObject(); var type = Text(value["type"]);
        if (value["item"] is JsonObject item)
        {
            var name = Text(item["name"]); var id = Text(item["id"]);
            if (id is not null && name is not null && restore.Tools.TryGetValue(name, out var identity) && identity.Custom) customItems[id] = identity;
            var restored = RestoreItem(item); if (restored is null) return null; value["item"] = restored;
        }
        var itemId = Text(value["item_id"]);
        if (type == "response.function_call_arguments.delta" && itemId is not null && customItems.ContainsKey(itemId))
        {
            argumentBuffers[itemId] = argumentBuffers.GetValueOrDefault(itemId, "") + (Text(value["delta"]) ?? "");
            return null; // JSON wrapper fragments are not freeform tool text.
        }
        if (type == "response.function_call_arguments.done" && itemId is not null && customItems.ContainsKey(itemId))
        {
            var arguments = Text(value["arguments"]) ?? argumentBuffers.GetValueOrDefault(itemId, "");
            value["type"] = "response.custom_tool_call_input.done"; value["input"] = CustomInput(arguments);
            value.Remove("arguments"); argumentBuffers.Remove(itemId);
        }
        if (value["output"] is JsonArray output) value["output"] = RestoreOutput(output);
        if (value["response"] is JsonObject response && response["output"] is JsonArray responseOutput) response["output"] = RestoreOutput(responseOutput);
        return value;
    }
    public JsonObject? RestoreItem(JsonObject source)
    {
        var item = source.DeepClone().AsObject(); var name = Text(item["name"]);
        if (name is not null && restore.HostedTools.Contains(name) && Text(item["type"]) == "function_call" && !restore.Tools.ContainsKey(name)) return null;
        if (name is not null && restore.Tools.TryGetValue(name, out var identity))
        {
            item["name"] = identity.Name;
            if (identity.Namespace is not null) item["namespace"] = identity.Namespace;
            if (identity.Custom && Text(item["type"]) == "function_call")
            {
                item["type"] = "custom_tool_call"; item["input"] = CustomInput(Text(item["arguments"]) ?? ""); item.Remove("arguments");
            }
            else if (identity.Custom && Text(item["type"]) == "function_call_output") item["type"] = "custom_tool_call_output";
        }
        return item;
    }
    private JsonArray RestoreOutput(JsonArray items)
    {
        var result = new JsonArray();
        foreach (var item in items.OfType<JsonObject>()) if (RestoreItem(item) is { } restored) result.Add(restored);
        return result;
    }
    public static string CustomInput(string arguments)
    {
        try
        {
            var value = JsonNode.Parse(arguments) as JsonObject;
            return Text(value?["input"]) ?? Text(value?["content"]) ?? arguments;
        }
        catch (System.Text.Json.JsonException) { return arguments; }
    }
}

/// <summary>Chat Completions chunks become item-scoped Responses events, retaining reasoning and tool IDs.</summary>
public sealed class ChatStreamAdapter
{
    private sealed class Output(string id, string type, int index)
    {
        public string Id { get; } = id;
        public string Type { get; } = type;
        public int Index { get; } = index;
        public string Text { get; set; } = "";
        public string Name { get; set; } = "";
        public string? CallId { get; set; }
        public bool Added { get; set; }
    }
    private readonly Dictionary<string, Output> outputs = new(StringComparer.Ordinal);
    private readonly ExternalResponseAdapter restorer;
    private string? responseId;
    private JsonNode? usage;
    private bool finished;
    private bool completed;
    public ChatStreamAdapter(ToolRestore restore) => restorer = new(restore);
    private static string? Text(JsonNode? node) => ExternalRequestAdapter.String(node);
    public IReadOnlyList<JsonObject> Append(JsonObject chunk)
    {
        if (completed) throw new InvalidDataException("The provider streamed data after completion.");
        var events = new List<JsonObject>();
        if (responseId is null)
        {
            responseId = Text(chunk["id"]) ?? throw new InvalidDataException("The provider omitted the response identity.");
            events.Add(new() { ["type"] = "response.created", ["response"] = new JsonObject { ["id"] = responseId, ["status"] = "in_progress", ["output"] = new JsonArray() } });
        }
        if (chunk["usage"] is JsonObject u)
            usage = new JsonObject { ["input_tokens"] = u["prompt_tokens"]?.DeepClone(), ["output_tokens"] = u["completion_tokens"]?.DeepClone(),
                ["total_tokens"] = u["total_tokens"]?.DeepClone(), ["input_tokens_details"] = u["prompt_tokens_details"]?.DeepClone(), ["output_tokens_details"] = u["completion_tokens_details"]?.DeepClone() };
        if (chunk["choices"] is not JsonArray choices) return events;
        foreach (var choice in choices.OfType<JsonObject>())
        {
            var choiceIndex = choice["index"]?.GetValue<int>() ?? 0;
            if (choice["finish_reason"] is not null) finished = true;
            if (choice["delta"] is not JsonObject delta) continue;
            foreach (var (key, type, eventType) in new[] { ("content", "message", "response.output_text.delta"), ("reasoning_content", "reasoning", "response.reasoning_summary_text.delta") })
            {
                if (Text(delta[key]) is not { Length: > 0 } content) continue;
                var output = GetOutput(type + choiceIndex, type);
                Add(output, events); output.Text += content;
                events.Add(new() { ["type"] = eventType, ["item_id"] = output.Id, ["output_index"] = output.Index, ["content_index"] = 0, ["summary_index"] = 0, ["delta"] = content });
            }
            if (delta["tool_calls"] is JsonArray calls)
                foreach (var call in calls.OfType<JsonObject>())
                {
                    var toolIndex = call["index"]?.GetValue<int>() ?? 0;
                    var output = GetOutput("tool" + choiceIndex + ":" + toolIndex, "function_call");
                    output.CallId ??= Text(call["id"]);
                    if (call["function"] is JsonObject function)
                    {
                        if (Text(function["name"]) is { } name) output.Name += name;
                        if (output.CallId is not null && output.Name.Length > 0) Add(output, events);
                        if (Text(function["arguments"]) is { } arguments)
                        {
                            output.Text += arguments;
                            if (output.Added) events.Add(new() { ["type"] = "response.function_call_arguments.delta", ["item_id"] = output.Id, ["output_index"] = output.Index, ["delta"] = arguments });
                        }
                    }
                }
        }
        return Rewrite(events);
    }
    public IReadOnlyList<JsonObject> Complete()
    {
        if (completed) return [];
        if (!finished || responseId is null) throw new InvalidDataException("The provider stream ended before a completed response was reported.");
        completed = true; var events = new List<JsonObject>(); var final = new JsonArray();
        foreach (var output in outputs.Values.OrderBy(item => item.Index))
        {
            if (output.Type == "function_call" && (output.CallId is null || output.Name.Length == 0)) throw new InvalidDataException("The provider omitted a tool-call identity.");
            Add(output, events);
            if (output.Type == "function_call") events.Add(new() { ["type"] = "response.function_call_arguments.done", ["item_id"] = output.Id, ["output_index"] = output.Index, ["arguments"] = output.Text });
            else events.Add(new() { ["type"] = output.Type == "message" ? "response.output_text.done" : "response.reasoning_summary_text.done", ["item_id"] = output.Id, ["output_index"] = output.Index, ["text"] = output.Text });
            var item = Item(output, true); events.Add(new() { ["type"] = "response.output_item.done", ["output_index"] = output.Index, ["item"] = item.DeepClone() }); final.Add(item);
        }
        events.Add(new() { ["type"] = "response.completed", ["response"] = new JsonObject { ["id"] = responseId, ["status"] = "completed", ["output"] = final, ["usage"] = usage?.DeepClone() } });
        return Rewrite(events);
    }
    private Output GetOutput(string key, string type)
    {
        if (!outputs.TryGetValue(key, out var output)) outputs[key] = output = new("veo_" + responseId + "_" + outputs.Count, type, outputs.Count);
        return output;
    }
    private static JsonObject Item(Output output, bool done) => output.Type switch
    {
        "message" => new() { ["id"] = output.Id, ["type"] = "message", ["role"] = "assistant", ["status"] = done ? "completed" : "in_progress", ["content"] = done ? new JsonArray(new JsonObject { ["type"] = "output_text", ["text"] = output.Text, ["annotations"] = new JsonArray() }) : new JsonArray() },
        "reasoning" => new() { ["id"] = output.Id, ["type"] = "reasoning", ["summary"] = done ? new JsonArray(new JsonObject { ["type"] = "summary_text", ["text"] = output.Text }) : new JsonArray() },
        _ => new() { ["id"] = output.Id, ["type"] = "function_call", ["name"] = output.Name, ["call_id"] = output.CallId, ["arguments"] = done ? output.Text : "", ["status"] = done ? "completed" : "in_progress" }
    };
    private static void Add(Output output, List<JsonObject> events)
    {
        if (output.Added) return; output.Added = true;
        events.Add(new() { ["type"] = "response.output_item.added", ["output_index"] = output.Index, ["item"] = Item(output, false) });
    }
    private IReadOnlyList<JsonObject> Rewrite(IEnumerable<JsonObject> events) => events.Select(restorer.RestoreEvent).Where(value => value is not null).Cast<JsonObject>().ToArray();
}
