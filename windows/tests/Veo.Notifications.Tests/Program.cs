using System.Collections.Concurrent;
using System.Text.Json;
using Veo.Core;
using Veo.Protocol;

if (args.Contains("--server")) { await Server(); return; }
var root = Path.Combine(Path.GetTempPath(), "Veo-Notification-Tests", Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
var self = Path.Combine(AppContext.BaseDirectory, "Veo.Notifications.Tests.exe");
var platform = new FakePlatform(); var watched = false; var count = 0; string veoId;
WorkspaceCoordinator Open() => new(root, _ => new(new CodexRuntimeOptions { ExecutablePath = self, AdditionalArguments = ["--server"] }));
try
{
    await using (var workspace = Open())
    {
        await workspace.InitializeAsync(); var session = await workspace.CreateAsync(); veoId = session.Record.VeoId;
        await workspace.EnsureRuntimeThreadAsync(session, new("bind", "", "fixture", "low", null, "Workspace", "Agentic", []));
        await using var notifications = new NotificationCoordinator(workspace, platform, _ => watched);
        async Task Emit(string method, string turn, string? item = null, string? request = null)
        {
            await workspace.InspectAsync("test/notify", new { method, threadId = session.Record.CodexThreadId, turn, item, request });
            var identity = $"{method}:{turn}:{item}:{(request is null ? null : JsonSerializer.Serialize(request))}";
            var key = "alert-" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(identity)));
            await Until(async () => await workspace.Threads.ReadStateAsync(veoId, key) is not null);
        }
        await Emit("turn/completed", "t1"); await Until(() => Task.FromResult(platform.Events.Length == 1));
        Check(platform.Events[0].Notification.ThreadId == veoId && !platform.Events[0].Sound, "completion routes to local identity and sound defaults off");
        await Emit("turn/completed", "t1"); await Task.Delay(80);
        Check(platform.Events.Length == 1, "duplicate completion is suppressed");
        watched = true; await Emit("turn/completed", "watched");
        Check(platform.Events.Length == 1, "watched-chat alert is suppressed");
        watched = false; workspace.Preferences.Notifications = false; await Emit("turn/completed", "disabled");
        Check(platform.Events.Length == 1, "disabled alerts receive durable suppression receipts");
        workspace.Preferences.Notifications = true; workspace.Preferences.CompletionSound = true; workspace.Preferences.CompletionSoundPath = "fixture.wav";
        await Emit("item/commandExecution/requestApproval", "t2", "command", "approval1"); await Until(() => Task.FromResult(platform.Events.Length == 2));
        Check(!platform.Events[1].Sound && !platform.Events[1].Notification.IsCompletion, "attention alerts do not use completion sound");
        await Emit("turn/completed", "t3"); await Until(() => Task.FromResult(platform.Events.Length == 3));
        Check(platform.Events[2].Sound && platform.Events[2].Path == "fixture.wav", "explicit sound preference reaches platform");
        platform.Fail = true;
        await workspace.InspectAsync("test/notify", new { method = "turn/completed", threadId = session.Record.CodexThreadId, turn = "failure" });
        await Until(() => Task.FromResult(notifications.LastError is not null));
        Check(!session.Timeline.IsRunning && notifications.LastError!.Contains("fixture"), "notification failure cannot fail the turn consumer");
        platform.Fail = false;
        await Emit("turn/completed", "after-error"); await Until(() => Task.FromResult(platform.Events.Length == 4));
        Check(platform.Events.Length == 4, "delivery recovers after platform failure");
        await workspace.SavePreferencesAsync();
    }
    await using (var workspace = Open())
    {
        await workspace.InitializeAsync(); var session = await workspace.LoadAsync((await workspace.CatalogAsync()).Single(x => x.VeoId == veoId));
        await using var notifications = new NotificationCoordinator(workspace, platform, _ => false);
        var delivered = await notifications.DeliverAsync(new("turn/completed:t1::", veoId, "Fixture", "done", true));
        Check(!delivered && platform.Events.Length == 4, "relaunch does not replay an old alert");
        Check(workspace.Preferences.CompletionSound && workspace.Preferences.CompletionSoundPath == "fixture.wav", "sound preference survives relaunch");
        await notifications.DeliverAsync(new("new-after-relaunch", veoId, "Fixture", "done", true));
        Check(platform.Events.Length == 5, "new completion after relaunch remains deliverable");
    }
}
finally
{
    var parent = Path.Combine(Path.GetTempPath(), "Veo-Notification-Tests");
    if (Path.GetDirectoryName(root) == parent && Directory.Exists(root)) Directory.Delete(root, true);
}
Console.WriteLine($"PASS: {count} notification scenarios.");
void Check(bool condition, string description) { if (!condition) throw new InvalidOperationException(description); count++; Console.WriteLine("PASS " + description); }
static async Task Until(Func<Task<bool>> condition) { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8)); while (!await condition()) await Task.Delay(20, timeout.Token); }
static async Task Server()
{
    while (await Console.In.ReadLineAsync() is { } line)
    {
        using var document = JsonDocument.Parse(line); var request = document.RootElement;
        if (!request.TryGetProperty("method", out var method) || !request.TryGetProperty("id", out var id)) continue;
        switch (method.GetString())
        {
            case "initialize": await Write(new { id, result = new { userAgent = "fixture" } }); break;
            case "model/list": await Write(new { id, result = new { data = Array.Empty<object>() } }); break;
            case "thread/start": await Write(new { id, result = new { thread = new { id = "runtime-notification" } } }); break;
            case "thread/resume": await Write(new { id, result = new { thread = new { id = "runtime-notification", status = "idle", turns = Array.Empty<object>() } } }); break;
            case "test/notify":
                var p = request.GetProperty("params"); var name = p.Str("method")!;
                var parameters = new { threadId = p.Str("threadId"), turnId = p.Str("turn"), itemId = p.Str("item"), turn = new { id = p.Str("turn"), status = "completed", items = Array.Empty<object>() } };
                if (p.Str("request") is { } requestId) await Write(new { id = requestId, method = name, @params = parameters });
                else await Write(new { method = name, @params = parameters });
                await Write(new { id, result = new { } }); break;
            default: await Write(new { id, result = new { } }); break;
        }
    }
    static async Task Write(object value) { await Console.Out.WriteLineAsync(JsonSerializer.Serialize(value)); await Console.Out.FlushAsync(); }
}
sealed class FakePlatform : INotificationPlatform
{
    readonly ConcurrentQueue<(VeoNotification Notification, bool Sound, string? Path)> events = new();
    public (VeoNotification Notification, bool Sound, string? Path)[] Events => events.ToArray();
    public bool Fail { get; set; }
    public bool Show(VeoNotification notification, bool soundEnabled, string? customSound)
    { if (Fail) throw new IOException("fixture notification failure"); events.Enqueue((notification, soundEnabled, customSound)); return true; }
}
