using System.Text.Json;
using Veo.Core;
using Veo.Protocol;

if (args.Contains("--fixture")) { await Server(args); return; }
var passed = 0;
var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Veo-Integrations-Tests", Guid.NewGuid().ToString("N"))); Directory.CreateDirectory(root);
var self = Path.Combine(AppContext.BaseDirectory, "Veo.Integrations.Tests" + (OperatingSystem.IsWindows() ? ".exe" : ""));
WorkspaceCoordinator Workspace(string name, string scenario = "normal") => new(Path.Combine(root, name), _ => new(new CodexRuntimeOptions { ExecutablePath = self, SchemaDirectory = Schema(), AdditionalArguments = ["--fixture", "--scenario=" + scenario, "--trace=" + Path.Combine(root, name + ".log")] }));
ComposerSnapshot Payload(string access = "Workspace") => new("client", "fixture", "fixture-model", "high", null, access, "Agentic", []);
try
{
    await Check("native forms validate schema constraints and refuse unsupported composition", async () =>
    {
        var form = NativeSchemaForm.Parse(Json("""{"type":"object","required":["name","count"],"properties":{"name":{"type":"string","minLength":2,"maxLength":5,"pattern":"^[a-z]+$"},"count":{"type":"integer","minimum":1,"exclusiveMaximum":5,"multipleOf":2},"tags":{"type":"array","uniqueItems":true,"items":{"type":"string","enum":["a","b"]}},"token":{"type":"string","writeOnly":true}}}"""));
        Assert(form.IsSupported && form.Fields.Single(x => x.Key == "token").Secret, "Supported form or secret detection failed.");
        var valid = new Dictionary<string, string> { ["name"] = "abc", ["count"] = "2", ["tags"] = "a\nb" };
        Assert(form.Validate(valid).GetProperty("count").GetInt32() == 2, "Integer was serialized as text.");
        await Throws<InvalidOperationException>(() => Task.FromResult(form.Validate(valid.Where(x => x.Key != "name").ToDictionary())));
        foreach (var bad in new[] { "0", "3", "6", "NaN" }) await Throws<InvalidOperationException>(() => Task.FromResult(form.Validate(new Dictionary<string, string>(valid) { ["count"] = bad })));
        await Throws<InvalidOperationException>(() => Task.FromResult(form.Validate(new Dictionary<string, string>(valid) { ["tags"] = "a\na" })));
        foreach (var schema in new[] { """{"type":"object","properties":{"n":{"type":"integer","enum":[1,2]}}}""", """{"type":"object","oneOf":[{}],"properties":{}}""", """{"type":"object","properties":{"nested":{"type":"object"}}}""" }) Assert(!NativeSchemaForm.Parse(Json(schema)).IsSupported, "Unknown schema was submitted through a generic form.");
    });
    await Check("scoped paginated inventories and confirmed skill writes", async () =>
    {
        await using var workspace = Workspace("inventory"); await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await workspace.EnsureRuntimeThreadAsync(session, Payload());
        await using var integrations = new IntegrationCoordinator(workspace); var context = IntegrationContext.For(session); var snapshot = await integrations.RefreshAsync(context);
        Assert(snapshot.Issues.Length == 0 && snapshot.Apps.Length == 2 && snapshot.McpServers.Length == 2 && snapshot.Skills.Single().Name == "fixture-skill", "Inventory scope or pagination was lost.");
        await integrations.SetSkillEnabledAsync(context, snapshot.Skills.Single(), false); Assert(!integrations.Snapshot(context).Skills.Single().Enabled, "Write returned without confirmed skill state.");
        var writes = Requests("inventory", "skills/config/write"); Assert(writes.Single().GetProperty("params").GetProperty("path").GetString() == Path.Combine(context.Cwd!, "SKILL.md"), "Skill identity was not retained.");
    });
    await Check("plugin and marketplace mutations are explicit and read back", async () =>
    {
        await using var workspace = Workspace("plugins"); await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await using var integrations = new IntegrationCoordinator(workspace); var context = IntegrationContext.For(session);
        var plugin = (await integrations.RefreshAsync(context)).Marketplaces.Single().Plugins.Single(); await integrations.SetPluginInstalledAsync(context, plugin, true);
        var installed = integrations.Snapshot(context).Marketplaces.Single().Plugins.Single(); Assert(installed.Installed, "Install was not confirmed.");
        await integrations.SetPluginInstalledAsync(context, installed, false); Assert(!integrations.Snapshot(context).Marketplaces.Single().Plugins.Single().Installed, "Uninstall was not confirmed.");
        await integrations.ChangeMarketplaceAsync(context, "add", "extra"); Assert(integrations.Snapshot(context).Marketplaces.Length == 2, "Added marketplace missing."); await integrations.ChangeMarketplaceAsync(context, "upgrade", "extra"); await integrations.ChangeMarketplaceAsync(context, "remove", "extra");
        var install = Requests("plugins", "plugin/install").Single().GetProperty("params"); Assert(install.Str("pluginName") == "fixture-plugin" && install.Str("marketplacePath") == "C:\\fixture-market", "Plugin selector diverged from runtime contract.");
    });
    await Check("apps use appIds and secure connection URLs without inventing connected state", async () =>
    {
        await using var workspace = Workspace("apps"); await workspace.InitializeAsync(); await using var integrations = new IntegrationCoordinator(workspace); var context = new IntegrationContext(null, null); var snapshot = await integrations.RefreshAsync(context); Uri? opened = null; integrations.Navigate += uri => opened = uri;
        var app = snapshot.Apps.Single(x => x.Id == "app-a"); integrations.OpenAppConnection(app); Assert(opened?.Host == "example.test" && !app.Accessible && app.Callable is null, "Opening a URL changed reported connection state.");
        var details = await integrations.ReadAppDetailsAsync(context, new[] { app.Id }); Assert(details.Single().Enabled && !details.Single().Accessible, "App details erased known connection state.");
        var p = Requests("apps", "app/read").Single().GetProperty("params"); Assert(p.GetProperty("appIds")[0].GetString() == "app-a" && !p.TryGetProperty("appId", out _), "Wrong app/read selector.");
        Assert(IntegrationCoordinator.SecureUri("http://example.test") is null && IntegrationCoordinator.SecureUri("https://user@example.test") is null, "An insecure auth URL was accepted.");
    });
    await Check("MCP tool forms, resources, binary artifacts and originating thread stay typed", async () =>
    {
        await using var workspace = Workspace("mcp"); await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await workspace.EnsureRuntimeThreadAsync(session, Payload()); await using var integrations = new IntegrationCoordinator(workspace); var context = IntegrationContext.For(session); var snapshot = await integrations.RefreshAsync(context); var tool = snapshot.McpServers[0].Tools.Single();
        var result = await integrations.CallToolAsync(context, "fixture-mcp", tool, new Dictionary<string, string> { ["query"] = "hello", ["limit"] = "2" }); Assert(result.Text.Single() == "fixture result" && result.Content.Length == 2 && result.Structured?.GetProperty("count").GetInt32() == 2, "Tool result artifacts were flattened or lost.");
        var resource = await integrations.ReadResourceAsync(context, "fixture-mcp", "fixture://document"); Assert(resource[0].Text == "fixture resource" && resource[1].Data!.SequenceEqual(new byte[] { 1, 2, 3 }), "Resource decoding changed bytes.");
        var call = Requests("mcp", "mcpServer/tool/call").Single().GetProperty("params"); Assert(call.Str("threadId") == session.Record.CodexThreadId && call.GetProperty("arguments").GetProperty("limit").GetInt32() == 2, "Tool dispatch lost thread or typed values.");
        await Throws<InvalidOperationException>(() => integrations.CallToolAsync(context with { RuntimeThreadId = null }, "fixture-mcp", tool, new Dictionary<string, string>()));
    });
    await Check("elicitation retains typed values and rejects stale request responses", async () =>
    {
        await using var workspace = Workspace("elicitation"); await workspace.InitializeAsync(); await using var integrations = new IntegrationCoordinator(workspace); await workspace.Runtime.RequestAsync("thread/list", null); await Until(() => workspace.PendingRequests.Count == 1); var request = workspace.PendingRequests.Single();
        await Throws<InvalidOperationException>(() => integrations.RespondElicitationAsync(request, new Dictionary<string, string>(), "accept"));
        await integrations.RespondElicitationAsync(request, new Dictionary<string, string> { ["title"] = "Accepted" }, "accept"); await Until(() => Requests("elicitation", null).Any(x => x.TryGetProperty("result", out _)));
        var response = Requests("elicitation", null).Single(x => x.TryGetProperty("result", out _)); Assert(response.GetProperty("result").GetProperty("content").Str("title") == "Accepted", "Elicitation response lost schema content.");
        await Throws<InvalidOperationException>(() => integrations.RespondElicitationAsync(request, null, "decline"));
    });
    await Check("import preserves detected artifacts and early completion, with source/home scope guard", async () =>
    {
        await using var workspace = Workspace("import"); await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await using var integrations = new IntegrationCoordinator(workspace); var context = IntegrationContext.For(session); var items = await integrations.DetectExternalAsync(context, false, "fixture-source");
        await Throws<InvalidOperationException>(() => integrations.ImportExternalAsync(context, [items.Single().Id], "different-source"));
        var id = await integrations.ImportExternalAsync(context, [items.Single().Id], "fixture-source"); await Until(() => integrations.ImportProgress(id)?.Complete == true); var progress = integrations.ImportProgress(id)!; Assert(progress.Successes == 1 && progress.Failures == 0, "Early import completion was replaced by pending state.");
        var p = Requests("import", "externalAgentConfig/import").Single().GetProperty("params"); Assert(JsonElement.DeepEquals(p.GetProperty("migrationItems")[0], items[0].Raw) && p.Str("migrationSource") == "fixture-source", "Detection was rewritten or source changed during import.");
    });
    await Check("configuration writes preserve expected version and distinguish overridden effective values", async () =>
    {
        await using var workspace = Workspace("config"); await workspace.InitializeAsync(); await using var runtime = new RuntimeManagementCoordinator(workspace); var context = new IntegrationContext(null, null); var snapshot = await runtime.RefreshAsync(context); Assert(snapshot.Issues.Length == 0 && snapshot.Hooks.Single().Managed, "Runtime inventory failed.");
        var saved = await runtime.WriteScalarAsync(context, "model", "changed-model"); Assert(saved.Applied && saved.EffectiveValue.GetString() == "changed-model", "Confirmed config write reported failure.");
        var write = Requests("config", "config/value/write").Single().GetProperty("params"); Assert(write.Str("expectedVersion") == "v1" && write.Str("filePath") == "C:\\fixture\\config.toml", "Config lost optimistic concurrency identity.");
        await using var overriddenWorkspace = Workspace("overridden", "overridden"); await overriddenWorkspace.InitializeAsync(); await using var overriddenRuntime = new RuntimeManagementCoordinator(overriddenWorkspace); await overriddenRuntime.RefreshAsync(context); Assert(!(await overriddenRuntime.WriteScalarAsync(context, "model", "ignored")).Applied, "An overridden write was claimed effective.");
    });
    await Check("managed access and features cannot silently widen scope", async () =>
    {
        await using var workspace = Workspace("managed", "managed"); await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await using var runtime = new RuntimeManagementCoordinator(workspace); var context = IntegrationContext.For(session); var snapshot = await runtime.RefreshAsync(context);
        await runtime.ValidateAccessAsync(session, Payload()); await Throws<InvalidOperationException>(() => runtime.ValidateAccessAsync(session, Payload("Full access"))); Assert(session.EffectiveAccess == "Workspace", "Managed rejection altered thread access.");
        Assert(snapshot.Fields.Single(x => x.Key == "sandbox_mode").Managed && snapshot.Features.Single().Required == true, "Managed values still appeared editable.");
        await Throws<InvalidOperationException>(() => runtime.SetFeatureAsync(context, snapshot.Features.Single(), false)); Assert(Requests("managed", "experimentalFeature/enablement/set").Length == 0, "Managed feature was sent as a mutation.");
    });
    await Check("feature readback and active subscription guards preserve runtime ownership", async () =>
    {
        await using var workspace = Workspace("features"); await workspace.InitializeAsync(); await using var runtime = new RuntimeManagementCoordinator(workspace); var context = new IntegrationContext(null, null); var snapshot = await runtime.RefreshAsync(context); await runtime.SetFeatureAsync(context, snapshot.Features.Single(), false); Assert(!runtime.Snapshot(context)!.Features.Single().Enabled, "Feature state was not read back.");
        await Throws<InvalidOperationException>(() => runtime.UnsubscribeAsync(context, "active")); await Throws<InvalidOperationException>(() => runtime.UnsubscribeAsync(context with { RuntimeThreadId = "inactive" }, "inactive")); await runtime.UnsubscribeAsync(context, "inactive"); Assert(!runtime.Snapshot(context)!.LoadedThreads.Contains("inactive"), "Unloaded subscription still reported loaded.");
    });
    await Check("Windows repair is explicit and failure keeps Workspace access", async () =>
    {
        await using var workspace = Workspace("sandbox"); await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await using var runtime = new RuntimeManagementCoordinator(workspace); await runtime.RefreshWindowsSandboxAsync(); Assert(runtime.WindowsSandboxStatus == "notConfigured", "Readiness was invented."); await runtime.RepairWindowsSandboxAsync(IntegrationContext.For(session), "unelevated"); await Until(() => runtime.WindowsSandboxError is not null); Assert(session.EffectiveAccess == "Workspace" && runtime.WindowsSandboxStatus == "notConfigured", "Repair failure broadened scope.");
        Assert(Requests("sandbox", "windowsSandbox/setupStart").Single().GetProperty("params").Str("mode") == "unelevated", "Sandbox repair requested unintended elevation.");
    });
    await Check("approval denials are visible and durable without serializing stdin or invented override events", async () =>
    {
        string recordId;
        await using (var workspace = Workspace("reviews"))
        {
            await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await workspace.EnsureRuntimeThreadAsync(session, Payload()); recordId = session.Record.VeoId; await using var runtime = new RuntimeManagementCoordinator(workspace); await workspace.Runtime.RequestAsync("account/rateLimits/read", new { threadId = session.Record.CodexThreadId }); await Until(() => runtime.ApprovalReviews(session).Count == 2); await Until(() => File.Exists(Path.Combine(root, "reviews.log")));
            Assert(runtime.ApprovalReviews(session).All(x => x.NeedsAttention) && runtime.ApprovalReviews(session).All(x => !JsonSerializer.Serialize(x).Contains("private-stdin")), "Denial attention or secret exclusion failed.");
            await Until(() => workspace.Threads.ReadStateAsync("approval-reviews", session.Record.CodexThreadId!).GetAwaiter().GetResult() is { } saved && JsonSerializer.Deserialize<RuntimeApprovalReview[]>(saved)?.Length == 2);
        }
        await using (var workspace = Workspace("reviews")) { await workspace.InitializeAsync(); var session = await workspace.LoadAsync((await workspace.CatalogAsync()).Single(x => x.VeoId == recordId)); await using var runtime = new RuntimeManagementCoordinator(workspace); await runtime.LoadApprovalReviewsAsync(session); Assert(runtime.ApprovalReviews(session).Count == 2, "Relaunch lost approval review status."); }
    });
    await Check("device login cancellation and reconnect invalidate one-time flows", async () =>
    {
        await using var workspace = Workspace("device"); await workspace.InitializeAsync(); await using var accounts = new AccountCoordinator(workspace); Uri? opened = null; accounts.Navigate += value => opened = value;
        var flow = await accounts.StartLoginAsync("chatgptDeviceCode"); Assert(flow.UserCode == "FIXTURE-CODE" && opened?.Host == "example.test" && flow.Status == "Awaiting user", "Device code flow was not shown truthfully.");
        await accounts.CancelLoginAsync(); Assert(accounts.Login?.Status == "Cancelled", "Cancellation was not acknowledged."); await accounts.StartLoginAsync("chatgptDeviceCode"); await workspace.ReconnectAsync(); await Throws<InvalidOperationException>(() => accounts.CancelLoginAsync());
    });
    await Check("early ChatGPT completion and API logout use account readback without retaining keys", async () =>
    {
        await using var workspace = Workspace("auth"); await workspace.InitializeAsync(); await using var accounts = new AccountCoordinator(workspace); var flow = await accounts.StartLoginAsync("chatgpt"); Assert(flow.Status == "Completed" && accounts.State.Identity?.Email == "fixture@example.test", "Early login completion was replaced by pending status.");
        await accounts.StartLoginAsync("apiKey", "fixture-api-secret"); Assert(accounts.State.Identity?.Type == "apiKey" && !JsonSerializer.Serialize(accounts.State).Contains("fixture-api-secret"), "API credentials leaked into app account metadata.");
        await accounts.LogoutAsync(); Assert(accounts.State.Identity is null && accounts.Login is null, "Logout was claimed without account readback.");
    });
    await Check("usage permissions remain unknown until backend says so and reset retries keep one attempt ID", async () =>
    {
        await using var workspace = Workspace("usage"); await workspace.InitializeAsync(); await using var accounts = new AccountCoordinator(workspace); var state = await accounts.RefreshAsync(); Assert(state.OrdinaryUsageAllowed is null && state.Usage.Single().Primary?.UsedPercent == 25 && state.Tokens?.LifetimeTokens == 1234, "Usage percentage inferred permission or typed usage was lost.");
        var attempt = Guid.NewGuid().ToString(); Assert(await accounts.RedeemResetCreditAsync(attempt, "credit") == "reset" && await accounts.RedeemResetCreditAsync(attempt, "credit") == "alreadyRedeemed", "One logical reset was duplicated.");
        Assert(Requests("usage", "account/rateLimitResetCredit/consume").All(x => x.GetProperty("params").Str("idempotencyKey") == attempt), "Reset idempotency identity changed during retry.");
    });
    await Check("live settings resolve missing turn IDs and separate future readback from live publication", async () =>
    {
        await using var workspace = Workspace("live", "live"); await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await workspace.EnsureRuntimeThreadAsync(session, Payload()); session.Timeline.Begin(null); await using var settings = new ThreadSettingsCoordinator(workspace);
        var result = await settings.ApplySelectionAsync(session, Payload() with { Model = "changed", Effort = "max", Tier = null }); Assert(result.LivePublished && result.FutureConfirmed && result.Status == "published", "Live settings lacked separate confirmation.");
        var live = Requests("live", "turn/settings/update").Single().GetProperty("params"); Assert(live.Str("turnId") == "live-turn" && !live.TryGetProperty("modelProvider", out _) && live.GetProperty("serviceTier").ValueKind == JsonValueKind.Null, "Live update used unsupported fields or lost explicit tier clearing.");
        await workspace.ReconnectAsync(); Assert(settings.Result(session) is null && settings.AcceptedSettings(session) is null, "A reconnect retained a green publication receipt from a previous generation.");
    });
    await Check("finished and unsupported live targets retain truthful next-turn behavior", async () =>
    {
        foreach (var scenario in new[] { "targetUnavailable", "no-live" })
        {
            await using var workspace = Workspace(scenario, scenario); await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await workspace.EnsureRuntimeThreadAsync(session, Payload()); session.Timeline.Begin("turn"); await using var settings = new ThreadSettingsCoordinator(workspace); var result = await settings.ApplySelectionAsync(session, Payload()); Assert(result.Status == "nextTurnOnly" && !result.LivePublished && result.FutureConfirmed, "Unavailable target was reported applied.");
        }
    });
    await Check("accepted memory receipts persist; goals use explicit user provenance and exact readback", async () =>
    {
        string recordId;
        await using (var workspace = Workspace("thread-controls"))
        {
            await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await workspace.EnsureRuntimeThreadAsync(session, Payload()); recordId = session.Record.VeoId; await using var settings = new ThreadSettingsCoordinator(workspace);
            await settings.SetMemoryModeAsync(session, "disabled"); Assert(settings.MemoryMode(session)?.Mode == "disabled", "Memory acknowledgement was not saved.");
            await settings.SetGoalAsync(session, "Implement the requested feature"); Assert(settings.Goal(session)?.TokenBudget is null && settings.Goal(session)?.Status == "active", "An unsolicited goal budget was supplied."); await settings.SetGoalStatusAsync(session, "paused"); Assert(settings.Goal(session)?.Status == "paused", "Pause lacked backend confirmation."); await settings.ClearGoalAsync(session); Assert(settings.Goal(session) is null, "Goal clear did not read back.");
            Assert(Requests("thread-controls", "thread/goal/set").All(x => x.GetProperty("params").Str("origin") == "user") && !Requests("thread-controls", "thread/goal/set").First().GetProperty("params").TryGetProperty("tokenBudget", out _), "Goal mutation lost explicit user origin or invented a budget.");
            Assert(settings.PersonalitySupport().Deprecated, "Selected CLI deprecation was ignored."); await Throws<NotSupportedException>(() => settings.SetPersonalityAsync(session, "friendly"));
        }
        await using (var workspace = Workspace("thread-controls")) { await workspace.InitializeAsync(); var session = await workspace.LoadAsync((await workspace.CatalogAsync()).Single(x => x.VeoId == recordId)); await using var settings = new ThreadSettingsCoordinator(workspace); await settings.LoadAsync(session); Assert(settings.MemoryMode(session)?.Mode == "disabled", "Relaunch lost the last accepted memory receipt."); }
    });
    await Check("composer Goal is armed locally, then set before sending the first turn", async () =>
    {
        const string name = "composer-goal";
        await using var workspace = Workspace(name);
        await workspace.InitializeAsync();
        await using var settings = new ThreadSettingsCoordinator(workspace);
        workspace.PrepareComposerGoalAsync = settings.PrepareComposerGoalAsync;
        var session = await workspace.CreateAsync();

        await settings.SetComposerGoalModeAsync(session, true);
        Assert(session.ComposerGoalArmed && settings.ComposerGoalEnabled(session) && session.Record.CodexThreadId is null,
            "Arming Goal created a runtime chat or failed to show the armed state.");
        var objective = Payload() with { Text = "  Verify the goal workflow.  ", StartGoal = true };
        await workspace.SubmitAsync(session, objective);
        Assert(!session.ComposerGoalArmed && settings.ActiveGoal(session)?.Objective == objective.Text.Trim(),
            "The armed goal was not converted to an acknowledged runtime goal.");

        var methods = Requests(name, null).Select(request => request.Str("method")).ToArray();
        Assert(Array.IndexOf(methods, "thread/start") < Array.IndexOf(methods, "thread/goal/set")
            && Array.IndexOf(methods, "thread/goal/set") < Array.IndexOf(methods, "turn/start"),
            "The runtime goal must be set after thread creation and before turn start.");
        await settings.SetComposerGoalModeAsync(session, false);
        Assert(!settings.ComposerGoalEnabled(session), "Turning off Goal did not clear the active runtime goal.");

        await settings.SetComposerGoalModeAsync(session, true);
        var queued = objective with { ClientId = "queued-goal" };
        await workspace.SubmitAsync(session, queued);
        Assert(session.Queue.Single().StartGoal && settings.ComposerGoalEnabled(session),
            "Queueing a goal lost the frozen goal choice.");
        await settings.SetComposerGoalModeAsync(session, false);
        Assert(session.Queue.Single() is { StartGoal: false } entry && entry.ClientId == queued.ClientId && entry.Text == queued.Text && !settings.ComposerGoalEnabled(session),
            "Turning off Goal discarded the queued prompt or retained its goal choice.");
    });
    await Check("concurrent memory writes serialize and late goal reads cannot replace a newer notification", async () =>
    {
        await using var workspace = Workspace("goal-race", "goal-race"); await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await workspace.EnsureRuntimeThreadAsync(session, Payload()); await using var settings = new ThreadSettingsCoordinator(workspace);
        await Task.WhenAll(settings.SetMemoryModeAsync(session, "disabled"), settings.SetMemoryModeAsync(session, "enabled")); Assert(settings.MemoryMode(session)?.Mode == "enabled", "Concurrent writes reordered the accepted memory receipt.");
        await workspace.Runtime.RequestAsync("thread/goal/set", new { threadId = session.Record.CodexThreadId, objective = "Older goal", origin = "user" }); var goal = await settings.RefreshGoalAsync(session); Assert(goal?.Objective == "Newer goal" && settings.Goal(session)?.Objective == "Newer goal", "Stale goal read overwrote a newer notification.");
    });
}
finally { var intended = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Veo-Integrations-Tests")); if (Path.GetDirectoryName(root) == intended && Directory.Exists(root)) Directory.Delete(root, true); }
Console.WriteLine($"PASS: {passed} integration/runtime checks. Fixture-only; no model turns, remote installs, real configuration writes, or administrator setup.");
async Task Check(string name, Func<Task> test) { await test().WaitAsync(TimeSpan.FromSeconds(30)); passed++; Console.WriteLine("PASS " + name); }
JsonElement[] Requests(string name, string? method) { var path = Path.Combine(root, name + ".log"); using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete); using var reader = new StreamReader(stream); var lines = reader.ReadToEnd().Split('\n'); return lines.Take(lines.Length - 1).Where(x => x.Length > 0).Select(Json).Where(x => method is null || x.Str("method") == method).ToArray(); }
static string? Schema() { var path = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../artifacts/protocol-schema")); return Directory.Exists(path) ? path : null; }
static JsonElement Json(string text) => JsonSerializer.Deserialize<JsonElement>(text);
static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
static async Task Throws<T>(Func<Task> action) where T : Exception { try { await action(); } catch (T) { return; } throw new InvalidOperationException("Expected " + typeof(T).Name); }
static async Task Until(Func<bool> condition) { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)); while (!condition()) await Task.Delay(20, timeout.Token); }

