using System.Text.Json;
using System.Text.Json.Nodes;

namespace Veo.Core;

public sealed record TimelineItem(string Id, string? TurnId, string Kind, string Text, string Status, JsonElement Raw, long Order);

/// <summary>Thread-scoped, synchronized item reduction. Completion never creates or reopens an artificial row.</summary>
public sealed partial class TimelineReducer
{
    readonly object sync = new();
    readonly Dictionary<string, TimelineItem> items = new(StringComparer.Ordinal);
    readonly HashSet<string> completedTurns = new(StringComparer.Ordinal);
    readonly HashSet<string> removedItems = new(StringComparer.Ordinal);
    long nextOrder;
    long lifecycle;
    bool running;
    string? activeTurn;
    public bool IsRunning { get { lock (sync) return running; } }
    public string? ActiveTurnId { get { lock (sync) return activeTurn; } }
    public long StateVersion { get { lock (sync) return lifecycle; } }
    public IReadOnlyCollection<string> RemovedItemIds { get { lock (sync) return removedItems.ToArray(); } }
    public void ConfirmRemovedItems(IEnumerable<string> ids) { lock (sync) foreach (var id in ids) removedItems.Remove(id); }
    public IReadOnlyList<TimelineItem> Items { get { lock (sync) return items.Values.OrderBy(x => x.Order).ToArray(); } }

    public long BeginPending()
    {
        lock (sync) { running = true; activeTurn = null; return ++lifecycle; }
    }
    public void AcknowledgeStart(long dispatch, string? turnId)
    {
        lock (sync)
        {
            turnId = NullIfBlank(turnId);
            if (dispatch != lifecycle || !running || (turnId is not null && completedTurns.Contains(turnId))) return;
            activeTurn = turnId ?? activeTurn;
            lifecycle++;
        }
    }
    public void Begin(string? turnId)
    {
        lock (sync)
        {
            turnId = NullIfBlank(turnId);
            if (turnId is not null && completedTurns.Contains(turnId)) return;
            lifecycle++;
            running = true; activeTurn = turnId ?? activeTurn;
        }
    }
    public void End(string? turnId)
    {
        lock (sync)
        {
            turnId = NullIfBlank(turnId);
            if (turnId is not null) completedTurns.Add(turnId);
            if (activeTurn is { } active && turnId is { } received && active != received) return;
            if (activeTurn is not null) completedTurns.Add(activeTurn);
            running = false; activeTurn = null;
            lifecycle++;
        }
    }
    public void Reconcile(IEnumerable<TimelineItem> history, bool isRunning, string? activeTurnId, long? expectedStateVersion = null)
    {
        lock (sync)
        {
            var materialized = history.ToArray();
            foreach (var incoming in materialized) UpsertCore(incoming.Raw, incoming.TurnId, incoming.Text, incoming);
            var incomingIds = materialized.Select(x => x.Id).Where(items.ContainsKey).ToHashSet(StringComparer.Ordinal);
            var ordered = materialized.Select(x => x.Id).Where(items.ContainsKey).Distinct(StringComparer.Ordinal)
                .Concat(items.Values.Where(x => !incomingIds.Contains(x.Id)).OrderBy(x => x.Order).Select(x => x.Id)).ToArray();
            nextOrder = 0;
            foreach (var id in ordered) items[id] = items[id] with { Order = nextOrder++ };
            if (expectedStateVersion is null || lifecycle == expectedStateVersion)
            {
                var staleActive = activeTurnId is { } known && completedTurns.Contains(known);
                running = isRunning && !staleActive; activeTurn = running ? NullIfBlank(activeTurnId) : null;
                lifecycle++;
            }
        }
    }
    public void AddLocal(string id, string kind, string text, string? turnId = null, string status = "completed")
    {
        var raw = JsonSerializer.SerializeToElement(new { id, clientId = kind == "userMessage" ? id : null, type = kind, text, status, veoLocal = true });
        Upsert(raw, turnId, text);
    }
    public void ReplaceHistory(IEnumerable<TimelineItem> history, bool isRunning, string? activeTurnId, IEnumerable<string>? retainedTurnIds = null)
    {
        lock (sync)
        {
            var authoritative = history.ToArray();
            var ids = authoritative.Select(x => x.Id).ToHashSet(StringComparer.Ordinal);
            var turns = authoritative.Select(x => x.TurnId).OfType<string>().Concat(retainedTurnIds ?? []).ToHashSet(StringComparer.Ordinal);
            foreach (var item in items.Values.ToArray())
            {
                var localArtifact = item.Kind is "veoUserInputAnswer" or "veoPlanArtifact";
                if (ids.Contains(item.Id) || (localArtifact && item.TurnId is { } turn && turns.Contains(turn))) continue;
                items.Remove(item.Id); removedItems.Add(item.Id);
            }
            completedTurns.IntersectWith(turns);
            foreach (var id in turnMetadata.Keys.Where(id => !turns.Contains(id)).ToArray()) turnMetadata.Remove(id);
            if (isRunning && activeTurnId is not null) completedTurns.Remove(activeTurnId);
            Reconcile(authoritative, isRunning, activeTurnId);
        }
    }
    public bool Apply(string method, JsonElement payload)
    {
        lock (sync)
        {
            var turn = payload.Str("turnId") ?? (payload.TryObjectProperty("turn", out var t) ? t.Str("id") : null);
            if (method == "turn/started") { ObserveTurnMetadata(payload.TryObjectProperty("turn", out var started) ? started : default, payload.Str("turnId")); Begin(turn); return true; }
            if (method is "turn/completed" or "turn/aborted")
            {
                ObserveTurnMetadata(payload.TryObjectProperty("turn", out var ended) ? ended : default, payload.Str("turnId"), terminalNotification: true);
                if (payload.TryObjectProperty("turn", out var snapshot) && snapshot.TryGetProperty("items", out var completed) && completed.ValueKind == JsonValueKind.Array)
                    foreach (var item in completed.EnumerateArray()) UpsertCore(item, turn);
                End(turn); return true;
            }
            if (method is "item/started" or "item/completed")
            {
                if (!payload.TryObjectProperty("item", out var item) || item.Str("id") is not { } itemId) return false;
                if (method == "item/started" && !running) return false;
                if (!running && turn is null && !items.ContainsKey(itemId)) return false;
                if (running && activeTurn is null && turn is not null && !completedTurns.Contains(turn)) activeTurn = turn;
                if (turn is not null) ObserveTurnMetadata(default, turn);
                UpsertCore(item, turn, statusOverride: method == "item/started" ? "inProgress" : "completed");
                return true;
            }
            if (!method.StartsWith("item/", StringComparison.Ordinal) || !(method.EndsWith("/delta", StringComparison.Ordinal) || method.EndsWith("Delta", StringComparison.Ordinal))) return false;
            var id = payload.Str("itemId");
            if (id is null) return false;
            items.TryGetValue(id, out var existing);
            var isReasoning = method.Contains("reasoning", StringComparison.OrdinalIgnoreCase);
            // Late reasoning belongs to its existing item, even after completion. Generic idle activity is ignored.
            if (!running && !(isReasoning && existing?.Kind == "reasoning")) return false;
            if (running && turn is not null && activeTurn is not null && turn != activeTurn && !(isReasoning && existing is not null)) return false;
            var delta = payload.Str("delta") ?? payload.Str("text") ?? "";
            if (delta.Length == 0) return false;
            if (existing is not null)
            {
                var replacingCommand = existing.Kind == "commandExecution" && existing.Text == existing.Raw.Str("command");
                items[id] = existing with { Text = replacingCommand ? delta : existing.Text + delta };
            }
            else
            {
                var kind = isReasoning ? "reasoning" : method.Contains("commandExecution", StringComparison.Ordinal) ? "commandExecution"
                    : method.StartsWith("item/plan/", StringComparison.Ordinal) ? "plan"
                    : method.StartsWith("item/fileChange/", StringComparison.Ordinal) ? "fileChange" : "agentMessage";
                var raw = JsonSerializer.SerializeToElement(new { id, type = kind, text = delta, status = "inProgress" });
                UpsertCore(raw, turn, delta);
            }
            return true;
        }
    }
    public void Upsert(JsonElement raw, string? turn, string? textOverride = null)
    { lock (sync) UpsertCore(raw, turn, textOverride); }

