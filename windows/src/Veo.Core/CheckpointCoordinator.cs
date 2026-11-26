using System.Collections.Concurrent;
using System.Text.Json;
using Veo.Infrastructure.Files;
using Veo.Infrastructure.Git;
using Veo.Infrastructure.Projects;
using Veo.Protocol;

namespace Veo.Core;

public sealed record TurnCheckpoint(WorkspaceCheckpoint Checkpoint, string? TurnId = null, string State = "captured");
/// <summary>Nonfatal pre-turn capture with durable payload-to-turn binding; never restores files automatically.</summary>
public sealed class CheckpointCoordinator
{
    static readonly TimeSpan CheckpointInspectionBudget = TimeSpan.FromSeconds(15);
    readonly WorkspaceCoordinator workspace; readonly ProjectPreferencesService projects; readonly ICoordinatorRpc rpc; readonly LocalGitService git;
    readonly ConcurrentDictionary<string, SemaphoreSlim> gates = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, string> warnings = new(StringComparer.Ordinal);
    public CheckpointCoordinator(WorkspaceCoordinator workspace, ProjectPreferencesService projects, ICoordinatorRpc? transport = null)
    { this.workspace = workspace; this.projects = projects; rpc = transport ?? new WorkspaceCoordinatorRpc(workspace); git = new(Path.Combine(workspace.DataRoot, "GitRecovery")); }
    public string? Warning(ThreadSession session) => warnings.GetValueOrDefault(session.Record.VeoId);
    public async Task<IReadOnlyList<TurnCheckpoint>> EntriesAsync(ThreadSession session, CancellationToken token = default)
    {
        var json = await workspace.Threads.ReadStateAsync(session.Record.VeoId, "turn-checkpoints", token);
        return json is null ? [] : JsonSerializer.Deserialize<TurnCheckpoint[]>(json) ?? [];
    }
    public async Task<WorkspaceCheckpoint?> ForTurnAsync(ThreadSession session, string turnId, CancellationToken token = default) =>
        (await EntriesAsync(session, token)).LastOrDefault(x => x.TurnId == turnId)?.Checkpoint;

    public async Task<IReadOnlyList<TurnCheckpoint>> WorkspaceEntriesAsync(ThreadSession session, CancellationToken token = default)
    {
        var states = await workspace.Threads.ReadWorkspaceCheckpointStatesAsync(session.Record.Cwd, token);
        return states.SelectMany(state => state.Key == "checkpoint"
                ? JsonSerializer.Deserialize<WorkspaceCheckpoint>(state.Json) is { } legacy ? [new TurnCheckpoint(legacy, State: "manual")] : Array.Empty<TurnCheckpoint>()
                : JsonSerializer.Deserialize<TurnCheckpoint[]>(state.Json) ?? [])
            .DistinctBy(entry => entry.Checkpoint.Id).OrderByDescending(entry => entry.Checkpoint.CreatedAt).ToArray();
    }

    public async Task CaptureManualAsync(ThreadSession session, CancellationToken token = default)
    {
        await WithIdleWorkspaceAsync(session, async snapshot =>
        {
            await CaptureAndSaveAsync(session, snapshot, Guid.NewGuid().ToString("N"), "manual", token);
        }, token);
    }

    public async Task RestoreFilesAsync(ThreadSession session, WorkspaceCheckpoint checkpoint, CancellationToken token = default)
    {
        await WithIdleWorkspaceAsync(session, async snapshot =>
        {
            if (!checkpoint.WorkspacePath.Equals(snapshot.WorkspacePath, StringComparison.OrdinalIgnoreCase) ||
                checkpoint.RepositoryRoot != snapshot.RootPath || checkpoint.Branch != snapshot.Branch || checkpoint.Head != snapshot.Head)
                throw new InvalidOperationException("Return to this checkpoint's workspace, branch and commit before restoring.");
            var entry = (await WorkspaceEntriesAsync(session, token)).FirstOrDefault(item => item.Checkpoint.Id == checkpoint.Id)
                ?? throw new InvalidOperationException("This checkpoint is no longer available in the workspace.");
            await CaptureAndSaveAsync(session, snapshot, "recovery-" + Guid.NewGuid().ToString("N"), "recovery", token);
            var legacyRoot = Path.Combine(workspace.DataRoot, "Recovery");
            var legacy = Path.GetDirectoryName(entry.Checkpoint.Recovery.BundlePath)?.Equals(legacyRoot, StringComparison.OrdinalIgnoreCase) == true;
            await (legacy ? new LocalGitService(legacyRoot) : git).RestoreCheckpointAsync(entry.Checkpoint, snapshot, token);
        }, token);
    }

    async Task WithIdleWorkspaceAsync(ThreadSession session, Func<GitRepositorySnapshot, Task> action, CancellationToken token)
    {
        await session.DispatchGate.WaitAsync(token);
        try
        {
            await workspace.CheckpointRestoreGate.WaitAsync(token);
            try
            {
                if (session.Timeline.IsRunning || session.IsSubmitting) throw new InvalidOperationException("Stop this chat's active turn first.");
                var snapshot = await git.SnapshotAsync(session.Record.Cwd, token);
                await EnsureNoActiveRepositoryAsync(workspace, rpc, session, git, snapshot, includeCurrentRuntime: true, token);
                await action(snapshot);
            }
            finally { workspace.CheckpointRestoreGate.Release(); }
        }
        finally { session.DispatchGate.Release(); workspace.NotifyChanged(); }
    }

