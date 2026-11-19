using System.Net;
using System.Text;
using System.Text.Json;
using Veo.Core;
using Veo.Protocol;

if (args.Contains("--model-server")) { await ModelServer(args); return; }
if (args.Contains("--bundled-probe"))
{
    var executable = CodexExecutableDiscovery.Resolve() ?? throw new FileNotFoundException("Codex unavailable.");
    var limits = await BundledModelCatalog.ReadAsync(executable);
    Console.WriteLine($"Verified selected CLI bundled catalog: {limits.Count} context-limit records. No refresh or model inference requested.");
    return;
}
var passed = 0;
var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Veo-Models-Tests", Guid.NewGuid().ToString("N"))); Directory.CreateDirectory(root);
var self = Path.Combine(AppContext.BaseDirectory, "Veo.Models.Tests" + (OperatingSystem.IsWindows() ? ".exe" : ""));
WorkspaceCoordinator Workspace(string name, string scenario = "normal", string? schema = null) =>
    new(Path.Combine(root, name), _ => new(new CodexRuntimeOptions
    {
        ExecutablePath = self,
        SchemaDirectory = schema,
        AdditionalArguments = ["--model-server", "--scenario=" + scenario, "--trace=" + Path.Combine(root, name + ".log")]
    }));
ModelSelectionService Selection(WorkspaceCoordinator workspace) => new(workspace, (_, _) => Task.FromResult<IReadOnlyDictionary<string, ModelContextLimits>>(CatalogRows().Select(NativeModelDescriptor.Parse).OfType<NativeModelDescriptor>().ToDictionary(x => x.Model, _ => new ModelContextLimits(200_000, 1_000_000), StringComparer.Ordinal).Append(new("phantom-not-live", new(100_000, 200_000))).ToDictionary(x => x.Key, x => x.Value, StringComparer.Ordinal)), (path, _) => Task.FromResult(path));
ComposerSnapshot Payload(string id = "client") => new(id, "Inspect the requested implementation", "gpt-6-astra", "high", "standard", "Workspace", "Agentic", []);
try
{
    await Check("context parser preserves whole token semantics and Maximum effort ID", () =>
    {
        Assert(ModelContextChoice.Parse("1.25m") == 1_250_000 && ModelContextChoice.Parse("200,000") == 200_000 && ModelContextChoice.Parse("0.0001k") is null && ModelContextChoice.Parse("-2") is null && ModelContextChoice.Parse("1e6") is null, "Context parser rounded or accepted unsupported input.");
        Assert(new ModelReasoning("max", "").Title == "Maximum" && new ModelReasoning("max", "").Id == "max", "Visible/internal effort titles changed."); return Task.CompletedTask;
    });
    await Check("live paginated catalog owns IDs; bundled data supplies only verified native limits", async () =>
    {
        await using var workspace = Workspace("catalog"); await workspace.InitializeAsync(); var models = Selection(workspace); await models.RefreshAsync();
        Assert(models.Catalog.Count == CatalogRows().Length && models.Find("phantom-not-live") is null && models.MultiAgentEnabled, "Bundled models or pagination changed live availability.");
        Assert(models.Limits("gpt-6-astra")?.Maximum == 1_000_000 && models.Limits("external/model") is null, "Unverified external limits were inferred from a native model.");
        foreach (var model in models.Visible.Take(models.Visible.Count - 1).ToArray()) await models.SetEnabledAsync(model.Id, false);
        await Throws<InvalidOperationException>(() => models.SetEnabledAsync(models.Visible.Single().Id, false));
    });
    await Check("speed options follow live tier IDs and GPT-5.6 is a persistent opt-in", async () =>
    {
        await using var workspace = Workspace("speed-availability");
        await workspace.InitializeAsync();
        var models = Selection(workspace);
        await models.RefreshAsync();
        var sol = models.Find("gpt-6.2-sol") ?? throw new InvalidOperationException("Missing Sol fixture.");
        var astra = models.Find("gpt-6-astra") ?? throw new InvalidOperationException("Missing Astra fixture.");
        Assert(sol.SpeedChoices().Select(choice => choice.TierId).SequenceEqual(new string?[] { "standard", "fast", "ultrafast" })
            && sol.SpeedFor("ultrafast") == ModelSpeed.Ultrafast
            && astra.SpeedChoices().All(choice => choice.Speed != ModelSpeed.Ultrafast),
            "Ultrafast was hidden for an eligible row or invented for a row without the tier.");
        var choice = new ModelSelectionChoice(sol.Id, sol.Model, sol.DefaultEffort, "ultrafast");
        Assert(models.Validate(choice).Tier == "ultrafast"
            && models.Validate(choice with { ModelId = astra.Id, Model = astra.Model }).Tier == astra.DefaultTier,
            "Tier selection did not preserve live IDs or clear a tier missing from the selected model.");
        Assert(!models.IncludeGPT56Models && models.Catalog.Any(model => model.IsGPT56)
            && models.Selectable.All(model => !model.IsGPT56), "GPT-5.6 was visible before opting in.");
        await models.SetIncludeGPT56ModelsAsync(true);
        var reloaded = Selection(workspace);
        await reloaded.RefreshAsync();
        Assert(reloaded.IncludeGPT56Models && reloaded.Selectable.Any(model => model.IsGPT56), "Opt-in was not persisted.");
        await reloaded.SetIncludeGPT56ModelsAsync(false);
        Assert(reloaded.Selectable.All(model => !model.IsGPT56), "Disabling the family left picker choices available.");
    });
    await Check("Daybreak requires selected CLI schema and advertised native choices and keeps the inherited turn field absent", async () =>
    {
        var schema = DaybreakSchema(root, "daybreak-schema", includeField: true);
        await using var workspace = Workspace("daybreak-turns", schema: schema);
        await workspace.InitializeAsync();
        var models = Selection(workspace);
        await models.RefreshAsync();
        Assert(models.SupportsDaybreakBlue && models.SupportsStandardCyberAccess &&
            models.Find("gpt-6-astra") is { SupportsDaybreakBlue: true, SupportsStandardCyberAccess: true },
            "Confirmed Blue/Standard capabilities are missing.");
        Assert(models.Find("external/model") is { SupportsDaybreakBlue: false } &&
            models.Find("text-only") is { SupportsDaybreakBlue: true, SupportsStandardCyberAccess: false },
            "The live catalog did not distinguish Blue-only and external models.");
        var session = await workspace.CreateAsync();
        Assert(await models.ReadConfiguredDaybreakAsync(session.Record.Cwd) == true,
            "The fixture's scoped inherited preference was lost.");
        await workspace.SubmitAsync(session, Payload("blue") with { Daybreak = true });
        await Until(() => !session.Timeline.IsRunning);
        var standard = await workspace.CreateAsync();
        await workspace.SubmitAsync(standard, Payload("standard") with { Daybreak = false });
        await Until(() => !standard.Timeline.IsRunning);
        var inherited = await workspace.CreateAsync();
        await workspace.SubmitAsync(inherited, Payload("default"));
        await Until(() => !inherited.Timeline.IsRunning);
        var blueOnly = await workspace.CreateAsync();
        await workspace.SubmitAsync(blueOnly, Payload("blue-only") with { Model = "text-only", CatalogModelId = "text-only", Daybreak = true });
        await Until(() => !blueOnly.Timeline.IsRunning);
        var standardOnly = await workspace.CreateAsync();
        await workspace.SubmitAsync(standardOnly, Payload("standard-only") with { Model = "gpt-6-sol", CatalogModelId = "gpt-6-sol", Daybreak = false });
        await Until(() => !standardOnly.Timeline.IsRunning);
        var recorded = ReadLogLines(Path.Combine(root, "daybreak-turns.log")).Select(Json).ToArray();
        var turns = recorded.Where(item => item.Str("method") == "turn/start").Select(item => item.GetProperty("params")).ToArray();
        Assert(turns.Length == 5 && turns[0].Str("cyberAccessProgram") == "daybreakBlue" &&
            turns[1].Str("cyberAccessProgram") == "standard" && !turns[2].TryGetProperty("cyberAccessProgram", out _) &&
            turns[3].Str("cyberAccessProgram") == "daybreakBlue" && turns[4].Str("cyberAccessProgram") == "standard",
            "Blue or Standard was sent inconsistently or inheritance became an explicit override.");
        var config = recorded.Single(item => item.Str("method") == "config/read").GetProperty("params");
        Assert(config.Str("cwd") == session.Record.Cwd && !config.GetProperty("includeLayers").GetBoolean(),
            "The inherited preference was read without its workspace scope.");
    });
    await Check("old schema, non-Direct routes and incompatible catalogs refuse explicit Daybreak before creating a runtime thread", async () =>
    {
        var old = DaybreakSchema(root, "old-daybreak-schema", includeField: false);
        await using (var workspace = Workspace("daybreak-old", schema: old))
        {
            await workspace.InitializeAsync();
            var session = await workspace.CreateAsync();
            var models = Selection(workspace);
            await models.RefreshAsync();
            Assert(!models.SupportsDaybreakBlue, "An older schema falsely advertised Blue support.");
            var choice = new ModelSelectionChoice("gpt-6-astra", "gpt-6-astra", "medium", null, Daybreak: true);
            Assert(models.Validate(choice with { Effort = "high" }).Daybreak == true,
                "A normal settings change discarded the persisted explicit selection.");
            await Throws<InvalidOperationException>(() => workspace.SubmitAsync(session, Payload() with { Daybreak = true }));
            Assert(session.Record.CodexThreadId is null, "A rejected selection started a thread.");
        }
        var schema = DaybreakSchema(root, "daybreak-gate-schema", includeField: true);
        await using (var workspace = Workspace("daybreak-gate", schema: schema))
        {
            await workspace.InitializeAsync();
            await Selection(workspace).RefreshAsync();
            var session = await workspace.CreateAsync();
            await Throws<InvalidOperationException>(() => workspace.SubmitAsync(session, Payload() with { Daybreak = true, RoutingMode = "Family6" }));
            await Throws<InvalidOperationException>(() => workspace.SubmitAsync(session, Payload() with { Daybreak = false, Model = "text-only" }));
            await Throws<InvalidOperationException>(() => workspace.SubmitAsync(session, Payload() with { Daybreak = true, Model = "gpt-6-sol" }));
            await Throws<InvalidOperationException>(() => workspace.SubmitAsync(session, Payload() with { Daybreak = true, Model = "external-runtime", CatalogModelId = "external/model" }));
            Assert(session.Record.CodexThreadId is null, "An incompatible model or route created a runtime thread.");
        }
    });
    await Check("Daybreak stays in durable drafts and local queues until a compatible new turn", async () =>
    {
        var explicitOn = Payload("daybreak-queued") with { Daybreak = true };
        var explicitOff = explicitOn with { Daybreak = false };
        var saved = ComposerDraft.Read(ComposerDraft.FromSnapshot(explicitOff).Persisted());
        Assert(saved.Snapshot(defaults: explicitOn).Daybreak == false, "An explicit off value was lost.");
        Assert(ComposerDraft.Read(new("old draft")).Snapshot().Daybreak is null, "A legacy draft gained a Daybreak override.");
        var schema = DaybreakSchema(root, "daybreak-queue-schema", includeField: true);
        await using var workspace = Workspace("daybreak-queue", schema: schema);
        await workspace.InitializeAsync();
        using var queue = new QueueCoordinator(workspace);
        var session = await workspace.CreateAsync();
        await workspace.EnsureRuntimeThreadAsync(session, Payload());
        session.Timeline.Begin("active");
        await workspace.SubmitAsync(session, explicitOn);
        var recordedQueue = JsonSerializer.Deserialize<ComposerSnapshot[]>((await workspace.Threads.ReadStateAsync(session.Record.VeoId, "queue"))!)!;
        Assert(recordedQueue.Single().Daybreak == true, "Queue persistence lost the frozen choice.");
        await Throws<InvalidOperationException>(() => queue.SteerAsync(session, explicitOn));
        session.Timeline.End("active");
        await workspace.DispatchNextQueuedAsync(session);
        var recorded = ReadLogLines(Path.Combine(root, "daybreak-queue.log")).Select(Json).ToArray();
        Assert(recorded.All(item => item.Str("method") is not ("thread/queue/add" or "turn/steer")) &&
            recorded.Single(item => item.Str("method") == "turn/start").GetProperty("params").Str("cyberAccessProgram") == "daybreakBlue",
            "Queue mirror or steer dropped the frozen treatment before the new turn.");
    });
    await Check("global/project defaults and per-model context survive relaunch without cross-project changes", async () =>
    {
        string a, b;
        await using (var workspace = Workspace("defaults"))
        {
            await workspace.InitializeAsync(); var models = Selection(workspace); await models.RefreshAsync(); var first = await workspace.CreateAsync(); var second = await workspace.CreateAsync(); a = first.Record.VeoId; b = second.Record.VeoId;
            await models.SaveSelectionAsync(first, new("gpt-6-astra", "gpt-6-astra", "high", "fast"));
            await models.SaveSelectionAsync(first, new("gpt-6-sol", "gpt-6-sol", "max", null), "Project");
            await models.SetContextAsync("gpt-6-sol", new("Custom", 300_000));
            Assert((await models.ResolveAsync(first)).ModelId == "gpt-6-sol" && (await models.ResolveAsync(second)).ModelId == "gpt-6-astra", "Project override changed global defaults.");
        }
        await using (var workspace = Workspace("defaults"))
        {
            await workspace.InitializeAsync(); var models = Selection(workspace); await models.RefreshAsync(); var catalog = await workspace.CatalogAsync();
            var first = await workspace.LoadAsync(catalog.Single(x => x.VeoId == a)); var second = await workspace.LoadAsync(catalog.Single(x => x.VeoId == b));
            Assert((await models.ResolveAsync(first)).ContextTokens == 300_000 && (await models.ResolveAsync(second)).ContextTokens == 200_000, "Relaunch lost scoped context choices.");
            await models.ResetProjectAsync(first); Assert((await models.ResolveAsync(first)).ModelId == "gpt-6-astra", "Project reset did not inherit global model.");
        }
    });
    await Check("worktree project identity follows common Git metadata without lowercasing paths", async () =>
    {
        var project = Path.Combine(root, "ProjectIdentity"); var worktree = Path.Combine(root, "WorktreeIdentity"); var metadata = Path.Combine(project, ".git");
        Directory.CreateDirectory(metadata); Directory.CreateDirectory(worktree); Directory.CreateDirectory(Path.Combine(metadata, "worktrees", "w"));
        await File.WriteAllTextAsync(Path.Combine(worktree, ".git"), "gitdir: " + Path.Combine(metadata, "worktrees", "w")); await File.WriteAllTextAsync(Path.Combine(metadata, "worktrees", "w", "commondir"), "../..");
        var first = await ModelSelectionService.ProjectIdentityAsync(project, default); var second = await ModelSelectionService.ProjectIdentityAsync(worktree, default);
        Assert(first == second && first.Contains("ProjectIdentity"), "Worktree inherited another identity or path case was lost.");
    });
    await Check("Auto candidates enforce speed/Ultra/image policy and use source fallback", () =>
    {
        var models = CatalogRows().Select(NativeModelDescriptor.Parse).OfType<NativeModelDescriptor>().ToArray();
        var routes = FirstPromptRouting.Candidates(models, new(true), true);
        Assert(routes.All(x => !x.IsFast && x.Effort != "ultra" && x.Model.SupportsImages) && routes.All(x => !x.Model.IsSpark), "Disallowed accelerated/Ultra/image route escaped filtering.");
        var fallback = FirstPromptRouting.Fallback(routes); Assert(fallback.Model.Id == "gpt-6-astra" && fallback.Effort == "medium" && !fallback.IsFast, "Fallback differs from source lead/default policy.");
        var enabled = FirstPromptRouting.Candidates(models, new(true, AllowFast: true, AllowUltra: true)); Assert(enabled.Any(x => x.IsFast) && enabled.Any(x => x.Effort == "ultra"), "Allowed routes were invented or omitted."); return Task.CompletedTask;
    });
    await Check("Jev response validation and Unicode truncation reject inconsistent choices", async () =>
    {
        var allowed = new HashSet<string>(["r0", "r1"], StringComparer.Ordinal);
        Assert(JevFirstPromptRouter.ValidatedChoice(Json("""{"answers":{"route":{"type":"choice","choice":"r1","confidence":0.8,"probabilities":{"r0":0.2,"r1":0.8}}}}"""), allowed) == "r1", "Valid choice rejected.");
        await Throws<InvalidDataException>(() => Task.FromResult(JevFirstPromptRouter.ValidatedChoice(Json("""{"answers":{"route":{"type":"choice","choice":"r0","confidence":0.8,"probabilities":{"r0":0.2,"r1":0.8}}}}"""), allowed)));
        var prompt = string.Concat(Enumerable.Repeat("🙂\u0301", 24001)); var truncated = FirstPromptRouting.TruncatePrompt(prompt);
        Assert(System.Globalization.StringInfo.ParseCombiningCharacters(truncated).Length == 24000 && truncated.EndsWith("🙂\u0301", StringComparison.Ordinal), "Prompt truncation split a text element.");
    });
    await Check("Jev HTTP fixture uses explicit credentials, bounded retry and allowed route IDs", async () =>
    {
        var routes = FirstPromptRouting.Candidates(CatalogRows().Take(1).Select(NativeModelDescriptor.Parse).OfType<NativeModelDescriptor>().ToArray(), new(true));
        var calls = 0; var handler = new FixtureHandler(async request =>
        {
            calls++; Assert(request.RequestUri!.Host == "api.typesafe.ai" && request.Headers.Authorization?.Parameter == "fixture-key", "Credential or endpoint mismatch.");
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync()); Assert(body.RootElement.GetProperty("state").GetProperty("first_user_prompt").GetString() == "prompt", "Router prompt changed.");
            if (calls == 1) return new(HttpStatusCode.TooManyRequests);
            var probabilities = routes.ToDictionary(x => x.Id, x => x.Id == routes[0].Id ? 1.0 : 0.0);
            return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { answers = new { route = new { type = "choice", choice = routes[0].Id, confidence = 1, probabilities } } })) };
        });
        using var client = new HttpClient(handler); using var router = new JevFirstPromptRouter(_ => Task.FromResult<string?>("fixture-key"), client);
        Assert(await router.ChooseAsync("prompt", routes) == routes[0].Id && calls == 2, "HTTP fixture did not retry or validate selection.");
    });
    await Check("first-prompt opt-in, durable route lock and reconnect never reroute a thread", async () =>
    {
        string id; var inference = new FixtureInference(request => Task.FromResult("{\"choice\":\"r0\"}"));
        await using (var workspace = Workspace("first"))
        {
            await workspace.InitializeAsync(); var models = Selection(workspace); await models.RefreshAsync(); await using var routing = new AutoRoutingCoordinator(workspace, models, inference: inference); var thread = await workspace.CreateAsync(); id = thread.Record.VeoId;
            await Throws<InvalidOperationException>(() => routing.PrepareAsync(thread, Payload() with { RoutingMode = "FirstPrompt", RouterPolicy = new() })); Assert(inference.Calls == 0, "Routing sent input without opt-in.");
            var prepared = await routing.PrepareAsync(thread, Payload() with { RoutingMode = "FirstPrompt", RouterPolicy = new(true, UtilityModelId: "gpt-6-luna") });
            Assert(inference.Calls == 1 && prepared.ContextTokens == 200_000 && routing.LockedRoute(thread) is not null, "First route was not frozen and persisted.");
        }
        await using (var workspace = Workspace("first"))
        {
            await workspace.InitializeAsync(); var models = Selection(workspace); await models.RefreshAsync(); await using var routing = new AutoRoutingCoordinator(workspace, models, inference: inference); var thread = await workspace.LoadAsync((await workspace.CatalogAsync()).Single(x => x.VeoId == id));
            var locked = await routing.PrepareAsync(thread, Payload("second") with { Model = "text-only", Effort = "ultra", RoutingMode = "Direct" });
            Assert(inference.Calls == 1 && locked.Model == "gpt-6-astra" && locked.Effort == "low", "Relaunch or picker changes rewrote the permanent route.");
        }
    });
    await Check("routing failure records fallback; cancellation never freezes a choice", async () =>
    {
        await using var workspace = Workspace("fallback"); await workspace.InitializeAsync(); var models = Selection(workspace); await models.RefreshAsync();
        var failed = new FixtureInference(_ => throw new IOException("fixture router failed")); await using var routing = new AutoRoutingCoordinator(workspace, models, inference: failed);
        var first = await workspace.CreateAsync(); var prepared = await routing.PrepareAsync(first, Payload() with { RoutingMode = "FirstPrompt", RouterPolicy = new(true, UtilityModelId: "gpt-6-luna") });
        Assert(routing.LockedRoute(first)?.UsedFallback == true && prepared.Model == "gpt-6-astra" && routing.Notice(first)!.Contains("fixture router failed"), "Fallback was silent or incorrect.");
        var cancelled = new FixtureInference(async _ => { await Task.Delay(500); return "{\"choice\":\"r0\"}"; }); await using var secondRouting = new AutoRoutingCoordinator(workspace, models, inference: cancelled); var second = await workspace.CreateAsync();
        using var cancellation = new CancellationTokenSource(30);
        await Throws<OperationCanceledException>(() => secondRouting.PrepareAsync(second, Payload() with { RoutingMode = "FirstPrompt", RouterPolicy = new(true, UtilityModelId: "gpt-6-luna") }, cancellation.Token));
        Assert(secondRouting.LockedRoute(second) is null, "Cancelled routing left a permanent route.");
    });
    await Check("family plans use only advertised lanes and invalidate review after new implementation", async () =>
    {
        var catalog = CatalogRows().Select(NativeModelDescriptor.Parse).OfType<NativeModelDescriptor>().ToArray();
        var plan = FamilyAutoRouting.Resolve(catalog, "6", true); Assert(plan.Routine.Model == "gpt-6-luna" && plan.Routine.Effort == "max" && plan.Parent.Model == "gpt-6-astra" && plan.Escalation.Model == "gpt-6-sol", "Family lanes differ from source.");
        Assert(FamilyAutoRouting.Resolve(catalog, "6", false).Availability == "single" && FamilyAutoRouting.Resolve(catalog.Where(x => x.Id != "gpt-6-luna").ToArray(), "6", true).Warnings.Length > 0, "Unavailable worker was invented.");
        await Throws<InvalidOperationException>(() => Task.FromResult(FamilyAutoRouting.Resolve(catalog.Where(x => x.Id != "gpt-6-astra").ToArray(), "6", true)));
        Assert(FamilyAutoRouting.Instructions(plan, "Plan").Contains("Do not edit files") && !FamilyAutoRouting.Instructions(plan, "Plan").Contains("Delegate routine"), "Plan mode delegated implementation.");
        TimelineItem Item(string id, string kind, string text, JsonElement raw, long order) => new(id, "t", kind, text, "completed", raw, order);
        var timeline = new List<TimelineItem> { Item("user", "userMessage", "request", Json("""{"id":"user","clientId":"family-client"}"""), 0), Item("worker", "collabAgentToolCall", "", Spawn("Implement objective", "gpt-6-luna", "worker"), 1), Item("review", "collabAgentToolCall", "", Spawn("You are a fresh reviewer. VERDICT: ship", "gpt-6-astra", "reviewer", "VERDICT: ship"), 2) };
        var state = AutoWorkflowReducer.Derive(timeline, "family-client", "t", plan, false); Assert(state.Verdict == "ship", "Observed review verdict was lost.");
        timeline.Add(Item("fix", "collabAgentToolCall", "", Spawn("Implement the fix", "gpt-6-sol", "fixer"), 3)); state = AutoWorkflowReducer.Derive(timeline, "family-client", "t", plan, true);
        Assert(state.Verdict is null && state.Steps.Single(x => x.Name == "Review").Status == "pending", "A new fix reused an old verdict.");
    });
    await Check("context is next-turn-only and failed resume rolls back previous context", async () =>
    {
        await using var workspace = Workspace("context", "reject-context"); await workspace.InitializeAsync(); var models = Selection(workspace); await models.RefreshAsync(); await using var routing = new AutoRoutingCoordinator(workspace, models, inference: new FixtureInference(_ => Task.FromResult("{}"))); var thread = await workspace.CreateAsync();
        await workspace.SubmitAsync(thread, Payload()); await Until(() => !thread.Timeline.IsRunning);
        await models.SetContextAsync("gpt-6-astra", new("Custom", 200_000)); await routing.ConfigureContextAsync(thread, Payload() with { ContextTokens = 200_000 });
        thread.Timeline.Begin("active"); Assert((await routing.ConfigureContextAsync(thread, Payload() with { ContextTokens = 300_000 })).Status == "NextTurnOnly", "Active context was changed."); thread.Timeline.End("active");
        await models.SetContextAsync("gpt-6-astra", new("Custom", 400_000)); await Throws<CodexRpcException>(() => routing.ConfigureContextAsync(thread, Payload() with { ContextTokens = 400_000 }));
        Assert(models.ContextChoice("gpt-6-astra").Tokens == 200_000, "Rejected context preference was not restored.");
        var calls = ReadLogLines(Path.Combine(root, "context.log")).Where(x => x.StartsWith('{')).Select(Json).Where(x => x.Str("method") == "thread/resume").ToArray(); Assert(calls.Last().GetProperty("params").GetProperty("config").GetProperty("model_context_window").GetInt64() == 200_000, "Runtime context rollback was not attempted.");
    });
    await Check("private utility stays on one runtime, declines tools and cleans its subscription", async () =>
    {
        await using var workspace = Workspace("utility"); await workspace.InitializeAsync(); var models = Selection(workspace); await models.RefreshAsync(); await using var utility = new UtilityInferenceService(workspace); workspace.TryHandleRuntimeEvent = utility.TryHandle;
        var directory = Path.Combine(root, "utility-cwd"); Directory.CreateDirectory(directory); var generation = workspace.Runtime.Generation; var process = workspace.Runtime.ProcessId;
        var output = await utility.InferAsync(new(JsonSerializer.SerializeToElement(new[] { new { type = "text", text = "fixture input" } }), Json("{\"type\":\"object\"}"), models.Find("gpt-6-luna")!, directory, true));
        Assert(output == "{\"choice\":\"r0\"}" && workspace.PendingRequests.Count == 0 && workspace.Runtime.ProcessId == process && workspace.Runtime.Generation == generation, "Private utility leaked UI requests or spawned a second runtime.");
        var log = ReadLogText(Path.Combine(root, "utility.log")); Assert(log.Contains("thread/unsubscribe") && log.Contains("decline"), "Private utility was not declined/cleaned.");
    });
    await Check("utility cancellation resolves missing turn IDs and interrupts only its private thread", async () =>
    {
        await using var workspace = Workspace("utility-cancel", "utility-delay"); await workspace.InitializeAsync(); var models = Selection(workspace); await models.RefreshAsync(); await using var utility = new UtilityInferenceService(workspace); workspace.TryHandleRuntimeEvent = utility.TryHandle;
        var directory = Path.Combine(root, "utility-cancel-cwd"); Directory.CreateDirectory(directory);
        using var cancellation = new CancellationTokenSource(100);
        await Throws<OperationCanceledException>(() => utility.InferAsync(new(Json("[]"), Json("{\"type\":\"object\"}"), models.Find("gpt-6-luna")!, directory, true), cancellation.Token));
        var requests = ReadLogLines(Path.Combine(root, "utility-cancel.log")).Select(Json).Where(x => x.Str("method") == "turn/interrupt").ToArray();
        Assert(requests.Length > 0 && requests.All(x => x.GetProperty("params").Str("turnId") == "utility-pending"), "Cancellation failed to resolve or targeted the wrong turn.");
    });
    await Check("queued route and vision arrays remain immutable and survive persisted readback", async () =>
    {
        await using var workspace = Workspace("queue-snapshot"); await workspace.InitializeAsync(); var thread = await workspace.CreateAsync(); thread.Timeline.Begin("active");
        var plan = FamilyAutoRouting.Resolve(CatalogRows().Select(NativeModelDescriptor.Parse).OfType<NativeModelDescriptor>().ToArray(), "6", false);
        var images = new[] { new VisionImageDescription("image.png", "image.png", "ABC", "original") }; var warnings = plan.Warnings; var typed = new[] { new ComposerAttachment(ComposerAttachmentKind.FileMention, "file.txt", "File") };
        await workspace.SubmitAsync(thread, Payload("queued") with { FamilyPlan = plan, RoutingMode = "Family6", VisionFallback = new("utility", "Utility", images), ContextTokens = 300_000, StructuredAttachments = typed });
        warnings[0] = "mutated"; images[0] = images[0] with { Description = "mutated" };
        typed[0] = typed[0] with { Source = "mutated" }; var retrievedAttachments = thread.Queue.Single().StructuredAttachments!; retrievedAttachments[0] = retrievedAttachments[0] with { Source = "changed getter" }; Assert(thread.Queue.Single().StructuredAttachments![0].Source == "file.txt", "Queue retained mutable typed attachment arrays.");
        var queued = thread.Queue.Single(); queued.FamilyPlan!.Warnings[0] = "changed getter";
        Assert(thread.Queue.Single().FamilyPlan!.Warnings[0] != "mutated" && thread.Queue.Single().FamilyPlan!.Warnings[0] != "changed getter" && thread.Queue.Single().VisionFallback!.Images[0].Description == "original", "Queue retained mutable route arrays.");
        var persisted = JsonSerializer.Deserialize<ComposerSnapshot[]>((await workspace.Threads.ReadStateAsync(thread.Record.VeoId, "queue"))!)!.Single();
        Assert(persisted.ContextTokens == 300_000 && persisted.RoutingMode == "Family6" && persisted.VisionFallback!.Images[0].Description == "original", "Persisted route snapshot lost meaningful settings.");
    });
    await Check("family stage evidence is persisted with its own client/turn identity", async () =>
    {
        await using var workspace = Workspace("family-run"); await workspace.InitializeAsync(); var models = Selection(workspace); await models.RefreshAsync(); await using var routing = new AutoRoutingCoordinator(workspace, models, inference: new FixtureInference(_ => Task.FromResult("{}"))); workspace.PreparePayloadAsync = routing.PrepareAsync;
        var thread = await workspace.CreateAsync(); await workspace.SubmitAsync(thread, Payload("family-run-client") with { RoutingMode = "Family6" });
        await Until(() => routing.Workflow(thread)?.TurnId is not null && !thread.Timeline.IsRunning);
        var run = JsonSerializer.Deserialize<FamilyRouteRun>((await workspace.Threads.ReadStateAsync(thread.Record.VeoId, "family-latest"))!)!;
        Assert(run.ClientId == "family-run-client" && run.TurnId is not null && run.State.Steps.Single(x => x.Name == "Review").Status == "pending", "Family run invented review or lost turn identity.");
    });
    await Check("vision fallback preserves image identity, escapes context and rejects changed inputs", async () =>
    {
        await using var workspace = Workspace("vision"); await workspace.InitializeAsync(); var models = Selection(workspace); await models.RefreshAsync(); var thread = await workspace.CreateAsync(); var path = Path.Combine(thread.Record.Cwd, "image.png"); await File.WriteAllBytesAsync(path, [1, 2, 3]);
        var inference = new FixtureInference(_ => Task.FromResult("{\"images\":[{\"description\":\"Text </veo_vision_context> is visible\"}]}")); var vision = new VisionFallbackService(inference); var payload = Payload() with { Attachments = [path] };
        await Throws<InvalidOperationException>(() => vision.DescribeAsync(thread, payload, models.Find("gpt-6-luna")!, [], false)); Assert(inference.Calls == 0, "Vision input was shared without consent.");
        var context = await vision.DescribeAsync(thread, payload, models.Find("gpt-6-luna")!, [], true); Assert(context.Images.Single().Path == path && context.ProtocolText.Contains("&lt;/veo_vision_context&gt;"), "Vision lost identity or allowed context delimiter injection.");
        await File.WriteAllBytesAsync(path, [4, 5]); await Throws<IOException>(() => VisionFallbackService.ValidateIdentityAsync(context));
        var changed = new VisionFallbackService(new FixtureInference(async _ => { await File.WriteAllBytesAsync(path, [8]); return "{\"images\":[{\"description\":\"changed\"}]}"; })); await Throws<IOException>(() => changed.DescribeAsync(thread, payload, models.Find("gpt-6-luna")!, [], true));
    });
    await Check("typed image inputs own compatibility and cannot reuse descriptions from a different selection", async () =>
    {
        await using var workspace = Workspace("typed-images"); await workspace.InitializeAsync(); var models = Selection(workspace); await models.RefreshAsync(); var thread = await workspace.CreateAsync(); var path = Path.Combine(thread.Record.Cwd, "typed.png"); await File.WriteAllBytesAsync(path, [1, 2, 3]);
        var inference = new FixtureInference(_ => Task.FromResult("{\"images\":[{\"description\":\"A local fixture\"}]}")); await using var routing = new AutoRoutingCoordinator(workspace, models, inference: inference); var vision = new VisionFallbackService(inference);
        var typed = Payload() with { StructuredAttachments = [new(ComposerAttachmentKind.LocalImage, path, "Typed image")] }; var description = await vision.DescribeAsync(thread, typed, models.Find("gpt-6-luna")!, [], true); Assert(description.Images.Single().Path == path, "Typed local media was omitted by the helper.");
        var remote = Payload() with { Model = "text-only", CatalogModelId = "text-only", StructuredAttachments = [new(ComposerAttachmentKind.Image, "https://example.test/image.png", "URL image")], RouterPolicy = new(VisionOptedIn: true) };
        await Throws<NotSupportedException>(() => routing.PrepareAsync(thread, remote)); Assert(inference.Calls == 1, "A remote fallback made an unapproved fetch or private partial inference.");
        var different = typed with { StructuredAttachments = [new(ComposerAttachmentKind.LocalImage, Path.Combine(thread.Record.Cwd, "other.png"), "Other")], VisionFallback = description }; await Throws<InvalidOperationException>(() => routing.PrepareAsync(thread, different));
        var onlyMention = Payload() with { Model = "text-only", CatalogModelId = "text-only", Attachments = ["legacy.png"], StructuredAttachments = [new(ComposerAttachmentKind.FileMention, "file.txt", "File")] }; Assert((await routing.PrepareAsync(thread, onlyMention)).VisionFallback is null, "A typed file reference was misclassified as legacy image input.");
    });
}
finally { var parent = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Veo-Models-Tests")); if (Path.GetDirectoryName(root) == parent && Directory.Exists(root)) Directory.Delete(root, true); }
Console.WriteLine($"PASS: {passed} model/routing checks.");
async Task Check(string name, Func<Task> test) { await test().WaitAsync(TimeSpan.FromSeconds(30)); passed++; Console.WriteLine("PASS " + name); }
static JsonElement Json(string text) => JsonSerializer.Deserialize<JsonElement>(text);
static string ReadLogText(string path)
{
    using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
    using var reader = new StreamReader(stream); return reader.ReadToEnd();
}
static string[] ReadLogLines(string path)
{
    var text = ReadLogText(path); var lines = text.Split('\n');
    return lines.Take(lines.Length - 1).Where(line => line.Length > 0).ToArray();
}
static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
static async Task Throws<T>(Func<Task> action) where T : Exception { try { await action(); } catch (T) { return; } throw new InvalidOperationException($"Expected {typeof(T).Name}."); }
static async Task Until(Func<bool> condition) { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)); while (!condition()) await Task.Delay(20, timeout.Token); }
static JsonElement Spawn(string prompt, string model, string receiver, string? verdict = null) => JsonSerializer.SerializeToElement(new { type = "collabAgentToolCall", tool = "spawnAgent", prompt, model, receiverThreadIds = new[] { receiver }, agentsStates = new Dictionary<string, object> { [receiver] = new { status = "completed", message = verdict } } });
static string DaybreakSchema(string root, string name, bool includeField)
{
    var directory = Path.Combine(root, name); Directory.CreateDirectory(directory);
    var methods = new[] { "initialize", "model/list", "account/read", "experimentalFeature/list", "config/read",
        "thread/start", "thread/read", "thread/queue/add", "thread/queue/list", "turn/start", "turn/steer" };
    File.WriteAllText(Path.Combine(directory, "ClientRequest.json"),
        JsonSerializer.Serialize(methods.Select(method => new { properties = new { method = new { @const = method } } })));
    var v2 = Path.Combine(directory, "v2"); Directory.CreateDirectory(v2);
    File.WriteAllText(Path.Combine(v2, "TurnStartParams.json"), includeField
        ? """{"properties":{"cyberAccessProgram":{"anyOf":[{"$ref":"#/definitions/CyberAccessProgram"},{"type":"null"}]}},"definitions":{"CyberAccessProgram":{"enum":["standard","daybreakBlue","daybreakRed"]}}}"""
        : """{"properties":{}}""");
    return directory;
}
static JsonElement[] CatalogRows()
{
    var names = new[] { "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.3-codex-spark", "text-only", "external/model", "gpt-6.2-sol" };
    return names.Select(name => JsonSerializer.SerializeToElement(new { id = name, model = name == "external/model" ? "external-runtime" : name, displayName = name, description = "Live fixture " + name, isDefault = name == "gpt-6-astra", hidden = false, defaultReasoningEffort = "medium", supportedReasoningEfforts = new[] { "low", "medium", "high", "max", "ultra" }.Select(effort => new { reasoningEffort = effort, description = effort }).ToArray(), serviceTiers = name == "gpt-6.2-sol"
        ? new[] { new { id = "standard", name = "Standard", description = "standard" }, new { id = "fast", name = "Fast", description = "faster" }, new { id = "ultrafast", name = "Ultrafast", description = "fastest" } }
        : new[] { new { id = "standard", name = "Standard", description = "standard" }, new { id = "fast", name = "Fast", description = "faster" } }, defaultServiceTier = "standard", inputModalities = name == "text-only" ? new[] { "text" } : new[] { "text", "image" },
        availableAccessPrograms = new
        {
            cyber = name is "gpt-6-astra" or "external/model" ? new[] { "standard", "daybreakBlue" }
                : name == "text-only" ? new[] { "daybreakBlue" } : new[] { "standard" }
        } })).ToArray();
}
static async Task ModelServer(string[] arguments)
{
    var scenario = arguments.Single(x => x.StartsWith("--scenario="))[11..]; var trace = arguments.Single(x => x.StartsWith("--trace="))[8..]; var next = 0; var utilityThreads = new HashSet<string>();
    while (await Console.In.ReadLineAsync() is { } line)
    {
        await File.AppendAllTextAsync(trace, line + "\n"); using var d = JsonDocument.Parse(line); var request = d.RootElement;
        if (!request.TryGetProperty("method", out var method) || !request.TryGetProperty("id", out var requestId)) continue; var id = requestId.GetInt64(); var p = request.TryGetProperty("params", out var parameters) ? parameters : default;
        switch (method.GetString())
        {
            case "initialize": await Write(new { id, result = new { userAgent = "models fixture" } }); break;
            case "model/list": var second = p.Str("cursor") == "next"; await Write(new { id, result = new { data = second ? CatalogRows().Skip(4).ToArray() : CatalogRows().Take(4).ToArray(), nextCursor = second ? null : "next" } }); break;
            case "experimentalFeature/list": await Write(new { id, result = new { data = new[] { new { name = "multi_agent", enabled = true } } } }); break;
            case "config/read": await Write(new { id, result = new { config = new { daybreak = true } } }); break;
            case "thread/start": var thread = "rt" + ++next; if (p.TryGetProperty("ephemeral", out var ephemeral) && ephemeral.ValueKind == JsonValueKind.True) utilityThreads.Add(thread); await Write(new { id, result = new { thread = new { id = thread } } }); break;
            case "thread/resume":
                if (scenario == "reject-context" && p.TryObjectProperty("config", out var config) && config.GetProperty("model_context_window").GetInt64() == 400_000) await Write(new { id, error = new { code = -32000, message = "fixture rejects requested context" } });
                else await Write(new { id, result = new { thread = new { id = p.Str("threadId"), status = "idle", turns = Array.Empty<object>() } } }); break;
            case "turn/start":
                var runtime = p.Str("threadId"); var isUtility = runtime is not null && utilityThreads.Contains(runtime);
                if (isUtility && scenario == "utility-delay") { await Write(new { method = "turn/started", @params = new { threadId = runtime, turn = new { status = "inProgress" } } }); break; }
                await Write(new { method = "turn/started", @params = new { threadId = runtime, turn = new { id = "turn" + next } } });
                if (isUtility) await Write(new { id = "private-approval", method = "item/commandExecution/requestApproval", @params = new { threadId = runtime, command = "do not run" } });
                var text = isUtility ? "{\"choice\":\"r0\"}" : "done";
                await Write(new { method = "turn/completed", @params = new { threadId = runtime, turn = new { id = "turn" + next, status = "completed", items = new[] { new { id = "assistant" + next, type = "agentMessage", text } } } } });
                await Write(new { id, result = new { turn = new { id = "turn" + next } } }); break;
            case "thread/read": await Write(new { id, result = new { thread = new { id = p.Str("threadId"), turns = new[] { new { id = "utility-pending", status = "inProgress" } } } } }); break;
            default: await Write(new { id, result = new { } }); break;
        }
    }
    static async Task Write(object value) { await Console.Out.WriteLineAsync(JsonSerializer.Serialize(value)); await Console.Out.FlushAsync(); }
}
sealed class FixtureInference(Func<UtilityInferenceRequest, Task<string>> run) : IUtilityInference
{
    public int Calls { get; private set; }
    public Task<string> InferAsync(UtilityInferenceRequest request, CancellationToken cancellation = default) { cancellation.ThrowIfCancellationRequested(); Calls++; return run(request); }
}
sealed class FixtureHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> run) : HttpMessageHandler
{ protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => run(request); }
