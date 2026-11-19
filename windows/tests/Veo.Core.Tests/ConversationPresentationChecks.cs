using System.Text.Json;
using Veo.Core;
using Veo.Infrastructure.Storage;
using Veo.Protocol;

static class ConversationPresentationChecks
{
    public static IEnumerable<(string Name, Func<Task> Run)> All(string root)
    {
        yield return ("activity groups preserve item order and outline targets", () =>
        {
            GroupingAndOutline();
            return Task.CompletedTask;
        });
        yield return ("tool content, image fallbacks and source metadata retain runtime identity", () =>
        {
            ToolAndSourcePresentation();
            return Task.CompletedTask;
        });
        yield return ("native artifact access preserves bytes and requires approval for an outside file", () => ArtifactReadbackAsync(root));
        yield return ("conversation activity and exact interrupted outcome survive SQLite reload", () => ActivityReadbackAsync(root));
    }

    static void GroupingAndOutline()
    {
        TimelineItem[] items =
        [
            Item("u1", "t1", "userMessage", "Add pagination to the sidebar.", 0),
            Item("r1", "t1", "reasoning", "One step", 1),
            Item("cmd1", "t1", "commandExecution", "First command", 2),
            Item("cmd2", "t2", "commandExecution", "Second command", 3),
            Item("a1", "t1", "agentMessage", "Pagination is ready.", 4),
            Item("u2", "t2", "userMessage", "Keep sidebar pagination on relaunch.", 5),
            Item("a2", "t2", "agentMessage", "Sidebar pagination now persists.", 6),
            Item("u3", "t3", "userMessage", "Switch to audio capture and voice transcription.", 7)
        ];

        var entries = TimelinePresentation.Entries(items.Reverse(), groupActivity: true);
        Require(entries.SelectMany(entry => entry.Items).Select(item => item.Id).SequenceEqual(items.Select(item => item.Id)), "Grouped rows reordered or lost original items.");
        var activities = entries.Where(entry => entry.Kind == "activity").ToArray();
        Require(activities.Length == 2 && activities[0].Id == "activity:r1" && activities[0].Items.Select(item => item.Id).SequenceEqual(["r1", "cmd1"]) && activities[1].Items.Single().Id == "cmd2", "Activity crossed the turn boundary or lost the group anchor.");
        Require(TimelinePresentation.Entries(items, groupActivity: false).Count == items.Length, "Disabling grouped activity did not restore item rows.");

        var topics = TimelinePresentation.Topics(items);
        Require(topics.Count == 2 && topics[0].TargetItemId == "u1" && topics[1].TargetItemId == "u3", "Outline did not retain source prompt identities.");
        Require(topics[0].SourceTurnCount == 2 && topics[0].ItemIds.Contains("cmd2") && topics[0].AssistantPreview == items[6].Text, "Follow-up outline lost turn items or the current answer.");
    }

    static void ToolAndSourcePresentation()
    {
        var tool = Item("tool1", "t1", "mcpToolCall", "", 0, """
            {
              "server": "fixture-server", "tool": "inspect",
              "result": { "content": [
                { "type": "text", "text": "Exact\r\n日本語🙂" },
                { "type": "image", "data": "AA==", "mimeType": "image/png" },
                { "type": "resource", "resource": { "uri": "fixture://audio", "mimeType": "audio/wav", "blob": "AA==" } },
                { "type": "futurePayload", "preserve": true }
              ] },
              "memoryCitation": { "entries": [{ "path": "notes.md", "lineStart": 2, "lineEnd": 4, "note": "Source note" }] },
              "citations": [{ "url": "https://example.invalid/source", "title": "Source article" }]
            }
            """);
        var presentation = TimelinePresentation.Item(tool);
        Require(presentation.Title == "fixture-server · inspect" && presentation.Body == "Exact\r\n日本語🙂", "Tool title or exact textual result changed.");
        Require(presentation.Artifacts.Select(artifact => (artifact.Id, artifact.Kind)).SequenceEqual([
            ("tool1:result:1", "inlineImage"), ("tool1:result:2", "inlineAudio"), ("tool1:result:3", "unknown")
        ]), "Mixed tool content reordered, duplicated its text or lost an unknown item.");
        Require(presentation.Sources.Length == 2 && presentation.Sources[0] is { Target: "notes.md", StartLine: 2, EndLine: 4, Note: "Source note" }, "Memory citation lost its source range.");
        Require(presentation.Sources[1] is { Label: "Source article", Target: "https://example.invalid/source" }, "URL citation lost its target.");

        var storedImage = TimelinePresentation.Item(Item("image1", "t1", "imageGeneration", "", 1, """{"fileId":"generated-id"}"""));
        Require(storedImage.Artifacts.Single() is { Id: "image1:generated", Kind: "storedFile", Source: "generated-id", UnavailableReason.Length: > 0 }, "Stored image without a read method lost its unavailable state.");
    }

