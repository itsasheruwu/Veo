using System.Text.Json;
using Veo.Core;
using Veo.Infrastructure.Storage;
using Veo.Protocol;

var passed = 0;
void Check(bool value, string name) { if (!value) throw new Exception("FAILED " + name); passed++; Console.WriteLine("PASS " + name); }
async Task Refuses(Func<Task> action, string name)
{ try { await action(); } catch (Exception error) when (error is ArgumentException or InvalidOperationException or InvalidDataException or IOException or NotSupportedException or CodexRpcException) { Check(true, name); return; } throw new Exception("FAILED accepted " + name); }
static JsonElement J(string value) => JsonDocument.Parse(value).RootElement.Clone();
static JsonElement E(object value) => JsonSerializer.SerializeToElement(value);
static ComposerSnapshot Payload(string id, string text = "original") => new(id, text, "fixture-model", "high", "priority", "Read only", "Plan", ["C:\\fixture image.png"], ContextTokens: 128000);
static PersistedItem Stored(string id, string? turn, string kind, string text, long order = 0) => new(id, turn, kind, null, "completed", JsonSerializer.Serialize(new { id, type = kind, text, future = new { preserved = true } }), order, DateTimeOffset.UtcNow);

await using (var f = await Fixture.Create())
{
    await f.Workspace.Threads.SaveTimelineAsync(f.Record.VeoId, [], [Stored("m1", "t1", "userMessage", "before 😀 needle after", 0), Stored("m2", "t1", "agentMessage", "NEEDLE second", 1), Stored("reason", "t1", "reasoning", "needle hidden", 2)]);
    var one = await f.Workspace.Threads.SearchMessagesAsync("needle", limit: 1);
    var two = await f.Workspace.Threads.SearchMessagesAsync("needle", limit: 1, cursor: one.NextCursor);
    Check(one.Data.Single().ItemId == "m1" && two.Data.Single().ItemId == "m2" && two.NextCursor is null, "local message keyset search pages without duplicate/reasoning rows");
    Check(one.Data[0].Snippet.Substring(one.Data[0].MatchStart, one.Data[0].MatchLength) == "needle" && one.Data[0].MatchStart == 10, "message match ranges use UTF16 positions including surrogate pair");
    await Refuses(() => f.Workspace.Threads.SearchMessagesAsync("other", cursor: one.NextCursor), "search cursor cannot cross queries");
    await f.Workspace.Threads.SaveItemAsync(f.Record.VeoId, Stored("answer-kept", "t1", "veoUserInputAnswer", "answer"));
    await f.Workspace.Threads.SaveItemAsync(f.Record.VeoId, Stored("answer-pruned", "t2", "veoUserInputAnswer", "later"));
    await f.Workspace.Threads.SaveItemAsync(f.Record.VeoId, Stored("plan-kept", "t1", "veoPlanArtifact", "plan"));
    await f.Workspace.Threads.SaveItemAsync(f.Record.VeoId, Stored("orphan", null, "veoPlanArtifact", "orphan"));
    await f.Workspace.Threads.SavePlanAsync(new(f.Record.VeoId, "p1", "t1", "kept", null));
    await f.Workspace.Threads.SavePlanAsync(new(f.Record.VeoId, "p2", "t2", "pruned", null));
    await f.Workspace.Threads.ReplaceHistoryAsync(f.Record.VeoId, [new("t1", "completed", null, null, 0)], [Stored("m1", "t1", "userMessage", "retained")]);
    var rows = await f.Workspace.Threads.ReadItemsAsync(f.Record.VeoId);
    Check(rows.Select(x => x.ItemId).ToHashSet().SetEquals(["m1", "answer-kept", "plan-kept"]), "authoritative history prunes removed turns and preserves only retained-turn local artifacts");
    Check((await f.Workspace.Threads.ReadPlansAsync(f.Record.VeoId)).Select(x => x.ItemId).SequenceEqual(["p1"]), "authoritative history prunes independent plans outside retained turns");
    Check(J(rows.Single(x => x.ItemId == "m1").RawJson).GetProperty("future").GetProperty("preserved").GetBoolean(), "unknown raw fields survive authoritative replacement");
}

