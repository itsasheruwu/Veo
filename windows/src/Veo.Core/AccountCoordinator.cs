using System.Collections.Concurrent;
using System.Text.Json;
using Veo.Protocol;

namespace Veo.Core;

public sealed record AccountIdentity(string Type, string? Email, string? Plan, string? Workspace, string? UserId, bool RequiresAuth);
public sealed record AccountLoginFlow(long Generation, string? LoginId, string Type, Uri? Url, string? UserCode, string Status, string? Error = null);
public sealed record AccountUsageWindow(int UsedPercent, long? DurationMinutes, DateTimeOffset? ResetsAt);
public sealed record AccountUsageBucket(string Id, string Title, AccountUsageWindow? Primary, AccountUsageWindow? Secondary, string? Balance, bool Unlimited, string? LimitReason);
public sealed record AccountResetCredit(string Id, string Title, string? Description, string Status, DateTimeOffset? ExpiresAt);
public sealed record AccountDailyUsage(string Date, long Tokens);
public sealed record AccountUsageSummary(long? LifetimeTokens, long? CurrentStreak, long? PeakDailyTokens, AccountDailyUsage[] Daily);
public sealed record AccountWorkspace(string AccountId, string Name, string? Kind);
public sealed record AccountSavedSession(string SessionId, string Name, bool Active, string? SelectedWorkspace, AccountWorkspace[] Workspaces);
public sealed record AccountState(AccountIdentity? Identity, AccountUsageBucket[] Usage, bool? OrdinaryUsageAllowed, long? AvailableResetCredits, AccountResetCredit[] ResetCredits, AccountUsageSummary? Tokens, AccountSavedSession[] Sessions, IntegrationIssue[] Issues)
{ public static AccountState Empty { get; } = new(null, [], null, null, [], null, [], []); }

