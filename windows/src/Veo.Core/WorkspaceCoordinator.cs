using System.Collections.Concurrent;
using System.Text.Json;
using Veo.Infrastructure.Storage;
using Veo.Protocol;

namespace Veo.Core;

public sealed record ModelOption(string Id, string Name, string Description, string DefaultEffort, string[] Efforts, string[] Tiers);
public sealed record ComposerSnapshot(string ClientId, string Text, string? Model, string? Effort, string? Tier, string Access, string Mode, string[] Attachments, bool PreserveDraft = false, long? ContextTokens = null, string RoutingMode = "Direct", AutoRouterPolicy? RouterPolicy = null, FamilyAutoPlan? FamilyPlan = null, VisionFallbackContext? VisionFallback = null, string? CatalogModelId = null, ComposerAttachment[]? StructuredAttachments = null, string? DraftOptionsJson = null, bool? Daybreak = null, bool StartGoal = false)
{
    public ComposerSnapshot Freeze() => this with
    {
        Attachments = Attachments.ToArray(),
        StructuredAttachments = StructuredAttachments?.ToArray(),
        FamilyPlan = FamilyPlan is { } family ? family with { Warnings = family.Warnings.ToArray() } : null,
        VisionFallback = VisionFallback is { } vision ? vision with { Images = vision.Images.ToArray() } : null
    };
}
public sealed class ThreadSession(PersistedThread record)
{
    readonly object queueSync = new();
    readonly List<ComposerSnapshot> queue = [];
    internal SemaphoreSlim LoadGate { get; } = new(1, 1);
    internal SemaphoreSlim PersistenceGate { get; } = new(1, 1);
    internal SemaphoreSlim DispatchGate { get; } = new(1, 1);
    internal bool IsLoaded { get; set; }
    internal int QueueDispatchScheduled;
    public PersistedThread Record { get; internal set; } = record;
    public TimelineReducer Timeline { get; } = new();
    public PersistedDraft Draft { get; internal set; } = new("");
    public IReadOnlyList<ComposerSnapshot> Queue { get { lock (queueSync) return queue.Select(x => x.Freeze()).ToArray(); } }
    internal void Enqueue(ComposerSnapshot snapshot) { lock (queueSync) if (queue.All(x => x.ClientId != snapshot.ClientId)) queue.Add(snapshot.Freeze()); }
    internal void RemoveQueued(string id) { lock (queueSync) queue.RemoveAll(x => x.ClientId == id); }
    internal void RestoreQueue(IEnumerable<ComposerSnapshot> snapshots) { lock (queueSync) { queue.Clear(); queue.AddRange(snapshots.Select(x => x.Freeze())); } }
    public string? DispatchWarning { get; internal set; }
    public string EffectiveAccess { get; internal set; } = "Workspace";
    public bool IsSubmitting { get; internal set; }
    public bool ComposerGoalArmed { get; internal set; }
    public bool CanToggleTemporaryChat => Record.WorkspaceKind is "scratch" or "temporary"
        && Record.CodexThreadId is null && !IsSubmitting && !Timeline.IsRunning && Timeline.Items.Count == 0;
}

/// <summary>Application ownership and coordination; each window retains its own selected thread.</summary>
public sealed class WorkspaceCoordinator : IAsyncDisposable
{
    readonly ConcurrentDictionary<string, ThreadSession> sessions = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, RuntimeEvent> requests = new(StringComparer.Ordinal);
    readonly CancellationTokenSource lifetime = new();
    readonly PreferencesStore preferences;
    readonly Func<VeoPreferences, CodexRuntimeService>? runtimeFactory;
    readonly DynamicToolBridge dynamicTools;
    Task? events;
    string? runtimeExecutableOverride;
    int changedPending;
    public string DataRoot { get; }
    public ThreadRepository Threads { get; }
    public CodexRuntimeService Runtime { get; private set; }
    public VeoPreferences Preferences { get; private set; } = new();
    public IReadOnlyList<ModelOption> Models { get; private set; } = [];
    public JsonElement Account { get; private set; }
    public JsonElement RateLimits { get; private set; }
    public string Status { get; private set; } = "Opening local workspace…";
    public IReadOnlyCollection<RuntimeEvent> PendingRequests => requests.Values.ToArray();
    public event Action? Changed;
    public event Action<Uri>? OpenBrowser;
    public event Action<ThreadSession, RuntimeEvent>? RuntimeEventApplied;
    public event Action<RuntimeEvent>? RuntimeNotificationReceived;
    public Func<ThreadSession, ComposerSnapshot, bool, Task>? BeforeDispatchAsync { get; set; }
    public Func<ThreadSession, string, CancellationToken, Task>? PrepareComposerGoalAsync { get; set; }
    public Func<ThreadSession, ComposerSnapshot, CancellationToken, Task>? CaptureTurnCheckpointAsync { get; set; }
    public Func<ThreadSession, ComposerSnapshot, string, CancellationToken, Task>? BindTurnCheckpointAsync { get; set; }
    internal SemaphoreSlim CheckpointRestoreGate { get; } = new(1, 1);
    public Func<ThreadSession, ComposerSnapshot, CancellationToken, Task<ComposerSnapshot>>? PreparePayloadAsync { get; set; }
    public event Action<RuntimeEvent>? RuntimeEventReceived;
    public Func<RuntimeEvent, bool>? TryHandleRuntimeEvent { get; set; }
    public IReadOnlyList<ThreadSession> LoadedSessions => sessions.Values.ToArray();
    public void NotifyChanged() => ScheduleChanged();
    public Func<ThreadSession, ComposerSnapshot, CancellationToken, Task>? QueueAddedAsync { get; set; }
    public Func<ThreadSession, ComposerSnapshot, CancellationToken, Task<bool>>? TryDispatchQueuedAsync { get; set; }