await using (var f = await Fixture.Create())
{
    var rpc = new FakeRpc(); var catalog = new ThreadCatalogCoordinator(f.Workspace, rpc); await catalog.InitializeAsync();
    Check(!(await catalog.LoadAsync()).Codex.Any() && rpc.Calls.Count == 0 && !f.Workspace.Preferences.ShowCodexHistory, "optional Codex catalog is off by default and performs no RPC");
    rpc.Handler = (method, p) => E(new { data = p.Str("cursor") is null ? new[] { new { id = "runtime", cwd = f.Record.Cwd, name = "owned", updatedAt = 1 }, new { id = "ext1", cwd = "C:\\other", name = "external", updatedAt = 3 } } : new[] { new { id = "ext1", cwd = "C:\\other", name = "external", updatedAt = 3 }, new { id = "ext2", cwd = "C:\\third", name = "external two", updatedAt = 2 } }, nextCursor = p.Str("cursor") is null ? "catalog-next" : null });
    await catalog.SetCodexHistoryAsync(true); await catalog.LoadAsync(); var next = await catalog.LoadAsync(true);
    Check(next.Veo.Count == 1 && next.Codex.Count == 2 && next.NextCodexCursor is null, "optional catalog paginates and deduplicates owned runtime identities across projects");
    Check(rpc.Calls.All(x => x.Parameters.TryGetProperty("cwd", out _) == false), "catalog never applies selected repository filter");
    await catalog.SaveOptionsAsync(new(CatalogSort.Manual, ["a", "hidden", "b"], new() { [f.Record.Cwd] = "Project label" }, [f.Record.Cwd]));
    await catalog.ReorderVisibleAsync(["b", "a"], ["a", "hidden", "b"]);
    Check(catalog.Options.ManualOrder!.SequenceEqual(["b", "hidden", "a"]), "manual visible reorder preserves hidden rows in master positions");
    var reopened = new ThreadCatalogCoordinator(f.Workspace, rpc); await reopened.InitializeAsync();
    Check(reopened.Options.ManualOrder!.SequenceEqual(catalog.Options.ManualOrder!) && reopened.Group(next.Veo).Single().Label == "Project label", "sort/manual/project labels/collapse persist in SQLite");
    CatalogEntry Projectless(string id, string kind, CatalogOrigin origin, string cwd) =>
        new(id, origin, f.Record with { VeoId = id, Cwd = cwd, WorkspaceKind = kind });
    var scratchDirectory = Path.Combine(f.Record.Cwd, "scratch");
    var scratch = Projectless("scratch", "scratch", CatalogOrigin.Veo, scratchDirectory);
    var temporary = Projectless("temporary", "temporary", CatalogOrigin.Veo, Path.Combine(f.Record.Cwd, "temporary"));
    var cli = Projectless("cli-scratch", "scratch", CatalogOrigin.Codex, scratchDirectory);
    var project = Projectless("alongside", "project", CatalogOrigin.Veo, scratchDirectory);
    var grouped = reopened.Group([scratch, temporary, cli, project]);
    var groupedVeo = grouped.Single(group => group.IsProjectless && group.Entries.All(entry => entry.Origin == CatalogOrigin.Veo));
    var groupedCli = grouped.Single(group => group.IsProjectless && group.Entries.All(entry => entry.Origin == CatalogOrigin.Codex));
    Check(groupedVeo.Label == "Projectless Chats" && groupedVeo.Entries.Select(entry => entry.Key).ToHashSet().SetEquals([scratch.Key, temporary.Key]), "scratch and temporary chats share one projectless heading across working directories");
    Check(groupedCli.CollapseKey != groupedVeo.CollapseKey && grouped.Single(group => !group.IsProjectless).Entries.Single() == project, "CLI projectless chats and real projects keep their own sections");
    await reopened.SaveOptionsAsync(reopened.Options with { CollapsedProjects = [.. reopened.Options.CollapsedProjects!, groupedVeo.CollapseKey] });
    await reopened.InitializeAsync();
    var regrouped = reopened.Group([temporary, cli, project]);
    Check(regrouped.Single(group => group.CollapseKey == groupedVeo.CollapseKey).IsCollapsed
        && !regrouped.Single(group => group.CollapseKey == groupedCli.CollapseKey).IsCollapsed,
        "projectless collapse survives membership changes and SQLite reload without collapsing the CLI section");
    rpc.Calls.Clear(); await catalog.RenameAsync(next.Veo.Single(), "local renamed");
    Check(rpc.Calls.Count == 0 && (await f.Workspace.Threads.ListThreadsAsync()).Single().Title == "local renamed", "Veo-owned rename changes only its local catalog");
    await catalog.ArchiveAsync(next.Veo.Single() with { Thread = f.Session.Record }, true);
    Check(rpc.Calls.Count == 0 && (await f.Workspace.Threads.ListThreadsAsync(true)).Single().IsArchived, "Veo-owned archive remains local and retains private runtime");
    rpc.Handler = (_, _) => J("{}"); await catalog.RenameAsync(next.Codex.First(), "external renamed");
    Check(rpc.Calls.Last().Method == "thread/name/set" && rpc.Calls.Last().Parameters.Str("name") == "external renamed", "Codex-origin rename uses exact protocol name method");
    await f.Workspace.Threads.UpsertThreadAsync(new("child", "child-runtime", f.Record.Cwd, "fork child", ParentThreadId: f.Record.VeoId));
    await f.Workspace.Threads.SaveStateAsync(f.Record.VeoId, "questions", "{}"); await f.Workspace.Threads.SaveStateAsync("catalog", "preserve", "{}");
    rpc.Calls.Clear(); await catalog.DeleteAsync(next.Veo.Single());
    Check((await f.Workspace.Threads.ListThreadsAsync()).Count == 0 && (await f.Workspace.Threads.ListThreadsAsync(true)).Count == 0 && rpc.Calls.Count == 0, "local chat deletion removes fork family without deleting runtime or project files");
    Check(await f.Workspace.Threads.ReadStateAsync(f.Record.VeoId, "questions") is null && await f.Workspace.Threads.ReadStateAsync("catalog", "preserve") is not null, "local deletion clears only exact chat durable-state scope");
}

