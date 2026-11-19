using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Veo.Infrastructure.Files;
using Veo.Infrastructure.Storage;
using Veo.Protocol;

namespace Veo.Core;

public sealed record ContinuationPreferences(int Version = 1, bool EnabledByDefault = false);
public sealed record ContinuationActivationResult(string? ThreadId, string Status);

/// <summary>App-owned continuation adapter. The scheduled helper never creates a runtime.</summary>
public sealed class WorkspaceContinuationService : IContinuationRuntime, IAsyncDisposable
{
    private readonly WorkspaceCoordinator workspace;
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim resuming = new(1, 1);
    private readonly Channel<RuntimeEvent> notifications = Channel.CreateBounded<RuntimeEvent>(new BoundedChannelOptions(32) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
    private readonly Func<ThreadSession, ComposerSnapshot, bool, Task>? previousBeforeDispatch;
    private readonly string preferencesFile;
    private Task? observer, timer;
    private bool initialized, monitoringFailed;
    private string? observedAccount;
    public ContinuationCoordinator Jobs { get; }
    public ContinuationPreferences Preferences { get; private set; } = new();
    public string Status { get; private set; } = "Automatic continuation is off by default.";
    public event Action? Changed;

    public WorkspaceContinuationService(WorkspaceCoordinator workspace)
    {
        this.workspace = workspace;
        Jobs = new(workspace.DataRoot);
        preferencesFile = Path.Combine(workspace.DataRoot, "Continuation", "preferences.json");
        previousBeforeDispatch = workspace.BeforeDispatchAsync;
        workspace.BeforeDispatchAsync = BeforeDispatchAsync;
        workspace.RuntimeNotificationReceived += ObserveNotification;
        Jobs.Changed += OnJobsChanged;
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        if (initialized) return;
        await Jobs.InitializeAsync(cancellationToken);
        if (File.Exists(preferencesFile))
        {
            Preferences = JsonSerializer.Deserialize<ContinuationPreferences>(await File.ReadAllTextAsync(preferencesFile, cancellationToken)) ?? throw new InvalidDataException("Continuation preferences are empty.");
            if (Preferences.Version != 1) throw new InvalidDataException("Unsupported continuation preferences version; the file was preserved.");
        }
        observedAccount = AccountIdentity(workspace.Account);
        if (workspace.Runtime.RuntimeState == CodexRuntimeState.Ready) await Jobs.CancelAccountAsync(observedAccount, cancellationToken);
        initialized = true;
        observer = ObserveAsync(); timer = TimerAsync();
        await ProcessDueAsync(cancellationToken);
    }

    public async Task SetEnabledByDefaultAsync(bool enabled, CancellationToken cancellationToken = default)
    {
        Preferences = Preferences with { EnabledByDefault = enabled };
        Directory.CreateDirectory(Path.GetDirectoryName(preferencesFile)!);
        var temporary = preferencesFile + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(Preferences), cancellationToken);
            if (File.Exists(preferencesFile)) File.Replace(temporary, preferencesFile, null); else File.Move(temporary, preferencesFile);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
        SetStatus(enabled ? "Future usage-limit interruptions can resume after their reported reset. Existing jobs keep their own choice." : "Future automatic continuation is off. Existing jobs keep their own choice.");
    }

    private async Task BeforeDispatchAsync(ThreadSession session, ComposerSnapshot payload, bool isContinuation)
    {
        if (previousBeforeDispatch is not null) await previousBeforeDispatch(session, payload, isContinuation);
        if (!isContinuation) await Jobs.CancelThreadAsync(session.Record.VeoId, "Cancelled by new activity.", lifetime.Token);
        else
        {
            var claim = (await Jobs.ListAsync(lifetime.Token)).FirstOrDefault(x => x.VeoThreadId == session.Record.VeoId && x.ClientMessageId == payload.ClientId);
            if (claim is null || !claim.IsEnabled || claim.Status != ContinuationStatus.Dispatching) throw new OperationCanceledException("The continuation was cancelled before dispatch.");
        }
        // Persist separately from the transient dispatch marker so a later turn error
        // retains the original access/model/effort/tier/mode, even after acknowledgement.
        var cwd = new WorkspacePathPolicy(session.Record.Cwd).RootPath;
        var routing = await workspace.Threads.ReadStateAsync(session.Record.VeoId, "model-route", lifetime.Token);
        await workspace.Threads.SaveStateAsync(session.Record.VeoId, "continuation-source-payload", JsonSerializer.Serialize(new SourcePayload(payload with { Attachments = payload.Attachments.ToArray() }, cwd, routing)), lifetime.Token);
    }