    public WorkspaceCoordinator(string dataRoot, Func<VeoPreferences, CodexRuntimeService>? runtimeFactory = null)
    {
        this.runtimeFactory = runtimeFactory;
        DataRoot = dataRoot; Directory.CreateDirectory(dataRoot);
        Threads = new(Path.Combine(dataRoot, "Threads", "veo.sqlite")); preferences = new(dataRoot);
        Runtime = new();
        dynamicTools = new(id => sessions.Values.FirstOrDefault(x => x.Record.CodexThreadId == id) is { } thread ? new(thread.Record.Cwd, thread.EffectiveAccess, id) : null, ListBackgroundTerminalsAsync);
    }
    public async Task InitializeAsync()
    {
        await Threads.InitializeAsync(lifetime.Token);
        Preferences = await preferences.LoadAsync();
        foreach (var stored in await Threads.ListThreadsAsync(limit: 10000))
        {
            var record = stored;
            // An MSIX development identity can virtualize the logical LocalAppData path.
            // App-managed workspaces are anchored to the actual profile root before external tools see cwd.
            var managed = Path.Combine(DataRoot, "Workspaces", record.VeoId);
            if (record.WorkspaceKind is "scratch" or "temporary" && Directory.Exists(managed)
                && Path.GetFileName(record.Cwd.TrimEnd(Path.DirectorySeparatorChar)) == record.VeoId && record.Cwd != managed)
            { record = record with { Cwd = managed }; await Threads.UpsertThreadAsync(record); }
            sessions[record.VeoId] = new(record);
        }
        Status = "Connecting to local Codex…"; ScheduleChanged();
        await Runtime.DisposeAsync();
        Runtime = CreateRuntime();
        runtimeExecutableOverride = Preferences.CodexExecutable;
        Runtime.Faulted += OnRuntimeFault;
        events = ConsumeEventsAsync();
        try { await ConnectAsync(); }
        catch (Exception e) { Status = "Codex unavailable: " + DiagnosticRedactor.Redact(e.Message); ScheduleChanged(); }
    }
    CodexRuntimeService CreateRuntime() => runtimeFactory?.Invoke(Preferences) ?? new(new CodexRuntimeOptions
    {
        ExecutablePath = Preferences.CodexExecutable,
        SchemaDirectory = Path.Combine(DataRoot, "Runtime", "Schema"), GenerateSchemaOnStart = true
    });
    void OnRuntimeFault(long generation, string error)
    {
        Status = "Codex disconnected: " + error;
        foreach (var session in sessions.Values.Where(x => x.Timeline.IsRunning))
            session.DispatchWarning = "The runtime disconnected. Reconnect to reconcile the active turn before sending again.";
        ScheduleChanged();
    }
    public async Task ConnectAsync()
    {
        await Runtime.StartAsync(lifetime.Token);
        await LoadModelsAsync();
        Account = await Runtime.RequestAsync("account/read", new { refreshToken = false }, lifetime.Token);
        foreach (var session in sessions.Values.Where(x => x.Record.CodexThreadId is not null && (x.Record.VeoId == Preferences.SelectedThread || x.Record.Status == "running")))
            await RehydrateAsync(session);
        Status = "Connected · local stdio"; ScheduleChanged();
    }
    public async Task ReconnectAsync()
    {
        requests.Clear();
        if (!string.Equals(runtimeExecutableOverride, Preferences.CodexExecutable, StringComparison.OrdinalIgnoreCase))
        {
            Runtime.Faulted -= OnRuntimeFault;
            await Runtime.DisposeAsync(); if (events is not null) await events;
            Runtime = CreateRuntime(); runtimeExecutableOverride = Preferences.CodexExecutable;
            Runtime.Faulted += OnRuntimeFault; events = ConsumeEventsAsync();
        }
        else await Runtime.StopAsync(lifetime.Token);
        await ConnectAsync();
        foreach (var session in sessions.Values.Where(x => x.Record.CodexThreadId is not null))
            await RehydrateAsync(session);
    }
    async Task LoadModelsAsync()
    {
        var generation = Runtime.Generation;
        var catalog = await Runtime.RequestAsync("model/list", new { includeHidden = false }, lifetime.Token);
        if (!catalog.TryGetProperty("data", out var data)) return;
        RememberDaybreakModels(data.EnumerateArray().Where(x => !x.TryGetProperty("hidden", out var hidden) || hidden.ValueKind != JsonValueKind.True)
            .Select(NativeModelDescriptor.Parse).OfType<NativeModelDescriptor>(), generation);
        Models = data.EnumerateArray().Where(x => !x.TryGetProperty("hidden", out var h) || !h.GetBoolean()).Select(x => new ModelOption(
            x.Str("model") ?? x.Str("id")!, x.Str("displayName") ?? x.Str("id")!, x.Str("description") ?? "",
            x.Str("defaultReasoningEffort") ?? "",
            x.TryGetProperty("supportedReasoningEfforts", out var efforts) ? efforts.EnumerateArray().Select(e => e.Str("reasoningEffort") ?? "").Where(e => e.Length > 0).ToArray() : [],
            x.TryGetProperty("serviceTiers", out var tiers) ? tiers.EnumerateArray().Select(t => t.ValueKind == JsonValueKind.String ? t.GetString()! : t.Str("id") ?? "").Where(t => t.Length > 0).ToArray() : []
        )).ToArray();
    }