static async Task Server(string[] arguments)
{
    var trace = arguments.Single(x => x.StartsWith("--trace="))[8..]; var scenario = arguments.Single(x => x.StartsWith("--scenario="))[11..]; var skill = true; var installed = false; var feature = true; var model = "fixture-model"; var version = "v1"; var markets = new HashSet<string>(["fixture-market"]); var loaded = new HashSet<string>(["inactive", "active"]); var next = 0; string? accountType = null; var resetAttempts = new HashSet<string>(); var goals = new Dictionary<string, JsonElement>();
    while (await Console.In.ReadLineAsync() is { } line)
    {
        await File.AppendAllTextAsync(trace, line + "\n"); using var document = JsonDocument.Parse(line); var request = document.RootElement;
        if (!request.TryGetProperty("method", out var method) || !request.TryGetProperty("id", out var idValue)) continue;
        var id = idValue.Clone(); var p = request.TryGetProperty("params", out var parameters) ? parameters : Json("{}"); object result = new { };
        switch (method.GetString())
        {
            case "initialize": result = new { userAgent = "integrations fixture" }; break;
            case "model/list": result = new { data = Array.Empty<object>() }; break;
            case "thread/start": var tid = "rt" + ++next; loaded.Add(tid); result = new { thread = new { id = tid } }; break;
            case "turn/start": result = new { turn = new { id = "goal-turn", status = "inProgress" } }; break;
            case "thread/resume": result = new { thread = new { id = p.Str("threadId"), turns = Array.Empty<object>(), status = "idle" } }; break;
            case "skills/list": var cwd = p.GetProperty("cwds")[0].GetString(); result = new { data = new[] { new { cwd, skills = new[] { new { name = "fixture-skill", path = Path.Combine(cwd!, "SKILL.md"), scope = "repo", enabled = skill, description = "Fixture skill" } } } } }; break;
            case "skills/config/write": skill = p.GetProperty("enabled").GetBoolean(); break;
            case "plugin/list": result = new { marketplaces = markets.Select(name => new { name, path = "C:\\" + name, plugins = name == "fixture-market" ? new[] { new { id = "plugin-id", name = "fixture-plugin", installed, enabled = installed, availability = "AVAILABLE", installPolicy = "AVAILABLE" } } : Array.Empty<object>() }).ToArray() }; break;
            case "plugin/install": installed = true; break;
            case "plugin/uninstall": installed = false; break;
            case "marketplace/add": markets.Add(p.Str("source")!); result = new { marketplaceName = p.Str("source") }; break;
            case "marketplace/remove": markets.Remove(p.Str("marketplaceName")!); break;
            case "app/list": var second = p.Str("cursor") == "next"; result = new { data = new[] { new { id = second ? "app-b" : "app-a", name = "Fixture app", isEnabled = true, isAccessible = false, installUrl = "https://example.test/connect" } }, nextCursor = second ? null : "next" }; break;
            case "app/installed": result = new { apps = Array.Empty<object>() }; break;
            case "app/read": result = new { apps = new[] { new { id = p.GetProperty("appIds")[0].GetString(), name = "Fixture app", tools = new[] { new { name = "fixture-app-tool" } } } } }; break;
            case "mcpServerStatus/list": var page2 = p.Str("cursor") == "next"; result = new { data = new[] { new { name = page2 ? "other-mcp" : "fixture-mcp", authStatus = "oAuth", runtimeStatus = "ready", tools = new Dictionary<string, object> { ["fixture-tool"] = new { name = "fixture-tool", inputSchema = Json("""{"type":"object","required":["query"],"properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1}}}""") } }, resources = new[] { new { uri = "fixture://document", name = "Document" } } } }, nextCursor = page2 ? null : "next" }; break;
            case "mcpServer/tool/call": result = new { isError = false, content = new object[] { new { type = "text", text = "fixture result" }, new { type = "image", mimeType = "image/png", data = "AQID" } }, structuredContent = new { count = 2 } }; break;
            case "mcpServer/resource/read": result = new { contents = new object[] { new { uri = "fixture://document", text = "fixture resource" }, new { uri = "fixture://bytes", mimeType = "application/octet-stream", blob = "AQID" } } }; break;
            case "externalAgentConfig/detect": result = new { items = new[] { new { itemType = "CONFIG", description = "Fixture settings", cwd = p.GetProperty("cwds")[0].GetString(), details = new { settings = new[] { "fixture" } }, originalIdentity = "must-retain" } } }; break;
            case "externalAgentConfig/import": await Write(new { method = "externalAgentConfig/import/completed", @params = new { importId = "import-1", itemTypeResults = new[] { new { successes = new[] { new { id = "a" } }, failures = Array.Empty<object>() } } } }); result = new { importId = "import-1" }; break;
            case "config/read": result = new { config = new { model, sandbox_mode = "workspace-write", approval_policy = "on-request" }, origins = new { }, layers = new[] { new { name = new { type = "user", file = "C:\\fixture\\config.toml" }, version } } }; break;
            case "configRequirements/read": result = new { requirements = new { allowedSandboxModes = scenario == "managed" ? new[] { "workspace-write" } : new[] { "workspace-write", "read-only", "danger-full-access" }, allowedApprovalPolicies = new[] { "on-request" }, featureRequirements = scenario == "managed" ? new Dictionary<string, bool> { ["fixture_feature"] = true } : new Dictionary<string, bool>() } }; break;
            case "config/value/write": if (scenario != "overridden") model = p.GetProperty("value").GetString()!; version = "v2"; result = new { status = scenario == "overridden" ? "okOverridden" : "ok", overriddenMetadata = new { message = "Managed override is effective." } }; break;
            case "experimentalFeature/list": result = new { data = new[] { new { name = "fixture_feature", displayName = "Fixture feature", enabled = feature, stage = "experimental" } } }; break;
            case "experimentalFeature/enablement/set": feature = p.GetProperty("enablement").GetProperty("fixture_feature").GetBoolean(); break;
            case "hooks/list": result = new { data = new[] { new { hooks = new[] { new { key = "hook1", eventName = "preToolUse", handlerType = "command", source = "project", sourcePath = "C:\\fixture\\hooks.json", trustStatus = "trusted", enabled = true, isManaged = true } } } } }; break;
            case "permissionProfile/list": result = new { data = new[] { new { id = "workspace", description = "Workspace", allowed = true } } }; break;
            case "thread/loaded/list": result = new { data = loaded.ToArray() }; break;
            case "thread/read": result = new { thread = new { id = p.Str("threadId"), status = new { type = p.Str("threadId") == "active" ? "active" : "idle" }, turns = scenario == "live" ? new object[] { new { id = "live-turn", status = new { type = "inProgress" } } } : Array.Empty<object>() } }; break;
            case "thread/unsubscribe": loaded.Remove(p.Str("threadId")!); break;
            case "windowsSandbox/readiness": result = new { status = "notConfigured" }; break;
            case "windowsSandbox/setupStart": result = new { started = true }; await Write(new { id, result }); await Write(new { method = "windowsSandbox/setupCompleted", @params = new { success = false, error = "Fixture setup denied" } }); continue;
            case "thread/list": await Write(new { id = "elicitation-1", method = "mcpServer/elicitation/request", @params = new { mode = "form", serverName = "fixture-mcp", requestedSchema = Json("""{"type":"object","required":["title"],"properties":{"title":{"type":"string"}}}""") } }); break;
            case "account/rateLimits/read":
                if (p.Str("threadId") is null) { result = new { ordinaryUsageAllowed = (bool?)null, rateLimits = new { limitId = "codex", primary = new { usedPercent = 25, windowDurationMins = 300, resetsAt = 2000000000 } }, rateLimitResetCredits = new { availableCount = 1, credits = new[] { new { id = "credit", status = "available", title = "Fixture credit" } } } }; break; }
                await Write(new { method = "item/autoApprovalReview/completed", @params = new { threadId = p.Str("threadId"), reviewId = "denied", action = new { type = "writeStdin", processId = "proc", stdin = "private-stdin" }, review = new { status = "denied", riskLevel = "high", rationale = "Explicit approval required" } } });
                await Write(new { method = "autoApprovalReview/strictReviewRequired", @params = new { threadId = p.Str("threadId"), turnId = "turn", action = new { type = "command", command = "tool --token private-secret" }, message = "Review the pending action" } }); break;
            case "account/read": result = new { account = accountType is null ? null : accountType == "apiKey" ? (object)new { type = "apiKey" } : new { type = "chatgpt", email = "fixture@example.test", planType = "plus", workspaceName = "Fixture" }, requiresOpenaiAuth = true }; break;
            case "account/login/start":
                var loginType = p.Str("type");
                if (loginType == "apiKey") { accountType = "apiKey"; result = new { type = loginType }; }
                else if (loginType == "chatgptDeviceCode") result = new { type = loginType, loginId = "device-login", userCode = "FIXTURE-CODE", verificationUrl = "https://example.test/device" };
                else { accountType = "chatgpt"; await Write(new { method = "account/login/completed", @params = new { loginId = "browser-login", success = true } }); result = new { type = loginType, loginId = "browser-login", authUrl = "https://example.test/login" }; } break;
            case "account/login/cancel": result = new { status = "canceled" }; break;
            case "account/logout": accountType = null; break;
            case "account/usage/read": result = new { summary = new { lifetimeTokens = 1234, currentStreakDays = 2 }, dailyUsageBuckets = new[] { new { startDate = "2026-11-17", tokens = 50 } } }; break;
            case "accountSession/list": result = new { sessions = Array.Empty<object>() }; break;
            case "account/rateLimitResetCredit/consume": result = new { outcome = resetAttempts.Add(p.Str("idempotencyKey")!) ? "reset" : "alreadyRedeemed" }; break;
            case "thread/settings/update": await Write(new { method = "thread/settings/updated", @params = new { threadId = p.Str("threadId"), threadSettings = new { model = p.Str("model"), effort = p.Str("effort"), serviceTier = p.Str("serviceTier") } } }); break;
            case "turn/settings/update": if (scenario == "no-live") { await Write(new { id, error = new { code = -32601, message = "Unsupported live settings" } }); continue; } result = new { status = scenario == "targetUnavailable" ? "targetUnavailable" : "applied" }; break;
            case "thread/goal/set":
                var runtime = p.Str("threadId")!; goals.TryGetValue(runtime, out var previous); var goal = JsonSerializer.SerializeToElement(new { threadId = runtime, objective = p.Str("objective") ?? previous.Str("objective"), status = p.Str("status") ?? previous.Str("status") ?? "active", tokenBudget = AccountCoordinator.Number(p, "tokenBudget") ?? AccountCoordinator.Number(previous, "tokenBudget"), tokensUsed = 0, timeUsedSeconds = 0, createdAt = 1, updatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds() }); goals[runtime] = goal; result = new { goal }; break;
            case "thread/goal/get":
                result = new { goal = goals.TryGetValue(p.Str("threadId")!, out var currentGoal) ? (JsonElement?)currentGoal : null };
                if (scenario == "goal-race") { await Write(new { method = "thread/goal/updated", @params = new { threadId = p.Str("threadId"), goal = new { threadId = p.Str("threadId"), objective = "Newer goal", status = "active", tokensUsed = 4, timeUsedSeconds = 1, updatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 1 } } }); await Task.Delay(50); } break;
            case "thread/goal/clear": goals.Remove(p.Str("threadId")!); break;
        }
        await Write(new { id, result });
    }
    static async Task Write(object value) { await Console.Out.WriteLineAsync(JsonSerializer.Serialize(value)); await Console.Out.FlushAsync(); }
}
