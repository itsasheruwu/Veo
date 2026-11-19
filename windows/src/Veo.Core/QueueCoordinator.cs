using System.Text.Json;
using Veo.Protocol;

namespace Veo.Core;

public sealed record QueueBinding(string ClientId, string? ServerId, string State, long Generation);
public sealed record QueueMirrorState(IReadOnlyList<QueueBinding> Bindings);
public sealed record QueueView(IReadOnlyList<ComposerSnapshot> Local, IReadOnlyList<QueueBinding> Bindings,
    IReadOnlyList<JsonElement> ServerOnly, string? Warning);

/// <summary>Mirrors stable input identities. Dispatch returns to the workspace's full frozen-settings pipeline.</summary>
public sealed class QueueCoordinator : IDisposable
{
    readonly WorkspaceCoordinator workspace;
    readonly ICoordinatorRpc rpc;
    readonly Dictionary<string, QueueView> views = new(StringComparer.Ordinal);
    readonly Func<ThreadSession, ComposerSnapshot, CancellationToken, Task>? previousAdded;
    readonly Func<ThreadSession, ComposerSnapshot, CancellationToken, Task<bool>>? previousDispatch;
    readonly Func<ThreadSession, ComposerSnapshot, CancellationToken, Task> addedHook;
    readonly Func<ThreadSession, ComposerSnapshot, CancellationToken, Task<bool>> dispatchHook;
    public QueueCoordinator(WorkspaceCoordinator workspace, ICoordinatorRpc? transport = null, bool attach = true)
    {
        this.workspace = workspace; rpc = transport ?? new WorkspaceCoordinatorRpc(workspace);
        previousAdded = workspace.QueueAddedAsync; previousDispatch = workspace.TryDispatchQueuedAsync;
        addedHook = async (session, payload, token) => { if (previousAdded is not null) await previousAdded(session, payload, token); await AddedUnderDispatchGateAsync(session, payload, token); };
        dispatchHook = async (session, payload, token) => await PrepareDispatchUnderGateAsync(session, payload, token) || previousDispatch is not null && await previousDispatch(session, payload, token);
        if (attach) { workspace.QueueAddedAsync = addedHook; workspace.TryDispatchQueuedAsync = dispatchHook; }
    }
    public async Task<QueueView> LoadAsync(ThreadSession session, CancellationToken token = default)
    {
        await session.DispatchGate.WaitAsync(token);
        try { return await ReconcileUnderGateAsync(session, token); }
        finally { session.DispatchGate.Release(); }
    }
    public QueueView View(ThreadSession session)
    {
        lock (views) return views.GetValueOrDefault(session.Record.VeoId) ?? new(session.Queue, [], [], null);
    }
    public async Task AddedUnderDispatchGateAsync(ThreadSession session, ComposerSnapshot payload, CancellationToken token = default)
    {
        // The server queue carries input only. Apply access programs and goals on the local dispatch path.
        if (payload.Daybreak is not null || payload.StartGoal) return;
        if (session.Record.CodexThreadId is not { } id || !rpc.Supports("thread/queue/add") || !rpc.Supports("thread/queue/list")) return;
        var bindings = await ReadBindingsAsync(session, token);
        if (bindings.Any(x => x.ClientId == payload.ClientId && x.State != "local")) return;
        Set(bindings, new(payload.ClientId, null, "pending-add", rpc.Generation)); await SaveBindingsAsync(session, bindings, token);
        try
        {
            var result = await rpc.RequestAsync("thread/queue/add", new { threadId = id, clientUserMessageId = payload.ClientId, input = ComposerProtocol.Input(payload) }, token);
            var queued = result.GetProperty("queuedSubmission");
            if (queued.Str("clientUserMessageId") != payload.ClientId || queued.Str("id") is not { Length: > 0 } serverId) throw new InvalidDataException("Codex did not confirm the queued input identity.");
            Set(bindings, new(payload.ClientId, serverId, "mirrored", rpc.Generation)); await SaveBindingsAsync(session, bindings, token);
        }
        catch (CodexRpcException error) when (error.Code == -32601)
        { Set(bindings, new(payload.ClientId, null, "local", rpc.Generation)); await SaveBindingsAsync(session, bindings, CancellationToken.None); }
        catch
        {
            // Never replay an ambiguous add. The local payload remains durable, including every captured setting.
            try
            {
                var reconciled = await ReconcileUnderGateAsync(session, CancellationToken.None);
                if (reconciled.Bindings.Any(x => x.ClientId == payload.ClientId && x.State is "mirrored" or "sent")) return;
            }
            catch { }
            throw new InvalidOperationException("The queue-add outcome is uncertain. The frozen local prompt was kept; refresh the queue before editing or starting it.");
        }
    }
    public async Task<bool> PrepareDispatchUnderGateAsync(ThreadSession session, ComposerSnapshot payload, CancellationToken token = default)
    {
        var state = await ReconcileUnderGateAsync(session, token);
        if (state.ServerOnly.Count > 0) throw new InvalidOperationException("Review server-only queued input before dispatching local queued work; its frozen settings are unavailable.");
        var binding = state.Bindings.FirstOrDefault(x => x.ClientId == payload.ClientId);
        if (binding?.State == "sent") return true;
        if (binding?.State is "uncertain" or "uncertain-steer" or "pending-add" or "pending-delete" or "missing") throw new InvalidOperationException("This queued prompt has an uncertain server outcome. Refresh and inspect runtime history before starting it.");
        if (binding?.ServerId is not null) await DeleteMirrorUnderGateAsync(session, binding, token);
        // Server queues expose input only. The ordinary turn/start path applies the entire immutable snapshot,
        // routing, context, family plan, vision fallback and checkpoint hooks after confirmed server removal.
        return false;
    }
    public async Task EditAsync(ThreadSession session, string clientId, string text, string[] attachments, CancellationToken token = default)
    {
        await session.DispatchGate.WaitAsync(token);
        try
        {
            var state = await ReconcileUnderGateAsync(session, token); var existing = session.Queue.FirstOrDefault(x => x.ClientId == clientId) ?? throw new InvalidOperationException("The queued prompt was already dispatched or removed.");
            var binding = state.Bindings.FirstOrDefault(x => x.ClientId == clientId);
            if (binding is { State: not "local" and not "mirrored" }) throw new InvalidOperationException("Resolve the uncertain queue outcome before editing.");
            if (binding?.ServerId is not null) await DeleteMirrorUnderGateAsync(session, binding, token);
            // Only input changes. Captured model/effort/access/context and client identity remain frozen.
            var replacement = existing with { Text = text, Attachments = attachments.ToArray(), StructuredAttachments = existing.StructuredAttachments is null ? null : existing.StructuredAttachments.Where(x => x.Kind != ComposerAttachmentKind.LocalImage).Concat(attachments.Select(path => new ComposerAttachment(ComposerAttachmentKind.LocalImage, path, Path.GetFileName(path)))).ToArray() };
            session.RestoreQueue(session.Queue.Select(x => x.ClientId == clientId ? replacement : x)); await SaveLocalAsync(session, token);
            await AddedUnderDispatchGateAsync(session, replacement, token); workspace.NotifyChanged();
        }
        finally { session.DispatchGate.Release(); }
    }
    public async Task RemoveAsync(ThreadSession session, string clientId, CancellationToken token = default)
    {
        await session.DispatchGate.WaitAsync(token);
        try
        {
            var state = await ReconcileUnderGateAsync(session, token); var binding = state.Bindings.FirstOrDefault(x => x.ClientId == clientId);
            if (binding is { State: not "local" and not "mirrored" and not "sent" }) throw new InvalidOperationException("The queue outcome must be resolved before removal.");
            if (binding?.ServerId is not null && binding.State != "sent") await DeleteMirrorUnderGateAsync(session, binding, token);
            session.RemoveQueued(clientId); await SaveLocalAsync(session, token); var bindings = await ReadBindingsAsync(session, token); bindings.RemoveAll(x => x.ClientId == clientId); await SaveBindingsAsync(session, bindings, token); workspace.NotifyChanged();
        }
        finally { session.DispatchGate.Release(); }
    }
    public async Task ReorderAsync(ThreadSession session, IReadOnlyList<string> clientIds, CancellationToken token = default)
    {
        await session.DispatchGate.WaitAsync(token);
        try
        {
            var state = await ReconcileUnderGateAsync(session, token); var local = session.Queue;
            if (clientIds.Count != local.Count || clientIds.Distinct(StringComparer.Ordinal).Count() != local.Count || clientIds.Any(id => local.All(x => x.ClientId != id))) throw new ArgumentException("Queue order must contain every current local identity exactly once.");
            if (state.Bindings.Any(x => x.State is not "local" and not "mirrored")) throw new InvalidOperationException("Resolve uncertain queue entries before reordering.");
            if (state.Bindings.Any(x => x.State == "mirrored"))
            {
                if (state.ServerOnly.Count > 0) throw new InvalidOperationException("Server-only queue entries must be reviewed before reordering local entries.");
                if (!rpc.Supports("thread/queue/reorder"))
                { foreach (var binding in state.Bindings.Where(x => x.State == "mirrored")) await DeleteMirrorUnderGateAsync(session, binding, token); }
                else
                {
                    var order = clientIds.Select(id => state.Bindings.FirstOrDefault(x => x.ClientId == id)?.ServerId).OfType<string>().ToArray();
                    // Persist the intended order before mutation so an ambiguous response cannot create a retry loop.
                    await workspace.Threads.SaveStateAsync(session.Record.VeoId, "queue-reorder", JsonSerializer.Serialize(new { state = "pending", order }), token);
                    try
                    {
                        await rpc.RequestAsync("thread/queue/reorder", new { threadId = session.Record.CodexThreadId, queuedSubmissionIds = order }, token);
                        var readback = await ListServerAsync(session, token);
                        if (!readback.Select(x => x.Str("id")).SequenceEqual(order)) throw new InvalidDataException("The runtime did not confirm the queue order.");
                        await workspace.Threads.SaveStateAsync(session.Record.VeoId, "queue-reorder", "{\"state\":\"complete\"}", token);
                    }
                    catch { throw new InvalidOperationException("Queue reorder outcome is uncertain. Refresh before another reorder; the local frozen order was kept."); }
                }
            }
            session.RestoreQueue(clientIds.Select(id => local.First(x => x.ClientId == id))); await SaveLocalAsync(session, token); workspace.NotifyChanged();
        }
        finally { session.DispatchGate.Release(); }
    }
    public async Task SteerAsync(ThreadSession session, ComposerSnapshot payload, CancellationToken token = default)
    {
        if (payload.Daybreak is not null) throw new InvalidOperationException("Start the queued message as a new turn to apply its Daybreak choice.");
        if (payload.StartGoal) throw new InvalidOperationException("Start the queued message as a new turn to apply its goal.");
        await session.DispatchGate.WaitAsync(token);
        try
        {
            if (!session.Timeline.IsRunning) throw new InvalidOperationException("Steer needs an active turn.");
            var turnId = session.Timeline.ActiveTurnId;
            if (turnId is null)
            {
                var response = await rpc.RequestAsync("thread/read", new { threadId = session.Record.CodexThreadId, includeTurns = true }, token);
                turnId = ThreadCatalogCoordinator.Rows(response.GetProperty("thread"), "turns").LastOrDefault(x => x.Str("status") is "inProgress" or "active" or "running").Str("id");
            }
            if (turnId is null) throw new InvalidOperationException("The active turn identity is unavailable; refresh this chat before steering.");
            if (session.Queue.Any(x => x.ClientId == payload.ClientId))
            {
                var view = await ReconcileUnderGateAsync(session, token); var binding = view.Bindings.FirstOrDefault(x => x.ClientId == payload.ClientId);
                if (binding is { State: not "mirrored" and not "local" }) throw new InvalidOperationException("Resolve the queued prompt's outcome before steering it.");
                if (binding?.ServerId is not null) await DeleteMirrorUnderGateAsync(session, binding, token);
            }
            await workspace.Threads.SaveStateAsync(session.Record.VeoId, "queue-steer", JsonSerializer.Serialize(new { state = "pending", payload = payload.Freeze(), expectedTurnId = turnId }), token);
            try
            {
                var sentAt = DateTimeOffset.UtcNow;
                await rpc.RequestAsync("turn/steer", new { threadId = session.Record.CodexThreadId, expectedTurnId = turnId, clientUserMessageId = payload.ClientId, input = ComposerProtocol.Input(payload) }, token);
                session.Timeline.RecordSteer(turnId, payload.ClientId, sentAt);
                session.RemoveQueued(payload.ClientId); await SaveLocalAsync(session, token);
                await workspace.Threads.SaveStateAsync(session.Record.VeoId, "queue-steer", "{\"state\":\"complete\"}", token);
                await workspace.PersistTimelineAsync(session);
                workspace.NotifyChanged();
            }
            catch (CodexRpcException) { await workspace.Threads.SaveStateAsync(session.Record.VeoId, "queue-steer", "{\"state\":\"rejected\"}", CancellationToken.None); throw; }
            catch { session.DispatchWarning = "Steer outcome is uncertain. Inspect runtime history before sending this input again."; throw; }
        }
        finally { session.DispatchGate.Release(); }
    }
    async Task<QueueView> ReconcileUnderGateAsync(ThreadSession session, CancellationToken token)
    {
        var bindings = await ReadBindingsAsync(session, token); JsonElement[] server = [];
        if (session.Record.CodexThreadId is not null && rpc.Supports("thread/queue/list")) server = await ListServerAsync(session, token);
        else if (bindings.Any(x => x.State != "local" && x.State != "sent")) throw new InvalidOperationException("The server queue cannot be inspected. Previously mirrored entries must remain blocked.");
        var duplicates = server.Where(x => x.Str("clientUserMessageId") is not null).GroupBy(x => x.Str("clientUserMessageId"), StringComparer.Ordinal).Any(x => x.Count() > 1);
        if (duplicates) throw new InvalidDataException("The server queue contains duplicate client identities; automatic dispatch is blocked.");
        var steerState = await workspace.Threads.ReadStateAsync(session.Record.VeoId, "queue-steer", token);
        string? pendingSteer = null;
        if (steerState is not null)
        {
            using var parsed = JsonDocument.Parse(steerState);
            if (parsed.RootElement.Str("state") == "pending" && parsed.RootElement.TryObjectProperty("payload", out var payload)) pendingSteer = payload.Str("ClientId");
        }
        foreach (var payload in session.Queue)
        {
            var row = server.FirstOrDefault(x => x.Str("clientUserMessageId") == payload.ClientId); var old = bindings.FirstOrDefault(x => x.ClientId == payload.ClientId);
            if (payload.ClientId == pendingSteer)
            {
                if (await HistoryContainsAsync(session, payload.ClientId, token))
                { Set(bindings, new(payload.ClientId, null, "sent", rpc.Generation)); session.RemoveQueued(payload.ClientId); await SaveLocalAsync(session, token); await workspace.Threads.SaveStateAsync(session.Record.VeoId, "queue-steer", "{\"state\":\"complete\"}", token); }
                else Set(bindings, new(payload.ClientId, row.Str("id"), "uncertain-steer", rpc.Generation));
            }
            else if (row.Str("id") is { } serverId) Set(bindings, new(payload.ClientId, serverId, "mirrored", rpc.Generation));
            else if (old?.State is "mirrored" or "pending-add" or "pending-delete" or "uncertain" or "missing")
            {
                var sent = await HistoryContainsAsync(session, payload.ClientId, token);
                if (sent) { Set(bindings, new(payload.ClientId, null, "sent", rpc.Generation)); session.RemoveQueued(payload.ClientId); await SaveLocalAsync(session, token); }
                else Set(bindings, old with { State = "uncertain" });
            }
            else if (old is null) Set(bindings, new(payload.ClientId, null, "local", rpc.Generation));
        }
        await SaveBindingsAsync(session, bindings, token);
        var localIds = session.Queue.Select(x => x.ClientId).ToHashSet(StringComparer.Ordinal);
        var view = new QueueView(session.Queue, bindings, server.Where(row => !localIds.Contains(row.Str("clientUserMessageId") ?? "")).ToArray(), bindings.Any(x => x.State is "uncertain" or "uncertain-steer") ? "A server mutation has no confirmed result. Automatic replay is blocked; inspect runtime history." : null);
        lock (views) views[session.Record.VeoId] = view; return view;
    }
    async Task DeleteMirrorUnderGateAsync(ThreadSession session, QueueBinding binding, CancellationToken token)
    {
        if (!rpc.Supports("thread/queue/delete")) throw new NotSupportedException("This runtime cannot safely remove the mirrored queue entry.");
        var bindings = await ReadBindingsAsync(session, token); Set(bindings, binding with { State = "pending-delete" }); await SaveBindingsAsync(session, bindings, token);
        try
        {
            await rpc.RequestAsync("thread/queue/delete", new { threadId = session.Record.CodexThreadId, queuedSubmissionId = binding.ServerId }, token);
            var server = await ListServerAsync(session, token);
            if (server.Any(row => row.Str("id") == binding.ServerId || row.Str("clientUserMessageId") == binding.ClientId)) throw new InvalidDataException("Codex did not confirm queue removal.");
            // A queue start racing the delete must not be sent a second time via turn/start.
            if (await HistoryContainsAsync(session, binding.ClientId, token)) throw new InvalidOperationException("This queued input was already consumed by the runtime. Refresh history.");
            Set(bindings, new(binding.ClientId, null, "local", rpc.Generation)); await SaveBindingsAsync(session, bindings, token);
        }
        catch
        { Set(bindings, binding with { State = "uncertain" }); await SaveBindingsAsync(session, bindings, CancellationToken.None); throw; }
    }
    async Task<JsonElement[]> ListServerAsync(ThreadSession session, CancellationToken token)
    {
        var rows = new List<JsonElement>(); var seen = new HashSet<string>(StringComparer.Ordinal); string? cursor = null;
        do
        {
            var result = await rpc.RequestAsync("thread/queue/list", new { threadId = session.Record.CodexThreadId, cursor, limit = 100 }, token);
            rows.AddRange(ThreadCatalogCoordinator.Rows(result, "data")); cursor = result.Str("nextCursor");
            if (cursor is not null && !seen.Add(cursor)) throw new InvalidDataException("The server queue repeated a page cursor.");
        } while (cursor is not null);
        if (rows.Any(row => row.Str("id") is null) || rows.GroupBy(row => row.Str("id"), StringComparer.Ordinal).Any(group => group.Count() > 1)) throw new InvalidDataException("The server queue has missing or duplicate identities.");
        return rows.ToArray();
    }
    async Task<bool> HistoryContainsAsync(ThreadSession session, string clientId, CancellationToken token)
    {
        var result = await rpc.RequestAsync("thread/read", new { threadId = session.Record.CodexThreadId, includeTurns = true }, token);
        foreach (var turn in ThreadCatalogCoordinator.Rows(result.GetProperty("thread"), "turns")) foreach (var item in ThreadCatalogCoordinator.Rows(turn, "items"))
            if ((item.Str("clientId") ?? item.Str("clientUserMessageId")) == clientId) return true;
        // A paginated history may omit the consumed entry. Without complete turns enumeration absence is unproven.
        if (result.GetProperty("thread").Str("historyMode") == "paginated")
        {
            if (!rpc.Supports("thread/turns/list")) throw new InvalidOperationException("Full history is required to prove a queued prompt was not consumed.");
            string? cursor = null; var seen = new HashSet<string>(StringComparer.Ordinal);
            do
            {
                var page = await rpc.RequestAsync("thread/turns/list", new { threadId = session.Record.CodexThreadId, cursor, limit = 100, sortDirection = "desc", itemsView = "full" }, token);
                if (ThreadCatalogCoordinator.Rows(page, "data").SelectMany(turn => ThreadCatalogCoordinator.Rows(turn, "items")).Any(item => (item.Str("clientId") ?? item.Str("clientUserMessageId")) == clientId)) return true;
                cursor = page.Str("nextCursor"); if (cursor is not null && !seen.Add(cursor)) throw new InvalidDataException("Queue-history reconciliation repeated a cursor.");
            } while (cursor is not null);
        }
        return false;
    }
    async Task<List<QueueBinding>> ReadBindingsAsync(ThreadSession session, CancellationToken token)
    {
        var json = await workspace.Threads.ReadStateAsync(session.Record.VeoId, "queue-mirror", token);
        return json is null ? [] : (JsonSerializer.Deserialize<QueueMirrorState>(json)?.Bindings ?? []).ToList();
    }
    Task SaveBindingsAsync(ThreadSession session, List<QueueBinding> bindings, CancellationToken token) => workspace.Threads.SaveStateAsync(session.Record.VeoId, "queue-mirror", JsonSerializer.Serialize(new QueueMirrorState(bindings)), token);
    Task SaveLocalAsync(ThreadSession session, CancellationToken token) => workspace.Threads.SaveStateAsync(session.Record.VeoId, "queue", JsonSerializer.Serialize(session.Queue), token);
    static void Set(List<QueueBinding> bindings, QueueBinding value) { bindings.RemoveAll(x => x.ClientId == value.ClientId); bindings.Add(value); }
    public void Dispose()
    {
        if (workspace.QueueAddedAsync == addedHook) workspace.QueueAddedAsync = previousAdded;
        if (workspace.TryDispatchQueuedAsync == dispatchHook) workspace.TryDispatchQueuedAsync = previousDispatch;
    }
}
