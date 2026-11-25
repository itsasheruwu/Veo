using System.Text.Json;
using System.Text.Json.Serialization;

namespace Veo.Core;

[JsonConverter(typeof(JsonStringEnumConverter<ContinuationStatus>))]
public enum ContinuationStatus { Waiting, Dispatching, Blocked, Completed, Cancelled }

public sealed record ContinuationJob
{
    public required string Id { get; init; }
    public required string VeoThreadId { get; init; }
    public required string RuntimeThreadId { get; init; }
    public required string FailedTurnId { get; init; }
    public required string ClientMessageId { get; init; }
    public required string AccountIdentity { get; init; }
    public required string Cwd { get; init; }
    public string Access { get; init; } = "Workspace";
    public string? Model { get; init; }
    public string? Effort { get; init; }
    public string? Tier { get; init; }
    public string InteractionMode { get; init; } = "Agentic";
    public string RoutingMode { get; init; } = "direct";
    public JsonElement? RouteSnapshot { get; init; }
    public DateTimeOffset? ResetAt { get; init; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
    public bool IsEnabled { get; init; }
    public ContinuationStatus Status { get; init; } = ContinuationStatus.Blocked;
    public string? Detail { get; init; }
    public string? ContinuationTurnId { get; init; }
    public bool RequiresSendReconciliation { get; init; }
    public long Revision { get; init; }
    [JsonIgnore] public DateTimeOffset? DispatchAt => ResetAt?.AddSeconds(8);
}

public sealed record ContinuationInspection
{
    public bool RuntimeReady { get; init; }
    public bool ThreadExists { get; init; }
    public bool IsArchived { get; init; }
    public bool WorkspaceAvailable { get; init; }
    public bool IsRunning { get; init; }
    public bool IsLoggedIn { get; init; }
    public required string AccountIdentity { get; init; }
    public required string RuntimeThreadId { get; init; }
    public bool HistoryReconciled { get; init; }
    public bool RateLimitsRechecked { get; init; }
    public bool HasAvailableCapacity { get; init; }
    public DateTimeOffset? NextResetAt { get; init; }
    public string? ExistingContinuationTurnId { get; init; }
}

public interface IContinuationRuntime
{
    /// <summary>Reconcile durable client identity with server history and reread account/limits.</summary>
    Task<ContinuationInspection> InspectAsync(ContinuationJob job, CancellationToken cancellationToken);
    /// <summary>The app's existing runtime sends the unchanged job snapshot, never the helper.</summary>
    Task<string> StartAsync(ContinuationJob job, string prompt, CancellationToken cancellationToken);
}

public sealed class ContinuationCoordinator
{
    public const string ContinuationPrompt = "Continue the interrupted task from the existing conversation and current workspace state. Inspect the work already completed, resume from where the previous turn stopped, verify the result, and do not repeat finished work.";
    private readonly string file;
    private readonly SemaphoreSlim writer = new(1, 1);
    private readonly List<ContinuationJob> jobs = [];
    private bool loaded;
    public event Action? Changed;
    public string JobsFile => file;

    public ContinuationCoordinator(string dataRoot) => file = Path.Combine(Path.GetFullPath(dataRoot), "Continuation", "jobs.json");

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await writer.WaitAsync(cancellationToken);
        try
        {
            if (loaded) return;
            if (File.Exists(file))
            {
                var state = JsonSerializer.Deserialize<ContinuationState>(await File.ReadAllTextAsync(file, cancellationToken)) ?? throw new InvalidDataException("Continuation state is empty.");
                if (state.Version != 1) throw new InvalidDataException("Unsupported continuation state version; the original file was preserved.");
                if (state.Jobs is null || state.Jobs.Count > 10000) throw new InvalidDataException("Continuation state has an invalid job count.");
                foreach (var job in state.Jobs)
                {
                    Validate(job);
                    // A previous dispatch may have reached the runtime. It must be reconciled,
                    // never changed back into a replayable waiting job on app restart.
                    jobs.Add(job.Status == ContinuationStatus.Dispatching
                        ? job with { Status = ContinuationStatus.Blocked, RequiresSendReconciliation = true, Detail = "A previous dispatch needs history reconciliation.", Revision = job.Revision + 1 }
                        : job);
                }
                if (jobs.Select(x => x.Id).Distinct(StringComparer.Ordinal).Count() != jobs.Count) throw new InvalidDataException("Continuation job IDs are duplicated.");
            }
            loaded = true;
        }
        catch { jobs.Clear(); throw; }
        finally { writer.Release(); }
    }

