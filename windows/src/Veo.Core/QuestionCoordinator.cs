using System.Text;
using System.Text.Json;
using Veo.Protocol;

namespace Veo.Core;

public sealed record QuestionOption(string Label, string Description = "");
public sealed record VeoQuestion(string Id, string Title, QuestionOption[] Options, bool Secret = false, bool AllowsOther = true);
public sealed record AsyncQuestionRequest(string ThreadId, string ItemId, VeoQuestion[] Questions, Dictionary<string, string> Answers, string? Resolution = null)
{
    public string Key => ThreadId + "\u001f" + ItemId;
    public string AnswerClientId => "async-answer-" + Convert.ToBase64String(Encoding.UTF8.GetBytes(Key));
    public string Answer(VeoQuestion question) => Answers.GetValueOrDefault(question.Id) ?? question.Options.FirstOrDefault()?.Label ?? "";
    public string? AnswerMessage => Questions.Length == 0 || Questions.Any(question => string.IsNullOrWhiteSpace(Answer(question))) ? null
        : string.Join("\n\n", Questions.Select(question => question.Title + "\n" + Answer(question).Trim()));
}
public sealed record BlockingQuestionDraft(Dictionary<string, string> Answers, bool KeepOpen = false, Dictionary<string, string>? Notes = null);
public sealed record QuestionTiming(TimeSpan Grace, TimeSpan Countdown)
{
    public static QuestionTiming SourceDefault { get; } = new(TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(60));
}

