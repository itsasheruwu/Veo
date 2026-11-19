using System.Text.Json;

namespace Veo.Core;

public sealed record TimelineTurn(string Id, string? Status, DateTimeOffset? StartedAt, string? ErrorJson, long Order, bool TerminalObserved)
{
    public static bool KnownTerminalStatus(string? status) => status is "completed" or "interrupted" or "failed" or "aborted" or "cancelled" or "canceled";
    public static TimelineTurn? Parse(JsonElement raw, string? envelopeId = null, bool terminalNotification = false, long order = 0)
    {
        var rawId = raw.Str("id");
        if (string.IsNullOrWhiteSpace(rawId)) rawId = null;
        if (string.IsNullOrWhiteSpace(envelopeId)) envelopeId = null;
        if (rawId is not null && envelopeId is not null && rawId != envelopeId) return null;
        var id = rawId ?? envelopeId;
        if (id is null) return null;
        var status = raw.Str("status") ?? (raw.TryObjectProperty("status", out var wrapped) ? wrapped.Str("type") : null);
        DateTimeOffset? started = null;
        if (raw.ValueKind == JsonValueKind.Object && raw.TryGetProperty("startedAt", out var date) && date.ValueKind == JsonValueKind.String && date.TryGetDateTimeOffset(out var value)) started = value;
        var error = raw.ValueKind == JsonValueKind.Object && raw.TryGetProperty("error", out var failure) && failure.ValueKind != JsonValueKind.Null ? failure.GetRawText() : null;
        // A terminal notification is evidence of closure even when its exact outcome is omitted.
        // Such a row retains a null status; neither its items nor the method name invent an outcome.
        return new(id, status, started, error, order, terminalNotification || KnownTerminalStatus(status));
    }
}

public sealed partial class TimelineReducer
{
    readonly Dictionary<string, TimelineTurn> turnMetadata = new(StringComparer.Ordinal);
    long nextTurnOrder;
    public IReadOnlyList<TimelineTurn> Turns { get { lock(sync) return turnMetadata.Values.OrderBy(t => t.Order).ToArray(); } }
    public (IReadOnlyList<TimelineItem> Items, IReadOnlyList<TimelineTurn> Turns) PersistenceSnapshot()
    {
        lock(sync) return (items.Values.OrderBy(i => i.Order).ToArray(), turnMetadata.Values.OrderBy(t => t.Order).ToArray());
    }
    public void ObserveTurnMetadata(JsonElement raw, string? envelopeId = null, bool terminalNotification = false)
    {
        if (TimelineTurn.Parse(raw, envelopeId, terminalNotification) is { } incoming) ObserveTurns([incoming]);
    }
    public void ObserveTurns(IEnumerable<TimelineTurn> incoming)
    {
        lock(sync)
        {
            foreach(var turn in incoming)
            {
                if(string.IsNullOrWhiteSpace(turn.Id)) continue;
                turnMetadata.TryGetValue(turn.Id, out var previous);
                if(previous?.TerminalObserved == true && !turn.TerminalObserved) continue;
                var combined = turn with
                {
                    Status = turn.Status ?? (turn.TerminalObserved && previous?.TerminalObserved != true ? null : previous?.Status),
                    StartedAt = turn.StartedAt ?? previous?.StartedAt,
                    ErrorJson = turn.ErrorJson ?? previous?.ErrorJson,
                    Order = previous?.Order ?? nextTurnOrder++,
                    TerminalObserved = turn.TerminalObserved || previous?.TerminalObserved == true
                };
                turnMetadata[turn.Id] = combined;
                if(combined.TerminalObserved) completedTurns.Add(turn.Id);
            }
        }
    }
}
