using System.Text.Json;
using Veo.Core;
using Veo.Infrastructure.Storage;
using Veo.Protocol;

if (args.Contains("--core-fake-server")) { await FakeServer(args); return; }
var passed = 0;
await Check("paragraph streaming retains fenced code and exact Unicode/newlines", () =>
{
    Assert(ParagraphStreaming.CompletedPrefix("first\n\npartial") == "first\n\n", "An incomplete paragraph leaked.");
    Assert(ParagraphStreaming.CompletedPrefix("prose\n```cs\ncode\n```") == "prose\n", "An unterminated closing fence leaked.");
    Assert(ParagraphStreaming.CompletedPrefix("prose\n```cs\ncode\n```\nnext") == "prose\n```cs\ncode\n```\n", "Completed code did not flush.");
    Assert(ParagraphStreaming.CompletedPrefix("日本語🙂\r\n\r\nunfinished") == "日本語🙂\r\n\r\n", "CRLF/Unicode was changed.");
    Assert(ParagraphStreaming.CompletedPrefix("~~~~\n```\n\n~~~\n") == "", "A shorter or mismatched fence closed code.");
    var item = new TimelineItem("x", "turn", "agentMessage", "unfinished", "inProgress", default, 0);
    Assert(ParagraphStreaming.Visible(item, true, "None") == "" && ParagraphStreaming.Visible(item, false, "None") == "unfinished", "Completion did not reveal the full response.");
    return Task.CompletedTask;
});
JsonElement Json(string text) => JsonSerializer.Deserialize<JsonElement>(text);
await Check("missing turn ID fallback, item ordering, interleaved late reasoning", () =>
{
    var reducer = new TimelineReducer();
    reducer.Apply("turn/started", Json("{}"));
    Assert(reducer.IsRunning && reducer.ActiveTurnId is null, "Missing ID lost running fallback.");
    reducer.Apply("item/started", Json("""{"turnId":"t1","item":{"id":"r1","type":"reasoning","summary":[]}}"""));
    reducer.Apply("item/reasoning/summaryTextDelta", Json("""{"itemId":"r1","turnId":"t1","delta":"one "}"""));
    reducer.Apply("item/started", Json("""{"item":{"id":"a1","type":"agentMessage","text":"answer"}}"""));
    reducer.Apply("turn/completed", Json("""{"turn":{"id":"t1","status":"completed"}}"""));
    reducer.Apply("item/reasoning/summaryTextDelta", Json("""{"itemId":"r1","turnId":"t1","delta":"two"}"""));
    Assert(!reducer.IsRunning && reducer.Items.Select(x => x.Id).SequenceEqual(new[] { "r1", "a1" }), "Interleaving flattened or reopened a turn.");
    Assert(reducer.Items[0].Text == "one two", "Late reasoning did not merge into its original item.");
    return Task.CompletedTask;
});
await Check("late idle activity cannot create rows; completion snapshots retain items", () =>
{
    var reducer = new TimelineReducer();
    Assert(!reducer.Apply("item/started", Json("""{"item":{"id":"late","type":"commandExecution"}}""")), "Idle item started was accepted.");
    Assert(!reducer.Apply("item/agentMessage/delta", Json("""{"turnId":"old","itemId":"late","delta":"late"}""")), "Idle delta was accepted.");
    reducer.Begin("t1");
    reducer.Apply("turn/completed", Json("""{"turn":{"id":"t1","items":[{"id":"a1","type":"agentMessage","text":"final"}]}}"""));
    Assert(reducer.Items.Count == 1 && reducer.Items[0].Text == "final", "Completion-only item was dropped.");
    return Task.CompletedTask;
});
await Check("completion before start acknowledgement does not resurrect Stop", () =>
{
    var reducer = new TimelineReducer();
    var dispatch = reducer.BeginPending();
    reducer.Begin("t1"); reducer.End("t1"); reducer.AcknowledgeStart(dispatch, "t1");
    Assert(!reducer.IsRunning && reducer.ActiveTurnId is null, "Late RPC response reactivated completed turn.");
    reducer.Begin("t2"); reducer.End("t1");
    Assert(reducer.IsRunning && reducer.ActiveTurnId == "t2", "Old completion stopped a newer turn.");
    return Task.CompletedTask;
});
await Check("item history reconciles exact IDs, chronology, client identity and unknown fields", () =>
{
    var reducer = new TimelineReducer();
    reducer.AddLocal("client1", "userMessage", "exact\n");
    reducer.Upsert(Json("""{"id":"a1","type":"agentMessage","text":"stream","future":{"x":1}}"""), "t1");
    var user = Json("""{"id":"server-user","clientId":"client1","type":"userMessage","content":[{"type":"text","text":"exact\n"}]}""");
    var assistant = Json("""{"id":"a1","type":"agentMessage","text":"final"}""");
    reducer.Reconcile(new[] { new TimelineItem("server-user", "t1", "userMessage", "exact\n", "completed", user, 0), new TimelineItem("a1", "t1", "agentMessage", "final", "completed", assistant, 1) }, false, null);
    Assert(reducer.Items.Count == 2 && reducer.Items[0].Id == "server-user", "Optimistic row duplicated or history reordered.");
    Assert(reducer.Items[0].Text == "exact\n" && reducer.Items[1].Raw.GetProperty("future").GetProperty("x").GetInt32() == 1, "Bytes or unknown fields were lost.");
    Assert(reducer.RemovedItemIds.Contains("client1"), "Replaced local row was not marked for durable removal.");
    return Task.CompletedTask;
});
await Check("stale history response cannot overwrite newer lifecycle", () =>
{
    var reducer = new TimelineReducer(); reducer.Begin("t1");
    var version = reducer.StateVersion; reducer.End("t1");
    reducer.Reconcile([], true, "t1", version);
    Assert(!reducer.IsRunning, "Old resume response reactivated a completed turn.");
    return Task.CompletedTask;
});
await Check("timeline is safe under concurrent snapshots and reduction", async () =>
{
    var reducer = new TimelineReducer(); reducer.Begin("t");
    await Task.WhenAll(Task.Run(() => { for (var i = 0; i < 1000; i++) reducer.Upsert(JsonSerializer.SerializeToElement(new { id = $"a{i}", type = "agentMessage", text = i.ToString() }), "t"); }),
        Task.Run(() => { for (var i = 0; i < 1000; i++) _ = reducer.Items.Count; }));
    Assert(reducer.Items.Count == 1000, "Concurrent reads lost items.");
});