await using (var f = await Fixture.Create())
{
    var rpc = new FakeRpc { Handler = (method, p) => method == "thread/fork" ? E(new { thread = new { id = "new-runtime" } }) : J("{}") };
    var catalog = new ThreadCatalogCoordinator(f.Workspace, rpc); var fork = await catalog.ForkAsync(f.Session, beforeTurnId: "t2");
    Check(fork.Record.CodexThreadId == "new-runtime" && fork.Record.ParentThreadId == f.Record.VeoId && fork.Record.VeoId != f.Record.VeoId && rpc.Calls.Single().Parameters.Str("beforeTurnId") == "t2", "fork preserves exclusive turn boundary and creates independent identities");
    await Refuses(() => catalog.ForkAsync(f.Session, "t1", "t2"), "fork rejects simultaneous inclusive and exclusive boundary");
}

await using (var f = await Fixture.Create())
{
    var rpc = new FakeRpc { Handler = (method, p) => method switch
    {
        "thread/timeline/list" => throw new CodexRpcException(-32601, "fixture absent"),
        "thread/items/list" when p.Str("cursor") is null => J("""{"data":[{"turnId":"t2","item":{"id":"b","type":"agentMessage","text":"newer"}}],"nextCursor":"items-next"}"""),
        "thread/items/list" => J("""{"data":[{"turnId":"t1","item":{"id":"a","type":"userMessage","content":[{"type":"text","text":"older"}]}}]}"""),
        _ => throw new Exception(method)
    } };
    var history = new HistoryCoordinator(f.Workspace, rpc); var page = await history.LoadAsync(f.Session); await history.LoadAsync(f.Session, true);
    Check(page.Mode == HistoryMode.Items && f.Session.Timeline.Items.Select(x => x.Id).SequenceEqual(["a", "b"]), "first-page timeline absence falls back to item pages and chronological prepend");
    Check(rpc.Calls.Last().Parameters.Str("cursor") == "items-next" && rpc.Calls.Count(x => x.Method == "thread/timeline/list") == 1, "history fallback keeps cursor types bound to selected method");
}

