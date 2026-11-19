using System.Collections.Concurrent;
using System.Text.Json;
using Veo.Infrastructure.Storage;
using Veo.Protocol;

namespace Veo.Core;

public sealed record ReportedContextUsage(long CumulativeTokens, long CurrentTokens, long? Window)
{
    public double? Fraction => Window is > 0 ? Math.Clamp((double)CurrentTokens / Window.Value, 0, 1) : null;
    public int Warning => Fraction is >= .9 ? 2 : Fraction is >= .75 ? 1 : 0;
    public static ReportedContextUsage? Parse(JsonElement usage) => usage.TryObjectProperty("total", out var total) && usage.TryObjectProperty("last", out var last) && AccountCoordinator.Number(total, "totalTokens") is >= 0 and var cumulative && AccountCoordinator.Number(last, "totalTokens") is >= 0 and var current ? new(cumulative, current, AccountCoordinator.Number(usage, "modelContextWindow") is > 0 and var window ? window : null) : null;
}
public sealed record ConversationPlanStep(string Text, string Status);
public sealed record ConversationFileChange(string Path, string Kind, string ItemId);
public sealed record ConversationActivitySnapshot(string? TurnId, string Status, ReportedContextUsage? Usage, ConversationPlanStep[] Plan, ConversationFileChange[] Files, ConversationAgent[] Agents, string Diff, bool DiffTruncated, bool Compacting, AutoWorkflowState? Route, DateTimeOffset UpdatedAt)
{ public static ConversationActivitySnapshot Empty { get; } = new(null, "idle", null, [], [], [], "", false, false, null, DateTimeOffset.MinValue); }

