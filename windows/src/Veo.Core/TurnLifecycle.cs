using System.Text.Json;

namespace Veo.Core;

public sealed record TimelineTurn(string Id, string? Status, DateTimeOffset? StartedAt, string? ErrorJson, long Order, bool TerminalObserved, DateTimeOffset? CompletedAt = null, string? Diff = null, IReadOnlyDictionary<string, DateTimeOffset>? Steers = null)
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
        var started = ReadDate(raw, "startedAt");
        var completed = ReadDate(raw, "completedAt");
        var error = raw.ValueKind == JsonValueKind.Object && raw.TryGetProperty("error", out var failure) && failure.ValueKind != JsonValueKind.Null ? failure.GetRawText() : null;
        // A terminal notification is evidence of closure even when its exact outcome is omitted.
        // Such a row retains a null status; neither its items nor the method name invent an outcome.
        return new(id, status, started, error, order, terminalNotification || KnownTerminalStatus(status), completed);
    }
    static DateTimeOffset? ReadDate(JsonElement raw, string name)
    {
        if (raw.ValueKind != JsonValueKind.Object || !raw.TryGetProperty(name, out var date)) return null;
        if (date.ValueKind == JsonValueKind.String && date.TryGetDateTimeOffset(out var value)) return value;
        if (date.ValueKind != JsonValueKind.Number || !date.TryGetInt64(out var epoch) || epoch <= 0) return null;
        var milliseconds = epoch > 10_000_000_000 ? epoch : epoch * 1000;
        return milliseconds <= 253402300799999 ? DateTimeOffset.FromUnixTimeMilliseconds(milliseconds) : null;
    }

}

public sealed partial class TimelineReducer
{
    readonly Dictionary<string, TimelineTurn> turnMetadata = new(StringComparer.Ordinal);
    long nextTurnOrder;
    DateTimeOffset? liveTurnStartedAt;
    public DateTimeOffset? LiveTurnStartedAt
    {
        get { lock (sync) return activeTurn is { } id && turnMetadata.TryGetValue(id, out var turn) ? turn.StartedAt ?? liveTurnStartedAt : liveTurnStartedAt; }
    }
    public IReadOnlyList<TimelineTurn> Turns { get { lock(sync) return turnMetadata.Values.OrderBy(t => t.Order).ToArray(); } }
    public (IReadOnlyList<TimelineItem> Items, IReadOnlyList<TimelineTurn> Turns) PersistenceSnapshot()
    {
        lock(sync) return (items.Values.OrderBy(i => i.Order).ToArray(), turnMetadata.Values.OrderBy(t => t.Order).ToArray());
    }
    public void RecordSteer(string turnId, string clientId, DateTimeOffset sentAt)
    {
        lock (sync)
        {
            if (!turnMetadata.TryGetValue(turnId, out var turn)) return;
            var steers = turn.Steers is null
                ? new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal)
                : new(turn.Steers, StringComparer.Ordinal);
            steers[clientId] = sentAt;
            turnMetadata[turnId] = turn with { Steers = steers };
        }
    }

    public void ObserveTurnMetadata(JsonElement raw, string? envelopeId = null, bool terminalNotification = false, bool liveNotification = false)
    {
        if (TimelineTurn.Parse(raw, envelopeId, terminalNotification) is not { } incoming) return;
        lock (sync)
        {
            turnMetadata.TryGetValue(incoming.Id, out var previous);
            var isSameActive = activeTurn == incoming.Id || activeTurn is null;
            var started = incoming.StartedAt ?? previous?.StartedAt
                ?? (liveNotification && isSameActive ? liveTurnStartedAt : null);
            var completed = incoming.CompletedAt ?? previous?.CompletedAt
                ?? (liveNotification && terminalNotification && previous?.TerminalObserved != true ? DateTimeOffset.UtcNow : null);
            ObserveTurns([incoming with { StartedAt = started, CompletedAt = completed }]);
        }
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
                    CompletedAt = turn.CompletedAt ?? previous?.CompletedAt,
                    Diff = turn.Diff ?? previous?.Diff,
                    Steers = turn.Steers ?? previous?.Steers,
                    Order = previous?.Order ?? nextTurnOrder++,
                    TerminalObserved = turn.TerminalObserved || previous?.TerminalObserved == true
                };
                turnMetadata[turn.Id] = combined;
                if(combined.TerminalObserved) completedTurns.Add(turn.Id);
            }
        }
    }
}