    private void ObserveNotification(RuntimeEvent message)
    {
        if (message.Method is not ("error" or "turn/completed" or "account/updated" or "account/rateLimits/updated" or "account/login/completed")) return;
        if (!notifications.Writer.TryWrite(message))
        {
            monitoringFailed = true;
            SetStatus("Continuation monitoring paused because its event backlog filled. Reopen Veo before enabling another continuation.");
        }
    }

    private async Task ObserveAsync()
    {
        try
        {
            await foreach (var message in notifications.Reader.ReadAllAsync(lifetime.Token))
            {
                if (message.Generation != workspace.Runtime.Generation) continue;
                if (message.Method is "account/updated" or "account/login/completed")
                {
                    if (workspace.Runtime.RuntimeState == CodexRuntimeState.Ready) await RefreshAccountIdentityAsync(lifetime.Token);
                    continue;
                }
                if (TryUsageLimitFailure(message, out var runtimeThread, out var failedTurn))
                    await RecordUsageLimitAsync(runtimeThread, failedTurn, lifetime.Token);
                else if (message.Method == "account/rateLimits/updated")
                    await ProcessDueAsync(lifetime.Token); // Fresh full read happens in InspectAsync; never treat a sparse update as recovery.
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception error) { monitoringFailed = true; SetStatus("Continuation monitoring paused: " + DiagnosticRedactor.Redact(error.Message)); }
    }

    public static bool TryUsageLimitFailure(RuntimeEvent message, out string runtimeThreadId, out string failedTurnId)
    {
        var p = message.Parameters;
        runtimeThreadId = p.Str("threadId") ?? "";
        failedTurnId = p.Str("turnId") ?? "";
        JsonElement error = default;
        if (message.Method == "error")
        {
            if (p.TryGetProperty("willRetry", out var retry) && retry.ValueKind == JsonValueKind.True) return false;
            if (p.TryObjectProperty("error", out var value)) error = value;
        }
        else if (message.Method == "turn/completed" && p.TryObjectProperty("turn", out var turn))
        { failedTurnId = turn.Str("id") ?? failedTurnId; if (turn.TryObjectProperty("error", out var value)) error = value; }
        return runtimeThreadId.Length > 0 && failedTurnId.Length > 0 && error.Str("codexErrorInfo") == "usageLimitExceeded";
    }

    private async Task RecordUsageLimitAsync(string runtimeId, string failedTurn, CancellationToken cancellationToken)
    {
        var record = await FindRecordAsync(x => x.CodexThreadId == runtimeId, cancellationToken);
        if (record is null || record.IsArchived) return;
        var source = await workspace.Threads.ReadStateAsync(record.VeoId, "continuation-source-payload", cancellationToken);
        if (source is null) { SetStatus("The interrupted turn has no durable payload snapshot; resume it manually."); return; }
        var saved = JsonSerializer.Deserialize<SourcePayload>(source) ?? throw new InvalidDataException("The failed-turn payload is invalid.");
        await workspace.RefreshAccountAsync();
        var account = AccountIdentity(workspace.Account);
        if (account is null) { SetStatus("The runtime did not report a stable account identity for automatic continuation."); return; }
        var reset = ApplicableReset(workspace.RateLimits, DateTimeOffset.UtcNow);
        if (reset is null) { SetStatus("Usage is limited, but Codex has not reported a reset time. Resume manually when usage is available."); return; }
        var pending = (await Jobs.ListAsync(cancellationToken)).LastOrDefault(x => x.VeoThreadId == record.VeoId && x.Status is not (ContinuationStatus.Completed or ContinuationStatus.Cancelled));
        if (pending?.FailedTurnId == failedTurn) return; // Error and turn/completed describe the same interruption.
        var enabled = pending?.IsEnabled ?? Preferences.EnabledByDefault;
        var routingMode = "direct"; JsonElement? route = null;
        if (saved.RoutingJson is not null)
        {
            using var document = JsonDocument.Parse(saved.RoutingJson);
            routingMode = document.RootElement.Str("routingMode") ?? "direct";
            route = document.RootElement.Clone();
        }
        await Jobs.UpsertAsync(new ContinuationJob
        {
            Id = Guid.NewGuid().ToString(), VeoThreadId = record.VeoId, RuntimeThreadId = runtimeId, FailedTurnId = failedTurn,
            ClientMessageId = "auto-continue-" + Guid.NewGuid().ToString("N"), AccountIdentity = account, Cwd = saved.Cwd,
            Access = saved.Payload.Access, Model = saved.Payload.Model, Effort = saved.Payload.Effort, Tier = saved.Payload.Tier,
            InteractionMode = saved.Payload.Mode, RoutingMode = routingMode, RouteSnapshot = route,
            ResetAt = reset, IsEnabled = enabled, Status = enabled ? ContinuationStatus.Waiting : ContinuationStatus.Blocked,
        }, cancellationToken);
        SetStatus(enabled ? "Continuation is waiting for the reported reset plus eight seconds." : "This usage-limit interruption is saved with automatic continuation off.");
    }

    public async Task ProcessDueAsync(CancellationToken cancellationToken = default)
    {
        if (!initialized || monitoringFailed || workspace.Runtime.RuntimeState != CodexRuntimeState.Ready) return;
        if (!(await Jobs.ListAsync(cancellationToken)).Any(x => x.Status is not (ContinuationStatus.Completed or ContinuationStatus.Cancelled))) return;
        await resuming.WaitAsync(cancellationToken);
        try
        {
            await RefreshAccountIdentityAsync(cancellationToken);
            foreach (var job in await Jobs.ListAsync(cancellationToken))
            {
                if (job.Status is ContinuationStatus.Completed or ContinuationStatus.Cancelled) continue;
                var record = await FindRecordAsync(x => x.VeoId == job.VeoThreadId, cancellationToken);
                if (record is null || record.IsArchived) { await Jobs.CancelThreadAsync(job.VeoThreadId, "Cancelled because the chat was deleted or archived.", cancellationToken); continue; }
                if (!ContinuationCoordinator.IsDue(job, DateTimeOffset.UtcNow)) continue;
                try { await Jobs.TryResumeAsync(job.Id, this, DateTimeOffset.UtcNow, cancellationToken); }
                catch (Exception error) when (error is not OperationCanceledException) { SetStatus("Continuation needs attention: " + DiagnosticRedactor.Redact(error.Message)); }
            }
        }
        finally { resuming.Release(); }
    }

    public async Task<ContinuationJob?> RecheckAsync(string id, CancellationToken cancellationToken = default)
    {
        if (monitoringFailed) throw new InvalidOperationException(Status);
        await resuming.WaitAsync(cancellationToken);
        try { return await Jobs.TryResumeAsync(id, this, DateTimeOffset.UtcNow, cancellationToken); }
        finally { resuming.Release(); }
    }

    public async Task<ContinuationActivationResult> HandleActivationAsync(string arguments, CancellationToken cancellationToken = default)
    {
        var match = System.Text.RegularExpressions.Regex.Match(arguments, @"(?:^|\s)--continuation-job\s+""?([0-9a-fA-F-]{32,36})""?(?:\s|$)");
        if (!match.Success || !Guid.TryParse(match.Groups[1].Value, out var id)) return new(null, "No continuation activation was requested.");
        if (!initialized) return new(null, "The workspace must initialize before reconciling continuation activation.");
        var job = (await Jobs.ListAsync(cancellationToken)).FirstOrDefault(x => Guid.TryParse(x.Id, out var existing) && existing == id);
        try
        {
            var logs = Path.Combine(workspace.DataRoot, "Logs"); Directory.CreateDirectory(logs);
            await File.WriteAllTextAsync(Path.Combine(logs, "last-continuation-activation.json"), JsonSerializer.Serialize(new { JobId = id, KnownJob = job is not null, ProcessId = Environment.ProcessId, RuntimeGeneration = workspace.Runtime.Generation, ReceivedAtUtc = DateTimeOffset.UtcNow }), cancellationToken);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { SetStatus("Continuation activation diagnostics could not be saved: " + DiagnosticRedactor.Redact(error.Message)); }
        if (job is null) return new(null, "The continuation is no longer present.");
        await ProcessDueAsync(cancellationToken);
        return new(job.VeoThreadId, Status);
    }

    public async Task<ContinuationInspection> InspectAsync(ContinuationJob job, CancellationToken cancellationToken)
    {
        var record = await FindRecordAsync(x => x.VeoId == job.VeoThreadId, cancellationToken);
        var ready = workspace.Runtime.RuntimeState == CodexRuntimeState.Ready;
        var account = ready ? await workspace.InspectAsync("account/read", new { refreshToken = false }) : default;
        var identity = AccountIdentity(account);
        var result = new ContinuationInspection { RuntimeReady = ready, ThreadExists = record is not null, IsArchived = record?.IsArchived ?? false, IsLoggedIn = identity is not null, AccountIdentity = identity ?? "", RuntimeThreadId = record?.CodexThreadId ?? "" };
        if (!ready || record is null || record.IsArchived || identity != job.AccountIdentity) return result;
        bool sameWorkspace;
        try { sameWorkspace = new WorkspacePathPolicy(record.Cwd).RootPath == new WorkspacePathPolicy(job.Cwd).RootPath; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { sameWorkspace = false; }
        if (!sameWorkspace) return result;
        var session = await workspace.LoadAsync(record);
        var history = await workspace.InspectAsync("thread/read", new { threadId = job.RuntimeThreadId, includeTurns = true });
        if (!history.TryObjectProperty("thread", out var thread)) throw new InvalidDataException("The runtime returned no thread history.");
        var running = session.Timeline.IsRunning || Running(thread);
        string? existingTurn = null;
        if (thread.TryGetProperty("turns", out var turns) && turns.ValueKind == JsonValueKind.Array)
            foreach (var turn in turns.EnumerateArray())
            {
                running |= Running(turn);
                if (turn.TryGetProperty("items", out var items) && items.ValueKind == JsonValueKind.Array && items.EnumerateArray().Any(item => (item.Str("clientId") ?? item.Str("clientUserMessageId")) == job.ClientMessageId)) existingTurn = turn.Str("id");
            }
        var limits = await workspace.InspectAsync("account/rateLimits/read");
        var accountId = account.TryObjectProperty("workspaceRouting", out var routing) ? routing.Str("chatgptAccountId") : null;
        var limitAccount = limits.Str("accountId");
        var capacity = limits.TryGetProperty("ordinaryUsageAllowed", out var allowed) && allowed.ValueKind == JsonValueKind.True && (accountId is null || limitAccount is null || accountId == limitAccount);
        if (!capacity) SetStatus("Codex has not reported permission to resume ordinary usage. The continuation remains blocked or deferred.");
        return result with { WorkspaceAvailable = true, IsRunning = running, HistoryReconciled = true, RateLimitsRechecked = true, HasAvailableCapacity = capacity, NextResetAt = ApplicableReset(limits, DateTimeOffset.UtcNow), ExistingContinuationTurnId = existingTurn, RuntimeThreadId = thread.Str("id") ?? result.RuntimeThreadId };
    }

    public async Task<string> StartAsync(ContinuationJob job, string prompt, CancellationToken cancellationToken)
    {
        if (job.RoutingMode != "direct") throw new NotSupportedException("The saved routing workflow is not implemented on this Windows artifact; resume it manually without dropping its route snapshot.");
        var record = await FindRecordAsync(x => x.VeoId == job.VeoThreadId, cancellationToken) ?? throw new InvalidOperationException("The continuation chat was deleted.");
        if (record.IsArchived || new WorkspacePathPolicy(record.Cwd).RootPath != new WorkspacePathPolicy(job.Cwd).RootPath) throw new InvalidOperationException("The continuation workspace changed.");
        var session = await workspace.LoadAsync(record);
        var access = job.Access switch { "ReadOnly" or "Read only" => "Read only", "Workspace" => "Workspace", "Full" or "Full access" => "Full access", _ => throw new InvalidDataException("The saved continuation access is unavailable.") };
        var snapshot = new ComposerSnapshot(job.ClientMessageId, prompt, job.Model, job.Effort, job.Tier, access, job.InteractionMode, [], PreserveDraft: true);
        if (job.RouteSnapshot is { ValueKind: JsonValueKind.Object } route && route.TryObjectProperty("payload", out var original))
            snapshot = JsonSerializer.Deserialize<ComposerSnapshot>(original.GetRawText())?.Freeze() ?? throw new InvalidDataException("The continuation request snapshot is invalid.");
        snapshot = snapshot with { ClientId = job.ClientMessageId, Text = prompt, Model = job.Model, Effort = job.Effort, Tier = job.Tier, Access = access, Mode = job.InteractionMode, Attachments = [], PreserveDraft = true };
        return await workspace.SubmitContinuationAsync(session, snapshot, cancellationToken);
    }

    private async Task RefreshAccountIdentityAsync(CancellationToken cancellationToken)
    {
        if (workspace.Runtime.RuntimeState != CodexRuntimeState.Ready) return;
        var account = await workspace.InspectAsync("account/read", new { refreshToken = false });
        var identity = AccountIdentity(account);
        if (identity != observedAccount) { await Jobs.CancelAccountAsync(identity, cancellationToken); observedAccount = identity; }
    }

    public static string? AccountIdentity(JsonElement response)
    {
        if (!response.TryObjectProperty("account", out var account) || account.Str("type") != "chatgpt") return null;
        string? stable = null;
        if (response.TryObjectProperty("workspaceRouting", out var routing) && routing.Str("chatgptAccountId") is { Length: > 0 } id)
            stable = "chatgpt|" + id + "|" + routing.Str("backendOrigin") + "|" + response.Str("userId");
        else if (account.Str("email") is { Length: > 0 } email) stable = "chatgpt|" + email + "|" + account.Str("workspaceName") + "|" + response.Str("userId");
        return stable is null ? null : Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(stable)));
    }

    public static DateTimeOffset? ApplicableReset(JsonElement response, DateTimeOffset now)
    {
        if (!response.TryObjectProperty("rateLimits", out var limits)) return null;
        var windows = new List<(int Used, DateTimeOffset Reset)>();
        foreach (var name in new[] { "primary", "secondary" })
            if (limits.TryObjectProperty(name, out var window) && window.TryGetProperty("resetsAt", out var reset) && reset.ValueKind == JsonValueKind.Number && reset.TryGetInt64(out var seconds) && window.TryGetProperty("usedPercent", out var used) && used.ValueKind == JsonValueKind.Number && used.TryGetInt32(out var percent))
            { try { var at = DateTimeOffset.FromUnixTimeSeconds(seconds); if (at > now) windows.Add((percent, at)); } catch (ArgumentOutOfRangeException) { } }
        var exhausted = windows.Where(x => x.Used >= 100).Select(x => (DateTimeOffset?)x.Reset).Min();
        return exhausted ?? windows.Select(x => (DateTimeOffset?)x.Reset).Min();
    }

    private async Task<PersistedThread?> FindRecordAsync(Func<PersistedThread, bool> predicate, CancellationToken cancellationToken)
    {
        foreach (var archived in new[] { false, true })
            for (var offset = 0; ; offset += 1000)
            {
                var page = await workspace.Threads.ListThreadsAsync(archived, limit: 1000, offset: offset, cancellationToken: cancellationToken);
                if (page.FirstOrDefault(predicate) is { } found) return found;
                if (page.Count < 1000) break;
            }
        return null;
    }
    private async Task TimerAsync()
    {
        using var ticks = new PeriodicTimer(TimeSpan.FromSeconds(5));
        try { while (await ticks.WaitForNextTickAsync(lifetime.Token)) await ProcessDueAsync(lifetime.Token); }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception error) { SetStatus("Continuation needs attention: " + DiagnosticRedactor.Redact(error.Message)); }
    }
    private static bool Running(JsonElement value) => (value.Str("status") ?? (value.TryObjectProperty("status", out var status) ? status.Str("type") : null)) is "inProgress" or "running" or "active";
    private void OnJobsChanged() => Changed?.Invoke();
    private void SetStatus(string status) { Status = status; Changed?.Invoke(); }
    public async ValueTask DisposeAsync()
    {
        workspace.RuntimeNotificationReceived -= ObserveNotification; Jobs.Changed -= OnJobsChanged;
        if (workspace.BeforeDispatchAsync == BeforeDispatchAsync) workspace.BeforeDispatchAsync = previousBeforeDispatch;
        lifetime.Cancel(); notifications.Writer.TryComplete();
        if (observer is not null) await observer; if (timer is not null) await timer;
        lifetime.Dispose(); resuming.Dispose();
    }
    private sealed record SourcePayload(ComposerSnapshot Payload, string Cwd, string? RoutingJson);
}
