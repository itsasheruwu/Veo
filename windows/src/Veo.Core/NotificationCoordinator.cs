using System.Text.Json;
using System.Threading.Channels;
using Veo.Protocol;

namespace Veo.Core;

public sealed record VeoNotification(string Identity, string ThreadId, string Title, string Body, bool IsCompletion);
public interface INotificationPlatform
{
    bool Show(VeoNotification notification, bool soundEnabled, string? customSound);
}

public sealed class NotificationCoordinator : IAsyncDisposable
{
    readonly WorkspaceCoordinator workspace;
    readonly INotificationPlatform platform;
    readonly Func<string, bool> watched;
    readonly Channel<RuntimeEvent> pending = Channel.CreateBounded<RuntimeEvent>(new BoundedChannelOptions(64) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
    readonly SemaphoreSlim gate = new(1, 1);
    readonly CancellationTokenSource lifetime = new();
    readonly Task processing;
    public string? LastError { get; private set; }
    public NotificationCoordinator(WorkspaceCoordinator workspace, INotificationPlatform platform, Func<string, bool> watched)
    { this.workspace = workspace; this.platform = platform; this.watched = watched; workspace.RuntimeEventReceived += Observe; processing = ProcessAsync(); }
    void Observe(RuntimeEvent message)
    {
        if (message.Method is not ("turn/completed" or "error" or "item/commandExecution/requestApproval" or "item/fileChange/requestApproval" or "item/tool/requestUserInput")) return;
        if (!pending.Writer.TryWrite(message)) LastError = "The notification queue filled; the conversation remains available in Veo.";
    }
    async Task ProcessAsync()
    {
        try
        {
            await foreach (var message in pending.Reader.ReadAllAsync(lifetime.Token))
            {
                try
                {
                    var thread = workspace.LoadedSessions.FirstOrDefault(x => x.Record.CodexThreadId == message.Parameters.Str("threadId"));
                    if (thread is null) continue;
                    var p = message.Parameters;
                    var turn = p.Str("turnId") ?? (p.TryObjectProperty("turn", out var snapshot) ? snapshot.Str("id") : null);
                    var identity = turn is null ? message.Id?.GetRawText() ?? Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(p.GetRawText()))) : turn + ":" + p.Str("itemId") + ":" + message.Id?.GetRawText();
                    var completion = message.Method == "turn/completed";
                    var failed = message.Method == "error" || (completion && p.TryObjectProperty("turn", out var t) && t.Str("status") == "failed");
                    var body = completion ? failed ? "Codex could not finish this turn." : "Codex finished this turn." : "Codex needs your attention.";
                    await DeliverAsync(new(message.Method + ":" + identity, thread.Record.VeoId, thread.Record.Title, body, completion && !failed));
                }
                catch (Exception e) { LastError = DiagnosticRedactor.Redact(e.Message); }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }
    public async Task<bool> DeliverAsync(VeoNotification notification)
    {
        await gate.WaitAsync(lifetime.Token);
        try
        {
            var key = "alert-" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(notification.Identity)));
            if (await workspace.Threads.ReadStateAsync(notification.ThreadId, key, lifetime.Token) is not null) return false;
            // Record suppression too: reopening the same history must not replay old alerts.
            await workspace.Threads.SaveStateAsync(notification.ThreadId, key, JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow }), lifetime.Token);
            if (!workspace.Preferences.Notifications || watched(notification.ThreadId)) return false;
            return platform.Show(notification, notification.IsCompletion && workspace.Preferences.CompletionSound, workspace.Preferences.CompletionSoundPath);
        }
        finally { gate.Release(); }
    }
    public async ValueTask DisposeAsync()
    {
        workspace.RuntimeEventReceived -= Observe; pending.Writer.TryComplete();
        await processing; lifetime.Cancel(); lifetime.Dispose(); gate.Dispose();
    }
}
