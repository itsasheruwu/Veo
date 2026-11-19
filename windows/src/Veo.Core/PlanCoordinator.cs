using System.Text;
using System.Text.Json;
using Veo.Infrastructure.Storage;
using Veo.Protocol;

namespace Veo.Core;

public sealed record PlanReference(string ThreadId, string ItemId)
{
    public string Key => ThreadId + "|" + ItemId;
}
public sealed record PlanHandoff(PlanReference Source, string TargetThreadId, string ClientId, string? RuntimeThreadId = null);

/// <summary>Durable editable documents and implementation handoffs, independent of window presentation.</summary>
public sealed class PlanCoordinator : IAsyncDisposable
{
    readonly WorkspaceCoordinator workspace;
    readonly SemaphoreSlim gate = new(1, 1);
    readonly Dictionary<string, PersistedPlan> artifacts = new(StringComparer.Ordinal);
    readonly Dictionary<string, PlanHandoff> handoffs = new(StringComparer.Ordinal);
    readonly Dictionary<string, string> editing = new(StringComparer.Ordinal);
    readonly Dictionary<string, string> errors = new(StringComparer.Ordinal);
    readonly HashSet<string> observed = new(StringComparer.Ordinal);
    readonly object snapshotLock = new();
    bool disposed;
    public event Action? Changed;
    public string? LastError { get; private set; }
    public PlanCoordinator(WorkspaceCoordinator workspace)
    { this.workspace = workspace; workspace.RuntimeEventApplied += OnRuntimeEvent; }
    public PersistedPlan? Get(PlanReference reference) { lock (snapshotLock) return artifacts.GetValueOrDefault(reference.Key); }
    public string Markdown(PlanReference reference, string fallback = "") => Get(reference) is { } plan ? plan.EditedMarkdown ?? plan.OriginalMarkdown : fallback;
    public string? EditingDraft(PlanReference reference) { lock (snapshotLock) return editing.GetValueOrDefault(reference.Key); }
    public string? Error(PlanReference reference) { lock (snapshotLock) return errors.GetValueOrDefault(reference.Key); }