    public async Task<IReadOnlyList<ContinuationJob>> ListAsync(CancellationToken cancellationToken = default)
    {
        await InitializeAsync(cancellationToken);
        await writer.WaitAsync(cancellationToken);
        try { return jobs.Select(Clone).ToArray(); }
        finally { writer.Release(); }
    }

    public async Task UpsertAsync(ContinuationJob job, CancellationToken cancellationToken = default)
    {
        Validate(job);
        await InitializeAsync(cancellationToken);
        await writer.WaitAsync(cancellationToken);
        try
        {
            var existing = jobs.LastOrDefault(x => x.VeoThreadId == job.VeoThreadId && x.Status is not (ContinuationStatus.Completed or ContinuationStatus.Cancelled));
            if (existing is not null && existing.Id != job.Id)
            {
                // A different failed turn supersedes the old record; never reuse its uncertain dispatch identity.
                Replace(existing, existing with { IsEnabled = false, Status = ContinuationStatus.Cancelled, Detail = "Superseded by a newer interruption.", Revision = existing.Revision + 1 });
            }
            var same = jobs.FirstOrDefault(x => x.Id == job.Id);
            if (same?.Status is ContinuationStatus.Completed or ContinuationStatus.Cancelled) throw new InvalidOperationException("Completed continuation identities cannot be reused.");
            if (same is not null && (same.RuntimeThreadId != job.RuntimeThreadId || same.FailedTurnId != job.FailedTurnId || same.AccountIdentity != job.AccountIdentity || same.ClientMessageId != job.ClientMessageId)) throw new InvalidOperationException("A continuation job cannot change its identity.");
            var requiresReconciliation = job.RequiresSendReconciliation || same?.RequiresSendReconciliation == true;
            var saved = Clone(job) with { Revision = (same?.Revision ?? -1) + 1, RequiresSendReconciliation = requiresReconciliation, Status = job.IsEnabled && !requiresReconciliation ? job.Status : ContinuationStatus.Blocked, Detail = !job.IsEnabled ? "Auto-continue is off for this interruption." : requiresReconciliation ? "A previous dispatch needs history reconciliation." : job.Detail };
            if (same is null) jobs.Add(saved); else Replace(same, saved);
            await SaveAsync(cancellationToken);
        }
        finally { writer.Release(); }
        Changed?.Invoke();
    }

    public async Task SetEnabledAsync(string id, bool enabled, CancellationToken cancellationToken = default)
    {
        await MutateAsync(x => x.Id == id && x.Status is not (ContinuationStatus.Completed or ContinuationStatus.Cancelled), x => x with { IsEnabled = enabled, Status = enabled && !x.RequiresSendReconciliation ? ContinuationStatus.Waiting : ContinuationStatus.Blocked, Detail = !enabled ? "Auto-continue is off for this interruption." : x.RequiresSendReconciliation ? "A previous dispatch needs history reconciliation." : null, Revision = x.Revision + 1 }, cancellationToken);
    }

    public Task CancelThreadAsync(string threadId, string reason = "Cancelled by new activity.", CancellationToken cancellationToken = default)
        => MutateAsync(x => x.VeoThreadId == threadId && x.Status is not (ContinuationStatus.Completed or ContinuationStatus.Cancelled), x => Cancel(x, reason), cancellationToken);
    public Task CancelAccountAsync(string? currentAccountIdentity, CancellationToken cancellationToken = default)
        => MutateAsync(x => x.Status is not (ContinuationStatus.Completed or ContinuationStatus.Cancelled) && (string.IsNullOrEmpty(currentAccountIdentity) || x.AccountIdentity != currentAccountIdentity), x => Cancel(x, "Cancelled because the account changed or signed out."), cancellationToken);