var self = Path.Combine(AppContext.BaseDirectory, "Veo.Core.Tests" + (OperatingSystem.IsWindows() ? ".exe" : ""));
var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Veo-Core-Tests", Guid.NewGuid().ToString("N")));
Directory.CreateDirectory(root);
CodexRuntimeService Fake(string scenario, string trace) => new(new CodexRuntimeOptions { ExecutablePath = self, AdditionalArguments = ["--core-fake-server", "--scenario=" + scenario, "--trace=" + trace] });
ComposerSnapshot Payload(string id, string text = "hello", string[]? attachments = null) => new(id, text, "fixture-model", "medium", null, "Workspace", "Agentic", attachments ?? []);
try
{
    foreach (var (name, test) in ConversationPresentationChecks.All(Path.Combine(root, "conversation")))
        await Check(name, test);
    await Check("workspace real-pipe completion race, durable identity and all-project catalog", async () =>
    {
        var data = Path.Combine(root, "workspace"); var trace = Path.Combine(root, "workspace.log");
        await using var workspace = new WorkspaceCoordinator(data, _ => Fake("immediate", trace));
        await workspace.InitializeAsync();
        var first = await workspace.CreateAsync(); var second = await workspace.CreateAsync();
        await workspace.SaveDraftAsync(first, "hello");
        await workspace.SubmitAsync(first, Payload("client-workspace"));
        await Until(() => !first.Timeline.IsRunning && first.Timeline.Items.Any(x => x.Id == "a1"));
        Assert(first.Timeline.Items.Count(x => x.Kind == "userMessage") == 1, "Live user row duplicated.");
        var saved = await workspace.Threads.ReadItemsAsync(first.Record.VeoId);
        Assert(saved.Count(x => x.Type == "userMessage") == 1 && saved.All(x => x.ItemId != "client-workspace"), "Database retained optimistic duplicate.");
        Assert((await workspace.CatalogAsync()).Count == 2 && first.Record.Cwd != second.Record.Cwd, "Cross-project catalog or scratch isolation failed.");
    });
    await Check("queue snapshots and empty drafts survive repeated loads and relaunch", async () =>
    {
        var data = Path.Combine(root, "queue"); var trace = Path.Combine(root, "queue.log"); string id;
        await using (var workspace = new WorkspaceCoordinator(data, _ => Fake("immediate", trace)))
        {
            await workspace.InitializeAsync(); var thread = await workspace.CreateAsync(); id = thread.Record.VeoId;
            thread.Timeline.Begin("test-active");
            var attachments = new[] { "original.png" };
            await workspace.SubmitAsync(thread, Payload("queued1", attachments: attachments)); attachments[0] = "mutated.png";
            Assert(thread.Queue.Single().Attachments[0] == "original.png", "Queued payload retained mutable attachment array.");
        }
        await using (var workspace = new WorkspaceCoordinator(data, _ => Fake("immediate", trace)))
        {
            await workspace.InitializeAsync(); var record = (await workspace.CatalogAsync()).Single(x => x.VeoId == id);
            var thread = await workspace.LoadAsync(record); var same = await workspace.LoadAsync(record);
            Assert(ReferenceEquals(thread, same) && thread.Queue.Count == 1 && thread.Queue[0].Attachments[0] == "original.png" && thread.Draft.Text == "", "Empty-draft reload lost or duplicated queue snapshot.");
        }
    });
    await Check("ambiguous dispatch remains durable and is never automatically replayed", async () =>
    {
        var data = Path.Combine(root, "uncertain"); var trace = Path.Combine(root, "uncertain.log"); string id;
        await using (var workspace = new WorkspaceCoordinator(data, _ => Fake("uncertain", trace)))
        {
            await workspace.InitializeAsync(); var thread = await workspace.CreateAsync(); id = thread.Record.VeoId;
            await workspace.SaveDraftAsync(thread, "keep draft");
            await ThrowsAsync<IOException>(() => workspace.SubmitAsync(thread, Payload("uncertain1", "keep draft")));
            Assert(thread.DispatchWarning is not null && thread.Draft.Text == "keep draft", "Uncertain send lost draft/warning.");
        }
        await using (var workspace = new WorkspaceCoordinator(data, _ => Fake("immediate", trace)))
        {
            await workspace.InitializeAsync(); var thread = await workspace.LoadAsync((await workspace.CatalogAsync()).Single(x => x.VeoId == id));
            Assert(thread.DispatchWarning is not null, "Relaunch forgot unresolved send.");
            await ThrowsAsync<InvalidOperationException>(() => workspace.SubmitAsync(thread, Payload("must-not-send")));
        }
        Assert(File.ReadAllLines(trace).Count(line => line == "turn/start") == 1, "Uncertain send was replayed.");
    });
    await Check("preferences default, snapshots and unknown values survive saved readback", async () =>
    {
        var data = Path.Combine(root, "preferences"); var store = new PreferencesStore(data);
        Assert(!(await store.LoadAsync()).RestoreBrowserTabs, "Browser restore default differs from source.");
        var value = new VeoPreferences { Appearance = "Light", Extra = new() { ["future"] = Json("{\"value\":7}") } };
        var saving = store.SaveAsync(value); value.Appearance = "Dark"; await saving;
        var restored = await store.LoadAsync();
        Assert(restored.Appearance == "Light" && restored.Extra!["future"].GetProperty("value").GetInt32() == 7, "Settings snapshot or unknown field was lost.");
        var path = Path.Combine(data, "Settings", "settings.json"); await File.WriteAllTextAsync(path, "invalid");
        await ThrowsAsync<InvalidDataException>(async () => _ = await store.LoadAsync());
        Assert(await File.ReadAllTextAsync(path) == "invalid", "Invalid settings were overwritten.");
    });
    await Check("browser query encoding and ChatGPT search contract", () =>
    {
        var url = BrowserSearch.Resolve("a & b/🙂", "ChatGPT").AbsoluteUri;
        Assert(url.Contains("temporary-chat=true") && url.Contains("hints=search") && url.Contains("a%20%26%20b%2F"), "Search parameters changed.");
        Assert(BrowserSearch.Resolve("example.com", "Google").Host == "example.com", "Domain was searched instead of navigated.");
        return Task.CompletedTask;
    });
}
finally
{
    // Delete only this generated disposable test directory after every database/process has been disposed.
    var parent = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Veo-Core-Tests"));
    if (Path.GetDirectoryName(root) == parent && Directory.Exists(root)) Directory.Delete(root, true);
}
await Check("dynamic tools isolate originating threads, namespaces and arguments", async () =>
{
    var bridge = new DynamicToolBridge(id => id == "owned" ? new("C:\\workspace", "Workspace", id) : null,
        (id, _) => Task.FromResult(JsonSerializer.SerializeToElement(new[] { new { processId = "123", cwd = "C:\\workspace" } })));
    var valid = JsonSerializer.SerializeToElement(new { threadId = "owned", tool = "veo_workspace_context", arguments = new { } });
    var result = await bridge.InvokeAsync(valid);
    if (!result.success || !result.contentItems[0].text.Contains("readOnly")) throw new Exception("Missing read-only workspace context.");
    foreach (var rejected in new object[] {
        new { threadId = "other", tool = "veo_workspace_context", arguments = new { } },
        new { threadId = "owned", tool = "veo_workspace_context", arguments = new { path = "outside" } },
        new { threadId = "owned", tool = "unknown", arguments = new { } },
        new { threadId = "owned", tool = "veo_workspace_context", @namespace = "other", arguments = new { } } })
        if ((await bridge.InvokeAsync(JsonSerializer.SerializeToElement(rejected))).success) throw new Exception("An unsupported tool call was accepted.");
    var background = await bridge.InvokeAsync(JsonSerializer.SerializeToElement(new { threadId = "owned", tool = "veo_background_terminals", arguments = new { } }));
    if (!background.success || !background.contentItems[0].text.Contains("123")) throw new Exception("Background inventory missing.");
});
Console.WriteLine($"PASS: {passed} Core checks.");
async Task Check(string name, Func<Task> test) { await test().WaitAsync(TimeSpan.FromSeconds(30)); passed++; Console.WriteLine("PASS " + name); }
static void Assert(bool condition, string error) { if (!condition) throw new InvalidOperationException(error); }
static async Task Until(Func<bool> condition) { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)); while (!condition()) await Task.Delay(20, timeout.Token); }
static async Task ThrowsAsync<T>(Func<Task> action) where T : Exception { try { await action(); } catch (T) { return; } throw new InvalidOperationException($"Expected {typeof(T).Name}."); }