await using (var f = await Fixture.Create())
{
    var rpc = new FakeRpc { Handler = (method, p) => p.Str("cursor") is null ? J("""{"data":[{"type":"turnStarted","turn_id":"t1","position":0},{"type":"item","turnId":"t1","position":1,"item":{"id":"reason","type":"reasoning","text":"real reasoning"}},{"type":"realtime","position":2,"item":{"id":"rt","type":"transcriptSegment","text":"voice","role":"user","realtimeSessionId":"r"}}],"nextCursor":"timeline-next"}""") : throw new CodexRpcException(-32601, "later missing") };
    var history = new HistoryCoordinator(f.Workspace, rpc); await history.LoadAsync(f.Session);
    Check(f.Session.Timeline.Items.Select(x => x.Id).SequenceEqual(["reason", "realtime-rt"]) && f.Session.Timeline.Items.Last().Kind == "userMessage", "timeline V3 preserves item identities and visible realtime transcript without fake boundary rows");
    await Refuses(() => history.LoadAsync(f.Session, true), "later timeline page failure refuses fallback cursor reuse");
    Check(rpc.Calls.All(x => x.Method == "thread/timeline/list") && f.Session.Timeline.Items.Count == 2, "failed later history page preserves loaded timeline");
}

await using (var f = await Fixture.Create())
{
    var reverted = false; var rpc = new FakeRpc { Handler = (method, p) => method switch
    {
        "thread/turns/list" => E(new { data = reverted ? new[] { Turn("t1", "a", "retained") } : new[] { Turn("t2", "b", "edit this"), Turn("t1", "a", "retained") } }),
        "thread/revert" => Revert(), _ => throw new Exception(method)
    } };
    JsonElement Revert() { reverted = true; return J("{}"); }
    var history = new HistoryCoordinator(f.Workspace, rpc); await history.LoadAsync(f.Session, preferred: HistoryMode.Turns);
    f.Session.Timeline.AddLocal("local-answer", "veoUserInputAnswer", "saved answer", "t1"); f.Session.Timeline.AddLocal("late-answer", "veoUserInputAnswer", "late answer", "t2");
    var result = await history.RevertAsync(f.Session, "t2", true);
    Check(result.RuntimeReverted && !result.FilesRestored && f.Session.Timeline.Items.Select(x => x.Id).ToHashSet().SetEquals(["a", "local-answer"]), "revert authoritatively prunes later items and retains local answer for retained turn");
    Check(f.Session.Draft.Text == "edit this" && (await f.Workspace.Threads.ReadItemsAsync(f.Record.VeoId)).All(x => x.TurnId != "t2"), "edit-from-here restores input draft after durable authoritative history replacement");
    Check(rpc.Calls.Single(x => x.Method == "thread/revert").Parameters.Str("beforeTurnId") == "t2", "revert uses exclusive beforeTurnId contract");
}

await using (var f = await Fixture.Create())
{
    var rpc = new FakeRpc { Handler = (method, p) => method == "thread/revert" ? throw new IOException("lost response") : E(new { data = new[] { Turn("t1", "a", "message") } }) };
    var history = new HistoryCoordinator(f.Workspace, rpc); await Refuses(() => history.RevertAsync(f.Session, "t1"), "lost revert response reports uncertain outcome");
    await Refuses(() => history.RevertAsync(f.Session, "t1"), "uncertain history mutation is not blindly replayed");
    Check(rpc.Calls.Count(x => x.Method == "thread/revert") == 1 && f.Session.DispatchWarning is not null, "uncertain revert remains durable and blocks further send");
}