/// <summary>Codex owns account credentials. Veo retains display metadata and one-time login state only in memory.</summary>
public sealed class AccountCoordinator : IAsyncDisposable
{
    readonly WorkspaceCoordinator workspace;
    readonly SemaphoreSlim mutations = new(1, 1);
    readonly SemaphoreSlim reads = new(1, 1);
    readonly ConcurrentDictionary<string, (long Generation, bool Success, string? Error)> completedLogins = new(StringComparer.Ordinal);
    bool disposed;
    public AccountState State { get; private set; } = AccountState.Empty;
    public AccountLoginFlow? Login { get; private set; }
    public event Action? Changed;
    public event Action<Uri>? Navigate;
    public AccountCoordinator(WorkspaceCoordinator workspace) { this.workspace = workspace; workspace.RuntimeEventReceived += OnEvent; }
    public bool Available(string method) => workspace.Runtime.Capabilities.Availability(method) != CapabilityAvailability.Unavailable;
    async Task<JsonElement> RequestAsync(string method, object? parameters, CancellationToken cancellation)
    { using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation); timeout.CancelAfter(TimeSpan.FromSeconds(30)); return await workspace.Runtime.RequestAsync(method, parameters, timeout.Token); }
    public async Task<AccountIdentity?> ReadIdentityAsync(CancellationToken cancellation = default)
    {
        var runtime = workspace.Runtime;
        var generation = runtime.Generation;
        var response = await RequestAsync("account/read", new { refreshToken = false }, cancellation);
        return ReferenceEquals(runtime, workspace.Runtime) && generation == runtime.Generation ? ParseIdentity(response) : null;
    }

    static AccountIdentity? ParseIdentity(JsonElement response) => response.TryObjectProperty("account", out var info)
        ? new(info.Str("type") ?? "unknown", info.Str("email"), info.Str("planType"), info.Str("workspaceName"),
            response.Str("userId"), IntegrationCoordinator.Bool(response, "requiresOpenaiAuth"))
        : null;

    public async Task<AccountState> RefreshAsync(CancellationToken cancellation = default)
    {
        await reads.WaitAsync(cancellation);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this); var generation = workspace.Runtime.Generation; var issues = new List<IntegrationIssue>();
            async Task<JsonElement> Read(string method, object? parameters)
            { try { return await RequestAsync(method, parameters, cancellation); } catch (Exception ex) when (ex is not OperationCanceledException || !cancellation.IsCancellationRequested) { issues.Add(new(method, DiagnosticRedactor.Redact(ex.Message), ex is NotSupportedException || ex is CodexRpcException { Code: -32601 })); return default; } }
            var account = await Read("account/read", new { refreshToken = false });
            var identity = account.ValueKind == JsonValueKind.Undefined ? State.Identity : ParseIdentity(account);
            var rate = await Read("account/rateLimits/read", null); var buckets = new List<AccountUsageBucket>();
            if (rate.TryObjectProperty("rateLimitsByLimitId", out var byId)) foreach (var bucket in byId.EnumerateObject()) buckets.Add(ParseBucket(bucket.Name, bucket.Value));
            else if (rate.TryObjectProperty("rateLimits", out var single)) buckets.Add(ParseBucket(single.Str("limitId") ?? "codex", single));
            bool? ordinary = rate.ValueKind == JsonValueKind.Object && rate.TryGetProperty("ordinaryUsageAllowed", out var allowed) && allowed.ValueKind is JsonValueKind.True or JsonValueKind.False ? allowed.GetBoolean() : null;
            var credits = rate.TryObjectProperty("rateLimitResetCredits", out var reset) ? reset : default;
            var resetCredits = IntegrationCoordinator.Rows(credits, "credits").Where(x => x.Str("id") is not null).Select(x => new AccountResetCredit(x.Str("id")!, x.Str("title") ?? "Usage reset credit", x.Str("description"), x.Str("status") ?? "unknown", Date(x, "expiresAt"))).ToArray();
            var tokens = await Read("account/usage/read", null); AccountUsageSummary? summary = null;
            if (tokens.TryObjectProperty("summary", out var t)) summary = new(Number(t, "lifetimeTokens"), Number(t, "currentStreakDays"), Number(t, "peakDailyTokens"), IntegrationCoordinator.Rows(tokens, "dailyUsageBuckets").Where(x => x.Str("startDate") is not null && Number(x, "tokens") is not null).Select(x => new AccountDailyUsage(x.Str("startDate")!, Number(x, "tokens")!.Value)).ToArray());
            var sessions = await Read("accountSession/list", new { });
            var saved = IntegrationCoordinator.Rows(sessions, "sessions").Where(x => x.Str("sessionId") is not null).Select(x => new AccountSavedSession(x.Str("sessionId")!, x.Str("displayName") ?? x.Str("email") ?? "Saved login", IntegrationCoordinator.Bool(x, "isActive"), x.Str("selectedWorkspaceAccountId"), IntegrationCoordinator.Rows(x, "workspaces").Where(w => w.Str("accountId") is not null).Select(w => new AccountWorkspace(w.Str("accountId")!, w.Str("name") ?? "Personal workspace", w.Str("kind"))).ToArray())).ToArray();
            if (generation != workspace.Runtime.Generation) throw new InvalidOperationException("The runtime reconnected while account state was loading. Refresh again.");
            State = new(identity, buckets.ToArray(), ordinary, Number(credits, "availableCount"), resetCredits, summary, saved, issues.ToArray()); Changed?.Invoke(); return State;
        }
        finally { reads.Release(); }
    }
    public async Task<AccountLoginFlow> StartLoginAsync(string type, string? apiKey = null, CancellationToken cancellation = default)
    {
        if (type is not ("apiKey" or "chatgpt" or "chatgptDeviceCode")) throw new NotSupportedException("This account login method is not supported by Veo.");
        if (type == "apiKey" && string.IsNullOrWhiteSpace(apiKey)) throw new InvalidOperationException("Enter an API key.");
        await mutations.WaitAsync(cancellation);
        try
        {
            if (Login is { Status: "Awaiting user", Generation: var current } && current == workspace.Runtime.Generation) throw new InvalidOperationException("Complete or cancel the current sign-in first.");
            var generation = workspace.Runtime.Generation; var parameters = new Dictionary<string, object?> { ["type"] = type }; if (type == "apiKey") parameters["apiKey"] = apiKey;
            else if (type == "chatgpt") { parameters["appBrand"] = "codex"; parameters["useHostedLoginSuccessPage"] = false; }
            var response = await RequestAsync("account/login/start", parameters, cancellation);
            if (generation != workspace.Runtime.Generation) throw new InvalidOperationException("The runtime changed during sign-in. Refresh account state before trying again.");
            var returned = response.Str("type"); if (returned != type) throw new InvalidDataException("Codex returned a different login method.");
            var id = response.Str("loginId"); var urlText = response.Str("authUrl") ?? response.Str("verificationUrl"); var url = IntegrationCoordinator.SecureUri(urlText);
            if (type != "apiKey" && (id is null || url is null)) throw new InvalidDataException("Codex did not return a complete secure sign-in flow.");
            var flow = new AccountLoginFlow(generation, id, type, url, response.Str("userCode"), type == "apiKey" ? "Accepted by Codex" : "Awaiting user");
            if (id is not null && completedLogins.TryGetValue(id, out var completion) && completion.Generation == generation) flow = flow with { Status = completion.Success ? "Completed" : "Failed", Error = completion.Error };
            Login = flow; if (url is not null && flow.Status == "Awaiting user") Navigate?.Invoke(url); await RefreshAsync(cancellation); Changed?.Invoke(); return Login;
        }
        finally { mutations.Release(); }
    }
    public void OpenLoginBrowser() { if (Login is not { Url: { } url, Status: "Awaiting user" } flow || flow.Generation != workspace.Runtime.Generation) throw new InvalidOperationException("There is no current sign-in URL."); Navigate?.Invoke(url); }
    public async Task CancelLoginAsync(CancellationToken cancellation = default)
    {
        await mutations.WaitAsync(cancellation);
        try
        {
            var flow = Login ?? throw new InvalidOperationException("No sign-in is pending."); if (flow.LoginId is null || flow.Generation != workspace.Runtime.Generation) throw new InvalidOperationException("This sign-in belongs to a previous runtime. Refresh account state.");
            var response = await RequestAsync("account/login/cancel", new { loginId = flow.LoginId }, cancellation); var status = response.Str("status");
            if (status is not ("canceled" or "notFound")) throw new InvalidDataException("Codex did not confirm cancellation.");
            Login = flow with { Status = status == "canceled" ? "Cancelled" : "No longer pending" }; await RefreshAsync(cancellation); Changed?.Invoke();
        }
        finally { mutations.Release(); }
    }
    public async Task LogoutAsync(CancellationToken cancellation = default)
    {
        await mutations.WaitAsync(cancellation);
        try { await RequestAsync("account/logout", null, cancellation); Login = null; completedLogins.Clear(); var state = await RefreshAsync(cancellation); if (state.Identity is not null) throw new IOException("Codex still reports a signed-in account. Logout was not confirmed."); }
        finally { mutations.Release(); }
    }
    public async Task SwitchAsync(string sessionId, string accountId, bool allowBrowserLogin, CancellationToken cancellation = default)
    {
        if (!State.Sessions.Any(x => x.SessionId == sessionId && x.Workspaces.Any(w => w.AccountId == accountId))) throw new InvalidOperationException("Choose a workspace from the latest saved-login inventory.");
        await mutations.WaitAsync(cancellation);
        try
        {
            var response = await RequestAsync("accountSession/switch", new { sessionId, accountId, allowBrowserLogin }, cancellation);
            if (response.Str("auth_url") is { } urlText)
            {
                var url = IntegrationCoordinator.SecureUri(urlText) ?? throw new InvalidDataException("Codex returned an insecure sign-in URL."); var id = response.Str("login_id") ?? throw new InvalidDataException("Codex returned no sign-in identity."); var flow = new AccountLoginFlow(workspace.Runtime.Generation, id, "chatgpt", url, null, "Awaiting user");
                if (completedLogins.TryGetValue(id, out var completion) && completion.Generation == flow.Generation) flow = flow with { Status = completion.Success ? "Completed" : "Failed", Error = completion.Error };
                Login = flow; if (flow.Status == "Awaiting user") Navigate?.Invoke(url); else await RefreshAsync(cancellation);
            }
            else { var state = await RefreshAsync(cancellation); if (!state.Sessions.Any(x => x.SessionId == sessionId && x.Active && x.SelectedWorkspace == accountId)) throw new IOException("Codex did not confirm the requested workspace selection."); }
            Changed?.Invoke();
        }
        finally { mutations.Release(); }
    }
    public async Task<string> RedeemResetCreditAsync(string idempotencyKey, string? creditId = null, CancellationToken cancellation = default)
    {
        if (!Guid.TryParse(idempotencyKey, out _)) throw new ArgumentException("Use one UUID for this logical reset attempt.", nameof(idempotencyKey));
        if (creditId is not null && !State.ResetCredits.Any(x => x.Id == creditId && x.Status == "available")) throw new InvalidOperationException("Refresh and choose an available reset credit.");
        await mutations.WaitAsync(cancellation);
        try
        {
            var response = await RequestAsync("account/rateLimitResetCredit/consume", new { creditId, idempotencyKey }, cancellation); var outcome = response.Str("outcome");
            if (outcome is not ("reset" or "nothingToReset" or "noCredit" or "alreadyRedeemed")) throw new InvalidDataException("Codex returned an unknown usage reset outcome.");
            await RefreshAsync(cancellation); return outcome;
        }
        finally { mutations.Release(); }
    }
    async void OnEvent(RuntimeEvent message)
    {
        if (disposed) return;
        try
        {
            if (message.Method == "account/login/completed" && message.Parameters.Str("loginId") is { } id)
            {
                var p = message.Parameters; var success = IntegrationCoordinator.Bool(p, "success"); var error = p.Str("error") is { } e ? DiagnosticRedactor.Redact(e) : null;
                completedLogins[id] = (message.Generation, success, error);
                if (Login is { } flow && flow.Generation == message.Generation && flow.LoginId == id) { Login = flow with { Status = success ? "Completed" : "Failed", Error = error }; Changed?.Invoke(); }
                await RefreshAsync();
            }
            else if (message.Method is "account/updated" or "account/rateLimits/updated") await RefreshAsync();
        }
        catch (Exception ex) { if (!disposed) { State = State with { Issues = State.Issues.Append(new IntegrationIssue("account refresh", DiagnosticRedactor.Redact(ex.Message), false)).TakeLast(8).ToArray() }; Changed?.Invoke(); } }
    }
    static AccountUsageBucket ParseBucket(string id, JsonElement value) => new(id, value.Str("limitName") ?? id, Window(value, "primary"), Window(value, "secondary"), value.TryObjectProperty("credits", out var credit) ? credit.Str("balance") : null, value.TryObjectProperty("credits", out credit) && IntegrationCoordinator.Bool(credit, "unlimited"), value.Str("rateLimitReachedType"));
    static AccountUsageWindow? Window(JsonElement element, string key) => element.TryObjectProperty(key, out var value) && Number(value, "usedPercent") is >= 0 and <= int.MaxValue and var percent ? new((int)percent, Number(value, "windowDurationMins"), Date(value, "resetsAt")) : null;
    public static long? Number(JsonElement element, string key) => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number) ? number : null;
    public static DateTimeOffset? Date(JsonElement element, string key) { if (Number(element, key) is not { } number) return null; try { return DateTimeOffset.FromUnixTimeSeconds(number); } catch (ArgumentOutOfRangeException) { return null; } }
    public ValueTask DisposeAsync() { disposed = true; workspace.RuntimeEventReceived -= OnEvent; return ValueTask.CompletedTask; }
}