    public async Task<IReadOnlyList<ContinuationJob>> DueAsync(DateTimeOffset now, CancellationToken cancellationToken = default)
        => (await ListAsync(cancellationToken)).Where(x => IsDue(x, now)).ToArray();
    public static bool IsDue(ContinuationJob job, DateTimeOffset now) => job.IsEnabled && !job.RequiresSendReconciliation && job.Status == ContinuationStatus.Waiting && job.DispatchAt is DateTimeOffset due && due <= now;

    public async Task<ContinuationJob?> TryResumeAsync(string id, IContinuationRuntime runtime, DateTimeOffset now, CancellationToken cancellationToken = default)
    {
        var job = (await ListAsync(cancellationToken)).FirstOrDefault(x => x.Id == id);
        if (job is null || !job.IsEnabled || job.Status is not (ContinuationStatus.Waiting or ContinuationStatus.Blocked or ContinuationStatus.Dispatching)) return job;
        if (job.Status == ContinuationStatus.Waiting && !IsDue(job, now)) return job;
        var inspection = await runtime.InspectAsync(job, cancellationToken);
        var cancellation = !inspection.IsLoggedIn || inspection.AccountIdentity != job.AccountIdentity ? "Cancelled because the account changed or signed out."
            : !inspection.ThreadExists || inspection.IsArchived || inspection.RuntimeThreadId != job.RuntimeThreadId ? "Cancelled because the chat was deleted, archived or replaced." : null;
        if (cancellation is not null) return await CompareExchangeAsync(job, Cancel(job, cancellation), cancellationToken);
        if (!inspection.RuntimeReady || !inspection.WorkspaceAvailable || inspection.IsRunning || !inspection.HistoryReconciled || !inspection.RateLimitsRechecked)
            return await CompareExchangeAsync(job, job with { Status = ContinuationStatus.Blocked, Detail = "Waiting for a ready workspace, idle thread and fresh account/history reconciliation.", Revision = job.Revision + 1 }, cancellationToken);
        if (inspection.ExistingContinuationTurnId is string existing)
            return await CompareExchangeAsync(job, job with { Status = ContinuationStatus.Completed, IsEnabled = false, RequiresSendReconciliation = false, ContinuationTurnId = existing, Detail = "Continuation reconciled from existing history.", Revision = job.Revision + 1 }, cancellationToken);
        if (job.RequiresSendReconciliation || job.Status is ContinuationStatus.Dispatching)
            return await CompareExchangeAsync(job, job with { Status = ContinuationStatus.Blocked, Detail = "The previous send remains uncertain; explicit manual recovery is required.", Revision = job.Revision + 1 }, cancellationToken);
        if (!inspection.HasAvailableCapacity)
            return await CompareExchangeAsync(job, job with { Status = ContinuationStatus.Waiting, ResetAt = inspection.NextResetAt, Detail = "The refreshed usage limit still prevents continuation.", Revision = job.Revision + 1 }, cancellationToken);
        // Preserve the original reset + 8s even when retrying a blocked job.
        if (job.DispatchAt is not DateTimeOffset dispatchAt || dispatchAt > now) return job;
        var dispatching = job with { Status = ContinuationStatus.Dispatching, RequiresSendReconciliation = true, Detail = null, Revision = job.Revision + 1 };
        var claim = await ExchangeAsync(job, dispatching, cancellationToken);
        if (!claim.Applied) return claim.Job;
        var claimed = claim.Job!;
        try
        {
            var turnId = await runtime.StartAsync(Clone(claimed), ContinuationPrompt, cancellationToken);
            if (string.IsNullOrWhiteSpace(turnId)) throw new InvalidDataException("The continuation send returned no turn identity.");
            return await CompareExchangeAsync(claimed, claimed with { Status = ContinuationStatus.Completed, IsEnabled = false, RequiresSendReconciliation = false, ContinuationTurnId = turnId, Detail = "Continued after the usage limit reset.", Revision = claimed.Revision + 1 }, CancellationToken.None);
        }
        catch (Exception)
        {
            // A failed response does not prove a failed send. Retain dispatch identity and do not replay.
            await CompareExchangeAsync(claimed, claimed with { Status = ContinuationStatus.Blocked, Detail = "A previous dispatch needs history reconciliation.", Revision = claimed.Revision + 1 }, CancellationToken.None);
            throw;
        }
    }

