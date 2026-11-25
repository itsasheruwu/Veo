using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.RegularExpressions;
using Veo.Protocol;

namespace Veo.Core;

public sealed record RuntimeConfigField(string Key, string Title, string Kind, JsonElement Value, string[] Choices, bool Managed);
public sealed record RuntimeFeature(string Name, string Title, string Description, string Stage, bool Enabled, bool? Required);
public sealed record RuntimeHook(string Key, string Event, string Handler, string Source, string Path, string Trust, bool Enabled, bool Managed);
public sealed record RuntimePermissionProfile(string Id, string? Description, bool Allowed);
public sealed record RuntimeConfigSnapshot(string? Cwd, JsonElement Config, JsonElement Requirements, RuntimeConfigField[] Fields, RuntimeFeature[] Features,
    RuntimeHook[] Hooks, RuntimePermissionProfile[] Profiles, string[] LoadedThreads, IntegrationIssue[] Issues, string? UserFile, string? UserVersion);
public sealed record RuntimeConfigWriteResult(bool Applied, string Message, JsonElement EffectiveValue);
public sealed record RuntimeApprovalReview(string Id, string RuntimeThreadId, string? TurnId, string? ItemId, string Phase, string Status, string? Risk, string Rationale, string Action, string? DecisionSource, DateTimeOffset UpdatedAt)
{
    public bool NeedsAttention => Status is "denied" or "timedOut" or "strictReviewRequired";
}

