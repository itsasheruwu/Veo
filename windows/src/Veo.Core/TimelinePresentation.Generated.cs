#nullable enable
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Veo.Protocol;

namespace Veo.Core;

public static partial class TimelinePresentation
{
    [GeneratedRegex(@"\b(generate|create|draw|render|make|produce|design)\b[^.\n]{0,60}\b(image|picture|illustration|logo|icon|poster|concepts?|mockups?|visuals?)\b", RegexOptions.IgnoreCase)]
    private static partial Regex ImageRequest();
    public static bool IsRoblox(TimelineItem item) => item.Kind == "mcpToolCall"
        && item.Raw.Str("server")?.Contains("roblox", StringComparison.OrdinalIgnoreCase) == true;
    public static bool RobloxToolFailed(TimelineItem item) => IsRoblox(item) &&
        (item.Status is "failed" or "error" or "cancelled" or "canceled"
            || item.Raw.Str("error") is { Length: > 0 }
            || item.Raw.TryObjectProperty("error", out _)
            || item.Raw.TryObjectProperty("result", out var result)
                && result.TryGetProperty("isError", out var failed) && failed.ValueKind == JsonValueKind.True);
    public static bool IsResearch(TimelineItem item) => item.Raw.ValueKind == JsonValueKind.Object
        && (item.Raw.TryGetProperty("veoWildResearch", out var value) && value.ValueKind == JsonValueKind.True
            || Purpose(item.Raw) is "research" or "reference");
    static string? Purpose(JsonElement item) =>
        item.Str("purpose") ?? (item.TryObjectProperty("_meta", out var metadata) ? metadata.Str("purpose") : null);
    public static bool IsInProgress(TimelineItem item) => item.Status is "inProgress" or "running" or "pending" or "active";

    public static JsonElement MarkResearch(JsonElement parameters, string? method, string prompt)
    {
        if (method is not ("item/started" or "item/completed") || !parameters.TryObjectProperty("item", out var item)) return parameters;
        var purpose = Purpose(item);
        if (item.Str("type") != "webSearch" && (item.Str("type") != "imageGeneration"
            || !(purpose is "research" or "reference" || purpose is null && !ImageRequest().IsMatch(prompt)))) return parameters;
        var copy = JsonNode.Parse(parameters.GetRawText())!.AsObject();
        copy["item"]!["veoWildResearch"] = true;
        return JsonSerializer.SerializeToElement(copy);
    }

    public static IReadOnlyList<TimelineItem> ProjectSpecialRows(IReadOnlyList<TimelineItem> rows)
    {
        if (!rows.Any(item => item.Kind == "imageGeneration" || IsRoblox(item))) return rows;
        var replies = rows.Where(row => row.Kind == "agentMessage" && row.TurnId is not null).ToLookup(row => row.TurnId!);
        var byReply = new Dictionary<string, List<ConversationArtifact>>(StringComparer.Ordinal);
        var consumed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows.Where(item => item.Kind == "imageGeneration" && !IsInProgress(item) && !IsResearch(item)))
        {
            if (row.TurnId is not { } turn || Item(row).Artifacts.FirstOrDefault() is not { UnavailableReason: null } image) continue;
            var candidates = replies[turn];
            var reply = candidates.FirstOrDefault(item => image.Kind == "localImage" && item.Text.Contains(image.Source, StringComparison.OrdinalIgnoreCase))
                ?? candidates.FirstOrDefault(item => item.Order > row.Order) ?? candidates.LastOrDefault();
            if (reply is null) continue;
            consumed.Add(row.Id);
            if (!byReply.TryGetValue(reply.Id, out var images)) byReply[reply.Id] = images = [];
            if (!images.Any(candidate => candidate.Source == image.Source)) images.Add(image);
        }

        var projected = new List<TimelineItem>(rows.Count);
        for (var index = 0; index < rows.Count; index++)
        {
            var row = rows[index];
            if (consumed.Contains(row.Id)) continue;
            if (IsRoblox(row))
            {
                var group = new List<TimelineItem> { row };
                while (index + 1 < rows.Count && rows[index + 1].TurnId == row.TurnId && IsRoblox(rows[index + 1]))
                    group.Add(rows[++index]);
                var title = "Roblox ×" + group.Count;
                if (group.Any(RobloxToolFailed)) title += " · Failed";
                projected.Add(new("veo-roblox-" + row.Id, row.TurnId, "veoRobloxGroup", title, "", JsonSerializer.SerializeToElement(group), row.Order));
                continue;
            }
            if (byReply.TryGetValue(row.Id, out var delivered))
            {
                var raw = row.Raw.ValueKind == JsonValueKind.Object ? JsonNode.Parse(row.Raw.GetRawText())!.AsObject() : new JsonObject();
                raw["veoGeneratedConcepts"] = JsonSerializer.SerializeToNode(delivered);
                row = row with { Raw = JsonSerializer.SerializeToElement(raw) };
            }
            projected.Add(row);
        }
        return projected;
    }

    public static ConversationArtifact[] GeneratedConcepts(TimelineItem item) =>
        item.Raw.ValueKind == JsonValueKind.Object && item.Raw.TryGetProperty("veoGeneratedConcepts", out var value)
            ? value.Deserialize<ConversationArtifact[]>() ?? [] : [];
}
