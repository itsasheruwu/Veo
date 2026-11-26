using System.Text.Json;
using System.Text.RegularExpressions;

namespace Veo.Core;

public sealed record TimelineDisplayEntry(string Id, string Kind, TimelineItem[] Items);
public sealed record ConversationTopic(string Id, string TargetItemId, string[] ItemIds, string Prompt, string AssistantPreview, int ContentLength, int SourceTurnCount, string[] Keywords);
public sealed record ConversationSource(string Id, string Label, string Target, int? StartLine = null, int? EndLine = null, string? Note = null);
public sealed record ConversationArtifact(string Id, string Kind, string Source, string Name, string? MimeType = null, string? UnavailableReason = null);
public sealed record ConversationAgent(string ThreadId, string Name, string Status, string? Message, string? Model = null);
public sealed record TimelineItemPresentation(string Title, string Body, ConversationArtifact[] Artifacts, ConversationSource[] Sources, ConversationAgent[] Agents, bool IsActivity);

/// <summary>Presentation derives from immutable item snapshots. Grouping never mutates the timeline or replaces item identities.</summary>
public static partial class TimelinePresentation
{
    static readonly HashSet<string> ActivityKinds = new(["reasoning", "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "subAgentActivity", "webSearch", "sleep", "enteredReviewMode", "contextCompaction", "planUpdate"], StringComparer.Ordinal);
    public static bool IsActivity(string kind) => ActivityKinds.Contains(kind);
    public static IReadOnlyList<TimelineDisplayEntry> Entries(IEnumerable<TimelineItem> source, bool groupActivity)
    {
        var result = new List<TimelineDisplayEntry>(); var group = new List<TimelineItem>();
        void Flush() { if (group.Count == 0) return; result.Add(new("activity:" + group[0].Id, "activity", group.ToArray())); group.Clear(); }
        foreach (var item in source.OrderBy(x => x.Order))
        {
            if (groupActivity && IsActivity(item.Kind)) { if (group.Count > 0 && group[^1].TurnId != item.TurnId) Flush(); group.Add(item); }
            else { Flush(); result.Add(new(item.Id, item.Kind, [item])); }
        }
        Flush(); return result;
    }
    public static TimelineItemPresentation Item(TimelineItem item)
    {
        var raw = item.Raw; var artifacts = new List<ConversationArtifact>(); var sources = new List<ConversationSource>(); var agents = new List<ConversationAgent>();
        var title = item.Kind switch { "userMessage" => "You", "agentMessage" => raw.Str("veoProviderName") ?? "Codex", "reasoning" => "Thinking", "commandExecution" => raw.Str("command") ?? "Command", "fileChange" => "Changed files", "mcpToolCall" => (raw.Str("server") ?? "MCP") + " · " + (raw.Str("tool") ?? "Tool"), "dynamicToolCall" => raw.Str("tool") ?? "Tool", "webSearch" => "Web search", "imageView" => "Viewed image", "imageGeneration" => "Generated image", "collabAgentToolCall" => "Subagents · " + raw.Str("tool"), "subAgentActivity" => "Subagent " + raw.Str("kind"), "sleep" => "Waiting", "contextCompaction" => "Compacting context", _ => item.Kind };
        var body = item.Text;
        if (item.Kind == "fileChange") body = string.Join("\n", IntegrationCoordinator.Rows(raw, "changes").Select(x => x.Str("path") ?? x.Str("filePath") ?? "Unknown path"));
        if (item.Kind == "imageView" && raw.Str("path") is { } viewed) artifacts.Add(new(item.Id + ":image", "localImage", viewed, Path.GetFileName(viewed)));
        if (item.Kind == "imageGeneration")
        {
            if (raw.Str("savedPath") is { } saved) artifacts.Add(new(item.Id + ":generated", "localImage", saved, "Generated image"));
            else if (raw.Str("result") is { Length: > 0 } generated) artifacts.Add(new(item.Id + ":generated", generated.StartsWith("data:", StringComparison.OrdinalIgnoreCase) ? "dataImage" : "inlineImage", generated, "Generated image", "image/png"));
            else if (raw.Str("fileId") is { } fileId) artifacts.Add(new(item.Id + ":generated", "storedFile", fileId, "Generated image", null, "Codex supplied a stored file identity without inline bytes or a saved path. This schema does not expose a verified file-content read method."));
            if (raw.TryObjectProperty("failure", out var failure)) body = failure.Str("message") ?? "Image generation failed.";
        }
        if (item.Kind == "userMessage") AddContent(IntegrationCoordinator.Rows(raw, "content"), item.Id, artifacts);
        if (raw.TryObjectProperty("result", out var result)) AddContent(IntegrationCoordinator.Rows(result, "content"), item.Id + ":result", artifacts);
        AddContent(IntegrationCoordinator.Rows(raw, "contentItems"), item.Id + ":content", artifacts);
        if (item.Kind == "collabAgentToolCall")
        {
            var states = raw.TryObjectProperty("agentsStates", out var values) ? values : default;
            var receivers = raw.TryGetProperty("receiverThreadIds", out var ids) && ids.ValueKind == JsonValueKind.Array ? ids.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray() : [];
            foreach (var id in receivers.Concat(states.ValueKind == JsonValueKind.Object ? states.EnumerateObject().Select(x => x.Name) : []).Distinct(StringComparer.Ordinal))
            {
                var state = states.ValueKind == JsonValueKind.Object && states.TryGetProperty(id, out var s) ? s : default;
                agents.Add(new(id, state.Str("agentNickname") ?? state.Str("nickname") ?? id, state.Str("status") ?? item.Status, state.Str("message"), raw.Str("model")));
            }
            body = agents.Count == 0 ? "Subagent activity" : string.Join(" · ", agents.GroupBy(x => x.Status).Select(x => $"{x.Count()} {x.Key}"));
        }
        if (item.Kind == "subAgentActivity" && raw.Str("agentThreadId") is { } child) agents.Add(new(child, raw.Str("agentPath") ?? child, raw.Str("kind") ?? item.Status, null));
        if (raw.TryObjectProperty("memoryCitation", out var memory))
            foreach (var entry in IntegrationCoordinator.Rows(memory, "entries"))
            {
                var path = entry.Str("path") ?? entry.Str("filePath"); if (path is null) continue;
                sources.Add(new(item.Id + ":memory:" + sources.Count, Path.GetFileName(path), path, Integer(entry, "lineStart"), Integer(entry, "lineEnd"), entry.Str("note")));
            }
        foreach (var entry in IntegrationCoordinator.Rows(raw, "citations"))
        {
            var target = entry.Str("url") ?? entry.Str("path"); if (target is not null) sources.Add(new(item.Id + ":citation:" + sources.Count, entry.Str("title") ?? target, target, Integer(entry, "lineStart"), Integer(entry, "lineEnd")));
        }
        if (item.Kind is "mcpToolCall" or "dynamicToolCall")
        {
            var texts = artifacts.Where(x => x.Kind == "text").Select(x => x.Source).ToArray(); if (texts.Length > 0) body = string.Join("\n\n", texts);
            else if (raw.TryObjectProperty("error", out var error)) body = error.Str("message") ?? "The tool reported an error.";
            else if (string.IsNullOrWhiteSpace(body)) body = artifacts.Count > 0 ? "" : "No textual result was supplied. Runtime status: " + item.Status;
        }
        var textInBody = item.Kind is "userMessage" or "mcpToolCall" or "dynamicToolCall";
        return new(title, body, artifacts.Where(x => x.Kind != "text" || !textInBody && body != x.Source).ToArray(), sources.ToArray(), agents.ToArray(), IsActivity(item.Kind));
    }
    static void AddContent(JsonElement[] content, string parent, List<ConversationArtifact> artifacts)
    {
        for (var index = 0; index < content.Length; index++)
        {
            var raw = content[index]; var type = raw.Str("type") ?? "unknown"; var id = parent + ":" + index; var mime = raw.Str("mimeType");
            if (type is "text" or "inputText" or "input_text") { if (raw.Str("text") is { } text) artifacts.Add(new(id, "text", text, "Text result", "text/plain")); }
            else if (type is "image" or "inputImage" or "audio" or "inputAudio")
            {
                var image = type is "image" or "inputImage"; var source = raw.Str("data") ?? raw.Str("url") ?? raw.Str(image ? "imageUrl" : "audioUrl");
                if (source is not null) artifacts.Add(new(id, raw.Str("data") is not null ? image ? "inlineImage" : "inlineAudio" : source.StartsWith("data:", StringComparison.OrdinalIgnoreCase) ? image ? "dataImage" : "dataAudio" : image ? "remoteImage" : "remoteAudio", source, image ? "Image" : "Audio", mime));
                else artifacts.Add(new(id, "unknown", raw.Str("fileId") ?? type, image ? "Image" : "Audio", mime, "The runtime supplied media without directly readable bytes or a URL."));
            }
            else if (type is "localImage" or "localAudio") { if (raw.Str("path") is { } path) artifacts.Add(new(id, type, path, Path.GetFileName(path), mime)); }
            else if (type == "resource")
            {
                var resource = raw.TryObjectProperty("resource", out var nested) ? nested : raw; var uri = resource.Str("uri") ?? "Resource"; var contentMime = resource.Str("mimeType") ?? mime;
                if (resource.Str("text") is { } text) artifacts.Add(new(id, "text", text, uri, contentMime));
                else if (resource.Str("blob") is { } blob) artifacts.Add(new(id, contentMime?.StartsWith("image/", StringComparison.Ordinal) == true ? "inlineImage" : contentMime?.StartsWith("audio/", StringComparison.Ordinal) == true ? "inlineAudio" : "inlineResource", blob, uri, contentMime));
                else artifacts.Add(new(id, "resource", uri, raw.Str("name") ?? uri, contentMime));
            }
            else if (type is "resource_link" or "mention" or "skill") artifacts.Add(new(id, "resource", raw.Str("uri") ?? raw.Str("path") ?? "", raw.Str("title") ?? raw.Str("name") ?? "Source", mime));
            else artifacts.Add(new(id, "unknown", type, "Unsupported tool content: " + type, mime, "This content type has no native renderer. The original item remains in local history."));
        }
    }
    static int? Integer(JsonElement value, string key) => AccountCoordinator.Number(value, key) is >= 1 and <= int.MaxValue and var number ? (int)number : null;
    public static IReadOnlyList<ConversationTopic> Topics(IEnumerable<TimelineItem> items)
    {
        var turns = new List<TopicBuilder>(); var byTurn = new Dictionary<string, TopicBuilder>(StringComparer.Ordinal); TopicBuilder? current = null;
        foreach (var item in items.OrderBy(x => x.Order))
        {
            if (item.TurnId is { } turn) { if (!byTurn.TryGetValue(turn, out current)) { current = new("turn:" + turn, item.Id); byTurn[turn] = current; turns.Add(current); } }
            else if (item.Kind == "userMessage" || current is null && item.Kind == "agentMessage") { current = new("item:" + item.Id, item.Id); turns.Add(current); }
            if (current is null) continue; current.Items.Add(item.Id);
            if (item.Kind == "userMessage") { if (current.Prompt.Length == 0) { current.Prompt = item.Text; current.Target = item.Id; } current.Length += item.Text.Length; current.Context.Add(item.Text); current.Conversation = true; }
            else if (item.Kind == "agentMessage") { current.Assistant.Add(item.Text); current.Length += item.Text.Length; current.Conversation = true; }
            else if (item.Kind is "fileChange" or "plan" or "planUpdate") current.Context.Add(item.Text);
        }
        var result = new List<ConversationTopic>();
        foreach (var turn in turns.Where(x => x.Conversation))
        {
            var topic = new ConversationTopic(turn.Id, turn.Target, turn.Items.ToArray(), Normalize(turn.Prompt, "User prompt unavailable"), Normalize(string.Join(" ", turn.Assistant), "No assistant response yet"), turn.Length, 1, Keywords(string.Join(" ", turn.Context)));
            if (result.Count == 0 || StartsTopic(result[^1], topic)) result.Add(topic);
            else { var old = result[^1]; result[^1] = old with { ItemIds = old.ItemIds.Concat(topic.ItemIds).ToArray(), AssistantPreview = topic.AssistantPreview == "No assistant response yet" ? old.AssistantPreview : topic.AssistantPreview, ContentLength = old.ContentLength + topic.ContentLength, SourceTurnCount = old.SourceTurnCount + 1, Keywords = old.Keywords.Concat(topic.Keywords).Distinct(StringComparer.Ordinal).ToArray() }; }
        }
        return result;
    }
    static bool StartsTopic(ConversationTopic previous, ConversationTopic candidate)
    {
        if (candidate.Keywords.Length == 0) return false; var overlap = candidate.Keywords.Intersect(previous.Keywords, StringComparer.Ordinal).Count(); var similarity = (double)overlap / Math.Max(1, Math.Min(previous.Keywords.Length, candidate.Keywords.Length)); if (overlap >= 2 || similarity >= .28) return false;
        var prompt = candidate.Prompt.ToLowerInvariant(); if (new[] { "new feature", "another feature", "different feature", "next feature", "switch to", "move on to", "instead work on", "start working on", "separate task", "different task", "new task", "now let's", "now lets" }.Any(prompt.Contains) && overlap == 0) return true;
        if (new[] { "that", "this", "it", "same", "continue", "keep", "still", "also", "first thing", "actually", "instead", "make it", "change it", "fix it" }.Any(prompt.StartsWith)) return false;
        return overlap == 0 && candidate.Keywords.Length >= 3 && candidate.Prompt.Length >= 72;
    }
    static readonly HashSet<string> StopWords = new("a an and are as at be been but by can could do does for from get has have how i if in into is it just make me more my new not now of on or please should so some than that the then there these this to up use want was we were what when where which will with you your add change fix implement update work working feature".Split(' '), StringComparer.Ordinal);
    static string[] Keywords(string text) => Regex.Split(text.ToLowerInvariant(), @"[^\p{L}\p{N}/.]+", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(150)).Where(x => x.Length >= 3 && !StopWords.Contains(x) && !x.All(char.IsNumber)).Distinct(StringComparer.Ordinal).ToArray();
    static string Normalize(string text, string fallback) { var result = string.Join(" ", text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)); return result.Length == 0 ? fallback : result; }
    sealed class TopicBuilder(string id, string target) { public string Id = id, Target = target, Prompt = ""; public int Length; public bool Conversation; public List<string> Items = [], Assistant = [], Context = []; }
}