await using (var f = await Fixture.Create([Payload("q1"), Payload("q2", "second")]))
{
    var server = new List<JsonElement>(); var rpc = new FakeRpc(); rpc.Handler = (method, p) => method switch
    {
        "thread/queue/list" => E(new { data = server }), "thread/read" => J("{\"thread\":{\"turns\":[],\"historyMode\":\"legacy\"}}"),
        "thread/queue/add" => Add(p), "thread/queue/delete" => Delete(p), "thread/queue/reorder" => Reorder(p), _ => throw new Exception(method)
    };
    JsonElement Add(JsonElement p) { var row = E(new { id = "server-" + p.Str("clientUserMessageId"), clientUserMessageId = p.Str("clientUserMessageId"), input = p.GetProperty("input") }); server.Add(row); return E(new { queuedSubmission = row }); }
    JsonElement Delete(JsonElement p) { server.RemoveAll(x => x.Str("id") == p.Str("queuedSubmissionId")); return J("{}"); }
    JsonElement Reorder(JsonElement p) { var order = p.GetProperty("queuedSubmissionIds").EnumerateArray().Select(x => x.GetString()).ToArray(); server = order.Select(id => server.Single(x => x.Str("id") == id)).ToList(); return J("{}"); }
    using var queue = new QueueCoordinator(f.Workspace, rpc); foreach (var payload in f.Session.Queue) await queue.AddedUnderDispatchGateAsync(f.Session, payload);
    var view = await queue.LoadAsync(f.Session); Check(view.Bindings.All(x => x.State == "mirrored") && view.Local.Count == 2, "server queue mirrors stable client identities to runtime queue IDs");
    await queue.ReorderAsync(f.Session, ["q2", "q1"]);
    Check(rpc.Calls.Last(x => x.Method == "thread/queue/reorder").Parameters.GetProperty("queuedSubmissionIds").EnumerateArray().Select(x => x.GetString()).SequenceEqual(["server-q2", "server-q1"]), "queue reorder sends complete server IDs in frozen local order");
    await queue.EditAsync(f.Session, "q1", "edited", ["C:\\changed.png"]); var edited = f.Session.Queue.Single(x => x.ClientId == "q1");
    Check(edited.Text == "edited" && edited.Model == "fixture-model" && edited.ContextTokens == 128000 && edited.Access == "Read only" && edited.Mode == "Plan", "queue edit changes input while retaining captured model/context/access/mode");
    var frozen = f.Session.Queue.Single(x => x.ClientId == "q1"); frozen.Attachments[0] = "mutated";
    Check(f.Session.Queue.Single(x => x.ClientId == "q1").Attachments.Single() == "C:\\changed.png", "queue getter isolates mutable attachments from captured payload");
    Check(!await queue.PrepareDispatchUnderGateAsync(f.Session, edited) && server.All(x => x.Str("clientUserMessageId") != "q1"), "queue dispatch confirms server removal then uses full local frozen-settings pipeline");
    Check(rpc.Calls.Any(x => x.Method == "thread/read") && rpc.Calls.All(x => x.Method != "thread/queue/start"), "queue dispatch proves input unconsumed and never starts with guessed server settings");
    await queue.RemoveAsync(f.Session, "q2"); Check(f.Session.Queue.Count == 1 && server.Count == 0, "queue removal confirms server deletion before durable local removal");
}

await using (var f = await Fixture.Create([Payload("lost")]))
{
    var server = new List<JsonElement>(); var rpc = new FakeRpc { Handler = (method, p) => method switch
    {
        "thread/queue/add" => LostAdd(p), "thread/queue/list" => E(new { data = server }), _ => throw new Exception(method)
    } };
    JsonElement LostAdd(JsonElement p) { server.Add(E(new { id = "accepted-id", clientUserMessageId = "lost", input = p.GetProperty("input") })); throw new IOException("lost response"); }
    using var queue = new QueueCoordinator(f.Workspace, rpc); await queue.AddedUnderDispatchGateAsync(f.Session, f.Session.Queue.Single()); await queue.AddedUnderDispatchGateAsync(f.Session, f.Session.Queue.Single());
    Check(rpc.Calls.Count(x => x.Method == "thread/queue/add") == 1 && (await queue.LoadAsync(f.Session)).Bindings.Single().ServerId == "accepted-id", "lost enqueue response reconciles stable identity without duplicate add");
}

await using (var f = await Fixture.Create([Payload("consumed")]))
{
    await f.Workspace.Threads.SaveStateAsync(f.Record.VeoId, "queue-mirror", JsonSerializer.Serialize(new QueueMirrorState([new("consumed", "old-id", "mirrored", 1)])));
    var rpc = new FakeRpc { Handler = (method, p) => method == "thread/queue/list" ? J("{\"data\":[]}") : J("""{"thread":{"historyMode":"legacy","turns":[{"id":"t1","items":[{"id":"runtime-user","type":"userMessage","clientId":"consumed"}]}]}}""") };
    using var queue = new QueueCoordinator(f.Workspace, rpc);
    Check(await queue.PrepareDispatchUnderGateAsync(f.Session, f.Session.Queue.Single()) && f.Session.Queue.Count == 0, "already consumed queue identity returns handled and prevents duplicate local dispatch");
}