    private sealed record DaybreakCatalog(long Generation, NativeModelDescriptor[] Models);
    private volatile DaybreakCatalog? daybreakCatalog;

    internal void RememberDaybreakModels(IEnumerable<NativeModelDescriptor> models, long generation)
    {
        if (generation != Runtime.Generation) return;
        daybreakCatalog = new(generation, models.Where(model => model.SupportsDaybreakBlue || model.SupportsStandardCyberAccess).ToArray());
    }

    internal bool SupportsDaybreakSelection => CurrentDaybreakCatalog() is not null;

    private DaybreakCatalog? CurrentDaybreakCatalog()
    {
        var runtime = Runtime;
        var catalog = daybreakCatalog;
        return runtime.RuntimeState == CodexRuntimeState.Ready &&
            catalog is { Models.Length: > 0 } && catalog.Generation == runtime.Generation &&
            runtime.Capabilities.SupportsTurnCyberAccessProgram("daybreakBlue") &&
            runtime.Capabilities.SupportsTurnCyberAccessProgram("standard") ? catalog : null;
    }

    string? DaybreakProgram(ComposerSnapshot payload)
    {
        if (payload.Daybreak is not { } enabled) return null;
        if (payload.RoutingMode != "Direct" || payload.FamilyPlan is not null)
            throw new InvalidOperationException("Choose a direct Codex model to change Daybreak access.");
        if (CurrentDaybreakCatalog()?.Models.Any(model => model.Model == payload.Model &&
            (payload.CatalogModelId is null || model.Id == payload.CatalogModelId) &&
            (enabled ? model.SupportsDaybreakBlue : model.SupportsStandardCyberAccess)) != true)
        {
            var program = enabled ? "Daybreak Blue" : "Standard";
            throw new InvalidOperationException($"The selected Codex runtime and model do not advertise {program}. Choose a compatible model or review the saved message settings.");
        }
        return enabled ? "daybreakBlue" : "standard";
    }
    public Task SavePreferencesAsync() => preferences.SaveAsync(Preferences);
    public async Task<IReadOnlyList<PersistedThread>> CatalogAsync(string? search = null) => await Threads.ListThreadsAsync(Preferences.ShowArchived, search, 10000);
    public async Task<ThreadSession> CreateAsync(string? directory = null)
    {
        var id = Guid.NewGuid().ToString("N");
        var cwd = directory is null ? Path.Combine(DataRoot, "Workspaces", id) : Path.GetFullPath(directory);
        if (directory is null) Directory.CreateDirectory(cwd);
        else if (!Directory.Exists(cwd)) throw new DirectoryNotFoundException(cwd);
        var record = new PersistedThread(id, null, cwd, "New chat", UpdatedAt: DateTimeOffset.UtcNow, WorkspaceKind: directory is null ? "scratch" : "project");
        await Threads.UpsertThreadAsync(record); var session = new ThreadSession(record) { IsLoaded = true }; sessions[id] = session;
        ScheduleChanged(); return session;
    }
    public async Task<ThreadSession> LoadAsync(PersistedThread record)
    {
        var session = sessions.GetOrAdd(record.VeoId, _ => new(record));
        await session.LoadGate.WaitAsync(lifetime.Token);
        try
        {
        if (session.IsLoaded) return session;
        session.Draft = await Threads.ReadDraftAsync(record.VeoId) ?? new("");
        var cached = await Threads.ReadItemsAsync(record.VeoId, limit: 10000);
        var cachedTurns = await Threads.ReadTurnsAsync(record.VeoId, lifetime.Token);
        session.Timeline.ObserveTurns(cachedTurns.Select(t => new TimelineTurn(t.TurnId, t.Status, t.StartedAt, t.ErrorJson, t.SortIndex, t.TerminalObserved)));
        session.Timeline.Reconcile(cached.Select(i => new TimelineItem(i.ItemId, i.TurnId, i.Type ?? "unknown", TextFromRaw(i.RawJson), i.Status ?? "completed", JsonSerializer.Deserialize<JsonElement>(i.RawJson), i.SortIndex)), false, null);
        var queue = await Threads.ReadStateAsync(record.VeoId, "queue");
        if (queue is not null) session.RestoreQueue(JsonSerializer.Deserialize<List<ComposerSnapshot>>(queue) ?? []);
        var pending = await Threads.ReadStateAsync(record.VeoId, "dispatch");
        if (pending is not null)
        {
            using var dispatch = JsonDocument.Parse(pending);
            if (dispatch.RootElement.Str("state") is not ("complete" or "rejected")) session.DispatchWarning = "A previous send needs history reconciliation. It will not be resent automatically.";
        }
        if (Runtime.RuntimeState == CodexRuntimeState.Ready && record.CodexThreadId is not null) await RehydrateAsync(session);
        session.IsLoaded = true;
        return session;
        }
        finally { session.LoadGate.Release(); }
    }
    public async Task RehydrateAsync(ThreadSession session)
    {
        if (session.Record.CodexThreadId is not { } runtimeId) return;
        var stateVersion = session.Timeline.StateVersion;
        var response = await Runtime.RequestAsync("thread/resume", new { threadId = runtimeId, cwd = session.Record.Cwd }, lifetime.Token);
        var thread = response.GetProperty("thread");
        var history = new List<TimelineItem>(); string? active = null;
        var running = RuntimeStatus(thread) is "inProgress" or "running" or "active";
        if (thread.TryGetProperty("turns", out var turns))
            foreach (var turn in turns.EnumerateArray())
            {
                session.Timeline.ObserveTurnMetadata(turn);
                var turnId = turn.Str("id");
                if (RuntimeStatus(turn) is "inProgress" or "running" or "active") { active = turnId; running = true; }
                if (!turn.TryGetProperty("items", out var items)) continue;
                foreach (var item in items.EnumerateArray())
                    if (item.Str("id") is { } id) history.Add(new(id, turnId, item.Str("type") ?? "unknown", TimelineReducer.ExtractText(item), item.Str("status") ?? "completed", item.Clone(), history.Count));
            }
        session.Timeline.Reconcile(history, running, active, stateVersion);
        if (session.DispatchWarning is not null)
        {
            var dispatchJson = await Threads.ReadStateAsync(session.Record.VeoId, "dispatch");
            if (dispatchJson is not null)
            {
                using var dispatch = JsonDocument.Parse(dispatchJson);
                var sendWarning = session.DispatchWarning.StartsWith("A previous send", StringComparison.Ordinal) || session.DispatchWarning.StartsWith("Send outcome", StringComparison.Ordinal);
                if (sendWarning && dispatch.RootElement.Str("state") is "complete" or "rejected") session.DispatchWarning = null;
                if (dispatch.RootElement.TryGetProperty("payload", out var payload) && (payload.Str("ClientId") ?? payload.Str("clientId")) is { } clientId
                    && history.Any(item => item.Kind == "userMessage" && (item.Raw.Str("clientId") == clientId || item.Raw.Str("clientUserMessageId") == clientId)))
                {
                    await Threads.SaveStateAsync(session.Record.VeoId, "dispatch", "{\"state\":\"complete\"}");
                    if (sendWarning) session.DispatchWarning = null;
                }
            }
        }
        await PersistTimelineAsync(session); ScheduleChanged();
    }
    public async Task SaveDraftAsync(ThreadSession session, string text, string[]? attachments = null, string? options = null)
    {
        session.Draft = new(text, attachments is null ? session.Draft.AttachmentsJson : JsonSerializer.Serialize(attachments), options ?? session.Draft.OptionsJson, DateTimeOffset.UtcNow);
        await Threads.SaveDraftAsync(session.Record.VeoId, session.Draft);
    }
    public async Task RenameAsync(ThreadSession session, string title)
    {
        session.Record = session.Record with { Title = title.Trim(), UpdatedAt = DateTimeOffset.UtcNow };
        await Threads.UpsertThreadAsync(session.Record); ScheduleChanged();
    }
    public async Task SetArchivedAsync(ThreadSession session, bool archived)
    {
        if (session.Timeline.IsRunning) throw new InvalidOperationException("Stop the active turn before archiving this chat.");
        session.Record = session.Record with { IsArchived = archived }; await Threads.UpsertThreadAsync(session.Record); ScheduleChanged();
    }
    public async Task SetPinnedAsync(ThreadSession session, bool pinned)
    { session.Record = session.Record with { IsPinned = pinned }; await Threads.UpsertThreadAsync(session.Record); ScheduleChanged(); }
    public Task MakeTemporaryAsync(ThreadSession session) => ChangeTemporaryChatAsync(session, enableOnly: true);