/// <summary>Thread activity is a derived view, persisted separately from item-aware history. There is one runtime event consumer in WorkspaceCoordinator.</summary>
public sealed class ConversationActivityCoordinator : IAsyncDisposable
{
    readonly WorkspaceCoordinator workspace;
    readonly AutoRoutingCoordinator? routing;
    readonly ICoordinatorRpc rpc;
    readonly ConcurrentDictionary<string, ConversationActivitySnapshot> snapshots = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, SemaphoreSlim> gates = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, byte> scheduled = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, Task> pendingSaves = new(StringComparer.Ordinal);
    readonly Dictionary<string, long> revisions = new(StringComparer.Ordinal);
    readonly CancellationTokenSource lifetime = new();
    readonly object sync = new();
    bool disposed;
    public event Action? Changed;
    public string? LastError { get; private set; }
    public ConversationActivityCoordinator(WorkspaceCoordinator workspace, AutoRoutingCoordinator? routing = null, ICoordinatorRpc? transport = null, bool observeEvents = true)
    { this.workspace = workspace; this.routing = routing; rpc = transport ?? new WorkspaceCoordinatorRpc(workspace); if (observeEvents) workspace.RuntimeEventReceived += OnEvent; if (observeEvents && routing is not null) routing.Changed += RoutingChanged; }
    public ConversationActivitySnapshot Snapshot(ThreadSession session)
    {
        lock (sync) { var state = snapshots.GetValueOrDefault(session.Record.VeoId) ?? ConversationActivitySnapshot.Empty; return state with { Route = routing?.Workflow(session)?.State ?? state.Route }; }
    }
    public async Task ObserveAsync(ThreadSession session)
    {
        var gate = gates.GetOrAdd(session.Record.VeoId, _ => new(1, 1)); await gate.WaitAsync(lifetime.Token);
        try
        {
            if (!snapshots.ContainsKey(session.Record.VeoId) && await workspace.Threads.ReadStateAsync(session.Record.VeoId, "activity", lifetime.Token) is { } raw)
            { try { var saved = JsonSerializer.Deserialize<ConversationActivitySnapshot>(raw); if (saved is not null) snapshots.TryAdd(session.Record.VeoId, saved); } catch (JsonException) { LastError = "Saved activity metadata could not be read. Timeline history is still available."; } }
            lock (sync)
            {
                var previous = Snapshot(session);
                var (items, turns) = session.Timeline.PersistenceSnapshot();
                var active = session.Timeline.ActiveTurnId;
                var running = session.Timeline.IsRunning;
                var newestTurn = turns.LastOrDefault();
                var turn = active ?? newestTurn?.Id ?? items.LastOrDefault(x => x.TurnId is not null)?.TurnId ?? previous.TurnId;
                var relevant = items.Where(x => x.TurnId == turn || x.TurnId is null).ToArray();
                var files = relevant.Where(x => x.Kind == "fileChange").SelectMany(FileChanges).DistinctBy(x => x.Path, StringComparer.Ordinal).ToArray();
                var agents = relevant.SelectMany(x => TimelinePresentation.Item(x).Agents).GroupBy(x => x.ThreadId, StringComparer.Ordinal).Select(x => x.Last()).ToArray();
                if (turn != previous.TurnId)
                    previous = ConversationActivitySnapshot.Empty with { Usage = previous.Usage, Route = previous.Route };
                var status = "idle";
                if (running) status = "running";
                else if (newestTurn is { TerminalObserved: true, Status: { } outcome } && newestTurn.Id == turn) status = outcome;
                snapshots[session.Record.VeoId] = previous with
                {
                    TurnId = turn,
                    Status = status,
                    Files = files.Length == 0 ? previous.Files : files,
                    Agents = agents.Length == 0 ? previous.Agents : agents,
                    Compacting = running && previous.Compacting,
                    Route = routing?.Workflow(session)?.State ?? previous.Route
                };
            }
        }
        finally { gate.Release(); }
        Schedule(session); Changed?.Invoke();
    }
    void OnEvent(RuntimeEvent message)
    {
        if (disposed || message.Parameters.Str("threadId") is not { } runtime) return;
        var session = workspace.LoadedSessions.FirstOrDefault(x => x.Record.CodexThreadId == runtime); if (session is not null) Apply(session, message);
    }
    public void Apply(ThreadSession session, RuntimeEvent message)
    {
        if (disposed || message.Generation != rpc.Generation || message.Parameters.Str("threadId") != session.Record.CodexThreadId) return;
        var p = message.Parameters; var changed = false;
        lock (sync)
        {
            var state = Snapshot(session); var turn = p.Str("turnId") ?? (p.TryObjectProperty("turn", out var t) ? t.Str("id") : null);
            switch (message.Method)
            {
                case "turn/started":
                    state = state with { TurnId = turn, Status = "running", Plan = [], Files = [], Agents = [], Diff = "", DiffTruncated = false, Compacting = false }; changed = true; break;
                case "turn/completed":
                    if (turn is not null && state.TurnId is not null && turn != state.TurnId) return;
                    state = state with { Status = p.TryObjectProperty("turn", out var complete) ? complete.Str("status") ?? "completed" : "completed", Compacting = false }; changed = true; break;
                case "thread/tokenUsage/updated":
                    if (turn is not null && state.TurnId is not null && turn != state.TurnId) return;
                    if (p.TryObjectProperty("tokenUsage", out var token) && ReportedContextUsage.Parse(token) is { } usage) { state = state with { Usage = usage }; changed = true; } break;
                case "turn/plan/updated":
                    if (WrongTurn(state, turn)) return; state = state with { TurnId = turn ?? state.TurnId, Plan = IntegrationCoordinator.Rows(p, "plan").Where(x => x.Str("step") is not null).Select(x => new ConversationPlanStep(x.Str("step")!, x.Str("status") ?? "pending")).ToArray() }; changed = true; break;
                case "turn/diff/updated":
                    if (WrongTurn(state, turn) || p.Str("diff") is not { } diff) return; state = state with { TurnId = turn ?? state.TurnId, Diff = diff[..Math.Min(diff.Length, 128 * 1024)], DiffTruncated = diff.Length > 128 * 1024 }; changed = true; break;
                case "item/started": case "item/completed":
                    if (WrongTurn(state, turn) || !p.TryObjectProperty("item", out var raw) || raw.Str("id") is not { } id) return;
                    var item = new TimelineItem(id, turn, raw.Str("type") ?? "unknown", TimelineReducer.ExtractText(raw), raw.Str("status") ?? (message.Method == "item/started" ? "inProgress" : "completed"), raw, 0);
                    if (item.Kind == "fileChange") { var updates = FileChanges(item).ToArray(); state = state with { Files = state.Files.Where(x => updates.All(u => u.Path != x.Path)).Concat(updates).ToArray() }; changed = true; }
                    var agents = TimelinePresentation.Item(item).Agents;
                    if (agents.Length > 0) { state = state with { Agents = state.Agents.Where(x => agents.All(a => a.ThreadId != x.ThreadId)).Concat(agents).ToArray() }; changed = true; }
                    if (item.Kind == "contextCompaction") { state = state with { Compacting = message.Method == "item/started" }; changed = true; } break;
            }
            if (changed) snapshots[session.Record.VeoId] = state with { UpdatedAt = DateTimeOffset.UtcNow, Route = routing?.Workflow(session)?.State ?? state.Route };
        }
        if (changed) Schedule(session);
    }
    static bool WrongTurn(ConversationActivitySnapshot state, string? turn) => turn is not null && state.TurnId is not null && turn != state.TurnId || turn is null && state.Status is not ("running" or "inProgress");
    static IEnumerable<ConversationFileChange> FileChanges(TimelineItem item) => IntegrationCoordinator.Rows(item.Raw, "changes").Where(x => x.Str("path") is not null).Select(x => new ConversationFileChange(x.Str("path")!, x.Str("kind") ?? (x.TryObjectProperty("kind", out var kind) ? kind.Str("type") : null) ?? "update", item.Id));
    void RoutingChanged() { if (!disposed) { foreach (var session in workspace.LoadedSessions.Where(x => routing?.Workflow(x) is not null)) { lock (sync) snapshots[session.Record.VeoId] = Snapshot(session) with { Route = routing?.Workflow(session)?.State }; Schedule(session); } } }
    void Schedule(ThreadSession session)
    {
        lock (sync) { revisions[session.Record.VeoId] = revisions.GetValueOrDefault(session.Record.VeoId) + 1; if (!scheduled.TryAdd(session.Record.VeoId, 0)) return; pendingSaves[session.Record.VeoId] = SaveLaterAsync(session); }
    }
    async Task SaveLaterAsync(ThreadSession session)
    {
        try
        {
            while (true)
            {
                await Task.Delay(150, lifetime.Token); long observed; lock (sync) observed = revisions.GetValueOrDefault(session.Record.VeoId);
                Changed?.Invoke(); var gate = gates.GetOrAdd(session.Record.VeoId, _ => new(1, 1)); await gate.WaitAsync(lifetime.Token);
                try { await workspace.Threads.SaveStateAsync(session.Record.VeoId, "activity", JsonSerializer.Serialize(Snapshot(session)), lifetime.Token); } finally { gate.Release(); }
                lock (sync) if (observed == revisions.GetValueOrDefault(session.Record.VeoId)) { scheduled.TryRemove(session.Record.VeoId, out _); return; }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { lock (sync) scheduled.TryRemove(session.Record.VeoId, out _); }
        catch (Exception ex) { lock (sync) scheduled.TryRemove(session.Record.VeoId, out _); LastError = DiagnosticRedactor.Redact(ex.Message); Changed?.Invoke(); }
    }
    public async Task<ThreadSession> OpenChildAsync(ThreadSession parent, string runtimeChildId, CancellationToken cancellation = default)
    {
        if (runtimeChildId == parent.Record.CodexThreadId || !parent.Timeline.Items.SelectMany(x => TimelinePresentation.Item(x).Agents).Any(x => x.ThreadId == runtimeChildId)) throw new InvalidOperationException("This child identity is not referenced by the selected parent chat.");
        var response = await rpc.RequestAsync("thread/read", new { threadId = runtimeChildId, includeTurns = false }, cancellation); if (!response.TryObjectProperty("thread", out var thread) || thread.Str("id") != runtimeChildId) throw new InvalidDataException("Codex returned a different child thread.");
        var cwd = thread.Str("cwd") ?? throw new InvalidDataException("The child thread supplied no workspace."); if (!Path.IsPathFullyQualified(cwd) || !Directory.Exists(cwd)) throw new DirectoryNotFoundException("The child workspace is unavailable.");
        var records = (await workspace.Threads.ListThreadsAsync(false, limit: 100000, cancellationToken: cancellation)).Concat(await workspace.Threads.ListThreadsAsync(true, limit: 100000, cancellationToken: cancellation));
        var record = records.FirstOrDefault(x => x.CodexThreadId == runtimeChildId);
        if (record is null) { record = new PersistedThread(Guid.NewGuid().ToString("N"), runtimeChildId, Path.GetFullPath(cwd), thread.Str("name") ?? thread.Str("preview") ?? "Subagent", ParentThreadId: parent.Record.VeoId, WorkspaceKind: "subagent", MetaJson: JsonSerializer.Serialize(new { runtimeParentId = parent.Record.CodexThreadId })); await workspace.Threads.UpsertThreadAsync(record, cancellation); }
        return await workspace.LoadAsync(record);
    }
    public async ValueTask DisposeAsync()
    { disposed = true; workspace.RuntimeEventReceived -= OnEvent; if (routing is not null) routing.Changed -= RoutingChanged; try { await Task.WhenAll(pendingSaves.Values); } finally { lifetime.Cancel(); lifetime.Dispose(); } }
}
