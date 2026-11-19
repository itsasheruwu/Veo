using System.Text.Json;
using Veo.Core;
using Veo.Protocol;

static class WorkspaceContinuationChecks
{
    public static async Task RunAsync(string root, Action<bool, string> assert)
    {
        var data = Path.Combine(root, "adapter"); var trace = Path.Combine(root, "adapter-trace.jsonl"); var control = Path.Combine(root, "adapter-control.json");
        var self = Path.Combine(AppContext.BaseDirectory, "Veo.Continuation.Tests.exe");
        await File.WriteAllTextAsync(control, "{\"allowed\":false,\"loggedIn\":true}");
        await using var workspace = new WorkspaceCoordinator(data, _ => new CodexRuntimeService(new CodexRuntimeOptions { ExecutablePath = self, AdditionalArguments = ["--continuation-adapter-server", "--trace=" + trace, "--control=" + control] }));
        await using var service = new WorkspaceContinuationService(workspace);
        await workspace.InitializeAsync(); await service.InitializeAsync();
        var thread = await workspace.CreateAsync();
        await workspace.SubmitAsync(thread, new("initial-source", "Interrupted source prompt", "fixture-model", "max", "fast", "Read only", "Plan", [], ContextTokens: 64000, CatalogModelId: "fixture-catalog-choice"));
        try { await UntilAsync(async () => (await service.Jobs.ListAsync()).Count == 1); }
        catch (OperationCanceledException) { throw new InvalidOperationException("Job creation timeout: " + service.Status + " / " + workspace.Status + " / fixture requests " + (File.Exists(trace) ? File.ReadAllLines(trace).Length : 0)); }
        var job = (await service.Jobs.ListAsync()).Single();
        assert(job.Status == ContinuationStatus.Blocked && !job.IsEnabled, "actual usage-limit notification creates a disabled job");
        assert(job.Model == "fixture-model" && job.Effort == "max" && job.Tier == "fast" && job.Access == "Read only" && job.InteractionMode == "Plan", "adapter captures the failed turn's exact request choices");
        await workspace.SaveDraftAsync(thread, "Keep this unsent user draft");
        await service.Jobs.SetEnabledAsync(job.Id, true);
        job = (await service.Jobs.ListAsync()).Single();
        await service.Jobs.UpsertAsync(job with { ResetAt = DateTimeOffset.UtcNow.AddSeconds(-30) });
        await service.ProcessDueAsync();
        assert(Starts(trace).Count == 1, "usage percentages and elapsed reset do not imply permission to resume");
        await File.WriteAllTextAsync(control, "{\"allowed\":true,\"loggedIn\":true}");
        job = (await service.Jobs.ListAsync()).Single();
        await service.Jobs.UpsertAsync(job with { ResetAt = DateTimeOffset.UtcNow.AddSeconds(-30) });
        await service.ProcessDueAsync();
        await UntilAsync(async () => (await service.Jobs.ListAsync()).Single().Status == ContinuationStatus.Completed);
        var starts = Starts(trace);
        var continuation = starts.Single(x => x.GetProperty("params").Str("clientUserMessageId")?.StartsWith("auto-continue-", StringComparison.Ordinal) == true).GetProperty("params");
        assert(starts.Count == 2 && continuation.GetProperty("sandboxPolicy").Str("type") == "readOnly" && continuation.Str("effort") == "max" && continuation.Str("serviceTier") == "fast" && continuation.GetProperty("collaborationMode").Str("mode") == "plan", "adapter continuation uses the original app runtime and exact access/model settings");
        assert((await workspace.Threads.ReadDraftAsync(thread.Record.VeoId))?.Text == "Keep this unsent user draft", "actual continuation preserves the unsent draft");
        using (var copied = JsonDocument.Parse((await workspace.Threads.ReadStateAsync(thread.Record.VeoId, "continuation-source-payload"))!))
            assert(copied.RootElement.GetProperty("Payload").GetProperty("ContextTokens").GetInt64() == 64000 && copied.RootElement.GetProperty("Payload").Str("CatalogModelId") == "fixture-catalog-choice", "direct continuation retains custom context and catalog selection metadata");
        await service.ProcessDueAsync(); assert(Starts(trace).Count == 2, "next eligibility pass cannot duplicate the acknowledged continuation");
        await service.SetEnabledByDefaultAsync(true);
        using (var preferences = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(data, "Continuation", "preferences.json"))))
            assert(preferences.RootElement.GetProperty("EnabledByDefault").GetBoolean(), "explicit future opt-in persists to its own settings file");
        await service.SetEnabledByDefaultAsync(false);
        await UntilAsync(() => Task.FromResult(!thread.Timeline.IsRunning));
        await workspace.SubmitAsync(thread, new("manual-source", "Another interrupted task", "fixture-model", "medium", null, "Workspace", "Agentic", []));
        await UntilAsync(async () => (await service.Jobs.ListAsync()).Any(x => x.FailedTurnId == "failed-3"));
        await workspace.SetArchivedAsync(thread, true); await service.ProcessDueAsync();
        assert((await service.Jobs.ListAsync()).Single(x => x.FailedTurnId == "failed-3").Status == ContinuationStatus.Cancelled, "archiving the actual local chat cancels its saved job");
        await workspace.SetArchivedAsync(thread, false);
        await workspace.SubmitAsync(thread, new("manual-again", "Account change interruption", "fixture-model", "medium", null, "Workspace", "Agentic", []));
        await UntilAsync(async () => (await service.Jobs.ListAsync()).Any(x => x.FailedTurnId == "failed-4"));
        await File.WriteAllTextAsync(control, "{\"allowed\":false,\"loggedIn\":false}"); await service.ProcessDueAsync();
        assert((await service.Jobs.ListAsync()).Single(x => x.FailedTurnId == "failed-4").Status == ContinuationStatus.Cancelled, "fresh actual account read cancels jobs after logout");
        var noReset = JsonSerializer.SerializeToElement(new { rateLimits = new { primary = new { usedPercent = 100, resetsAt = (long?)null } } });
        assert(WorkspaceContinuationService.ApplicableReset(noReset, DateTimeOffset.UtcNow) is null, "nullable protocol reset metadata stays unknown");
    }

    private static List<JsonElement> Starts(string trace) => File.ReadAllLines(trace).Select(line => JsonSerializer.Deserialize<JsonElement>(line)).Where(x => x.Str("method") == "turn/start").ToList();
    private static async Task UntilAsync(Func<Task<bool>> condition)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        while (!await condition()) await Task.Delay(20, timeout.Token);
    }

    public static async Task ServerAsync(string[] arguments)
    {
        var trace = arguments.Single(x => x.StartsWith("--trace="))[8..];
        var control = arguments.Single(x => x.StartsWith("--control="))[10..];
        var turns = new List<object>(); var count = 0; var cwd = "";
        while (await Console.In.ReadLineAsync() is { } line)
        {
            using var document = JsonDocument.Parse(line); var request = document.RootElement;
            if (!request.TryGetProperty("id", out var id)) continue;
            await File.AppendAllTextAsync(trace, request.GetRawText() + "\n");
            var parameters = request.TryGetProperty("params", out var supplied) ? supplied : default;
            switch (request.Str("method"))
            {
                case "initialize": await Reply(new { id, result = new { userAgent = "continuation-fixture 0.169.0" } }); break;
                case "model/list": await Reply(new { id, result = new { data = new[] { new { id = "fixture-model", model = "fixture-model", displayName = "Fixture" } } } }); break;
                case "account/read":
                    using (var config = JsonDocument.Parse(await File.ReadAllTextAsync(control)))
                        await Reply(new { id, result = new { account = config.RootElement.GetProperty("loggedIn").GetBoolean() ? (object)new { type = "chatgpt", email = "fixture@example.test", planType = "plus" } : null, userId = "fixture-user", workspaceRouting = new { chatgptAccountId = "fixture-account", backendOrigin = "https://chatgpt.com", accountRoutingOverride = "NO_CONSTRAINT" }, requiresOpenaiAuth = true } });
                    break;
                case "account/rateLimits/read":
                    using (var config = JsonDocument.Parse(await File.ReadAllTextAsync(control)))
                        await Reply(new { id, result = new { accountId = "fixture-account", ordinaryUsageAllowed = config.RootElement.GetProperty("allowed").GetBoolean(), rateLimits = new { primary = new { usedPercent = 100, resetsAt = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds() } } } });
                    break;
                case "thread/start": cwd = parameters.Str("cwd")!; await Reply(new { id, result = new { thread = new { id = "runtime-thread" } } }); break;
                case "thread/resume" or "thread/read": await Reply(new { id, result = new { thread = new { id = "runtime-thread", cwd, status = new { type = "idle" }, turns } } }); break;
                case "turn/start":
                    count++; var clientId = parameters.Str("clientUserMessageId")!;
                    var continuation = clientId.StartsWith("auto-continue-", StringComparison.Ordinal);
                    var turnId = continuation ? "continued-turn" : "failed-" + count;
                    var user = new { id = "user-" + count, clientId, type = "userMessage", content = new[] { new { type = "text", text = "fixture" } } };
                    var turn = new { id = turnId, status = continuation ? "completed" : "failed", items = new[] { user }, error = continuation ? (object?)null : new { message = "Synthetic usage-limit interruption", codexErrorInfo = "usageLimitExceeded" } };
                    turns.Add(turn);
                    await Reply(new { method = "turn/started", @params = new { threadId = "runtime-thread", turn = new { id = turnId } } });
                    if (!continuation) await Reply(new { method = "error", @params = new { threadId = "runtime-thread", turnId, willRetry = false, error = new { message = "Synthetic usage-limit interruption", codexErrorInfo = "usageLimitExceeded" } } });
                    await Reply(new { method = "turn/completed", @params = new { threadId = "runtime-thread", turn } });
                    await Task.Delay(60); await Reply(new { id, result = new { turn } }); break;
                default: await Reply(new { id, result = new { } }); break;
            }
        }
        static async Task Reply(object value) { await Console.Out.WriteLineAsync(JsonSerializer.Serialize(value)); await Console.Out.FlushAsync(); }
    }
}