static async Task FakeServer(string[] arguments)
{
    var scenario = arguments.Single(x => x.StartsWith("--scenario="))[11..];
    var trace = arguments.Single(x => x.StartsWith("--trace="))[8..];
    while (await Console.In.ReadLineAsync() is { } line)
    {
        using var document = JsonDocument.Parse(line); var request = document.RootElement;
        if (!request.TryGetProperty("id", out var requestId)) continue;
        var id = requestId.GetInt64(); var method = request.Str("method");
        await File.AppendAllTextAsync(trace, method + "\n");
        switch (method)
        {
            case "initialize": await Write(new { id, result = new { userAgent = "core-fixture 0.169.0" } }); break;
            case "model/list": await Write(new { id, result = new { data = new[] { new { id = "fixture-model", model = "fixture-model", displayName = "Fixture", defaultReasoningEffort = "medium" } } } }); break;
            case "account/read": await Write(new { id, result = new { account = (object?)null, requiresOpenaiAuth = false } }); break;
            case "thread/start": await Write(new { id, result = new { thread = new { id = "runtime-thread" } } }); break;
            case "thread/resume": await Write(new { id, result = new { thread = new { id = "runtime-thread", status = new { type = "idle" }, turns = Array.Empty<object>() } } }); break;
            case "turn/start":
                if (scenario == "uncertain") { Environment.Exit(42); return; }
                var clientId = request.GetProperty("params").Str("clientUserMessageId");
                var user = new { id = "server-user", clientId, type = "userMessage", content = new[] { new { type = "text", text = "hello" } } };
                await Write(new { method = "turn/started", @params = new { threadId = "runtime-thread", turn = new { status = "inProgress" } } });
                await Write(new { method = "item/completed", @params = new { threadId = "runtime-thread", turnId = "turn1", item = user } });
                await Write(new { method = "turn/completed", @params = new { threadId = "runtime-thread", turn = new { id = "turn1", status = "completed", items = new object[] { user, new { id = "a1", type = "agentMessage", text = "answer" } } } } });
                // Ensure the completion enters the reducer before the request task is acknowledged.
                await Task.Delay(100);
                await Write(new { id, result = new { turn = new { id = "turn1", status = "completed" } } }); break;
            default: await Write(new { id, result = new { } }); break;
        }
    }
    static async Task Write(object value) { await Console.Out.WriteLineAsync(JsonSerializer.Serialize(value)); await Console.Out.FlushAsync(); }
}