    internal async Task<WorkspaceCheckpoint> CaptureAndSaveAsync(ThreadSession session, GitRepositorySnapshot snapshot, string payloadId, string state, CancellationToken token)
    {
        var captured = await git.CaptureCheckpointAsync(snapshot, session.Record.VeoId, payloadId, token);
        var entries = (await EntriesAsync(session, token)).Append(new TurnCheckpoint(captured, State: state)).ToArray();
        await workspace.Threads.SaveStateAsync(session.Record.VeoId, "turn-checkpoints", JsonSerializer.Serialize(entries), token);
        return captured;
    }

    public async Task BeforeDispatchAsync(ThreadSession session, ComposerSnapshot payload, CancellationToken token = default)
    {
        warnings.TryRemove(session.Record.VeoId, out _);
        // Source captures only where the runtime can revert paginated history, with default-on project preference.
        if (session.Record.CodexThreadId is not { } runtimeId || !rpc.Supports("thread/revert")) return;
        var gate = gates.GetOrAdd(session.Record.VeoId, _ => new(1, 1)); await gate.WaitAsync(token);
        using var preflight = CancellationTokenSource.CreateLinkedTokenSource(token);
        preflight.CancelAfter(CheckpointInspectionBudget);
        var checkpointToken = preflight.Token;
        try
        {
            if ((await projects.ConfigurationAsync(session.Record.Cwd, checkpointToken)).CheckpointsEnabled == false) return;
            if ((await EntriesAsync(session, checkpointToken)).Any(x => x.Checkpoint.PayloadId == payload.ClientId)) return;
            // History eligibility is cheap. Skip Git's full workspace fingerprint when the turn cannot use a checkpoint.
            var response = await rpc.RequestAsync("thread/read", new { threadId = runtimeId, includeTurns = false }, checkpointToken);
            if (!response.TryObjectProperty("thread", out var thread) || thread.Str("historyMode") != "paginated") return;
            GitRepositorySnapshot snapshot;
            try { snapshot = await git.SnapshotAsync(session.Record.Cwd, checkpointToken); }
            catch (NotGitRepositoryException) { return; }
            preflight.CancelAfter(Timeout.InfiniteTimeSpan);
            checkpointToken.ThrowIfCancellationRequested();
            // Once capture starts, let it finish its recovery bundle and metadata as one operation.
            await CaptureAndSaveAsync(session, snapshot, payload.ClientId, "captured", token);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
        catch (OperationCanceledException) when (preflight.IsCancellationRequested)
        { warnings[session.Record.VeoId] = "The automatic checkpoint was skipped because workspace inspection timed out."; }
        catch (Exception error)
        { warnings[session.Record.VeoId] = "Workspace checkpoint unavailable: " + DiagnosticRedactor.Redact(error.Message); }
        finally { gate.Release(); workspace.NotifyChanged(); }
    }
    public async Task AfterDispatchAsync(ThreadSession session, ComposerSnapshot payload, string turnId, CancellationToken token = default)
    {
        if (string.IsNullOrWhiteSpace(turnId)) return;
        try
        {
            var entries = (await EntriesAsync(session, token)).ToArray(); var at = Array.FindIndex(entries, x => x.Checkpoint.PayloadId == payload.ClientId);
            if (at < 0) return;
            if (entries[at].TurnId is { } existing && existing != turnId) throw new InvalidDataException("A saved checkpoint already belongs to a different runtime turn.");
            entries[at] = entries[at] with { TurnId = turnId, State = "bound" };
            await workspace.Threads.SaveStateAsync(session.Record.VeoId, "turn-checkpoints", JsonSerializer.Serialize(entries), token);
        }
        catch (Exception error) { warnings[session.Record.VeoId] = "Turn started, but its checkpoint identity could not be saved: " + DiagnosticRedactor.Redact(error.Message); }
        finally { workspace.NotifyChanged(); }
    }

    internal static async Task EnsureNoActiveRepositoryAsync(WorkspaceCoordinator workspace, ICoordinatorRpc rpc, ThreadSession session,
        LocalGitService git, GitRepositorySnapshot snapshot, bool includeCurrentRuntime, CancellationToken token)
    {
        async Task<bool> UsesRepositoryAsync(string cwd)
        {
            try { return (await git.SnapshotAsync(cwd, token)).CommonDirectory.Equals(snapshot.CommonDirectory, StringComparison.OrdinalIgnoreCase); }
            catch (NotGitRepositoryException) { return false; }
        }
        foreach (var other in workspace.LoadedSessions.Where(x => x.Record.VeoId != session.Record.VeoId && (x.Timeline.IsRunning || x.IsSubmitting)))
            if (await UsesRepositoryAsync(other.Record.Cwd)) throw new InvalidOperationException("Another active chat uses this repository. Stop it before restoring files.");
        if (!rpc.Supports("thread/list")) throw new NotSupportedException("Connect a Codex runtime that can check active chats before changing checkpoint files.");
        string? cursor = null; var seen = new HashSet<string>(StringComparer.Ordinal);
        do
        {
            var response = await rpc.RequestAsync("thread/list", new { cursor, limit = 100, archived = false, currentAccountOnly = false }, token);
            foreach (var row in ThreadCatalogCoordinator.Rows(response, "data"))
            {
                if (!includeCurrentRuntime && row.Str("id") == session.Record.CodexThreadId) continue;
                var status = row.Str("status") ?? (row.TryObjectProperty("status", out var statusObject) ? statusObject.Str("type") : null);
                if (status is not ("active" or "running" or "inProgress")) continue;
                if (row.Str("cwd") is not { } cwd) throw new InvalidOperationException("An active runtime chat has no workspace identity.");
                if (await UsesRepositoryAsync(cwd)) throw new InvalidOperationException("An active Codex chat uses this repository. Stop it before restoring files.");
            }
            cursor = response.Str("nextCursor");
            if (cursor is not null && !seen.Add(cursor)) throw new InvalidDataException("Runtime chat enumeration repeated a cursor.");
        } while (cursor is not null);
    }
}
