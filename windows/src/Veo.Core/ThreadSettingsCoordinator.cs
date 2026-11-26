using System.Collections.Concurrent;
using System.Text.Json;
using Veo.Protocol;

namespace Veo.Core;

public sealed record ThreadSettingsResult(string Status, string Message, bool FutureConfirmed, bool LivePublished);
public sealed record AcceptedMemoryMode(string Mode, string RuntimeThreadId, DateTimeOffset AcceptedAt, long Generation);
public sealed record NativeThreadGoal(string ThreadId, string Objective, string Status, long? TokenBudget, long TokensUsed, long TimeUsedSeconds, long UpdatedAt);
public sealed record ThreadPersonalitySupport(string[] Choices, bool Deprecated, string Message);

/// <summary>Future thread defaults and one live turn have separate acknowledgements. No setting publication is presented as a completed inference.</summary>
public sealed class ThreadSettingsCoordinator : IAsyncDisposable
{
    readonly WorkspaceCoordinator workspace;
    readonly ConcurrentDictionary<string, SemaphoreSlim> gates = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, JsonElement> accepted = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, long> sequences = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, TaskCompletionSource<JsonElement>> pending = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, ThreadSettingsResult> results = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, AcceptedMemoryMode> memory = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, NativeThreadGoal> goals = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, long> goalVersions = new(StringComparer.Ordinal);
    readonly object generationSync = new();
    readonly object goalSync = new();
    long generation;
    bool disposed;
    public event Action? Changed;
    public ThreadSettingsCoordinator(WorkspaceCoordinator workspace) { this.workspace = workspace; generation = workspace.Runtime.Generation; workspace.RuntimeEventReceived += OnEvent; }
    public ThreadSettingsResult? Result(ThreadSession session) { CheckGeneration(); return results.GetValueOrDefault(session.Record.VeoId); }
    public JsonElement? AcceptedSettings(ThreadSession session) { CheckGeneration(); return session.Record.CodexThreadId is { } id && accepted.TryGetValue(id, out var value) ? value : null; }
    public AcceptedMemoryMode? MemoryMode(ThreadSession session) => memory.GetValueOrDefault(session.Record.VeoId);
    public NativeThreadGoal? Goal(ThreadSession session) { CheckGeneration(); return session.Record.CodexThreadId is { } id ? goals.GetValueOrDefault(id) : null; }
    public bool Available(string method) => workspace.Runtime.Capabilities.Availability(method) != CapabilityAvailability.Unavailable;
    async Task<JsonElement> Request(string method, object? value, CancellationToken ct)
    { using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(20)); return await workspace.Runtime.RequestAsync(method, value, timeout.Token); }
    public async Task<ThreadSettingsResult> ApplySelectionAsync(ThreadSession session, ComposerSnapshot selection, CancellationToken cancellation = default)
    {
        CheckGeneration();
        var sequence = sequences.AddOrUpdate(session.Record.VeoId, 1, (_, n) => n + 1); var gate = gates.GetOrAdd(session.Record.VeoId, _ => new(1, 1)); await gate.WaitAsync(cancellation);
        try
        {
            if (sequence != sequences[session.Record.VeoId]) return Result(session) ?? new("superseded", "A newer selection is waiting.", false, false);
            if (session.Record.CodexThreadId is not { } runtime) return Save(session, new("nextTurnOnly", "Saved in the composer for the next turn. This chat has no loaded runtime session.", false, false));
            if (selection.RoutingMode != "Direct") return Save(session, new("nextTurnOnly", "Routing choices resolve through the next submitted snapshot. The active turn is unchanged.", false, false));
            var generation = workspace.Runtime.Generation; var payload = new Dictionary<string, object?> { ["threadId"] = runtime, ["serviceTier"] = selection.Tier };
            if (selection.Model is { } model) payload["model"] = model; if (selection.Effort is { } effort) payload["effort"] = effort;
            var futureConfirmed = false;
            if (Available("thread/settings/update"))
            {
                try { var observed = await UpdateThreadAsync(runtime, payload, cancellation); futureConfirmed = observed is { } settings && Matches(settings, selection); }
                catch (Exception ex) when (ex is NotSupportedException || ex is CodexRpcException { Code: -32601 }) { }
            }
            if (generation != workspace.Runtime.Generation || sequence != sequences[session.Record.VeoId]) return Save(session, new("superseded", "Runtime or selection changed during publication. Refresh before applying again.", false, false));
            if (!session.Timeline.IsRunning) return Save(session, new("nextTurnOnly", futureConfirmed ? "Next-turn defaults confirmed by Codex. No turn is running." : "Saved in the composer for the next turn. Runtime defaults were not confirmed.", futureConfirmed, false));
            if (!Available("turn/settings/update")) return Save(session, new("nextTurnOnly", "This runtime does not support live settings. The next submitted snapshot retains your selection.", futureConfirmed, false));
            var turn = session.Timeline.ActiveTurnId;
            if (string.IsNullOrWhiteSpace(turn))
            {
                var read = await Request("thread/read", new { threadId = runtime, includeTurns = true }, cancellation);
                if (read.TryObjectProperty("thread", out var thread)) turn = IntegrationCoordinator.Rows(thread, "turns").LastOrDefault(x => x.Str("status") is "inProgress" or "running" or "active" || x.TryObjectProperty("status", out var state) && state.Str("type") is "inProgress" or "running" or "active").Str("id");
            }
            if (turn is null || !session.Timeline.IsRunning || generation != workspace.Runtime.Generation) return Save(session, new("nextTurnOnly", "The running turn no longer accepts this change. Your next-turn selection is retained.", futureConfirmed, false));
            var live = new Dictionary<string, object?>(payload) { ["turnId"] = turn };
            JsonElement response;
            try { response = await Request("turn/settings/update", live, cancellation); }
            catch (Exception ex) when (ex is NotSupportedException || ex is CodexRpcException { Code: -32601 }) { return Save(session, new("nextTurnOnly", "Live changes are unavailable in this runtime. The next submitted snapshot retains your selection.", futureConfirmed, false)); }
            if (sequence != sequences[session.Record.VeoId] || generation != workspace.Runtime.Generation) return Save(session, new("superseded", "A newer selection or runtime replaced this publication.", futureConfirmed, false));
            return response.Str("status") switch
            {
                "applied" => Save(session, new("published", "Published for later steps of the running turn. Already-started steps and child sessions keep their captured settings; another inference is not guaranteed.", futureConfirmed, true)),
                "targetUnavailable" => Save(session, new("nextTurnOnly", "The active turn finished or stopped accepting updates. Your next-turn selection is retained.", futureConfirmed, false)),
                _ => throw new InvalidDataException("Codex returned an unknown live settings status.")
            };
        }
        catch (Exception ex) { Save(session, new("failed", DiagnosticRedactor.Redact(ex.Message) + " Your composer selection remains available for the next turn.", false, false)); throw; }
        finally { gate.Release(); }
    }
    async Task<JsonElement?> UpdateThreadAsync(string runtime, Dictionary<string, object?> payload, CancellationToken ct)
    {
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!pending.TryAdd(runtime, completion)) throw new InvalidOperationException("Another thread settings write is awaiting acknowledgement.");
        try
        {
            await Request("thread/settings/update", payload, ct);
            try { return await completion.Task.WaitAsync(TimeSpan.FromSeconds(2), ct); } catch (TimeoutException) { return null; }
        }
        finally { pending.TryRemove(new KeyValuePair<string, TaskCompletionSource<JsonElement>>(runtime, completion)); }
    }
    static bool Matches(JsonElement settings, ComposerSnapshot selection) => (selection.Model is null || settings.Str("model") == selection.Model) && (selection.Effort is null || settings.Str("effort") == selection.Effort) && settings.TryGetProperty("serviceTier", out var tier) && (selection.Tier is null ? tier.ValueKind == JsonValueKind.Null : tier.ValueKind == JsonValueKind.String && tier.GetString() == selection.Tier);
    ThreadSettingsResult Save(ThreadSession session, ThreadSettingsResult result) { results[session.Record.VeoId] = result; Changed?.Invoke(); return result; }
    public Task SetMemoryModeAsync(ThreadSession session, string mode, CancellationToken cancellation = default) => MutateAsync(session, async () =>
    {
        if (mode is not ("enabled" or "disabled")) throw new ArgumentException("Select enabled or disabled.", nameof(mode));
        var runtime = session.Record.CodexThreadId ?? throw new InvalidOperationException("Load a runtime chat before changing memory mode.");
        var generation = workspace.Runtime.Generation; await Request("thread/memoryMode/set", new { threadId = runtime, mode }, cancellation);
        if (generation != workspace.Runtime.Generation) throw new InvalidOperationException("The runtime changed before memory mode could be acknowledged.");
        var receipt = new AcceptedMemoryMode(mode, runtime, DateTimeOffset.UtcNow, generation); memory[session.Record.VeoId] = receipt;
        await workspace.Threads.SaveStateAsync(session.Record.VeoId, "memory-mode", JsonSerializer.Serialize(receipt)); Changed?.Invoke();
    }, cancellation);
    public async Task LoadAsync(ThreadSession session, CancellationToken cancellation = default)
    {
        if (await workspace.Threads.ReadStateAsync(session.Record.VeoId, "memory-mode") is { } saved)
        { try { var receipt = JsonSerializer.Deserialize<AcceptedMemoryMode>(saved); if (receipt is not null && receipt.RuntimeThreadId == session.Record.CodexThreadId) memory[session.Record.VeoId] = receipt; } catch (JsonException) { } }
        if (session.Record.CodexThreadId is not null && Available("thread/goal/get")) await RefreshGoalAsync(session, cancellation); Changed?.Invoke();
    }
    public async Task<NativeThreadGoal?> RefreshGoalAsync(ThreadSession session, CancellationToken cancellation = default)
    {
        CheckGeneration(); var runtime = session.Record.CodexThreadId ?? throw new InvalidOperationException("Load a runtime chat before reading its goal."); long observed; lock (goalSync) observed = goalVersions.GetValueOrDefault(runtime); var currentGeneration = workspace.Runtime.Generation; var response = await Request("thread/goal/get", new { threadId = runtime }, cancellation);
        if (currentGeneration != workspace.Runtime.Generation) throw new InvalidOperationException("The runtime changed while reading this goal.");
        lock (goalSync) if (goalVersions.GetValueOrDefault(runtime) == observed) { if (response.TryObjectProperty("goal", out var goal)) goals[runtime] = ParseGoal(goal); else goals.TryRemove(runtime, out _); }
        Changed?.Invoke(); return Goal(session);
    }
    public NativeThreadGoal? ActiveGoal(ThreadSession session) => Goal(session) is { } goal
        && !goal.Status.Equals("complete", StringComparison.OrdinalIgnoreCase) ? goal : null;

    public bool ComposerGoalEnabled(ThreadSession session) =>
        session.ComposerGoalArmed || HasActiveComposerGoal(session);

    public bool HasActiveComposerGoal(ThreadSession session) =>
        session.HasManagedGoal || ActiveGoal(session) is not null || session.Queue.Any(submission => submission.StartGoal);

    public async Task SelectComposerGoalModeAsync(ThreadSession session, ComposerGoalMode mode, CancellationToken cancellation = default)
    {
        await session.DispatchGate.WaitAsync(cancellation);
        try
        {
            if (HasActiveComposerGoal(session)) throw new InvalidOperationException("Stop the active goal before changing its mode.");
            await workspace.ManagedGoals.SelectAsync(session, mode, cancellation);
            Changed?.Invoke();
        }
        finally { session.DispatchGate.Release(); }
    }

    public async Task SetComposerGoalModeAsync(ThreadSession session, bool enabled, CancellationToken cancellation = default)
    {
        await session.DispatchGate.WaitAsync(cancellation);
        try
        {
            if (enabled)
            {
                if (!ComposerGoalEnabled(session)) session.ComposerGoalArmed = true;
            }
            else
            {
                if (ActiveGoal(session) is not null) await ClearGoalAsync(session, cancellation);
                await workspace.ManagedGoals.StopAsync(session, cancellation);
                await workspace.ClearQueuedComposerGoalsAsync(session);
                session.ComposerGoalArmed = false;
            }
            Changed?.Invoke();
        }
        finally { session.DispatchGate.Release(); }
    }

    public Task PrepareComposerGoalAsync(ThreadSession session, string objective, CancellationToken cancellation) =>
        MutateAsync(session, async () =>
        {
            await RefreshGoalAsync(session, cancellation);
            if (ActiveGoal(session) is { } existing)
            {
                if (existing.Objective != objective) throw new InvalidOperationException("This chat already has an active goal.");
                return;
            }
            await SetGoalCoreAsync(session, objective, null, activate: true, cancellation);
        }, cancellation);

    public Task SetGoalAsync(ThreadSession session, string objective, long? tokenBudget = null, CancellationToken cancellation = default) =>
        MutateAsync(session, () => SetGoalCoreAsync(session, objective, tokenBudget, activate: false, cancellation), cancellation);

    async Task SetGoalCoreAsync(ThreadSession session, string objective, long? tokenBudget, bool activate, CancellationToken cancellation)
    {
        if (string.IsNullOrWhiteSpace(objective)) throw new InvalidOperationException("Write the goal you want this chat to pursue.");
        if (tokenBudget is <= 0) throw new InvalidOperationException("A token budget must be positive, or left blank.");
        var runtime = session.Record.CodexThreadId ?? throw new InvalidOperationException("Load a runtime chat before setting its goal.");
        var text = objective.Trim();
        var parameters = new Dictionary<string, object?> { ["threadId"] = runtime, ["objective"] = text, ["origin"] = "user" };
        if (tokenBudget is { } budget) parameters["tokenBudget"] = budget;
        if (activate) parameters["status"] = "active";
        await Request("thread/goal/set", parameters, cancellation);
        var actual = await RefreshGoalAsync(session, cancellation);
        if (actual?.Objective != text || tokenBudget is not null && actual.TokenBudget != tokenBudget || activate && actual.Status != "active")
            throw new IOException("Codex did not confirm the requested goal.");
    }
    public Task SetGoalStatusAsync(ThreadSession session, string status, CancellationToken cancellation = default) => MutateAsync(session, async () =>
    {
        if (status is not ("active" or "paused" or "complete")) throw new InvalidOperationException("Choose Resume, Pause or Complete.");
        var runtime = session.Record.CodexThreadId ?? throw new InvalidOperationException("Load a runtime chat first."); if (await RefreshGoalAsync(session, cancellation) is null) throw new InvalidOperationException("This chat has no goal.");
        await Request("thread/goal/set", new { threadId = runtime, status, origin = "user" }, cancellation); if ((await RefreshGoalAsync(session, cancellation))?.Status != status) throw new IOException("Codex did not confirm the requested goal status.");
    }, cancellation);
    public Task ClearGoalAsync(ThreadSession session, CancellationToken cancellation = default) => MutateAsync(session, async () =>
    { var runtime = session.Record.CodexThreadId ?? throw new InvalidOperationException("Load a runtime chat first."); await Request("thread/goal/clear", new { threadId = runtime, origin = "user" }, cancellation); if (await RefreshGoalAsync(session, cancellation) is not null) throw new IOException("Codex still reports a goal."); }, cancellation);
    public ThreadPersonalitySupport PersonalitySupport()
    {
        var directory = workspace.Runtime.Capabilities.SchemaDirectory; if (directory is null) return new([], false, "This runtime supplied no verified personality schema.");
        var path = Path.Combine(directory, "v2", "ThreadSettingsUpdateParams.json"); if (!File.Exists(path)) return new([], false, "This runtime supplied no personality update schema.");
        using var document = JsonDocument.Parse(File.ReadAllBytes(path));
        if (!document.RootElement.TryObjectProperty("definitions", out var definitions) || !definitions.TryObjectProperty("Personality", out var definition)) return new([], false, "This runtime does not expose a personality setting.");
        var description = definition.Str("description") ?? ""; var deprecated = description.Contains("Deprecated", StringComparison.OrdinalIgnoreCase) || description.Contains("no longer", StringComparison.OrdinalIgnoreCase);
        var choices = definition.TryGetProperty("enum", out var values) ? values.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray() : [];
        return new(choices, deprecated, deprecated ? "This CLI deprecated personality styles. Friendly and Pragmatic no longer select a style, and saving the legacy value does not rewrite existing instructions." : description);
    }
    public async Task SetPersonalityAsync(ThreadSession session, string choice, CancellationToken cancellation = default)
    {
        var support = PersonalitySupport(); if (support.Deprecated) throw new NotSupportedException(support.Message); if (!support.Choices.Contains(choice, StringComparer.Ordinal)) throw new InvalidOperationException("Choose a personality supplied by this runtime.");
        var runtime = session.Record.CodexThreadId ?? throw new InvalidOperationException("Load a runtime chat first."); var result = await UpdateThreadAsync(runtime, new() { ["threadId"] = runtime, ["personality"] = choice }, cancellation);
        if (result?.Str("personality") != choice) throw new IOException("The runtime did not confirm this personality setting."); Changed?.Invoke();
    }
    void OnEvent(RuntimeEvent message)
    {
        CheckGeneration();
        if (disposed || message.Parameters.Str("threadId") is not { } runtime) return; var p = message.Parameters;
        if (message.Method == "thread/settings/updated" && p.TryObjectProperty("threadSettings", out var settings)) { accepted[runtime] = settings.Clone(); if (pending.TryGetValue(runtime, out var completion)) completion.TrySetResult(settings.Clone()); Changed?.Invoke(); }
        else if (message.Method == "thread/goal/updated" && p.TryObjectProperty("goal", out var raw)) { var goal = ParseGoal(raw); lock (goalSync) { goalVersions.AddOrUpdate(runtime, 1, (_, n) => n + 1); goals.AddOrUpdate(runtime, goal, (_, old) => old.UpdatedAt > goal.UpdatedAt ? old : goal); } Changed?.Invoke(); }
        else if (message.Method == "thread/goal/cleared") { lock (goalSync) { goalVersions.AddOrUpdate(runtime, 1, (_, n) => n + 1); goals.TryRemove(runtime, out _); } Changed?.Invoke(); }
    }
    async Task MutateAsync(ThreadSession session, Func<Task> action, CancellationToken cancellation)
    { CheckGeneration(); var gate = gates.GetOrAdd(session.Record.VeoId, _ => new(1, 1)); await gate.WaitAsync(cancellation); try { await action(); } finally { gate.Release(); } }
    void CheckGeneration()
    {
        var current = workspace.Runtime.Generation; if (current == Interlocked.Read(ref generation)) return;
        lock (generationSync)
        {
            if (current == generation) return; generation = current; accepted.Clear(); results.Clear(); lock (goalSync) { goals.Clear(); goalVersions.Clear(); } foreach (var entry in pending.ToArray()) if (pending.TryRemove(entry)) entry.Value.TrySetCanceled();
        }
    }
    static NativeThreadGoal ParseGoal(JsonElement goal) => new(goal.Str("threadId") ?? throw new InvalidDataException("Goal thread missing."), goal.Str("objective") ?? "", goal.Str("status") ?? "unknown", AccountCoordinator.Number(goal, "tokenBudget"), AccountCoordinator.Number(goal, "tokensUsed") ?? 0, AccountCoordinator.Number(goal, "timeUsedSeconds") ?? 0, AccountCoordinator.Number(goal, "updatedAt") ?? 0);
    public ValueTask DisposeAsync() { disposed = true; workspace.RuntimeEventReceived -= OnEvent; foreach (var completion in pending.Values) completion.TrySetCanceled(); return ValueTask.CompletedTask; }
}