    public async Task ObserveAsync(ThreadSession session)
    {
        await gate.WaitAsync();
        try
        {
            if (!observed.Contains(session.Record.VeoId))
            {
                foreach (var plan in await workspace.Threads.ReadPlansAsync(session.Record.VeoId))
                {
                    var reference = new PlanReference(plan.ThreadKey, plan.ItemId);
                    lock (snapshotLock) artifacts[reference.Key] = plan;
                    var state = await workspace.Threads.ReadStateAsync("plan-handoff", reference.Key);
                    if (state is not null && JsonSerializer.Deserialize<PlanHandoff>(state) is { } handoff) handoffs[reference.Key] = handoff;
                }
                observed.Add(session.Record.VeoId);
            }
            foreach (var item in session.Timeline.Items.Where(x => x.Kind == "plan" && x.Status is not ("inProgress" or "pending")))
                await IngestCoreAsync(session.Record.VeoId, item);
        }
        finally { gate.Release(); }
        Changed?.Invoke();
    }
    async Task IngestCoreAsync(string threadId, TimelineItem item)
    {
        var reference = new PlanReference(threadId, item.Id);
        if (Get(reference) is not null || string.IsNullOrWhiteSpace(item.Text)) return;
        PersistedPlan[] previous;
        lock (snapshotLock) previous = artifacts.Values.Where(x => x.ThreadKey == threadId && x.Lifecycle == "ready").ToArray();
        foreach (var old in previous) await SaveCoreAsync(old with { Lifecycle = "superseded", UpdatedAt = DateTimeOffset.UtcNow });
        await SaveCoreAsync(new(threadId, item.Id, item.TurnId, item.Text, null, UpdatedAt: DateTimeOffset.UtcNow));
    }
    public void BeginEditing(PlanReference reference)
    {
        var plan = Get(reference) ?? throw new InvalidOperationException("The plan has not been saved yet.");
        if (plan.Lifecycle != "ready") throw new InvalidOperationException("Only a ready plan can be edited.");
        lock (snapshotLock) editing[reference.Key] = plan.EditedMarkdown ?? plan.OriginalMarkdown;
        Changed?.Invoke();
    }
    public void UpdateDraft(PlanReference reference, string markdown) { lock (snapshotLock) if (editing.ContainsKey(reference.Key)) editing[reference.Key] = markdown; }
    public void CancelEditing(PlanReference reference) { lock (snapshotLock) editing.Remove(reference.Key); Changed?.Invoke(); }
    public async Task SaveEditingAsync(PlanReference reference)
    {
        await gate.WaitAsync();
        try
        {
            var plan = Get(reference) ?? throw new InvalidOperationException("Unknown plan.");
            var draft = EditingDraft(reference) ?? throw new InvalidOperationException("The plan is not being edited.");
            if (plan.Lifecycle != "ready" || string.IsNullOrWhiteSpace(draft)) throw new InvalidOperationException("A ready plan needs nonempty Markdown.");
            await SaveCoreAsync(plan with { EditedMarkdown = draft == plan.OriginalMarkdown ? null : draft, UpdatedAt = DateTimeOffset.UtcNow });
            lock (snapshotLock) editing.Remove(reference.Key);
        }
        finally { gate.Release(); }
        Changed?.Invoke();
    }
    public async Task RevertAsync(PlanReference reference)
    {
        await gate.WaitAsync();
        try
        {
            var plan = Get(reference) ?? throw new InvalidOperationException("Unknown plan.");
            if (plan.Lifecycle != "ready") throw new InvalidOperationException("Only a ready plan can be reverted.");
            await SaveCoreAsync(plan with { EditedMarkdown = null, UpdatedAt = DateTimeOffset.UtcNow });
            lock (snapshotLock) editing.Remove(reference.Key);
        }
        finally { gate.Release(); }
        Changed?.Invoke();
    }
    public async Task ExportAsync(PlanReference reference, string destination)
    {
        var markdown = Markdown(reference);
        if (markdown.Length == 0) throw new InvalidOperationException("Unknown plan.");
        // The native Save picker owns overwrite consent; direct callers may only create a new export.
        await using var output = new FileStream(Path.GetFullPath(destination), FileMode.CreateNew, FileAccess.Write, FileShare.None);
        await output.WriteAsync(Encoding.UTF8.GetBytes(markdown));
    }
    public async Task<ThreadSession> ImplementAsync(PlanReference reference, ThreadSession source, ComposerSnapshot settings, bool inNewTask = false)
    {
        if (source.Record.VeoId != reference.ThreadId) throw new InvalidOperationException("Plan source and selected thread differ.");
        if (source.Timeline.IsRunning || !string.IsNullOrWhiteSpace(source.Draft.Text) || source.Draft.AttachmentsJson != "[]")
            throw new InvalidOperationException("Finish the active turn and send or clear feedback and attachments before implementing the plan.");
        await gate.WaitAsync();
        try
        {
            var plan = Get(reference) ?? throw new InvalidOperationException("Unknown plan.");
            if (plan.Lifecycle != "ready" || EditingDraft(reference) is not null) throw new InvalidOperationException("Save a ready plan before implementing it.");
            lock (snapshotLock) errors.Remove(reference.Key);
            var target = inNewTask ? await workspace.CreateAsync(source.Record.Cwd) : source;
            var client = "plan-implementation-" + Guid.NewGuid().ToString("N");
            var markdown = plan.EditedMarkdown ?? plan.OriginalMarkdown;
            var text = "<codex_internal_context source=\"veo_plan_handoff\">\nThe user approved the following implementation plan in Veo. Treat this exact Markdown as the authoritative plan to implement. Preserve the task's current access and approval settings.\n\n" + markdown + "\n</codex_internal_context>";
            var handoff = new PlanHandoff(reference, target.Record.VeoId, client, target.Record.CodexThreadId);
            handoffs[reference.Key] = handoff;
            await workspace.Threads.SaveStateAsync("plan-handoff", reference.Key, JsonSerializer.Serialize(handoff));
            await SaveCoreAsync(plan with { Lifecycle = "implementing", ImplementationClientId = client, UpdatedAt = DateTimeOffset.UtcNow });
            try
            {
                await workspace.SubmitAsync(target, settings with { ClientId = client, Text = text, Mode = "Agentic", Attachments = [], StructuredAttachments = [] });
                var turn = target.Timeline.Items.FirstOrDefault(x => x.Raw.Str("clientId") == client)?.TurnId ?? target.Timeline.ActiveTurnId;
                var current = Get(reference)!;
                await SaveCoreAsync(current with { ImplementationTurnId = turn, UpdatedAt = DateTimeOffset.UtcNow });
                handoff = handoff with { RuntimeThreadId = target.Record.CodexThreadId };
                handoffs[reference.Key] = handoff;
                await workspace.Threads.SaveStateAsync("plan-handoff", reference.Key, JsonSerializer.Serialize(handoff));
            }
            catch (Exception exception)
            {
                LastError = DiagnosticRedactor.Redact(exception.Message);
                lock (snapshotLock) errors[reference.Key] = LastError;
                handoff = handoff with { RuntimeThreadId = target.Record.CodexThreadId };
                handoffs[reference.Key] = handoff;
                await workspace.Threads.SaveStateAsync("plan-handoff", reference.Key, JsonSerializer.Serialize(handoff));
                if (exception is CodexRpcException || target.DispatchWarning is null)
                    await SaveCoreAsync(plan with { Lifecycle = "ready", ImplementationClientId = null, ImplementationTurnId = null, UpdatedAt = DateTimeOffset.UtcNow });
                // An uncertain send remains implementing until authoritative runtime history resolves it.
                throw;
            }
            return target;
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    public async Task ReconcileImplementationAsync(PlanReference reference)
    {
        await gate.WaitAsync();
        try
        {
            if (disposed) return;
            var plan = Get(reference);
            if (plan?.Lifecycle != "implementing" || !handoffs.TryGetValue(reference.Key, out var handoff) || handoff.RuntimeThreadId is null) return;
            var response = await workspace.InspectAsync("thread/read", new { threadId = handoff.RuntimeThreadId, includeTurns = true });
            if (!response.TryObjectProperty("thread", out var thread) || !thread.TryGetProperty("turns", out var turns)) return;
            foreach (var turn in turns.EnumerateArray())
            {
                var matches = turn.Str("id") == plan.ImplementationTurnId;
                if (!matches && turn.TryGetProperty("items", out var items)) matches = items.EnumerateArray().Any(item => item.Str("clientId") == handoff.ClientId);
                if (matches && turn.Str("status") is "completed" or "failed" or "interrupted") await FinishCoreAsync(plan, turn);
            }
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    async void OnRuntimeEvent(ThreadSession session, RuntimeEvent message)
    {
        if (disposed || message.Method is not ("item/completed" or "turn/completed")) return;
        await gate.WaitAsync();
        try
        {
            if (disposed) return;
            if (message.Method == "item/completed" && message.Parameters.TryObjectProperty("item", out var item) && item.Str("type") == "plan")
                await IngestCoreAsync(session.Record.VeoId, new(item.Str("id")!, message.Parameters.Str("turnId"), "plan", TimelineReducer.ExtractText(item), "completed", item, 0));
            if (message.Method == "turn/completed" && message.Parameters.TryObjectProperty("turn", out var turn))
                foreach (var entry in handoffs.Values.Where(x => x.TargetThreadId == session.Record.VeoId).ToArray())
                {
                    var plan = Get(entry.Source);
                    if (plan?.Lifecycle != "implementing") continue;
                    var matches = plan.ImplementationTurnId == turn.Str("id");
                    if (!matches && turn.TryGetProperty("items", out var items)) matches = items.EnumerateArray().Any(item => item.Str("clientId") == entry.ClientId);
                    if (matches) await FinishCoreAsync(plan, turn);
                }
        }
        catch (Exception exception) { LastError = DiagnosticRedactor.Redact(exception.Message); }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    async Task FinishCoreAsync(PersistedPlan plan, JsonElement turn)
    {
        var failed = turn.Str("status") is "failed" or "interrupted" || (turn.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object);
        await SaveCoreAsync(plan with { Lifecycle = failed ? "ready" : "implemented", ImplementationTurnId = turn.Str("id"), UpdatedAt = DateTimeOffset.UtcNow });
        var key = new PlanReference(plan.ThreadKey, plan.ItemId).Key;
        lock (snapshotLock)
        {
            if (failed) { LastError = "The implementation turn did not complete. The plan is ready to try again."; errors[key] = LastError; }
            else errors.Remove(key);
        }
    }
    async Task SaveCoreAsync(PersistedPlan plan)
    {
        await workspace.Threads.SavePlanAsync(plan);
        lock (snapshotLock) artifacts[new PlanReference(plan.ThreadKey, plan.ItemId).Key] = plan;
    }
    public async ValueTask DisposeAsync() { disposed = true; workspace.RuntimeEventApplied -= OnRuntimeEvent; await gate.WaitAsync(); gate.Release(); }
}
