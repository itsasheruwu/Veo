using System.Text.Json;
using Veo.Core;
using Veo.Infrastructure.Git;
using Veo.Protocol;

if (args.Contains("--workflow-server")) { await Server(args); return; }
var passed = 0;
var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Veo-Workflow-Tests", Guid.NewGuid().ToString("N")));
Directory.CreateDirectory(root);
var self = Path.Combine(AppContext.BaseDirectory, "Veo.Workflows.Tests" + (OperatingSystem.IsWindows() ? ".exe" : ""));
WorkspaceCoordinator Workspace(string name, string scenario = "complete") => new(Path.Combine(root, name), _ => new(new CodexRuntimeOptions { ExecutablePath = self, AdditionalArguments = ["--workflow-server", "--scenario=" + scenario, "--trace=" + Path.Combine(root, name + ".log")] }));
ComposerSnapshot Settings() => new(Guid.NewGuid().ToString("N"), "", "fixture", "high", "fast", "Workspace", "Plan", []);
try
{
    await Check("plan edit/cancel/save/revert/export and relaunch preserve exact Markdown", async () =>
    {
        string id;
        await using (var workspace = Workspace("plans"))
        await using (var plans = new PlanCoordinator(workspace))
        {
            await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); id = session.Record.VeoId;
            session.Timeline.AddLocal("plan1", "plan", "# Exact plan\n\n1. Keep CRLF files.\n"); await plans.ObserveAsync(session);
            var reference = new PlanReference(id, "plan1"); plans.BeginEditing(reference); plans.UpdateDraft(reference, "discard"); plans.CancelEditing(reference);
            Assert(plans.Markdown(reference).StartsWith("# Exact"), "Cancel saved the edit.");
            plans.BeginEditing(reference); plans.UpdateDraft(reference, "# Edited\n\n- exact bytes\n"); await plans.SaveEditingAsync(reference);
            var export = Path.Combine(root, "plan.md"); await plans.ExportAsync(reference, export);
            Assert(await File.ReadAllTextAsync(export) == "# Edited\n\n- exact bytes\n", "Export changed Markdown bytes.");
            await Throws<IOException>(() => plans.ExportAsync(reference, export));
        }
        await using (var workspace = Workspace("plans"))
        await using (var plans = new PlanCoordinator(workspace))
        {
            await workspace.InitializeAsync(); var session = await workspace.LoadAsync((await workspace.CatalogAsync()).Single(x => x.VeoId == id)); await plans.ObserveAsync(session);
            var reference = new PlanReference(id, "plan1"); Assert(plans.Markdown(reference) == "# Edited\n\n- exact bytes\n", "Relaunch lost edit.");
            await plans.RevertAsync(reference); Assert(plans.Markdown(reference) == "# Exact plan\n\n1. Keep CRLF files.\n", "Revert lost original.");
            session.Timeline.AddLocal("plan2", "plan", "# Newer"); await plans.ObserveAsync(session);
            Assert(plans.Get(reference)!.Lifecycle == "superseded", "Older ready plan was not superseded.");
        }
    });
    await Check("plan same/new-chat handoff retains settings and completed lifecycle", async () =>
    {
        await using var workspace = Workspace("implement"); await using var plans = new PlanCoordinator(workspace); await workspace.InitializeAsync();
        var session = await workspace.CreateAsync(); session.Timeline.AddLocal("plan1", "plan", "# Approved\n\nDo it exactly."); await plans.ObserveAsync(session);
        var first = new PlanReference(session.Record.VeoId, "plan1"); var target = await plans.ImplementAsync(first, session, Settings());
        await Until(() => plans.Get(first)?.Lifecycle == "implemented"); Assert(ReferenceEquals(target, session), "Same-task handoff changed thread.");
        session.Timeline.AddLocal("plan2", "plan", "# New task"); await plans.ObserveAsync(session);
        var second = new PlanReference(session.Record.VeoId, "plan2"); var next = await plans.ImplementAsync(second, session, Settings(), true);
        await Until(() => plans.Get(second)?.Lifecycle == "implemented");
        Assert(next.Record.VeoId != session.Record.VeoId && next.Record.Cwd == session.Record.Cwd && next.Record.CodexThreadId != session.Record.CodexThreadId, "New-task identity or cwd was wrong.");
        var requests = File.ReadAllLines(Path.Combine(root, "implement.log")).Select(Json).Where(x => x.Str("method") == "turn/start").ToArray();
        var p = requests[0].GetProperty("params");
        Assert(p.Str("model") == "fixture" && p.Str("effort") == "high" && p.Str("serviceTier") == "fast" && p.GetProperty("sandboxPolicy").Str("type") == "workspaceWrite", "Handoff changed access/model snapshot.");
        Assert(p.GetProperty("input")[0].Str("text")!.Contains("# Approved\n\nDo it exactly."), "Handoff omitted approved Markdown.");
    });
    await Check("failed and uncertain implementations cannot become fabricated successes", async () =>
    {
        await using (var workspace = Workspace("failed-plan", "failed"))
        await using (var plans = new PlanCoordinator(workspace))
        {
            await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); session.Timeline.AddLocal("p", "plan", "# Failure"); await plans.ObserveAsync(session);
            var reference = new PlanReference(session.Record.VeoId, "p"); await plans.ImplementAsync(reference, session, Settings());
            await Until(() => plans.Get(reference)?.Lifecycle == "ready"); Assert(plans.LastError is not null, "Failed implementation lacked error.");
        }
        await using (var workspace = Workspace("uncertain-plan", "uncertain"))
        await using (var plans = new PlanCoordinator(workspace))
        {
            await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); session.Timeline.AddLocal("p", "plan", "# Uncertain"); await plans.ObserveAsync(session);
            var reference = new PlanReference(session.Record.VeoId, "p"); await Throws<IOException>(() => plans.ImplementAsync(reference, session, Settings()));
            Assert(plans.Get(reference)?.Lifecycle == "implementing", "Uncertain outcome allowed unsafe replay.");
        }
    });
    await Check("async question answers persist; durable delivery preserves ordinary composer draft", async () =>
    {
        string id;
        await using (var workspace = Workspace("questions"))
        await using (var questions = new QuestionCoordinator(workspace))
        {
            await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); id = session.Record.VeoId;
            session.Timeline.Upsert(Json("""{"id":"async1","type":"agentMessage","delivery":"async","questions":[{"title":"Choose a color","options":["Blue","Green"]},{"title":"Why?","options":[]}]}"""), null);
            await questions.ObserveAsync(session); var question = questions.Pending(id).Single(); Assert(question.Answer(question.Questions[0]) == "Blue", "Source default suggestion changed.");
            await questions.AnswerAsync(question, "1", "Because it is clear."); await workspace.SaveDraftAsync(session, "ordinary draft", ["unrelated.png"]);
        }
        await using (var workspace = Workspace("questions"))
        await using (var questions = new QuestionCoordinator(workspace))
        {
            await workspace.InitializeAsync(); var session = await workspace.LoadAsync((await workspace.CatalogAsync()).Single(x => x.VeoId == id)); await questions.ObserveAsync(session);
            var question = questions.Pending(id).Single(); Assert(question.AnswerMessage!.Contains("Because it is clear."), "Relaunch lost answer draft.");
            await questions.SendAsync(session, question, Settings()); await Until(() => session.Queue.Count == 0 && session.Record.CodexThreadId is not null && !session.Timeline.IsRunning);
            Assert(session.Draft.Text == "ordinary draft" && session.Draft.AttachmentsJson.Contains("unrelated.png"), "Answer delivery cleared ordinary composer.");
            Assert((await workspace.Threads.ReadDraftAsync(id))!.Text == "ordinary draft", "Preserved draft did not reach disk.");
            Assert(questions.Pending(id).Count == 0, "Delivered question remained pending.");
        }
    });
    await Check("question dismissal is durable and sends no answer", async () =>
    {
        await using var workspace = Workspace("dismiss"); await using var questions = new QuestionCoordinator(workspace); await workspace.InitializeAsync(); var session = await workspace.CreateAsync();
        session.Timeline.Upsert(Json("""{"id":"q","type":"agentMessage","delivery":"async","questions":[{"title":"Proceed?","options":["Yes"]}]}"""), null);
        await questions.ObserveAsync(session); await questions.DismissAsync(questions.Pending(session.Record.VeoId).Single()); await questions.ObserveAsync(session);
        Assert(questions.Pending(session.Record.VeoId).Count == 0 && !File.ReadAllText(Path.Combine(root, "dismiss.log")).Contains("turn/start"), "Dismissal submitted or reopened an answer.");
    });
    await Check("blocking answers retain runtime identity, exclude secret persistence and keep open", async () =>
    {
        await using var workspace = Workspace("blocking"); await using var questions = new QuestionCoordinator(workspace, new(TimeSpan.FromMilliseconds(40), TimeSpan.FromMilliseconds(40)));
        await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await workspace.SubmitAsync(session, Settings() with { Text = "bind" });
        await workspace.InspectAsync("test/ask", new { isBlocking = false }); await Until(() => workspace.PendingRequests.Count > 0); var request = workspace.PendingRequests.Single();
        await questions.OpenBlockingAsync(session, request); await questions.AnswerBlockingAsync(session, request, "public", "Choice"); await questions.AnswerBlockingAsync(session, request, "secret", "fixture-secret-123");
        await questions.NoteBlockingAsync(session, request, "public", "selected details");
        await Task.Delay(150); Assert(workspace.PendingRequests.Count == 1, "Interaction did not cancel countdown.");
        var state = await workspace.Threads.ReadStateAsync(session.Record.VeoId, "blocking-question-" + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("ask-item")));
        Assert(state is not null && !state.Contains("fixture-secret-123") && state.Contains("Choice"), "Secret was persisted or public draft was lost.");
        await questions.SendBlockingAsync(session, request); Assert(workspace.PendingRequests.Count == 0, "Response did not resolve original request.");
        var delivered = await workspace.InspectAsync("test/response");
        Assert(delivered.GetProperty("result").GetProperty("answers").GetProperty("public").GetProperty("answers")[1].GetString() == "user_note:selected details", "Optional notes were not delivered using source protocol semantics.");
        Assert(session.Timeline.Items.Any(item => item.Kind == "veoUserInputAnswer" && item.Text.Contains("••••••") && !item.Text.Contains("fixture-secret-123")), "Answer receipt leaked secret.");
    });
    await Check("nonblocking grace/countdown explicitly skips unanswered questions", async () =>
    {
        await using var workspace = Workspace("countdown"); await using var questions = new QuestionCoordinator(workspace, new(TimeSpan.FromMilliseconds(40), TimeSpan.FromMilliseconds(80)));
        await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); await workspace.SubmitAsync(session, Settings() with { Text = "bind" });
        await workspace.InspectAsync("test/ask", new { isBlocking = false }); await Until(() => workspace.PendingRequests.Count > 0); var request = workspace.PendingRequests.Single();
        await questions.OpenBlockingAsync(session, request); await Until(() => questions.CountdownDeadline(request) is not null); await Until(() => workspace.PendingRequests.Count == 0);
        Assert(session.Timeline.Items.Any(item => item.Kind == "veoUserInputAnswer" && item.Text.Contains("Skipped")), "Countdown fabricated an answer.");
    });
    await Check("quote references preserve encoded identities and exact trimmed passage", () =>
    {
        var reference = new QuoteReference("thread /🙂", "item&1"); var markdown = reference.Markdown("  exact passage\nsecond line  ", "my comment");
        Assert(QuoteReference.Parse(reference.Uri) == reference && markdown.StartsWith("> exact passage\n> second line") && markdown.EndsWith("my comment"), "Quote changed passage or identity.");
        Assert(QuoteReference.Parse(new Uri("veo-quote://source?thread=a&thread=b&item=x")) is null, "Ambiguous source reference was accepted."); return Task.CompletedTask;
    });
    await Check("review comment captures displayed patch rows and persists in the ordinary draft without submission", async () =>
    {
        const string patch = "diff --git a/src/a.txt b/src/a.txt\n@@ -8,4 +8,5 @@\n-old text\r\n+replacement 🦊  \r\n+inserted\r\n kept\r\n-skipped old\r\n+skipped new\r\n tail\r\n";
        var hunk = UnifiedDiff.Parse(patch).Hunks.Single();
        var captured = new GitReviewComment("src/a.txt", staged: true, ignoreWhitespace: true, hunk);
        var replacement = captured.Lines[1];
        var earlier = captured.Lines[0];
        var context = captured.Lines[3];
        var tail = captured.Lines[6];
        var formatted = captured.FormatDraft([tail, replacement, earlier, context], "  Keep the accent.  ");
        var expected = """
            Review comment on src/a.txt (staged) · whitespace ignored
            Old lines: 8–9, 11
            New lines: 8, 10, 12

            Keep the accent.

            Selected patch lines:
            > old:8 new:– -old text
            > old:– new:8 +replacement 🦊
            > old:9 new:10  kept
            > old:11 new:12  tail
            """.ReplaceLineEndings("\n").Replace("+replacement 🦊\n", "+replacement 🦊  \n");
        Assert(formatted == expected, "Path, stage, exact selected locations, ordering or whitespace was lost.");
        await Throws<ArgumentException>(() => Task.FromResult(captured.FormatDraft([earlier with { Text = "later file contents" }], "Stale")));
        await Throws<ArgumentException>(() => Task.FromResult(captured.FormatDraft([earlier], " ")));

        string id;
        var attachment = new ComposerAttachment(ComposerAttachmentKind.FileMention, "fixture/path", "fixture.txt", "fixture");
        const string options = """{"access":"Read only","future":{"enabled":true}}""";
        await using (var workspace = Workspace("review-comment"))
        {
            await workspace.InitializeAsync();
            var session = await workspace.CreateAsync();
            id = session.Record.VeoId;
            var draft = new ComposerDraft("Existing draft", [attachment], options);
            await ComposerDraft.SaveAsync(workspace, session, draft.Append(formatted, []));
            Assert(session.Queue.Count == 0 && session.Record.CodexThreadId is null, "Adding to draft submitted a prompt.");
        }
        await using (var workspace = Workspace("review-comment"))
        {
            await workspace.InitializeAsync();
            var saved = ComposerDraft.Read((await workspace.Threads.ReadDraftAsync(id))!);
            Assert(saved.Text == "Existing draft\n\n" + expected && saved.Attachments.SequenceEqual([attachment]) && saved.OptionsJson == options,
                "Reopening the database lost the comment or altered the existing draft.");
            var trace = Path.Combine(root, "review-comment.log");
            Assert(!File.Exists(trace) || !File.ReadAllText(trace).Contains("turn/start"), "Adding to draft dispatched a turn.");
        }
    });
    await Check("temporary chat toggles preserve the workspace and set ephemeral runtime creation", async () =>
    {
        string id;
        string scratchPath;
        await using (var workspace = Workspace("temporary-chat"))
        {
            await workspace.InitializeAsync();
            var session = await workspace.CreateAsync();
            id = session.Record.VeoId;
            scratchPath = session.Record.Cwd;
            Assert(session.CanToggleTemporaryChat, "A new projectless chat cannot become temporary.");
            await workspace.ToggleTemporaryChatAsync(session);
            Assert(session.Record.WorkspaceKind == "temporary", "First toggle did not make the chat temporary.");
            await workspace.ToggleTemporaryChatAsync(session);
            Assert(session.Record.WorkspaceKind == "scratch", "Second toggle did not restore a regular chat.");
            await workspace.MakeTemporaryAsync(session);
            await Throws<InvalidOperationException>(() => workspace.MakeTemporaryAsync(session));

            var projectPath = Directory.CreateDirectory(Path.Combine(root, "project")).FullName;
            var project = await workspace.CreateAsync(projectPath);
            Assert(!project.CanToggleTemporaryChat, "A project chat exposed the temporary toggle.");
            await Throws<InvalidOperationException>(() => workspace.ToggleTemporaryChatAsync(project));
        }
        await using (var workspace = Workspace("temporary-chat"))
        {
            await workspace.InitializeAsync();
            var record = (await workspace.CatalogAsync()).Single(row => row.VeoId == id);
            Assert(record.WorkspaceKind == "temporary" && record.Cwd == scratchPath, "Temporary status or workspace path did not survive restart.");
            var session = await workspace.LoadAsync(record);
            await workspace.SubmitAsync(session, Settings() with { Text = "Temporary fixture" });
            var request = File.ReadAllLines(Path.Combine(root, "temporary-chat.log")).Select(Json)
                .Single(message => message.Str("method") == "thread/start");
            Assert(request.GetProperty("params").GetProperty("ephemeral").GetBoolean(), "Codex did not receive an ephemeral thread start.");
            Assert(!session.CanToggleTemporaryChat, "A bound runtime thread still exposed the toggle.");
            await Throws<InvalidOperationException>(() => workspace.ToggleTemporaryChatAsync(session));
        }
    });
}
finally
{
    var parent = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Veo-Workflow-Tests"));
    if (Path.GetDirectoryName(root) == parent && Directory.Exists(root)) Directory.Delete(root, true);
}
Console.WriteLine($"PASS: {passed} workflow checks.");
async Task Check(string name, Func<Task> test) { await test().WaitAsync(TimeSpan.FromSeconds(30)); passed++; Console.WriteLine("PASS " + name); }
static JsonElement Json(string text) => JsonSerializer.Deserialize<JsonElement>(text);
static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
static async Task Until(Func<bool> condition) { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)); while (!condition()) await Task.Delay(20, timeout.Token); }
static async Task Throws<T>(Func<Task> action) where T : Exception { try { await action(); } catch (T) { return; } throw new InvalidOperationException($"Expected {typeof(T).Name}"); }
static async Task Server(string[] arguments)
{
    var scenario = arguments.Single(x => x.StartsWith("--scenario="))[11..]; var trace = arguments.Single(x => x.StartsWith("--trace="))[8..]; var threads = 0; var turns = 0; var runtime = ""; JsonElement? response = null;
    while (await Console.In.ReadLineAsync() is { } line)
    {
        await File.AppendAllTextAsync(trace, line + "\n"); using var d = JsonDocument.Parse(line); var request = d.RootElement;
        if (!request.TryGetProperty("method", out var method)) { response = request.Clone(); continue; }
        if (!request.TryGetProperty("id", out var idValue)) continue; var id = idValue.GetInt64();
        switch (method.GetString())
        {
            case "initialize": await Write(new { id, result = new { userAgent = "workflows 0.169.0" } }); break;
            case "model/list": await Write(new { id, result = new { data = new[] { new { id = "fixture", model = "fixture", displayName = "Fixture", defaultReasoningEffort = "high" } } } }); break;
            case "thread/start": runtime = "runtime" + ++threads; await Write(new { id, result = new { thread = new { id = runtime } } }); break;
            case "thread/resume": await Write(new { id, result = new { thread = new { id = runtime, status = "idle", turns = Array.Empty<object>() } } }); break;
            case "turn/start":
                if (scenario == "uncertain") { Environment.Exit(42); return; }
                var p = request.GetProperty("params"); var turn = "turn" + ++turns;
                var user = new { id = "user" + turns, type = "userMessage", clientId = p.Str("clientUserMessageId"), content = p.GetProperty("input").Clone() };
                await Write(new { method = "turn/started", @params = new { threadId = p.Str("threadId"), turn = new { id = turn } } });
                await Write(new { method = "turn/completed", @params = new { threadId = p.Str("threadId"), turn = new { id = turn, status = scenario == "failed" ? "failed" : "completed", error = scenario == "failed" ? new { message = "fixture failure" } : null, items = new object[] { user, new { id = "assistant" + turns, type = "agentMessage", text = "done" } } } } });
                await Task.Delay(50); await Write(new { id, result = new { turn = new { id = turn } } }); break;
            case "test/ask":
                await Write(new { id = "question-id", method = "item/tool/requestUserInput", @params = new { threadId = runtime, turnId = "turn1", itemId = "ask-item", isBlocking = request.GetProperty("params").GetProperty("isBlocking").GetBoolean(), questions = new[] { new { id = "public", question = "Choose", isSecret = false }, new { id = "secret", question = "Credential", isSecret = true } } } });
                await Write(new { id, result = new { } }); break;
            case "test/response": await Write(new { id, result = response }); break;
            default: await Write(new { id, result = new { } }); break;
        }
    }
    static async Task Write(object value) { await Console.Out.WriteLineAsync(JsonSerializer.Serialize(value)); await Console.Out.FlushAsync(); }
}