    public Task ToggleTemporaryChatAsync(ThreadSession session) => ChangeTemporaryChatAsync(session, enableOnly: false);

    async Task ChangeTemporaryChatAsync(ThreadSession session, bool enableOnly)
    {
        await session.DispatchGate.WaitAsync(lifetime.Token);
        try
        {
            var kind = session.Record.WorkspaceKind;
            if (!session.CanToggleTemporaryChat || (enableOnly && kind != "scratch"))
                throw new InvalidOperationException("Only an unused projectless chat can change temporary status.");
            var updated = session.Record with { WorkspaceKind = kind == "scratch" ? "temporary" : "scratch" };
            await Threads.UpsertThreadAsync(updated);
            session.Record = updated;
            ScheduleChanged();
        }
        finally { session.DispatchGate.Release(); }
    }
    public async Task DeleteAsync(ThreadSession session)
    {
        if (session.Timeline.IsRunning) throw new InvalidOperationException("Stop the active turn first.");
        await Threads.DeleteThreadAsync(session.Record.VeoId); sessions.TryRemove(session.Record.VeoId, out _); ScheduleChanged();
    }
    public async Task SubmitAsync(ThreadSession session, ComposerSnapshot payload)
    {
        payload = payload.Freeze();
        await session.DispatchGate.WaitAsync(lifetime.Token);
        session.IsSubmitting = true; ScheduleChanged();
        try
        {
            if (payload.StartGoal)
            {
                if (!session.ComposerGoalArmed) payload = payload with { StartGoal = false };
                else if (string.IsNullOrWhiteSpace(payload.Text)) throw new InvalidOperationException("Write a goal before sending.");
            }
            if (session.Timeline.IsRunning)
            {
                session.Enqueue(payload); await SaveQueueAsync(session);
                if (payload.StartGoal) session.ComposerGoalArmed = false;
                if (QueueAddedAsync is { } added) await added(session, payload, lifetime.Token);
                if (!payload.PreserveDraft) await SaveDraftAsync(session, "", []); ScheduleChanged(); return;
            }
            await DispatchAsync(session, payload);
            if (payload.StartGoal) session.ComposerGoalArmed = false;
        }
        finally { session.IsSubmitting = false; session.DispatchGate.Release(); ScheduleChanged(); }
    }
    async Task<string> DispatchAsync(ThreadSession session, ComposerSnapshot payload, bool fromQueue = false, bool isContinuation = false)
    {
        foreach (var domain in new[] { "history-revert", "queue-steer" })
        {
            if (await Threads.ReadStateAsync(session.Record.VeoId, domain, lifetime.Token) is not { } uncertain) continue;
            using var operation = JsonDocument.Parse(uncertain);
            if (operation.RootElement.Str("state") == "pending") throw new InvalidOperationException("A previous " + (domain == "history-revert" ? "history change" : "steer request") + " needs reconciliation. Inspect that operation before sending again.");
        }
        if (session.DispatchWarning is not null) throw new InvalidOperationException(session.DispatchWarning);
        if (Runtime.RuntimeState != CodexRuntimeState.Ready) throw new InvalidOperationException("Connect Codex in Runtime settings first. Your draft has been kept.");
        _ = DaybreakProgram(payload);
        if (PreparePayloadAsync is { } preparePayload && !isContinuation) payload = await preparePayload(session, payload, lifetime.Token);
        _ = DaybreakProgram(payload);
        await Threads.SaveStateAsync(session.Record.VeoId, "model-route", JsonSerializer.Serialize(new { routingMode = payload.RoutingMode == "Direct" ? "direct" : payload.RoutingMode, payload = payload.Freeze() }), lifetime.Token);
        if (BeforeDispatchAsync is { } beforeDispatch) await beforeDispatch(session, payload, isContinuation);
        if (session.Record.CodexThreadId is null)
        {
            await StartRuntimeThreadCoreAsync(session, payload, lifetime.Token);
        }
        await CheckpointRestoreGate.WaitAsync(lifetime.Token);
        try
        {
            if (payload.StartGoal && !isContinuation)
            {
                if (PrepareComposerGoalAsync is not { } prepareGoal) throw new InvalidOperationException("Goals are unavailable in this workspace.");
                await prepareGoal(session, payload.Text.Trim(), lifetime.Token);
            }
            return await StartTurnAsync(session, payload, fromQueue);
        }
        finally { CheckpointRestoreGate.Release(); }
    }
    async Task<string> StartTurnAsync(ThreadSession session, ComposerSnapshot payload, bool fromQueue)
    {
        var daybreak = DaybreakProgram(payload);
        if (CaptureTurnCheckpointAsync is { } captureCheckpoint) await captureCheckpoint(session, payload, lifetime.Token);
        await Threads.SaveStateAsync(session.Record.VeoId, "dispatch", JsonSerializer.Serialize(new { state = "pending", payload }));
        session.EffectiveAccess = payload.Access;
        if (fromQueue) { session.RemoveQueued(payload.ClientId); await SaveQueueAsync(session); }
        session.Timeline.AddLocal(payload.ClientId, "userMessage", payload.Text, status: "pending");
        await PersistTimelineAsync(session); var dispatchVersion = session.Timeline.BeginPending(); ScheduleChanged();
        var input = ComposerProtocol.Input(payload);
        var request = new Dictionary<string, object?>
        {
            ["threadId"] = session.Record.CodexThreadId, ["clientUserMessageId"] = payload.ClientId,
            ["input"] = input, ["cwd"] = session.Record.Cwd, ["approvalPolicy"] = "on-request",
            ["sandboxPolicy"] = ComposerProtocol.SandboxPolicy(payload.Access, session.Record.Cwd), ["model"] = payload.Model,
            ["effort"] = payload.Effort, ["serviceTier"] = payload.Tier,
        };
        if (daybreak is not null) request["cyberAccessProgram"] = daybreak;
        var familyInstructions = payload.FamilyPlan is { } familyPlan ? FamilyAutoRouting.Instructions(familyPlan, payload.Mode) : null;
        if ((payload.Mode == "Plan" || familyInstructions is not null) && payload.Model is not null)
            request["collaborationMode"] = new { mode = payload.Mode == "Plan" ? "plan" : "default", settings = new { model = payload.Model, reasoning_effort = payload.Effort, developer_instructions = familyInstructions } };
        if (payload.Mode == "Debug") request["additionalContext"] = new { veo_debug = new { kind = "application", name = "Veo Debug", value = "Investigate with evidence before changing code. Reproduce, form hypotheses, inspect relevant state, make a focused fix, and verify the result." } };
        try
        {
            var response = await Runtime.RequestAsync("turn/start", request, lifetime.Token);
            var turn = response.GetProperty("turn");
            var turnId = turn.Str("id");
            session.Timeline.ObserveTurnMetadata(turn);
            session.Timeline.AcknowledgeStart(dispatchVersion, turnId);
            if (turnId is not null && BindTurnCheckpointAsync is { } bindCheckpoint)
                await bindCheckpoint(session, payload, turnId, lifetime.Token);
            await PersistTimelineAsync(session);
            session.Record = session.Record with { Preview = payload.Text, Title = session.Record.Title == "New chat" ? payload.Text[..Math.Min(70, payload.Text.Length)].Replace('\n', ' ') : session.Record.Title, UpdatedAt = DateTimeOffset.UtcNow };
            await Threads.UpsertThreadAsync(session.Record);
            await Threads.SaveStateAsync(session.Record.VeoId, "dispatch", "{\"state\":\"complete\"}");
            if (!payload.PreserveDraft) await SaveDraftAsync(session, "", []);
            return turnId ?? throw new InvalidDataException("Codex accepted the turn without returning its identity.");
        }
        catch (CodexRpcException)
        { session.Timeline.End(null); await Threads.SaveStateAsync(session.Record.VeoId, "dispatch", "{\"state\":\"rejected\"}"); throw; }
        catch
        { session.DispatchWarning = "Send outcome is uncertain. Reconnect and inspect history before sending again."; throw; }
        finally { ScheduleChanged(); }
    }
    public async Task StopAsync(ThreadSession session)
    {
        var runtimeId = session.Record.CodexThreadId ?? throw new InvalidOperationException("No runtime thread.");
        var turnId = session.Timeline.ActiveTurnId;
        if (turnId is null)
        {
            var response = await Runtime.RequestAsync("thread/read", new { threadId = runtimeId, includeTurns = true }, lifetime.Token);
            if (response.GetProperty("thread").TryGetProperty("turns", out var turns))
                turnId = turns.EnumerateArray().Reverse().FirstOrDefault(t => t.Str("status") is "inProgress" or "active" or "running").Str("id");
        }
        if (turnId is null) throw new InvalidOperationException("Codex did not return an active turn. Reconnect to reconcile the thread.");
        await Runtime.RequestAsync("turn/interrupt", new { threadId = runtimeId, turnId }, lifetime.Token);
    }
    public async Task SteerAsync(ThreadSession session, ComposerSnapshot payload)
    {
        if (payload.Daybreak is not null) throw new InvalidOperationException("Start a new turn to apply the saved Daybreak choice.");
        if (payload.StartGoal) throw new InvalidOperationException("Start a new turn to apply the queued goal.");
        if (!session.Timeline.IsRunning || session.Timeline.ActiveTurnId is null) throw new InvalidOperationException("An identified active turn is required for steering.");
        await Runtime.RequestAsync("turn/steer", new { threadId = session.Record.CodexThreadId, expectedTurnId = session.Timeline.ActiveTurnId, input = new[] { new { type = "text", text = payload.Text } } }, lifetime.Token);
        await SaveDraftAsync(session, "", []);
    }
    public async Task RemoveQueuedAsync(ThreadSession session, string clientId)
    { session.RemoveQueued(clientId); await SaveQueueAsync(session); ScheduleChanged(); }
    Task SaveQueueAsync(ThreadSession session) => Threads.SaveStateAsync(session.Record.VeoId, "queue", JsonSerializer.Serialize(session.Queue));

