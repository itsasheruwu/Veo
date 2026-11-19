using System.Collections.Concurrent;
using System.Text.Json;
using Veo.Protocol;

namespace Veo.Core;

public sealed record UtilityInferenceRequest(JsonElement Input, JsonElement OutputSchema, NativeModelDescriptor Model, string Cwd, bool OptedIn);
public interface IUtilityInference
{ Task<string> InferAsync(UtilityInferenceRequest request, CancellationToken cancellation = default); }

/// <summary>Private ephemeral turns use the same app-server process, never a second runtime or workspace transport.</summary>
public sealed class UtilityInferenceService : IUtilityInference, IAsyncDisposable
{
    sealed class Pending(long generation)
    {
        public long Generation { get; } = generation;
        public TaskCompletionSource<string> Result { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public string? TurnId;
        public string Text = "";
    }
    readonly WorkspaceCoordinator workspace;
    readonly ConcurrentDictionary<string, Pending> pending = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, byte> closing = new(StringComparer.Ordinal);
    bool disposed;
    public UtilityInferenceService(WorkspaceCoordinator workspace) { this.workspace = workspace; workspace.Changed += CheckRuntime; }
    void CheckRuntime()
    {
        foreach (var state in pending.Values)
            if (state.Generation != workspace.Runtime.Generation || workspace.Runtime.RuntimeState is CodexRuntimeState.Faulted or CodexRuntimeState.Disposed or CodexRuntimeState.Stopped)
                state.Result.TrySetException(new IOException("The runtime changed during private utility inference."));
    }