    static async Task ArtifactReadbackAsync(string root)
    {
        var workspace = Path.Combine(root, "workspace");
        var outside = Path.Combine(root, "outside.txt");
        Directory.CreateDirectory(workspace);
        var png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/e/wAAAAASUVORK5CYII=");
        await File.WriteAllBytesAsync(Path.Combine(workspace, "image.png"), png);
        await File.WriteAllTextAsync(outside, "Exact\r\n日本語🙂");
        var session = new ThreadSession(new("veo1", null, workspace, "Artifact fixture"));
        var access = new ConversationArtifactAccess(root);
        var local = await access.ReadAsync(session, new("local", "localImage", "image.png", "Local image"));
        var inline = await access.ReadAsync(session, new("inline", "dataImage", "data:image/png;base64," + Convert.ToBase64String(png), "Inline image"));
        Require(local.MimeType == "image/png" && local.CanonicalPath is not null && local.Bytes.SequenceEqual(png) && inline.Bytes.SequenceEqual(png), "Local and inline preview data differ from the source.");

        var outsideArtifact = new ConversationArtifact("outside", "localText", outside, "Outside source");
        Require(!access.IsInsideApprovedRoots(session, outside), "An outside source was reported as already approved.");
        await RejectedAsync<UnauthorizedAccessException>(() => access.ReadAsync(session, outsideArtifact));
        var approved = await access.ReadAsync(session, outsideArtifact, allowOutside: true);
        Require(System.Text.Encoding.UTF8.GetString(approved.Bytes) == "Exact\r\n日本語🙂", "Explicit preview altered the source bytes.");
        await RejectedAsync<UnauthorizedAccessException>(() => access.ReadAsync(session, outsideArtifact));
        await RejectedAsync<NotSupportedException>(() => access.ReadAsync(session, new("remote", "remoteImage", "https://example.invalid/image.png", "Remote image")));
    }

    static async Task ActivityReadbackAsync(string root)
    {
        var data = Path.Combine(root, "activity");
        var record = new PersistedThread("veo1", "codex1", root, "Activity fixture");
        await using (var workspace = new WorkspaceCoordinator(data))
        {
            await workspace.Threads.InitializeAsync();
            await workspace.Threads.UpsertThreadAsync(record);
            var session = await workspace.LoadAsync(record);
            await using var activity = new ConversationActivityCoordinator(workspace, observeEvents: false);

            void Apply(string notification, long? generation = null)
            {
                var runtimeEvent = new RuntimeEvent(generation ?? workspace.Runtime.Generation, Json(notification));
                if (generation is null)
                    session.Timeline.Apply(runtimeEvent.Method!, runtimeEvent.Parameters);
                activity.Apply(session, runtimeEvent);
            }

            Apply("""{"method":"turn/started","params":{"threadId":"codex1","turn":{"id":"first","status":"inProgress"}}}""");
            Apply("""{"method":"turn/plan/updated","params":{"threadId":"codex1","turnId":"first","plan":[{"step":"Review","status":"inProgress"}]}}""");
            Apply("""{"method":"thread/tokenUsage/updated","params":{"threadId":"codex1","turnId":"first","tokenUsage":{"total":{"totalTokens":2000},"last":{"totalTokens":91},"modelContextWindow":100}}}""");
            Apply("""{"method":"item/completed","params":{"threadId":"codex1","turnId":"first","item":{"id":"change1","type":"fileChange","changes":[{"path":"file.cs","kind":{"type":"update"}}]}}}""");
            Apply("""{"method":"turn/diff/updated","params":{"threadId":"codex1","turnId":"first","diff":"current diff"}}""");
            Apply("""{"method":"turn/diff/updated","params":{"threadId":"codex1","turnId":"stale","diff":"stale turn"}}""");
            Apply("""{"method":"turn/diff/updated","params":{"threadId":"codex1","turnId":"first","diff":"stale process"}}""", workspace.Runtime.Generation - 1);
            Apply("""{"method":"turn/completed","params":{"threadId":"codex1","turn":{"id":"first","status":"interrupted"}}}""");
            Apply("""{"method":"turn/diff/updated","params":{"threadId":"codex1","diff":"late turn-less diff"}}""");
            await workspace.PersistTimelineAsync(session);
            var live = activity.Snapshot(session);
            Require(live is { TurnId: "first", Status: "interrupted", Diff: "current diff", Usage.Warning: 2 } && live.Plan.Single().Text == "Review" && live.Files.Single().ItemId == "change1", "Live side metadata was lost or overwritten by stale events.");
        }
        await using (var reopened = new WorkspaceCoordinator(data))
        {
            await reopened.Threads.InitializeAsync();
            var session = await reopened.LoadAsync((await reopened.CatalogAsync()).Single());
            await using var activity = new ConversationActivityCoordinator(reopened, observeEvents: false);
            await activity.ObserveAsync(session);
            var restored = activity.Snapshot(session);
            Require(restored is { TurnId: "first", Status: "interrupted", Diff: "current diff", Usage.Warning: 2 } && restored.Plan.Single().Text == "Review" && restored.Files.Single().ItemId == "change1", $"Activity reload changed the outcome or lost metadata ({restored.Status}).");
        }
    }

    static TimelineItem Item(string id, string turn, string kind, string text, long order, string raw = "{}")
        => new(id, turn, kind, text, "completed", Json(raw), order);

    static JsonElement Json(string value) => JsonSerializer.Deserialize<JsonElement>(value);

    static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    static async Task RejectedAsync<T>(Func<Task> read) where T : Exception
    {
        try { await read(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }
}
