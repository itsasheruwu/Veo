using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using Veo.Infrastructure.Git;
using Veo.Infrastructure.Storage;
using Veo.Protocol;

namespace Veo.Core;

public enum HistoryMode { Automatic, TimelineV3, Items, Turns, Read }
public sealed record HistoryPage(HistoryMode Mode, IReadOnlyList<TimelineItem> Items, string? NextCursor, IReadOnlyList<string> TurnIds, bool IsRunning = false, string? ActiveTurnId = null, IReadOnlyList<TimelineTurn>? TurnMetadata = null);
public sealed record HistoryRevertResult(bool RuntimeReverted, bool FilesRestored, GitRecoveryReceipt? Recovery, string? Warning);

/// <summary>Cursor types remain bound to their history method; only a first-page method absence permits fallback.</summary>
public sealed class HistoryCoordinator(WorkspaceCoordinator workspace, ICoordinatorRpc? transport = null, CheckpointCoordinator? checkpoints = null)
{
    readonly ICoordinatorRpc rpc = transport ?? new WorkspaceCoordinatorRpc(workspace);
    readonly ConcurrentDictionary<string, SemaphoreSlim> gates = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, (HistoryMode Mode, string? Cursor, HashSet<string> Seen)> paging = new(StringComparer.Ordinal);
    public async Task<HistoryPage> LoadAsync(ThreadSession session, bool more = false, HistoryMode preferred = HistoryMode.Automatic, CancellationToken token = default)
    {
        var gate = gates.GetOrAdd(session.Record.VeoId, _ => new(1, 1)); await gate.WaitAsync(token);
        try
        {
            var id = session.Record.CodexThreadId ?? throw new InvalidOperationException("This chat has no runtime history yet.");
            var mode = preferred; string? cursor = null; var seen = new HashSet<string>(StringComparer.Ordinal);
            if (more)
            {
                if (!paging.TryGetValue(session.Record.VeoId, out var previous) || previous.Cursor is null) return new(preferred, [], null, []);
                mode = previous.Mode; cursor = previous.Cursor; seen = new(previous.Seen, StringComparer.Ordinal);
            }
            var version = session.Timeline.StateVersion;
            var page = await ReadPageAsync(id, mode, cursor, token);
            session.Timeline.ObserveTurns(page.TurnMetadata ?? []);
            if (page.NextCursor is not null && !seen.Add(page.NextCursor)) throw new InvalidDataException("History repeated a page cursor; the current timeline was kept.");
            var current = session.Timeline.Items.Where(x => x.Kind is not "veoUserInputAnswer" and not "veoPlanArtifact").ToArray();
            var combined = more && page.Mode != HistoryMode.TimelineV3 ? page.Items.Concat(current) : current.Concat(page.Items);
            var items = combined.GroupBy(x => x.Id, StringComparer.Ordinal).Select(x => x.Last()).Select((item, order) => item with { Order = order }).ToArray();
            session.Timeline.Reconcile(items, session.Timeline.IsRunning, session.Timeline.ActiveTurnId, version);
            await workspace.PersistTimelineAsync(session); paging[session.Record.VeoId] = (page.Mode, page.NextCursor, seen); workspace.NotifyChanged();
            return page;
        }
        finally { gate.Release(); }
    }
    public async Task<TimelineItem?> NavigateOccurrenceAsync(ThreadSession session, CatalogSearchResult occurrence, CancellationToken token = default)
    {
        if (occurrence.TurnCursor is { } cursor && rpc.Supports("thread/turns/list"))
        {
            var response = await rpc.RequestAsync("thread/turns/list", new { threadId = session.Record.CodexThreadId, cursor, limit = 1, sortDirection = "asc", itemsView = "full" }, token);
            var page = ParseTurns(response, HistoryMode.Turns);
            session.Timeline.ObserveTurns(page.TurnMetadata ?? []);
            if (!page.Items.Any(x => x.Id == occurrence.ItemId && x.TurnId == occurrence.TurnId)) throw new InvalidDataException("The occurrence cursor did not resolve to the expected message.");
            session.Timeline.Reconcile(page.Items.Concat(session.Timeline.Items).DistinctBy(x => x.Id), session.Timeline.IsRunning, session.Timeline.ActiveTurnId);
            await workspace.PersistTimelineAsync(session); workspace.NotifyChanged();
        }
        return session.Timeline.Items.FirstOrDefault(x => x.Id == occurrence.ItemId && x.TurnId == occurrence.TurnId);
    }
    public async Task<HistoryPage> ReconcilePendingRevertAsync(ThreadSession session, CancellationToken token = default)
    {
        var gate = gates.GetOrAdd(session.Record.VeoId, _ => new(1, 1)); await gate.WaitAsync(token);
        try { await session.DispatchGate.WaitAsync(token); } catch { gate.Release(); throw; }
        try
        {
            if (session.Timeline.IsRunning || session.IsSubmitting) throw new InvalidOperationException("Stop the active chat before reconciling a history change.");
            var json = await workspace.Threads.ReadStateAsync(session.Record.VeoId, "history-revert", token) ?? throw new InvalidOperationException("There is no recorded history change to reconcile.");
            using var state = JsonDocument.Parse(json); var boundary = state.RootElement.Str("beforeTurnId") ?? throw new InvalidDataException("The saved history change has no turn boundary.");
            var page = await ReadAllTurnsAsync(session.Record.CodexThreadId ?? throw new InvalidOperationException("This chat has no runtime history."), token);
            if (page.TurnIds.Contains(boundary, StringComparer.Ordinal)) throw new InvalidOperationException("The selected turn is still present. The prior outcome remains uncertain; this action did not repeat the revert.");
            await session.PersistenceGate.WaitAsync(token);
            try
            {
                await workspace.Threads.ReplaceHistoryAsync(session.Record.VeoId, PersistTurns(page), Persist(page.Items), token);
                session.Timeline.ReplaceHistory(page.Items, page.IsRunning, page.ActiveTurnId, page.TurnIds); session.Timeline.ConfirmRemovedItems(session.Timeline.RemovedItemIds);
                session.Timeline.ObserveTurns(page.TurnMetadata ?? []);
            }
            finally { session.PersistenceGate.Release(); }
            var reconciled = JsonNode.Parse(json)!.AsObject(); reconciled["state"] = "reconciled";
            await workspace.Threads.SaveStateAsync(session.Record.VeoId, "history-revert", reconciled.ToJsonString(), token);
            if (session.DispatchWarning?.StartsWith("History change", StringComparison.Ordinal) == true || session.DispatchWarning?.StartsWith("Codex accepted the history change", StringComparison.Ordinal) == true) session.DispatchWarning = null;
            paging.TryRemove(session.Record.VeoId, out _); return page;
        }
        finally { session.DispatchGate.Release(); gate.Release(); workspace.NotifyChanged(); }
    }
    public async Task<HistoryRevertResult> RevertAsync(ThreadSession session, string beforeTurnId, bool editFromHere = false,
        WorkspaceCheckpoint? restoreFiles = null, CancellationToken token = default)
    {
        var gate = gates.GetOrAdd(session.Record.VeoId, _ => new(1, 1)); await gate.WaitAsync(token);
        try { await session.DispatchGate.WaitAsync(token); } catch { gate.Release(); throw; }
        var restoreGateHeld = false;
        try
        {
            if (session.Timeline.IsRunning || session.IsSubmitting) throw new InvalidOperationException("Stop the active turn before changing history.");
            if (!rpc.Supports("thread/revert")) throw new NotSupportedException("The connected Codex runtime cannot revert history.");
            var id = session.Record.CodexThreadId ?? throw new InvalidOperationException("This chat has no runtime history.");
            var previous = await workspace.Threads.ReadStateAsync(session.Record.VeoId, "history-revert", token);
            if (previous is not null)
            {
                using var saved = JsonDocument.Parse(previous);
                if (saved.RootElement.Str("state") == "pending") throw new InvalidOperationException("A previous history change is uncertain. Inspect and refresh runtime history before another revert.");
            }
            var selected = session.Timeline.Items.FirstOrDefault(x => x.TurnId == beforeTurnId && x.Kind == "userMessage");
            if (editFromHere && selected is null) throw new InvalidOperationException("Edit from here needs a user message with a turn boundary.");
            var remoteBefore = await ReadAllTurnsAsync(id, token);
            if (remoteBefore.IsRunning) throw new InvalidOperationException("Stop the runtime's active turn before changing history.");
            if (!remoteBefore.TurnIds.Contains(beforeTurnId, StringComparer.Ordinal)) throw new InvalidOperationException("The selected turn no longer exists; refresh history.");
            LocalGitService? git = null; WorkspaceCheckpoint? reversal = null; GitRepositorySnapshot? snapshot = null;
            if (restoreFiles is not null)
            {
                await workspace.CheckpointRestoreGate.WaitAsync(token);
                restoreGateHeld = true;
                if (restoreFiles.ThreadId != session.Record.VeoId || !Path.GetFullPath(restoreFiles.WorkspacePath).Equals(Path.GetFullPath(session.Record.Cwd), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("The checkpoint belongs to a different chat or workspace.");
                git = new(Path.Combine(workspace.DataRoot, "GitRecovery")); snapshot = await git.SnapshotAsync(session.Record.Cwd, token);
                if (snapshot.Head != restoreFiles.Head || snapshot.Branch != restoreFiles.Branch || !snapshot.CanMutate) throw new InvalidOperationException("The checkpoint branch or HEAD changed, or Git is busy.");
                await CheckpointCoordinator.EnsureNoActiveRepositoryAsync(workspace, rpc, session, git, snapshot, includeCurrentRuntime: false, token);
                var recoveryId = "recovery-" + Guid.NewGuid().ToString("N");
                reversal = checkpoints is not null
                    ? await checkpoints.CaptureAndSaveAsync(session, snapshot, recoveryId, "recovery", token)
                    : await git.CaptureCheckpointAsync(snapshot, session.Record.VeoId, recoveryId, token);
            }
            await workspace.Threads.SaveStateAsync(session.Record.VeoId, "history-revert", JsonSerializer.Serialize(new { state = "pending", beforeTurnId, recovery = reversal }), token);
            try { await rpc.RequestAsync("thread/revert", new { threadId = id, beforeTurnId }, token); }
            catch (CodexRpcException) { await workspace.Threads.SaveStateAsync(session.Record.VeoId, "history-revert", "{\"state\":\"rejected\"}", CancellationToken.None); throw; }
            catch { session.DispatchWarning = "History change outcome is uncertain. Refresh runtime history before sending or reverting again."; throw; }
            try
            {
                var retained = await ReadAllTurnsAsync(id, token);
                if (retained.TurnIds.Contains(beforeTurnId, StringComparer.Ordinal)) throw new InvalidDataException("Codex did not confirm the selected history boundary was removed.");
                await session.PersistenceGate.WaitAsync(token);
                try
                {
                    await workspace.Threads.ReplaceHistoryAsync(session.Record.VeoId, PersistTurns(retained), Persist(retained.Items), token);
                    session.Timeline.ReplaceHistory(retained.Items, retained.IsRunning, retained.ActiveTurnId, retained.TurnIds);
                    session.Timeline.ObserveTurns(retained.TurnMetadata ?? []);
                    session.Timeline.ConfirmRemovedItems(session.Timeline.RemovedItemIds);
                }
                finally { session.PersistenceGate.Release(); }
                if (editFromHere && selected is not null)
                {
                    var images = ThreadCatalogCoordinator.Rows(selected.Raw, "content").Where(x => x.Str("type") == "localImage").Select(x => x.Str("path")).OfType<string>().ToArray();
                    var existing = JsonSerializer.Deserialize<string[]>(session.Draft.AttachmentsJson) ?? [];
                    await workspace.SaveDraftAsync(session, string.IsNullOrWhiteSpace(session.Draft.Text) ? selected.Text : session.Draft.Text + "\n\n" + selected.Text, existing.Concat(images).Distinct(StringComparer.Ordinal).ToArray());
                }
                GitRecoveryReceipt? receipt = reversal?.Recovery;
                if (restoreFiles is not null && git is not null)
                {
                    try
                    {
                        await CheckpointCoordinator.EnsureNoActiveRepositoryAsync(workspace, rpc, session, git, snapshot!, includeCurrentRuntime: true, token);
                        var restored = await git.RestoreCheckpointAsync(restoreFiles, snapshot, token); receipt = reversal?.Recovery ?? restored.Recovery;
                    }
                    catch (Exception error)
                    {
                        await workspace.Threads.SaveStateAsync(session.Record.VeoId, "history-revert", JsonSerializer.Serialize(new { state = "history-reverted-files-failed", beforeTurnId, recovery = reversal }), CancellationToken.None);
                        return new(true, false, receipt, "History was reverted and the draft restored. File restoration failed: " + error.Message);
                    }
                }
                await workspace.Threads.SaveStateAsync(session.Record.VeoId, "history-revert", JsonSerializer.Serialize(new { state = "complete", beforeTurnId, recovery = reversal }), CancellationToken.None);
                paging.TryRemove(session.Record.VeoId, out _); return new(true, restoreFiles is not null, receipt, null);
            }
            catch { session.DispatchWarning = "Codex accepted the history change, but refresh failed. Refresh history before sending again; do not repeat the revert."; throw; }
        }
        finally
        {
            if (restoreGateHeld) workspace.CheckpointRestoreGate.Release();
            session.DispatchGate.Release(); gate.Release(); workspace.NotifyChanged();
        }
    }
    async Task<HistoryPage> ReadAllTurnsAsync(string id, CancellationToken token)
    {
        var all = new List<TimelineItem>(); var turns = new List<string>(); var metadata = new List<TimelineTurn>(); string? cursor = null; var seen = new HashSet<string>(StringComparer.Ordinal); bool running = false; string? active = null;
        do
        {
            var page = await ReadPageAsync(id, HistoryMode.Turns, cursor, token); all.InsertRange(0, page.Items); turns.InsertRange(0, page.TurnIds); metadata.InsertRange(0, page.TurnMetadata ?? []); cursor = page.NextCursor;
            running |= page.IsRunning; active ??= page.ActiveTurnId;
            if (cursor is not null && !seen.Add(cursor)) throw new InvalidDataException("Runtime history repeated a cursor.");
        } while (cursor is not null);
        return new(HistoryMode.Turns, all.DistinctBy(x => x.Id).Select((item, index) => item with { Order = index }).ToArray(), null, turns.Distinct(StringComparer.Ordinal).ToArray(), running, active, metadata.DistinctBy(t => t.Id).Select((t, index) => t with { Order = index }).ToArray());
    }
    async Task<HistoryPage> ReadPageAsync(string id, HistoryMode mode, string? cursor, CancellationToken token)
    {
        var candidates = mode == HistoryMode.Automatic ? new[] { HistoryMode.TimelineV3, HistoryMode.Items, HistoryMode.Turns, HistoryMode.Read } : cursor is null ? mode switch { HistoryMode.TimelineV3 => [HistoryMode.TimelineV3, HistoryMode.Items, HistoryMode.Turns, HistoryMode.Read], HistoryMode.Items => [HistoryMode.Items, HistoryMode.Turns, HistoryMode.Read], HistoryMode.Turns => [HistoryMode.Turns, HistoryMode.Read], _ => new[] { mode } } : [mode];
        foreach (var candidate in candidates)
        {
            var method = candidate switch { HistoryMode.TimelineV3 => "thread/timeline/list", HistoryMode.Items => "thread/items/list", HistoryMode.Turns => "thread/turns/list", _ => "thread/read" };
            if (!rpc.Supports(method)) { if (cursor is not null) throw new NotSupportedException("The runtime lost support for the current history cursor."); continue; }
            JsonElement response;
            try
            {
                response = await rpc.RequestAsync(method, candidate switch
                {
                    HistoryMode.TimelineV3 => new { threadId = id, cursor, limit = 100 },
                    HistoryMode.Items => (object)new { threadId = id, cursor, limit = 100, sortDirection = "desc" },
                    HistoryMode.Turns => new { threadId = id, cursor, limit = 100, sortDirection = "desc", itemsView = "full" },
                    _ => new { threadId = id, includeTurns = true }
                }, token);
            }
            catch (CodexRpcException error) when (error.Code == -32601 && cursor is null) { continue; }
            if (candidate is HistoryMode.Read or HistoryMode.Turns) return ParseTurns(response, candidate);
            var items = new List<TimelineItem>(); var turns = new List<string>();
            foreach (var row in ThreadCatalogCoordinator.Rows(response, "data"))
            {
                var turn = row.Str("turnId") ?? row.Str("turn_id"); if (turn is not null) turns.Add(turn);
                if (!row.TryObjectProperty("item", out var item)) continue;
                if (candidate == HistoryMode.TimelineV3 && row.Str("type") == "realtime")
                {
                    if (item.Str("type") != "transcriptSegment" || item.Str("id") is not { } realtimeId) continue;
                    var raw = JsonNode.Parse(item.GetRawText())!.AsObject(); raw["id"] = "realtime-" + realtimeId; raw["type"] = item.Str("role") == "user" ? "userMessage" : "agentMessage"; item = JsonSerializer.SerializeToElement(raw);
                }
                if (Item(item, turn, items.Count) is { } parsed) items.Add(parsed);
            }
            if (candidate == HistoryMode.Items) items.Reverse();
            return new(candidate, items.Select((item, order) => item with { Order = order }).ToArray(), response.Str("nextCursor"), turns.Distinct(StringComparer.Ordinal).ToArray());
        }
        throw new NotSupportedException("The connected runtime exposes no usable history method.");
    }
    static HistoryPage ParseTurns(JsonElement response, HistoryMode mode)
    {
        var turns = mode == HistoryMode.Read && response.TryObjectProperty("thread", out var thread) ? ThreadCatalogCoordinator.Rows(thread, "turns") : ThreadCatalogCoordinator.Rows(response, "data");
        if (mode != HistoryMode.Read) Array.Reverse(turns);
        var items = new List<TimelineItem>(); foreach (var turn in turns) foreach (var item in ThreadCatalogCoordinator.Rows(turn, "items")) if (Item(item, turn.Str("id"), items.Count) is { } parsed) items.Add(parsed);
        var active = turns.LastOrDefault(Running).Str("id");
        return new(mode, items, mode == HistoryMode.Read ? null : response.Str("nextCursor"), turns.Select(x => x.Str("id")).OfType<string>().ToArray(), active is not null || mode == HistoryMode.Read && response.TryObjectProperty("thread", out var metadata) && Running(metadata), active, turns.Select((t, order) => TimelineTurn.Parse(t, order: order)).OfType<TimelineTurn>().ToArray());
    }
    static TimelineItem? Item(JsonElement raw, string? turn, long order) => raw.Str("id") is { } id ? new(id, turn, raw.Str("type") ?? "unknown", TimelineReducer.ExtractText(raw), raw.Str("status") ?? "completed", raw.Clone(), order) : null;
    static bool Running(JsonElement value) => (value.Str("status") ?? (value.TryObjectProperty("status", out var status) ? status.Str("type") : null)) is "active" or "running" or "inProgress";
    static PersistedTurn[] PersistTurns(HistoryPage page) => (page.TurnMetadata ?? []).Select(t => new PersistedTurn(t.Id, t.Status, t.StartedAt, t.ErrorJson, t.Order, t.TerminalObserved, t.CompletedAt, t.Diff, t.Steers)).ToArray();
    static PersistedItem[] Persist(IReadOnlyList<TimelineItem> items) => items.Select(item =>
    {
        var raw = JsonNode.Parse(item.Raw.GetRawText())!.AsObject(); raw["veoRenderedText"] = item.Text;
        return new PersistedItem(item.Id, item.TurnId, item.Kind, item.Raw.Str("clientId"), item.Status, raw.ToJsonString(), item.Order, DateTimeOffset.UtcNow);
    }).ToArray();
}