    public async Task<string> InferAsync(UtilityInferenceRequest request, CancellationToken cancellation = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!request.OptedIn) throw new InvalidOperationException("Enable Utility inference explicitly before sending input to a model.");
        if (!request.Model.Efforts.Any(x => x.Id.Equals("low", StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("The selected utility model does not advertise Low reasoning.");
        cancellation.ThrowIfCancellationRequested();
        var generation = workspace.Runtime.Generation;
        using var startTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var thread = await workspace.Runtime.RequestAsync("thread/start", new
        {
            cwd = request.Cwd, model = request.Model.Model, ephemeral = true, sandbox = "read-only", approvalPolicy = "never", threadSource = "veoUtility",
            baseInstructions = "You perform a private Veo utility task. Do not use tools. Return only the JSON required by the output schema.",
            developerInstructions = "Never inspect files, run commands, browse or modify state. Analyze only input supplied directly by the application.",
        }, startTimeout.Token);
        var id = thread.GetProperty("thread").Str("id") ?? throw new InvalidDataException("Codex did not return a utility thread ID.");
        var state = new Pending(generation);
        if (!pending.TryAdd(id, state)) throw new InvalidOperationException("Duplicate utility thread ID.");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, deadline.Token);
        using var registration = linked.Token.Register(() => { state.Result.TrySetCanceled(linked.Token); _ = CloseAsync(id, state); });
        if (linked.IsCancellationRequested) { await CloseAsync(id, state); linked.Token.ThrowIfCancellationRequested(); }
        _ = StartTurnAsync(id, state, request);
        try { return await state.Result.Task; }
        finally { pending.TryRemove(id, out _); await CloseAsync(id, state); }
    }
    async Task StartTurnAsync(string id, Pending state, UtilityInferenceRequest request)
    {
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(90));
            var response = await workspace.Runtime.RequestAsync("turn/start", new
            {
                threadId = id, input = request.Input, model = request.Model.Model, effort = "low", summary = "none",
                serviceTier = request.Model.Tiers.FirstOrDefault(x => x.IsFast)?.Id, approvalPolicy = "never",
                sandboxPolicy = new { type = "readOnly", networkAccess = false }, outputSchema = request.OutputSchema,
            }, timeout.Token);
            state.TurnId = response.TryObjectProperty("turn", out var turn) ? turn.Str("id") : null;
            if (state.Result.Task.IsCompleted || state.Generation != workspace.Runtime.Generation) await CloseAsync(id, state);
        }
        catch (Exception exception) { state.Result.TrySetException(exception); }
    }
    public bool TryHandle(RuntimeEvent message)
    {
        var p = message.Parameters;
        if (message.Method == "thread/started" && p.TryObjectProperty("thread", out var created) && created.TryGetProperty("ephemeral", out var ephemeral) && ephemeral.ValueKind == JsonValueKind.True) return true;
        var id = p.Str("threadId") ?? (p.TryObjectProperty("thread", out var thread) ? thread.Str("id") : null);
        if (id is null) return false;
        if (!pending.TryGetValue(id, out var state))
        {
            if (!closing.ContainsKey(id)) return false;
            if (message.IsServerRequest) _ = DeclineAsync(message);
            return true;
        }
        if (message.Generation != state.Generation) return true;
        if (message.IsServerRequest) { _ = DeclineAsync(message); return true; }
        if (message.Method == "turn/started") state.TurnId = p.TryObjectProperty("turn", out var turn) ? turn.Str("id") : p.Str("turnId");
        if (message.Method == "item/completed" && p.TryObjectProperty("item", out var item) && item.Str("type") == "agentMessage") state.Text = TimelineReducer.ExtractText(item);
        if (message.Method == "turn/completed" && p.TryObjectProperty("turn", out var completed))
        {
            if (completed.TryObjectProperty("error", out var error)) state.Result.TrySetException(new IOException(DiagnosticRedactor.Redact(error.Str("message") ?? "Utility inference failed.")));
            else
            {
                if (completed.TryGetProperty("items", out var items) && items.ValueKind == JsonValueKind.Array)
                    foreach (var final in items.EnumerateArray().Where(x => x.Str("type") == "agentMessage")) state.Text = TimelineReducer.ExtractText(final);
                if (string.IsNullOrWhiteSpace(state.Text)) state.Result.TrySetException(new InvalidDataException("The utility model returned no result."));
                else state.Result.TrySetResult(state.Text);
            }
        }
        if (message.Method == "error") state.Result.TrySetException(new IOException(DiagnosticRedactor.Redact(p.Str("message") ?? "Utility inference failed.")));
        return true;
    }
    async Task DeclineAsync(RuntimeEvent request)
    {
        try
        {
            object? result = request.Method switch
            {
                "item/permissions/requestApproval" => new { permissions = new { }, scope = "turn" },
                "item/commandExecution/requestApproval" or "item/fileChange/requestApproval" => new { decision = "decline" },
                "item/tool/requestUserInput" => new { answers = new { } },
                "mcpServer/elicitation/request" => new { action = "decline" },
                "item/tool/call" => new { success = false, contentItems = Array.Empty<object>() }, _ => null,
            };
            if (result is not null) await workspace.Runtime.RespondAsync(request, result);
            else await workspace.Runtime.RespondErrorAsync(request, -32601, "Private utility threads cannot use this client tool.");
        }
        catch (Exception exception) when (exception is IOException or InvalidOperationException or ObjectDisposedException) { }
    }
    async Task CloseAsync(string id, Pending state)
    {
        closing[id] = 0;
        if (state.Generation != workspace.Runtime.Generation || workspace.Runtime.RuntimeState != CodexRuntimeState.Ready) { closing.TryRemove(id, out _); return; }
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try
        {
            if (!state.Result.Task.IsCompletedSuccessfully)
            {
                var turnId = state.TurnId;
                if (turnId is null)
                {
                    var response = await workspace.Runtime.RequestAsync("thread/read", new { threadId = id, includeTurns = true }, timeout.Token);
                    if (response.TryObjectProperty("thread", out var thread) && thread.TryGetProperty("turns", out var turns))
                        turnId = turns.EnumerateArray().Reverse().FirstOrDefault(x => x.Str("status") is "inProgress" or "running" or "active").Str("id");
                }
                if (turnId is not null) await workspace.Runtime.RequestAsync("turn/interrupt", new { threadId = id, turnId }, timeout.Token);
            }
            await workspace.Runtime.RequestAsync("thread/unsubscribe", new { threadId = id }, timeout.Token);
        }
        catch (Exception exception) when (exception is IOException or CodexRpcException or OperationCanceledException or InvalidOperationException or NotSupportedException) { }
        finally { _ = RemoveClosingAsync(id); }
    }
    async Task RemoveClosingAsync(string id) { await Task.Delay(TimeSpan.FromSeconds(5)); closing.TryRemove(id, out _); }
    public ValueTask DisposeAsync()
    {
        disposed = true;
        workspace.Changed -= CheckRuntime;
        foreach (var item in pending) { item.Value.Result.TrySetException(new OperationCanceledException("Veo utility inference stopped.")); _ = CloseAsync(item.Key, item.Value); }
        return ValueTask.CompletedTask;
    }
}