await using (var f = await Fixture.Create([Payload("uncertain")]))
{
    var rpc = new FakeRpc { Handler = (method, p) => method switch { "thread/queue/add" => throw new IOException("lost"), "thread/queue/list" => J("{\"data\":[]}"), _ => J("{\"thread\":{\"turns\":[],\"historyMode\":\"legacy\"}}") } };
    using var queue = new QueueCoordinator(f.Workspace, rpc); await Refuses(() => queue.AddedUnderDispatchGateAsync(f.Session, f.Session.Queue.Single()), "ambiguous unconfirmed enqueue preserves draft and exposes uncertainty");
    await Refuses(() => queue.PrepareDispatchUnderGateAsync(f.Session, f.Session.Queue.Single()), "missing enqueue outcome blocks automatic replay");
    Check((await queue.LoadAsync(f.Session)).Warning is not null && f.Session.Queue.Count == 1, "uncertain queue state keeps durable frozen input for review");
}

await using (var f = await Fixture.Create([Payload("steer")]))
{
    f.Session.Timeline.Begin(null); var rpc = new FakeRpc { Handler = (method, p) => method == "thread/read" ? J("{\"thread\":{\"turns\":[{\"id\":\"active-id\",\"status\":\"inProgress\",\"items\":[]}]}}") : method == "thread/queue/list" ? J("{\"data\":[]}") : J("{}") };
    using var queue = new QueueCoordinator(f.Workspace, rpc); await queue.SteerAsync(f.Session, f.Session.Queue.Single()); var steer = rpc.Calls.Single(x => x.Method == "turn/steer");
    Check(steer.Parameters.Str("expectedTurnId") == "active-id" && steer.Parameters.GetProperty("input").EnumerateArray().Any(x => x.Str("type") == "localImage"), "steer resolves missing active-turn ID and sends complete captured attachments");
    Check(f.Session.Queue.Count == 0, "confirmed steer removes its original queued identity");
}

{
    var reducer = new TimelineReducer(); reducer.AddLocal("kept", "veoUserInputAnswer", "retained empty turn answer", "empty"); reducer.AddLocal("pending-plan", "veoPlanArtifact", "pending artifact", "empty", "pending"); reducer.AddLocal("removed", "veoUserInputAnswer", "late answer", "removed");
    reducer.ReplaceHistory([], false, null, ["empty"]);
    Check(reducer.Items.Select(x => x.Id).ToHashSet().SetEquals(["kept", "pending-plan"]) && reducer.Items.Single(x => x.Id == "pending-plan").Status == "pending", "authoritative empty retained turn preserves answer and pending local plan");
    Check(reducer.RemovedItemIds.Contains("removed") && !reducer.RemovedItemIds.Contains("kept"), "history removal tracks only pruned artifact identities for durable deletion");
}

await using (var f = await Fixture.Create())
{
    var removed = false; var rpc = new FakeRpc { Handler = (method, p) => method == "thread/revert" ? Lose() : E(new { data = removed ? Array.Empty<object>() : new[] { Turn("t1", "a", "original") } }) };
    JsonElement Lose() { removed = true; throw new IOException("accepted then response lost"); }
    var history = new HistoryCoordinator(f.Workspace, rpc); await Refuses(() => history.RevertAsync(f.Session, "t1"), "accepted revert with lost response remains blocked until explicit reconciliation");
    await history.ReconcilePendingRevertAsync(f.Session);
    Check(f.Session.DispatchWarning is null && rpc.Calls.Count(x => x.Method == "thread/revert") == 1 && J((await f.Workspace.Threads.ReadStateAsync(f.Record.VeoId, "history-revert"))!).Str("state") == "reconciled", "authoritative refresh clears confirmed history uncertainty without replaying mutation");
}

await using (var f = await Fixture.Create([Payload("q")]))
{
    var rpc = new FakeRpc { Methods = [], Handler = (_, _) => throw new Exception("No network expected") }; using var queue = new QueueCoordinator(f.Workspace, rpc);
    await queue.AddedUnderDispatchGateAsync(f.Session, f.Session.Queue.Single());
    Check(!await queue.PrepareDispatchUnderGateAsync(f.Session, f.Session.Queue.Single()) && rpc.Calls.Count == 0 && f.Session.Queue.Count == 1, "unsupported queue capabilities retain exact local frozen dispatch fallback");
}