    void UpsertCore(JsonElement raw, string? turn, string? textOverride = null, TimelineItem? history = null, string? statusOverride = null)
    {
        var id = raw.Str("id") ?? history?.Id; if (id is null) return;
        items.TryGetValue(id, out var previous);
        var kind = raw.Str("type") ?? history?.Kind ?? previous?.Kind ?? "unknown";
        var clientId = raw.Str("clientId") ?? raw.Str("clientUserMessageId");
        if (kind == "userMessage" && clientId is not null && clientId != id)
        {
            var optimistic = items.Values.FirstOrDefault(x => x.Kind == "userMessage" && x.Raw.Str("clientId") == clientId && x.Raw.TryGetProperty("veoLocal", out var local) && local.ValueKind == JsonValueKind.True);
            if (optimistic is not null)
            {
                previous ??= optimistic;
                items.Remove(optimistic.Id);
                removedItems.Add(optimistic.Id);
            }
        }
        var text = textOverride ?? ExtractText(raw);
        if (text.Length == 0 && previous is not null) text = previous.Text;
        var mergedRaw = MergeRaw(previous?.Raw, raw);
        items[id] = new(id, turn ?? previous?.TurnId, kind, text,
            raw.Str("status") ?? statusOverride ?? history?.Status ?? previous?.Status ?? "completed", mergedRaw,
            previous?.Order ?? nextOrder++);
    }
    static JsonElement MergeRaw(JsonElement? old, JsonElement incoming)
    {
        if (old is not { ValueKind: JsonValueKind.Object } previous) return incoming.Clone();
        var node = JsonNode.Parse(previous.GetRawText())!.AsObject();
        foreach (var property in incoming.EnumerateObject()) node[property.Name] = JsonNode.Parse(property.Value.GetRawText());
        // An authoritative runtime item replaces local ownership, while preserving unknown runtime fields.
        if (!incoming.TryGetProperty("veoLocal", out _)) node.Remove("veoLocal");
        return JsonSerializer.SerializeToElement(node);
    }
    public static string ExtractText(JsonElement raw)
    {
        foreach (var field in new[] { "veoRenderedText", "text", "aggregatedOutput", "output", "command", "message" })
            if (raw.Str(field) is { } value) return value;
        var parts = new List<string>();
        foreach (var field in new[] { "content", "summary", "reasoning" })
            if (raw.ValueKind == JsonValueKind.Object && raw.TryGetProperty(field, out var content) && content.ValueKind == JsonValueKind.Array)
                foreach (var part in content.EnumerateArray())
                    if (part.ValueKind == JsonValueKind.String) parts.Add(part.GetString()!);
                    else if (part.Str("text") is { } text) parts.Add(text);
        return string.Join("\n", parts);
    }
    static string? NullIfBlank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;
}

public static class JsonValues
{
    public static string? Str(this JsonElement element, string property) => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    public static bool TryObjectProperty(this JsonElement element, string property, out JsonElement value)
    { value = default; return element.ValueKind == JsonValueKind.Object && element.TryGetProperty(property, out value) && value.ValueKind == JsonValueKind.Object; }
}