    internal async Task ClearQueuedComposerGoalsAsync(ThreadSession session)
    {
        var previous = session.Queue;
        if (!previous.Any(submission => submission.StartGoal)) return;
        session.RestoreQueue(previous.Select(submission => submission with { StartGoal = false }));
        try { await SaveQueueAsync(session); }
        catch { session.RestoreQueue(previous); throw; }
    }
    public async Task EnqueueContextAsync(ThreadSession session, ComposerSnapshot payload)
    {
        session.Enqueue(payload with { PreserveDraft = true }); await SaveQueueAsync(session); ScheduleChanged();
        if (!session.Timeline.IsRunning) ScheduleNextQueued(session);
    }
    public async Task<string> SubmitContinuationAsync(ThreadSession session, ComposerSnapshot payload, CancellationToken cancellationToken = default)
    {
        await session.DispatchGate.WaitAsync(cancellationToken);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (session.Timeline.IsRunning || session.Record.IsArchived || session.Record.CodexThreadId is null)
                throw new InvalidOperationException("The continuation thread is no longer eligible.");
            return await DispatchAsync(session, payload with { PreserveDraft = true }, isContinuation: true);
        }
        finally { session.DispatchGate.Release(); }
    }
    public async Task EnsureRuntimeThreadAsync(ThreadSession session, ComposerSnapshot settings, CancellationToken cancellationToken = default)
    {
        await session.DispatchGate.WaitAsync(cancellationToken);
        try { if (session.Record.CodexThreadId is null) await StartRuntimeThreadCoreAsync(session, settings, cancellationToken); }
        finally { session.DispatchGate.Release(); }
    }
    async Task StartRuntimeThreadCoreAsync(ThreadSession session, ComposerSnapshot payload, CancellationToken cancellationToken)
    {
        var parameters = new Dictionary<string, object?>
        {
            ["cwd"] = session.Record.Cwd, ["model"] = payload.Model, ["sandbox"] = Sandbox(payload.Access),
            ["approvalPolicy"] = "on-request", ["ephemeral"] = session.Record.WorkspaceKind == "temporary",
            ["dynamicTools"] = DynamicToolBridge.Specifications
        };
        if (payload.ContextTokens is { } tokens) parameters["config"] = new { model_context_window = tokens };
        var created = await Runtime.RequestAsync("thread/start", parameters, cancellationToken);
        session.Record = session.Record with { CodexThreadId = created.GetProperty("thread").Str("id") };
        await Threads.UpsertThreadAsync(session.Record, cancellationToken);
    }
    async Task ConsumeEventsAsync()
    {
        try
        {
            await foreach (var message in Runtime.ReadEventsAsync(lifetime.Token))
            {
                if (message.Generation != Runtime.Generation) continue;
                RuntimeEventReceived?.Invoke(message);
                if (TryHandleRuntimeEvent?.Invoke(message) == true) continue;
                if (!message.IsServerRequest) RuntimeNotificationReceived?.Invoke(message);
                if (message.IsServerRequest)
                {
                    if (message.Method == "item/tool/call") { _ = HandleDynamicToolAsync(message); continue; }
                    requests[message.Id!.Value.GetRawText()] = message; ScheduleChanged(); continue;
                }
                var p = message.Parameters; var id = p.Str("threadId");
                if (message.Method == "serverRequest/resolved" && p.ValueKind == JsonValueKind.Object && p.TryGetProperty("requestId", out var resolved))
                { requests.TryRemove(resolved.GetRawText(), out _); ScheduleChanged(); continue; }
                var session = id is null ? null : sessions.Values.FirstOrDefault(x => x.Record.CodexThreadId == id);
                if (session is not null && session.Timeline.Apply(message.Method ?? "", p))
                {
                    RuntimeEventApplied?.Invoke(session, message);
                    if (message.Method is "turn/started" or "turn/completed" or "turn/aborted")
                    {
                        session.Record = session.Record with { Status = session.Timeline.IsRunning ? "running" : "idle" };
                        await Threads.UpsertThreadAsync(session.Record);
                    }
                    if (message.Method is "item/completed" or "turn/started" or "turn/completed" or "turn/aborted") await PersistTimelineAsync(session);
                    ScheduleChanged();
                    if (message.Method == "turn/completed" && session.Queue.Count > 0)
                    {
                        ScheduleNextQueued(session);
                    }
                }
                if (message.Method == "account/rateLimits/updated") { RateLimits = p.Clone(); ScheduleChanged(); }
                if (message.Method == "error") { Status = DiagnosticRedactor.Redact(p.GetRawText()); ScheduleChanged(); }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception e) { Status = "Runtime event failure: " + DiagnosticRedactor.Redact(e.Message); ScheduleChanged(); }
    }
    void ScheduleNextQueued(ThreadSession session)
    {
        if (Interlocked.CompareExchange(ref session.QueueDispatchScheduled, 1, 0) == 0) _ = RunQueuedAsync(session);
    }
    public Task DispatchNextQueuedAsync(ThreadSession session)
    {
        if (session.DispatchWarning is not null) throw new InvalidOperationException("Resolve the current dispatch warning before starting a queued message.");
        return Interlocked.CompareExchange(ref session.QueueDispatchScheduled, 1, 0) == 0 ? RunQueuedAsync(session) : Task.CompletedTask;
    }
    async Task RunQueuedAsync(ThreadSession session)
    {
        try
        {
            await session.DispatchGate.WaitAsync(lifetime.Token);
            try
            {
                if (!session.Timeline.IsRunning && session.Queue.FirstOrDefault() is { } next)
                {
                    if (TryDispatchQueuedAsync is { } queued && await queued(session, next, lifetime.Token))
                    { session.RemoveQueued(next.ClientId); await SaveQueueAsync(session); }
                    else await DispatchAsync(session, next, true);
                }
            }
            finally { session.DispatchGate.Release(); }
        }
        catch (Exception e) { session.DispatchWarning = DiagnosticRedactor.Redact(e.Message); ScheduleChanged(); }
        finally
        {
            Interlocked.Exchange(ref session.QueueDispatchScheduled, 0);
            if (!lifetime.IsCancellationRequested && !session.Timeline.IsRunning && session.Queue.Count > 0 && session.DispatchWarning is null) ScheduleNextQueued(session);
        }
    }
    public async Task RespondAsync(RuntimeEvent request, object result)
    { await Runtime.RespondAsync(request, result, lifetime.Token); requests.TryRemove(request.Id!.Value.GetRawText(), out _); ScheduleChanged(); }
    public async Task RejectUnsupportedAsync(RuntimeEvent request)
    { await Runtime.RespondErrorAsync(request, -32601, "This request has no supported Windows handler.", lifetime.Token); requests.TryRemove(request.Id!.Value.GetRawText(), out _); ScheduleChanged(); }
    public async Task LoginAsync(string type)
    {
        var response = await Runtime.RequestAsync("account/login/start", new { type }, lifetime.Token);
        if (response.Str("authUrl") is { } url) OpenBrowser?.Invoke(new Uri(url));
        Status = "Complete sign-in in Veo's browser, then refresh Account."; ScheduleChanged();
    }
    public async Task RefreshAccountAsync()
    { Account = await Runtime.RequestAsync("account/read", new { refreshToken = false }); RateLimits = await Runtime.RequestAsync("account/rateLimits/read"); ScheduleChanged(); }
    public Task<JsonElement> InspectAsync(string method, object? parameters = null) => Runtime.RequestAsync(method, parameters, lifetime.Token);
    async Task HandleDynamicToolAsync(RuntimeEvent request)
    {
        DynamicToolResult result;
        try { result = await dynamicTools.InvokeAsync(request.Parameters, lifetime.Token); }
        catch (Exception e) { result = DynamicToolBridge.Failure(e.Message); }
        try { await Runtime.RespondAsync(request, result, lifetime.Token); }
        catch (Exception e) when (e is OperationCanceledException or InvalidOperationException or IOException) { }
    }
    async Task<JsonElement> ListBackgroundTerminalsAsync(string threadId, CancellationToken token)
    {
        var rows = new List<JsonElement>(); string? cursor = null; var seen = new HashSet<string>();
        do
        {
            var response = await Runtime.RequestAsync("thread/backgroundTerminals/list", new { threadId, cursor, limit = 100 }, token);
            if (response.TryGetProperty("data", out var data)) rows.AddRange(data.EnumerateArray().Select(x => x.Clone()));
            cursor = response.Str("nextCursor");
            if (cursor is not null && !seen.Add(cursor)) throw new InvalidDataException("The terminal inventory repeated a pagination cursor.");
        } while (cursor is not null);
        return JsonSerializer.SerializeToElement(rows.Select(x => new { processId = x.Str("processId"), command = x.Str("command"), cwd = x.Str("cwd") }));
    }
    public async Task PersistTimelineAsync(ThreadSession session)
    {
        await session.PersistenceGate.WaitAsync(lifetime.Token);
        try
        {
        var snapshot = session.Timeline.PersistenceSnapshot();
        var persisted = new List<PersistedItem>();
        foreach (var item in snapshot.Items)
        {
            var raw = item.Raw.ValueKind == JsonValueKind.Object ? item.Raw.GetRawText() : "{}";
            // Persist accumulated text without discarding unknown original fields.
            var node = System.Text.Json.Nodes.JsonNode.Parse(raw)!.AsObject(); node["veoRenderedText"] = item.Text;
            persisted.Add(new(item.Id, item.TurnId, item.Kind, item.Raw.Str("clientId"), item.Status, node.ToJsonString(), item.Order, DateTimeOffset.UtcNow));
        }
        var turns = snapshot.Turns.Select(t => new PersistedTurn(t.Id, t.Status, t.StartedAt, t.ErrorJson, t.Order, t.TerminalObserved)).ToArray();
        await Threads.SaveTimelineAsync(session.Record.VeoId, turns, persisted);
        var removed = session.Timeline.RemovedItemIds;
        if (removed.Count > 0)
        {
            await Threads.DeleteItemsAsync(session.Record.VeoId, removed);
            session.Timeline.ConfirmRemovedItems(removed);
        }
        }
        finally { session.PersistenceGate.Release(); }
    }
    static string TextFromRaw(string json) { using var d = JsonDocument.Parse(json); return d.RootElement.Str("veoRenderedText") ?? TimelineReducer.ExtractText(d.RootElement); }
    static string? RuntimeStatus(JsonElement element) => element.Str("status") ?? (element.TryObjectProperty("status", out var status) ? status.Str("type") : null);
    static string Sandbox(string access) => access switch { "Read only" => "read-only", "Full access" => "danger-full-access", _ => "workspace-write" };
    void ScheduleChanged()
    {
        if (Interlocked.Exchange(ref changedPending, 1) != 0) return;
        _ = Task.Run(async () => { await Task.Delay(32); Interlocked.Exchange(ref changedPending, 0); Changed?.Invoke(); });
    }
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel(); await Runtime.DisposeAsync();
        if (events is not null) await events;
        await Threads.DisposeAsync(); lifetime.Dispose();
    }
}