    private async Task<ContinuationJob?> CompareExchangeAsync(ContinuationJob expected, ContinuationJob replacement, CancellationToken cancellationToken)
        => (await ExchangeAsync(expected, replacement, cancellationToken)).Job;
    private async Task<(bool Applied, ContinuationJob? Job)> ExchangeAsync(ContinuationJob expected, ContinuationJob replacement, CancellationToken cancellationToken)
    {
        await writer.WaitAsync(cancellationToken);
        try
        {
            var current = jobs.FirstOrDefault(x => x.Id == expected.Id);
            if (current is null || current.Revision != expected.Revision) return (false, current is null ? null : Clone(current));
            Replace(current, replacement); await SaveAsync(cancellationToken); return (true, Clone(replacement));
        }
        finally { writer.Release(); Changed?.Invoke(); }
    }
    private async Task MutateAsync(Func<ContinuationJob, bool> predicate, Func<ContinuationJob, ContinuationJob> mutate, CancellationToken cancellationToken)
    {
        await InitializeAsync(cancellationToken); await writer.WaitAsync(cancellationToken);
        try { for (var i = 0; i < jobs.Count; i++) if (predicate(jobs[i])) jobs[i] = mutate(jobs[i]); await SaveAsync(cancellationToken); }
        finally { writer.Release(); }
        Changed?.Invoke();
    }
    private async Task SaveAsync(CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        var temporary = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var stream = new FileStream(temporary, new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None, Options = FileOptions.Asynchronous | FileOptions.WriteThrough }))
            {
                await JsonSerializer.SerializeAsync(stream, new ContinuationState(1, jobs), new JsonSerializerOptions { WriteIndented = true }, cancellationToken);
                await stream.FlushAsync(cancellationToken);
                // Persist the dispatch marker before the caller can issue a network send.
                stream.Flush(flushToDisk: true);
            }
            if (File.Exists(file)) File.Replace(temporary, file, null); else File.Move(temporary, file);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private void Replace(ContinuationJob existing, ContinuationJob replacement) => jobs[jobs.IndexOf(existing)] = replacement;
    private static ContinuationJob Cancel(ContinuationJob job, string reason) => job with { Status = ContinuationStatus.Cancelled, IsEnabled = false, Detail = reason, Revision = job.Revision + 1 };
    private static ContinuationJob Clone(ContinuationJob job) => job with { RouteSnapshot = job.RouteSnapshot?.Clone() };
    private static void Validate(ContinuationJob job)
    {
        if (new[] { job.Id, job.VeoThreadId, job.RuntimeThreadId, job.FailedTurnId, job.ClientMessageId, job.AccountIdentity, job.Cwd }.Any(string.IsNullOrWhiteSpace)) throw new InvalidDataException("Continuation identity and workspace are required.");
        if (!Guid.TryParse(job.Id, out _)) throw new InvalidDataException("A continuation job requires a GUID identity for packaged activation.");
        if (job.Access is not ("ReadOnly" or "Read only" or "Workspace" or "Auto" or "Full" or "Full access")) throw new InvalidDataException("The saved continuation access mode is unsupported.");
        if (!Path.IsPathFullyQualified(job.Cwd)) throw new InvalidDataException("The continuation workspace must be an absolute path.");
        if (job.ResetAt > DateTimeOffset.MaxValue.AddSeconds(-8)) throw new InvalidDataException("The continuation reset time exceeds the supported range.");
    }
    private sealed record ContinuationState(int Version, List<ContinuationJob> Jobs);
}