/// <summary>Runtime configuration and managed policy stay owned by Codex. Failed setup never changes Veo access.</summary>
public sealed class RuntimeManagementCoordinator : IAsyncDisposable
{
    readonly WorkspaceCoordinator workspace;
    readonly SemaphoreSlim writes = new(1, 1);
    readonly ConcurrentDictionary<string, RuntimeConfigSnapshot> snapshots = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, RuntimeApprovalReview> reviews = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, JsonElement> configSchemas = new(StringComparer.Ordinal);
    bool disposed;
    public string WindowsSandboxStatus { get; private set; } = "unknown";
    public string? WindowsSandboxError { get; private set; }
    public event Action? Changed;
    public RuntimeManagementCoordinator(WorkspaceCoordinator workspace) { this.workspace = workspace; workspace.RuntimeEventReceived += OnEvent; }
    public RuntimeConfigSnapshot? Snapshot(IntegrationContext context) => snapshots.GetValueOrDefault(context.Key);
    public IReadOnlyList<RuntimeApprovalReview> ApprovalReviews(ThreadSession? session) => reviews.Values.Where(x => session?.Record.CodexThreadId == x.RuntimeThreadId).OrderByDescending(x => x.UpdatedAt).ToArray();
    async Task<JsonElement> RequestAsync(string method, object? parameters, CancellationToken cancellation, int seconds = 30)
    { using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation); timeout.CancelAfter(TimeSpan.FromSeconds(seconds)); return await workspace.Runtime.RequestAsync(method, parameters, timeout.Token); }
    public async Task<RuntimeConfigSnapshot> RefreshAsync(IntegrationContext context, CancellationToken cancellation = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this); var issues = new List<IntegrationIssue>();
        async Task<JsonElement> Read(string method, object? parameters)
        {
            try { return await RequestAsync(method, parameters, cancellation); }
            catch (Exception exception) when (exception is not OperationCanceledException || !cancellation.IsCancellationRequested)
            { issues.Add(new(method, DiagnosticRedactor.Redact(exception.Message), exception is NotSupportedException || exception is CodexRpcException { Code: -32601 })); return default; }
        }
        var configResponse = await Read("config/read", new { cwd = context.Cwd, includeLayers = true });
        var requirementsResponse = await Read("configRequirements/read", null);
        var config = configResponse.TryObjectProperty("config", out var c) ? c.Clone() : JsonSerializer.SerializeToElement(new { });
        var requirements = requirementsResponse.TryObjectProperty("requirements", out var r) ? r.Clone() : JsonSerializer.SerializeToElement(new { });
        var origins = configResponse.TryObjectProperty("origins", out var o) ? o : default;
        var features = new List<RuntimeFeature>();
        foreach (var item in await PagesAsync("experimentalFeature/list", new() { ["threadId"] = context.RuntimeThreadId }, Read, cancellation))
        {
            if (item.Str("name") is not { } name) continue; bool? forced = null;
            if (requirements.TryObjectProperty("featureRequirements", out var required) && required.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False) forced = value.GetBoolean();
            features.Add(new(name, item.Str("displayName") ?? Humanize(name), item.Str("description") ?? "", item.Str("stage") ?? "unknown", IntegrationCoordinator.Bool(item, "enabled"), forced));
        }
        var hooksResponse = await Read("hooks/list", new { cwds = context.Cwd is null ? System.Array.Empty<string>() : new[] { context.Cwd }, threadId = context.RuntimeThreadId });
        var hooks = IntegrationCoordinator.Rows(hooksResponse, "data").SelectMany(x => IntegrationCoordinator.Rows(x, "hooks")).Where(x => x.Str("key") is not null).Select(x => new RuntimeHook(x.Str("key")!, x.Str("eventName") ?? "Hook", x.Str("handlerType") ?? "unknown", x.Str("source") ?? "unknown", x.Str("sourcePath") ?? "", x.Str("trustStatus") ?? "unknown", IntegrationCoordinator.Bool(x, "enabled"), IntegrationCoordinator.Bool(x, "isManaged"))).ToArray();
        var profiles = (await PagesAsync("permissionProfile/list", new() { ["cwd"] = context.Cwd }, Read, cancellation)).Where(x => x.Str("id") is not null).Select(x => new RuntimePermissionProfile(x.Str("id")!, x.Str("description"), IntegrationCoordinator.Bool(x, "allowed"))).ToArray();
        var loaded = (await PagesAsync("thread/loaded/list", new(), Read, cancellation)).Select(x => x.ValueKind == JsonValueKind.String ? x.GetString() : x.Str("id") ?? x.Str("threadId")).OfType<string>().Distinct(StringComparer.Ordinal).ToArray();
        string? userFile = null, userVersion = null;
        foreach (var layer in IntegrationCoordinator.Rows(configResponse, "layers"))
            if (layer.TryObjectProperty("name", out var name) && name.Str("type") == "user") { userFile = name.Str("file"); userVersion = layer.Str("version"); }
        LoadConfigSchemas();
        var fields = config.EnumerateObject().Where(x => x.Value.ValueKind is JsonValueKind.String or JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False or JsonValueKind.Null)
            .Where(x => !SensitiveKey(x.Name)).Select(property =>
            {
                var kind = property.Value.ValueKind switch { JsonValueKind.String => "string", JsonValueKind.Number => property.Value.TryGetInt64(out _) ? "integer" : "number", JsonValueKind.True or JsonValueKind.False => "boolean", _ => SchemaType(property.Name) };
                var originManaged = origins.ValueKind == JsonValueKind.Object && origins.TryObjectProperty(property.Name, out var origin) && origin.TryObjectProperty("name", out var name) && name.Str("type") is "enterpriseManaged" or "mdm" or "legacyManagedConfigTomlFromFile";
                var requirementKey = property.Name switch { "sandbox_mode" => "allowedSandboxModes", "approval_policy" => "allowedApprovalPolicies", "approvals_reviewer" => "allowedApprovalsReviewers", _ => null };
                var allowed = requirementKey is not null && requirements.TryGetProperty(requirementKey, out var permitted) && permitted.ValueKind == JsonValueKind.Array ? permitted.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray() : null;
                var choices = allowed ?? SchemaChoices(property.Name);
                var policyManaged = allowed is { Length: <= 1 } || property.Name == "model_provider" && requirements.Str("modelProvider") is not null;
                return new RuntimeConfigField(property.Name, Humanize(property.Name), kind, property.Value.Clone(), choices, originManaged || policyManaged);
            }).ToArray();
        var snapshot = new RuntimeConfigSnapshot(context.Cwd, config, requirements, fields, features.ToArray(), hooks, profiles, loaded, issues.ToArray(), userFile, userVersion); snapshots[context.Key] = snapshot;
        try { await RefreshWindowsSandboxAsync(cancellation); } catch (Exception exception) when (exception is not OperationCanceledException || !cancellation.IsCancellationRequested) { WindowsSandboxError = DiagnosticRedactor.Redact(exception.Message); }
        Changed?.Invoke(); return snapshot;
    }
    static async Task<JsonElement[]> PagesAsync(string method, Dictionary<string, object?> parameters, Func<string, object?, Task<JsonElement>> read, CancellationToken cancellation)
    {
        var result = new List<JsonElement>(); var seen = new HashSet<string>(); string? cursor = null;
        do
        {
            cancellation.ThrowIfCancellationRequested(); var page = new Dictionary<string, object?>(parameters) { ["limit"] = 100 }; if (cursor is not null) page["cursor"] = cursor;
            var response = await read(method, page); result.AddRange(IntegrationCoordinator.Rows(response, "data")); cursor = response.Str("nextCursor");
            if (!string.IsNullOrEmpty(cursor) && !seen.Add(cursor)) throw new InvalidDataException($"{method} repeated a pagination cursor.");
        } while (!string.IsNullOrEmpty(cursor));
        return result.ToArray();
    }
    public async Task ValidateAccessAsync(ThreadSession session, ComposerSnapshot payload)
    {
        JsonElement response;
        try { response = await RequestAsync("configRequirements/read", null, default); }
        catch (NotSupportedException) { return; }
        catch (CodexRpcException exception) when (exception.Code == -32601) { return; }
        if (!response.TryObjectProperty("requirements", out var requirements)) return;
        var permission = ComposerPermission.Get(payload.Access);
        if (requirements.TryGetProperty("allowedSandboxModes", out var modes) && modes.ValueKind == JsonValueKind.Array && !modes.EnumerateArray().Any(x => x.ValueKind == JsonValueKind.String && x.GetString() == permission.Sandbox)) throw new InvalidOperationException("Managed runtime policy does not allow the selected access. Choose an allowed profile; Veo has kept the current scope unchanged.");
        if (requirements.TryGetProperty("allowedApprovalPolicies", out var policies) && policies.ValueKind == JsonValueKind.Array && !policies.EnumerateArray().Any(x => x.ValueKind == JsonValueKind.String && x.GetString() == permission.Policy)) throw new InvalidOperationException("Managed runtime policy does not allow the selected permission mode. Choose an allowed mode before sending.");
    }
    public async Task<RuntimeConfigWriteResult> WriteScalarAsync(IntegrationContext context, string key, string value, CancellationToken cancellation = default)
    {
        await writes.WaitAsync(cancellation);
        try
        {
            var before = Snapshot(context) ?? await RefreshAsync(context, cancellation); var field = before.Fields.FirstOrDefault(x => x.Key == key) ?? throw new InvalidOperationException("Refresh the supported configuration fields before editing.");
            if (field.Managed) throw new InvalidOperationException("This setting is controlled by managed policy.");
            object? typed = field.Kind switch { "string" => value, "boolean" => bool.Parse(value), "integer" => long.Parse(value, System.Globalization.CultureInfo.InvariantCulture), "number" => double.Parse(value, System.Globalization.CultureInfo.InvariantCulture), _ => throw new NotSupportedException("This configuration field has no supported native editor.") };
            if (field.Choices.Length > 0 && !field.Choices.Contains(value, StringComparer.Ordinal)) throw new InvalidOperationException("Choose a value advertised by the selected CLI schema.");
            if (typed is double d && !double.IsFinite(d)) throw new InvalidOperationException("A finite number is required.");
            var parameters = new Dictionary<string, object?> { ["keyPath"] = key, ["mergeStrategy"] = "replace", ["value"] = typed };
            if (before.UserVersion is not null) parameters["expectedVersion"] = before.UserVersion;
            if (before.UserFile is not null) parameters["filePath"] = before.UserFile;
            var written = await RequestAsync("config/value/write", parameters, cancellation);
            var after = await RefreshAsync(context, cancellation); var effective = after.Config.TryGetProperty(key, out var actual) ? actual.Clone() : default;
            var applied = effective.ValueKind != JsonValueKind.Undefined && JsonElement.DeepEquals(effective, JsonSerializer.SerializeToElement(typed));
            return new(applied, applied ? "Saved and confirmed. Active turns retain their current settings." : written.TryObjectProperty("overriddenMetadata", out var overridden) ? overridden.Str("message") ?? "The saved value is overridden by another configuration layer." : "The runtime did not confirm this value as effective.", effective);
        }
        finally { writes.Release(); Changed?.Invoke(); }
    }
    public async Task SetFeatureAsync(IntegrationContext context, RuntimeFeature feature, bool enabled, CancellationToken cancellation = default)
    {
        await writes.WaitAsync(cancellation);
        try
        {
            var snapshot = Snapshot(context) ?? await RefreshAsync(context, cancellation); var current = snapshot.Features.FirstOrDefault(x => x.Name == feature.Name) ?? throw new InvalidOperationException("Refresh the runtime feature inventory.");
            if (current.Required is { } required && required != enabled) throw new InvalidOperationException("This feature is required by managed policy.");
            await RequestAsync("experimentalFeature/enablement/set", new { enablement = new Dictionary<string, bool> { [feature.Name] = enabled } }, cancellation);
            var after = await RefreshAsync(context, cancellation); if (after.Features.FirstOrDefault(x => x.Name == feature.Name)?.Enabled != enabled) throw new IOException("The runtime did not confirm this feature's enabled state.");
        }
        finally { writes.Release(); Changed?.Invoke(); }
    }
    public async Task UnsubscribeAsync(IntegrationContext context, string runtimeThreadId, CancellationToken cancellation = default)
    {
        if (runtimeThreadId == context.RuntimeThreadId) throw new InvalidOperationException("The selected chat keeps its subscription. Select another chat before unloading it.");
        var thread = await RequestAsync("thread/read", new { threadId = runtimeThreadId, includeTurns = true }, cancellation);
        if (thread.TryObjectProperty("thread", out var value) && (value.Str("status") is "inProgress" or "running" or "active" || value.TryObjectProperty("status", out var status) && status.Str("type") is "inProgress" or "running" or "active" || IntegrationCoordinator.Rows(value, "turns").Any(x => x.Str("status") is "inProgress" or "running" or "active"))) throw new InvalidOperationException("An active turn keeps its runtime subscription.");
        await RequestAsync("thread/unsubscribe", new { threadId = runtimeThreadId }, cancellation); var refreshed = await RefreshAsync(context, cancellation);
        if (refreshed.LoadedThreads.Contains(runtimeThreadId, StringComparer.Ordinal)) throw new IOException("The runtime still reports this thread as loaded.");
    }
    public async Task RefreshWindowsSandboxAsync(CancellationToken cancellation = default)
    { var readiness = await RequestAsync("windowsSandbox/readiness", null, cancellation); WindowsSandboxStatus = readiness.Str("status") ?? "unknown"; WindowsSandboxError = null; Changed?.Invoke(); }
    public async Task RepairWindowsSandboxAsync(IntegrationContext context, string mode, CancellationToken cancellation = default)
    {
        if (mode is not ("unelevated" or "elevated") || context.Cwd is null) throw new InvalidOperationException("Select a project and an explicit sandbox setup mode.");
        var response = await RequestAsync("windowsSandbox/setupStart", new { cwd = context.Cwd, mode }, cancellation);
        if (!IntegrationCoordinator.Bool(response, "started")) throw new IOException("Windows sandbox setup did not start.");
        WindowsSandboxStatus = "settingUp"; Changed?.Invoke();
    }
    void LoadConfigSchemas()
    {
        var root = workspace.Runtime.Capabilities.SchemaDirectory;
        if (root is null) return; var path = Path.Combine(root, "v2", "ConfigReadResponse.json"); if (!File.Exists(path)) return;
        using var document = JsonDocument.Parse(File.ReadAllBytes(path));
        if (!document.RootElement.TryObjectProperty("definitions", out var definitions) || !definitions.TryObjectProperty("Config", out var config) || !config.TryObjectProperty("properties", out var properties)) return;
        foreach (var property in properties.EnumerateObject())
        {
            var schema = property.Value;
            if (schema.TryGetProperty("anyOf", out var variants)) schema = variants.EnumerateArray().FirstOrDefault(x => x.Str("type") != "null");
            if (schema.Str("$ref") is { } reference && definitions.TryGetProperty(reference.Split('/').Last(), out var definition)) schema = definition;
            configSchemas[property.Name] = schema.Clone();
        }
    }
    string SchemaType(string key) => configSchemas.GetValueOrDefault(key).Str("type") ?? "unknown";
    string[] SchemaChoices(string key)
    {
        var schema = configSchemas.GetValueOrDefault(key);
        if (schema.ValueKind != JsonValueKind.Object) return [];
        if (schema.TryGetProperty("enum", out var values)) return values.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray();
        if (schema.TryGetProperty("oneOf", out var variants)) return variants.EnumerateArray().Where(x => x.TryGetProperty("enum", out _)).SelectMany(x => x.GetProperty("enum").EnumerateArray()).Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray();
        return [];
    }
    async void OnEvent(RuntimeEvent message)
    {
        if (disposed) return; var p = message.Parameters;
        try
        {
            if (message.Method == "windowsSandbox/setupCompleted")
            {
                if (IntegrationCoordinator.Bool(p, "success")) await RefreshWindowsSandboxAsync();
                else { WindowsSandboxStatus = "notConfigured"; WindowsSandboxError = DiagnosticRedactor.Redact(p.Str("error") ?? "Windows sandbox setup failed."); Changed?.Invoke(); }
                return;
            }
            if (message.Method is not ("item/autoApprovalReview/started" or "item/autoApprovalReview/completed" or "autoApprovalReview/strictReviewRequired" or "guardianWarning")) return;
            var thread = p.Str("threadId"); if (thread is null) return;
            var review = p.TryObjectProperty("review", out var value) ? value : default;
            var id = p.Str("reviewId") ?? (message.Method + "|" + p.Str("turnId") + "|" + (p.TryGetProperty("startedAtMs", out var at) ? at.ToString() : ""));
            var action = p.TryObjectProperty("action", out var a) ? a : default;
            var status = message.Method == "autoApprovalReview/strictReviewRequired" ? "strictReviewRequired" : message.Method == "guardianWarning" ? "denied" : review.Str("status") ?? "inProgress";
            var rationale = DiagnosticRedactor.Redact(review.Str("rationale") ?? p.Str("message") ?? (status == "strictReviewRequired" ? "Automatic approval stopped. Review the pending request yourself." : ""));
            var record = new RuntimeApprovalReview(id, thread, p.Str("turnId"), p.Str("targetItemId"), message.Method.EndsWith("started", StringComparison.Ordinal) ? "reviewing" : "completed", status, review.Str("riskLevel"), rationale, ActionSummary(action), p.Str("decisionSource"), DateTimeOffset.UtcNow);
            reviews[thread + "|" + id] = record;
            var retained = reviews.Values.Where(x => x.RuntimeThreadId == thread).OrderByDescending(x => x.UpdatedAt).Take(64).ToArray();
            foreach (var old in reviews.Where(x => x.Value.RuntimeThreadId == thread && retained.All(r => r.Id != x.Value.Id)).ToArray()) reviews.TryRemove(old.Key, out _);
            await workspace.Threads.SaveStateAsync("approval-reviews", thread, JsonSerializer.Serialize(retained)); Changed?.Invoke();
        }
        catch (Exception exception) { WindowsSandboxError = DiagnosticRedactor.Redact(exception.Message); Changed?.Invoke(); }
    }
    public async Task LoadApprovalReviewsAsync(ThreadSession session)
    {
        if (session.Record.CodexThreadId is not { } thread || await workspace.Threads.ReadStateAsync("approval-reviews", thread) is not { } raw) return;
        foreach (var item in JsonSerializer.Deserialize<RuntimeApprovalReview[]>(raw) ?? []) reviews.TryAdd(thread + "|" + item.Id, item);
    }
    static string ActionSummary(JsonElement action)
    {
        var text = action.Str("type") switch
        {
            "command" => action.Str("command") ?? "Command", "execve" => action.Str("program") ?? "Program",
            "writeStdin" => "Input to process " + action.Str("processId"), "applyPatch" => $"Change {IntegrationCoordinator.Rows(action, "files").Length} files",
            "networkAccess" => "Network access to " + action.Str("host"), "mcpToolCall" => action.Str("server") + " / " + action.Str("toolTitle"),
            "requestPermissions" => action.Str("reason") ?? "Additional permissions", _ => "Approval review",
        };
        return Regex.Replace(DiagnosticRedactor.Redact(text), @"(?i)(--(?:password|token|api-key|secret)\s+)[^\s]+", "$1[redacted]", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
    }
    static string Humanize(string key) => System.Globalization.CultureInfo.InvariantCulture.TextInfo.ToTitleCase(key.Replace('_', ' '));
    static bool SensitiveKey(string key) => new[] { "api_key", "access_token", "refresh_token", "password", "secret" }.Any(value => key.Contains(value, StringComparison.OrdinalIgnoreCase));
    public ValueTask DisposeAsync() { disposed = true; workspace.RuntimeEventReceived -= OnEvent; return ValueTask.CompletedTask; }
}