/// <summary>Async questions have a durable outbox lifecycle; blocking questions keep their original RPC identity.</summary>
public sealed class QuestionCoordinator : IAsyncDisposable
{
    readonly WorkspaceCoordinator workspace;
    readonly QuestionTiming timing;
    readonly SemaphoreSlim gate = new(1, 1);
    readonly object sync = new();
    readonly Dictionary<string, AsyncQuestionRequest> asynchronous = new(StringComparer.Ordinal);
    readonly Dictionary<string, BlockingQuestionDraft> blocking = new(StringComparer.Ordinal);
    readonly Dictionary<string, CancellationTokenSource> timers = new(StringComparer.Ordinal);
    readonly Dictionary<string, DateTimeOffset> deadlines = new(StringComparer.Ordinal);
    readonly HashSet<string> observed = new(StringComparer.Ordinal);
    bool disposed;
    public event Action? Changed;
    public string? LastError { get; private set; }
    public QuestionCoordinator(WorkspaceCoordinator workspace, QuestionTiming? timing = null)
    { this.workspace = workspace; this.timing = timing ?? QuestionTiming.SourceDefault; workspace.RuntimeEventApplied += OnRuntimeEvent; }
    public IReadOnlyList<AsyncQuestionRequest> Pending(string threadId)
    { lock (sync) return asynchronous.Values.Where(x => x.ThreadId == threadId && x.Resolution is null).Select(Clone).ToArray(); }
    static AsyncQuestionRequest Clone(AsyncQuestionRequest request) => request with { Answers = new(request.Answers, StringComparer.Ordinal) };
    public async Task ObserveAsync(ThreadSession session)
    {
        await gate.WaitAsync();
        try
        {
            if (!observed.Contains(session.Record.VeoId))
            {
                var raw = await workspace.Threads.ReadStateAsync(session.Record.VeoId, "async-questions");
                if (raw is not null)
                    foreach (var request in JsonSerializer.Deserialize<AsyncQuestionRequest[]>(raw) ?? []) lock (sync) asynchronous[request.Key] = request;
                observed.Add(session.Record.VeoId);
            }
            foreach (var item in session.Timeline.Items) await IngestAsyncCore(session.Record.VeoId, item.Raw);
        }
        finally { gate.Release(); }
        Changed?.Invoke();
    }
    public static VeoQuestion[] ParseAsync(JsonElement item)
    {
        if (item.Str("type") != "agentMessage" || item.Str("delivery") != "async" || !item.TryGetProperty("questions", out var questions) || questions.ValueKind != JsonValueKind.Array) return [];
        return questions.EnumerateArray().Select((question, index) => new VeoQuestion(index.ToString(System.Globalization.CultureInfo.InvariantCulture), question.Str("title") ?? "",
            question.TryGetProperty("options", out var options) && options.ValueKind == JsonValueKind.Array
                ? options.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => new QuestionOption(x.GetString()!)).ToArray() : []))
            .Where(question => !string.IsNullOrWhiteSpace(question.Title)).ToArray();
    }
    public static VeoQuestion[] ParseBlocking(RuntimeEvent request)
    {
        var p = request.Parameters;
        if (request.Method != "item/tool/requestUserInput" || p.ValueKind != JsonValueKind.Object || !p.TryGetProperty("questions", out var questions) || questions.ValueKind != JsonValueKind.Array) return [];
        return questions.EnumerateArray().Select(question => new VeoQuestion(question.Str("id") ?? "", question.Str("question") ?? "",
            question.TryGetProperty("options", out var options) && options.ValueKind == JsonValueKind.Array
                ? options.EnumerateArray().Select(x => new QuestionOption(x.Str("label") ?? "", x.Str("description") ?? "")).ToArray() : [],
            Bool(question, "isSecret") || Sensitive(question.Str("header") + " " + question.Str("question")), Bool(question, "isOther"))).Where(question => question.Id.Length > 0).ToArray();
    }
    async Task IngestAsyncCore(string threadId, JsonElement item)
    {
        var questions = ParseAsync(item); var itemId = item.Str("id");
        if (questions.Length == 0 || itemId is null) return;
        var request = new AsyncQuestionRequest(threadId, itemId, questions, new());
        lock (sync)
        {
            if (asynchronous.TryGetValue(request.Key, out var previous))
            {
                if (previous.Resolution is not null) return;
                request = request with { Answers = previous.Answers };
            }
            asynchronous[request.Key] = request;
        }
        await PersistAsyncCore(threadId);
    }
    public async Task AnswerAsync(AsyncQuestionRequest request, string questionId, string answer)
    {
        await gate.WaitAsync();
        try
        {
            lock (sync)
            {
                if (!asynchronous.TryGetValue(request.Key, out var current) || current.Resolution is not null) return;
                if (current.Questions.All(x => x.Id != questionId)) throw new ArgumentException("Unknown question.", nameof(questionId));
                current.Answers[questionId] = answer;
            }
            await PersistAsyncCore(request.ThreadId);
        }
        finally { gate.Release(); }
    }
    public async Task DismissAsync(AsyncQuestionRequest request)
    {
        await gate.WaitAsync();
        try
        {
            lock (sync) if (asynchronous.TryGetValue(request.Key, out var current)) asynchronous[request.Key] = current with { Resolution = "dismissed" };
            await PersistAsyncCore(request.ThreadId);
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    public async Task SendAsync(ThreadSession session, AsyncQuestionRequest request, ComposerSnapshot settings)
    {
        if (session.Record.VeoId != request.ThreadId) throw new InvalidOperationException("The question belongs to another thread.");
        await gate.WaitAsync();
        try
        {
            AsyncQuestionRequest current;
            lock (sync) current = asynchronous.GetValueOrDefault(request.Key) ?? throw new InvalidOperationException("Unknown question.");
            if (current.Resolution is not null || current.AnswerMessage is not { } message) throw new InvalidOperationException("Answer every question before sending.");
            // Queue first, then resolve: a crash leaves the same durable client identity for reconciliation.
            await workspace.EnqueueContextAsync(session, settings with { ClientId = current.AnswerClientId, Text = message, Attachments = [], StructuredAttachments = [] });
            lock (sync) asynchronous[request.Key] = current with { Resolution = "queued" };
            await PersistAsyncCore(request.ThreadId);
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    Task PersistAsyncCore(string threadId)
    {
        AsyncQuestionRequest[] snapshot;
        lock (sync) snapshot = asynchronous.Values.Where(x => x.ThreadId == threadId).Select(Clone).ToArray();
        return workspace.Threads.SaveStateAsync(threadId, "async-questions", JsonSerializer.Serialize(snapshot));
    }
    static string BlockingKey(RuntimeEvent request) => "blocking-question-" + Convert.ToBase64String(Encoding.UTF8.GetBytes(request.Parameters.Str("itemId") ?? request.Id?.GetRawText() ?? "unknown"));
    static string RuntimeKey(RuntimeEvent request) => request.Generation + ":" + request.Id?.GetRawText();
    public BlockingQuestionDraft BlockingDraft(RuntimeEvent request)
    { lock (sync) return blocking.TryGetValue(RuntimeKey(request), out var draft) ? draft with { Answers = new(draft.Answers, StringComparer.Ordinal), Notes = draft.Notes is null ? null : new(draft.Notes, StringComparer.Ordinal) } : new(new()); }
    public DateTimeOffset? CountdownDeadline(RuntimeEvent request) { lock (sync) return deadlines.GetValueOrDefault(RuntimeKey(request)) is { } value && value != default ? value : null; }
    public async Task OpenBlockingAsync(ThreadSession session, RuntimeEvent request)
    {
        if (request.Parameters.Str("threadId") != session.Record.CodexThreadId) throw new InvalidOperationException("The question belongs to another runtime thread.");
        await gate.WaitAsync();
        try
        {
            var key = RuntimeKey(request);
            lock (sync) if (blocking.ContainsKey(key)) return;
            var raw = await workspace.Threads.ReadStateAsync(session.Record.VeoId, BlockingKey(request));
            var draft = raw is null ? new BlockingQuestionDraft(new()) : JsonSerializer.Deserialize<BlockingQuestionDraft>(raw) ?? new(new());
            lock (sync) blocking[key] = draft;
            if (!Bool(request.Parameters, "isBlocking", true) && !draft.KeepOpen)
            {
                var cancellation = new CancellationTokenSource(); lock (sync) timers[key] = cancellation;
                _ = RunCountdownAsync(session, request, cancellation.Token);
            }
        }
        finally { gate.Release(); }
    }
    public async Task AnswerBlockingAsync(ThreadSession session, RuntimeEvent request, string questionId, string answer)
    {
        await gate.WaitAsync();
        try
        {
            var key = RuntimeKey(request); var draft = BlockingDraft(request); draft.Answers[questionId] = answer;
            lock (sync) blocking[key] = draft with { KeepOpen = true };
            CancelTimer(request);
            await PersistBlockingCore(session, request);
        }
        finally { gate.Release(); }
    }
    public async Task KeepOpenAsync(ThreadSession session, RuntimeEvent request)
    {
        await gate.WaitAsync();
        try
        {
            var draft = BlockingDraft(request); lock (sync) blocking[RuntimeKey(request)] = draft with { KeepOpen = true };
            CancelTimer(request); await PersistBlockingCore(session, request);
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    public async Task NoteBlockingAsync(ThreadSession session, RuntimeEvent request, string questionId, string note)
    {
        await gate.WaitAsync();
        try
        {
            var draft = BlockingDraft(request); var notes = draft.Notes ?? new(); notes[questionId] = note;
            lock (sync) blocking[RuntimeKey(request)] = draft with { Notes = notes, KeepOpen = true };
            CancelTimer(request); await PersistBlockingCore(session, request);
        }
        finally { gate.Release(); }
    }
    public async Task SendBlockingAsync(ThreadSession session, RuntimeEvent request, bool skip = false)
    {
        if (request.Parameters.Str("threadId") != session.Record.CodexThreadId) throw new InvalidOperationException("The question belongs to another runtime thread.");
        await gate.WaitAsync();
        try
        {
            if (!workspace.PendingRequests.Any(x => x.Generation == request.Generation && x.Id?.GetRawText() == request.Id?.GetRawText())) throw new InvalidOperationException("The question is no longer pending.");
            var draft = BlockingDraft(request); var questions = ParseBlocking(request);
            if (!skip && questions.Any(x => string.IsNullOrWhiteSpace(draft.Answers.GetValueOrDefault(x.Id)))) throw new InvalidOperationException("Answer every question or explicitly choose Skip.");
            var answers = questions.ToDictionary(x => x.Id, x => new { answers = skip ? Array.Empty<string>()
                : draft.Notes?.GetValueOrDefault(x.Id) is { Length: > 0 } note ? new[] { draft.Answers[x.Id], "user_note:" + note.Trim() } : new[] { draft.Answers[x.Id] } });
            await workspace.RespondAsync(request, new { answers }); CancelTimer(request);
            // Store a redacted answer receipt independently of runtime-owned history.
            var receipt = string.Join("\n\n", questions.Select(x => x.Title + "\n" + (skip ? "Skipped" : x.Secret ? "••••••" : draft.Answers[x.Id]
                + (draft.Notes?.GetValueOrDefault(x.Id) is { Length: > 0 } note ? "\nNote: " + note : ""))));
            var raw = JsonSerializer.SerializeToElement(new { id = "veo-user-input-answer-" + request.Parameters.Str("itemId"), type = "veoUserInputAnswer", text = receipt, status = "completed" });
            session.Timeline.Upsert(raw, request.Parameters.Str("turnId"));
            await workspace.Threads.SaveItemAsync(session.Record.VeoId, new(raw.Str("id")!, request.Parameters.Str("turnId"), "veoUserInputAnswer", null, "completed", raw.GetRawText(), session.Timeline.Items.Last().Order, DateTimeOffset.UtcNow));
            lock (sync) blocking.Remove(RuntimeKey(request));
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    Task PersistBlockingCore(ThreadSession session, RuntimeEvent request)
    {
        var draft = BlockingDraft(request); var secretIds = ParseBlocking(request).Where(x => x.Secret).Select(x => x.Id).ToHashSet(StringComparer.Ordinal);
        return workspace.Threads.SaveStateAsync(session.Record.VeoId, BlockingKey(request), JsonSerializer.Serialize(draft with
        {
            Answers = draft.Answers.Where(x => !secretIds.Contains(x.Key)).ToDictionary(x => x.Key, x => x.Value),
            Notes = draft.Notes?.Where(x => !secretIds.Contains(x.Key)).ToDictionary(x => x.Key, x => x.Value),
        }));
    }
    async Task RunCountdownAsync(ThreadSession session, RuntimeEvent request, CancellationToken cancellation)
    {
        try
        {
            await Task.Delay(timing.Grace, cancellation);
            lock (sync) deadlines[RuntimeKey(request)] = DateTimeOffset.UtcNow + timing.Countdown;
            Changed?.Invoke(); await Task.Delay(timing.Countdown, cancellation);
            await SendBlockingAsync(session, request, true);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception exception) { LastError = DiagnosticRedactor.Redact(exception.Message); Changed?.Invoke(); }
    }
    void CancelTimer(RuntimeEvent request)
    {
        lock (sync)
        {
            if (timers.Remove(RuntimeKey(request), out var cancellation)) { cancellation.Cancel(); cancellation.Dispose(); }
            deadlines.Remove(RuntimeKey(request));
        }
    }
    async void OnRuntimeEvent(ThreadSession session, RuntimeEvent message)
    {
        if (disposed || message.Method is not ("item/started" or "item/completed") || !message.Parameters.TryObjectProperty("item", out var item) || ParseAsync(item).Length == 0) return;
        await gate.WaitAsync();
        try { if (!disposed) await IngestAsyncCore(session.Record.VeoId, item); }
        catch (Exception exception) { LastError = DiagnosticRedactor.Redact(exception.Message); }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    static bool Bool(JsonElement value, string property, bool fallback = false) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(property, out var result) && result.ValueKind is JsonValueKind.True or JsonValueKind.False ? result.GetBoolean() : fallback;
    static bool Sensitive(string text) => new[] { "secret", "password", "passcode", "credential", "api key", "access token", "private key", "sensitive" }.Any(term => text.Contains(term, StringComparison.OrdinalIgnoreCase));
    public async ValueTask DisposeAsync()
    {
        disposed = true; workspace.RuntimeEventApplied -= OnRuntimeEvent;
        lock (sync) foreach (var timer in timers.Values) { timer.Cancel(); timer.Dispose(); }
        await gate.WaitAsync(); gate.Release();
    }
}