await using (var f = await Fixture.Create([Payload("q")]))
{
    var rpc = new FakeRpc { Handler = (_, _) => J("""{"data":[{"id":"unknown","clientUserMessageId":"other-client","input":[{"type":"text","text":"other client"}]}]}""") }; using var queue = new QueueCoordinator(f.Workspace, rpc);
    await Refuses(() => queue.PrepareDispatchUnderGateAsync(f.Session, f.Session.Queue.Single()), "server-only queued input blocks guessed settings and duplicate ordering");
    Check((await queue.LoadAsync(f.Session)).ServerOnly.Single().Str("id") == "unknown", "unknown server input remains inspectable without inventing local settings");
}

await using (var f = await Fixture.Create([Payload("q")]))
{
    var rpc = new FakeRpc { Handler = (_, _) => J("""{"data":[{"id":"one","clientUserMessageId":"q"},{"id":"two","clientUserMessageId":"q"}]}""") }; using var queue = new QueueCoordinator(f.Workspace, rpc);
    await Refuses(() => queue.LoadAsync(f.Session), "duplicate server client identities are rejected rather than collapsed");
}

await using (var f = await Fixture.Create([Payload("steer-lost")]))
{
    f.Session.Timeline.Begin("active"); var rpc = new FakeRpc { Handler = (method, _) => method switch { "turn/steer" => throw new IOException("lost"), "thread/queue/list" => J("{\"data\":[]}"), _ => J("{\"thread\":{\"turns\":[],\"historyMode\":\"legacy\"}}") } }; using var queue = new QueueCoordinator(f.Workspace, rpc);
    await Refuses(() => queue.SteerAsync(f.Session, f.Session.Queue.Single()), "ambiguous steer retains original frozen input");
    await Refuses(() => queue.PrepareDispatchUnderGateAsync(f.Session, f.Session.Queue.Single()), "ambiguous steer cannot later dispatch same input as new turn");
    Check(rpc.Calls.Count(x => x.Method == "turn/steer") == 1 && (await queue.LoadAsync(f.Session)).Bindings.Single().State == "uncertain-steer", "pending steer outcome survives durable reconciliation without automatic replay");
}

Console.WriteLine($"{passed} catalog/history/queue checks passed. All protocol operations used deterministic fixtures; no live chats or repositories mutated.");

static object Turn(string id, string item, string text) => new { id, status = "completed", items = new[] { new { id = item, type = "userMessage", content = new[] { new { type = "text", text } } } } };
sealed class FakeRpc : ICoordinatorRpc
{
    public long Generation { get; set; } = 1;
    public HashSet<string>? Methods { get; set; }
    public Func<string, JsonElement, JsonElement> Handler { get; set; } = (_, _) => JsonSerializer.SerializeToElement(new { data = Array.Empty<object>() });
    public List<(string Method, JsonElement Parameters)> Calls { get; } = [];
    public bool Supports(string method) => Methods is null || Methods.Contains(method);
    public Task<JsonElement> RequestAsync(string method, object? parameters, CancellationToken token = default)
    { token.ThrowIfCancellationRequested(); var p = JsonSerializer.SerializeToElement(parameters); Calls.Add((method, p)); return Task.FromResult(Handler(method, p)); }
}
sealed class Fixture : IAsyncDisposable
{
    public WorkspaceCoordinator Workspace { get; }
    public PersistedThread Record { get; }
    public ThreadSession Session { get; private set; } = null!;
    Fixture(string root) { Workspace = new(root); Record = new("local", "runtime", root, "Fixture chat", UpdatedAt: DateTimeOffset.FromUnixTimeSeconds(100)); }
    public static async Task<Fixture> Create(ComposerSnapshot[]? queue = null)
    {
        var fixture = new Fixture(Path.Combine(Path.GetTempPath(), "Veo.CatalogHistory.Tests-" + Guid.NewGuid().ToString("N")));
        await fixture.Workspace.Threads.InitializeAsync(); await fixture.Workspace.Threads.UpsertThreadAsync(fixture.Record);
        if (queue is not null) await fixture.Workspace.Threads.SaveStateAsync(fixture.Record.VeoId, "queue", JsonSerializer.Serialize(queue));
        fixture.Session = await fixture.Workspace.LoadAsync(fixture.Record); return fixture;
    }
    public ValueTask DisposeAsync() => Workspace.DisposeAsync();
}
