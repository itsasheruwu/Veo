using System.Text.Json;
using System.Threading.Channels;
using Veo.Protocol;

namespace Veo.Core;

public interface IVoiceAudio : IAsyncDisposable
{
    event Action<ReadOnlyMemory<byte>>? Captured;
    event Action<Exception>? Faulted;
    Task StartAsync(string? inputDevice, string? outputDevice, CancellationToken token);
    Task PlayAsync(ReadOnlyMemory<byte> pcm16, int sampleRate, int channels, CancellationToken token);
    Task StopAsync();
}
public sealed record VoicePreferences(string Protocol = "Automatic", string Output = "audio", string? Voice = null, string? InputDevice = null, string? OutputDevice = null);

/// <summary>Opt-in voice through the same app-server, with bounded audio and generation-safe teardown.</summary>
public sealed class RealtimeVoiceCoordinator : IAsyncDisposable
{
    readonly WorkspaceCoordinator workspace;
    readonly IVoiceAudio audio;
    readonly SemaphoreSlim lifecycle = new(1, 1);
    readonly Channel<(long Epoch, RuntimeEvent Event)> incoming = Channel.CreateBounded<(long, RuntimeEvent)>(new BoundedChannelOptions(32) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
    readonly CancellationTokenSource lifetime = new();
    Channel<ReadOnlyMemory<byte>>? capture;
    CancellationTokenSource? sessionLifetime;
    Task? sender;
    readonly Task receiver;
    string? threadId;
    long runtimeGeneration;
    long sessionEpoch;
    int userStopped;
    TaskCompletionSource? audioReady;
    VoicePreferences? activePreferences;
    int faultScheduled;
    bool disposed;
    public string State { get; private set; } = "Stopped";
    public string Transcript { get; private set; } = "";
    public string? Error { get; private set; }
    public VoicePreferences Preferences { get; private set; } = new();
    public event Action? Changed;
    public RealtimeVoiceCoordinator(WorkspaceCoordinator workspace, IVoiceAudio audio)
    {
        this.workspace = workspace; this.audio = audio;
        workspace.RuntimeEventReceived += OnEvent; workspace.Changed += OnWorkspaceChanged; audio.Captured += OnCaptured; audio.Faulted += OnAudioFault;
        receiver = ReceiveAsync();
    }
    public async Task InitializeAsync()
    {
        if (await workspace.Threads.ReadStateAsync("preferences", "voice") is { } raw) Preferences = JsonSerializer.Deserialize<VoicePreferences>(raw) ?? new();
    }
    public async Task SavePreferencesAsync(VoicePreferences value)
    { Preferences = value; await workspace.Threads.SaveStateAsync("preferences", "voice", JsonSerializer.Serialize(value)); }
    public async Task<string[]> VoicesAsync()
    {
        var response = await workspace.Runtime.RequestAsync("thread/realtime/listVoices");
        var voices = response.GetProperty("voices");
        var key = Preferences.Protocol == "Legacy v2" ? "v2" : "v3";
        if (!voices.TryGetProperty(key, out var list) || list.ValueKind != JsonValueKind.Array) return [];
        return list.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray();
    }
    public async Task StartAsync(ThreadSession session, ComposerSnapshot settings)
    {
        await lifecycle.WaitAsync(lifetime.Token);
        var ownsStart = false;
        try
        {
            if (State is "Starting" or "Listening") throw new InvalidOperationException("Stop the current voice session first.");
            ownsStart = true; activePreferences = Preferences;
            Interlocked.Increment(ref sessionEpoch); Interlocked.Exchange(ref userStopped, 0);
            sessionLifetime = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            audioReady = new(TaskCreationOptions.RunContinuationsAsynchronously);
            capture = Channel.CreateBounded<ReadOnlyMemory<byte>>(new BoundedChannelOptions(8) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
            runtimeGeneration = workspace.Runtime.Generation;
            Error = null; Transcript = ""; State = "Starting"; Changed?.Invoke();
            await workspace.EnsureRuntimeThreadAsync(session, settings, sessionLifetime.Token);
            threadId = session.Record.CodexThreadId; runtimeGeneration = workspace.Runtime.Generation;
            var version = activePreferences.Protocol == "Legacy v2" ? "v2" : "v3";
            var parameters = Parameters(version);
            try { await workspace.Runtime.RequestAsync("thread/realtime/start", parameters, sessionLifetime.Token); }
            catch (CodexRpcException e) when (activePreferences.Protocol == "Automatic" && e.Code == -32602)
            { await workspace.Runtime.RequestAsync("thread/realtime/start", Parameters("v2"), sessionLifetime.Token); }
            sender = SendCaptureAsync(capture.Reader, threadId!, runtimeGeneration, sessionLifetime.Token);
            await audio.StartAsync(activePreferences.InputDevice, activePreferences.OutputDevice, sessionLifetime.Token);
            sessionLifetime.Token.ThrowIfCancellationRequested();
            State = "Listening"; audioReady.TrySetResult(); Changed?.Invoke();
        }
        catch (Exception e)
        {
            if (!ownsStart) throw;
            var stopped = Volatile.Read(ref userStopped) != 0 || disposed;
            if (!stopped) Error ??= DiagnosticRedactor.Redact(e.Message);
            await StopCoreAsync(); State = stopped ? "Stopped" : "Failed"; Changed?.Invoke(); if (!stopped) throw;
        }
        finally { lifecycle.Release(); }
    }
    Dictionary<string, object?> Parameters(string version)
    {
        var values = new Dictionary<string, object?> { ["threadId"] = threadId, ["outputModality"] = activePreferences!.Output, ["voice"] = activePreferences.Voice, ["version"] = version, ["includeStartupContext"] = true, ["transport"] = new { type = "websocket" }, ["voiceSessionId"] = Guid.NewGuid().ToString("N") };
        if (version == "v3") { values["codexResponsesAsItems"] = true; values["codexResponseHandoffMode"] = "commentary"; values["flushTranscriptTailOnSessionEnd"] = true; }
        return values;
    }
    void OnCaptured(ReadOnlyMemory<byte> bytes)
    {
        if (State is not ("Starting" or "Listening") || sessionLifetime?.IsCancellationRequested != false || bytes.IsEmpty) return;
        if (bytes.Length % 2 != 0 || bytes.Length > 48000 || capture?.Writer.TryWrite(bytes.ToArray()) != true) ScheduleFailure("Microphone paused because an audio chunk was invalid or its send queue filled.");
    }
    async Task SendCaptureAsync(ChannelReader<ReadOnlyMemory<byte>> reader, string id, long generation, CancellationToken token)
    {
        try
        {
            await foreach (var bytes in reader.ReadAllAsync(token))
            {
                if (workspace.Runtime.Generation != generation) throw new IOException("The voice runtime disconnected.");
                await workspace.Runtime.RequestAsync("thread/realtime/appendAudio", new { threadId = id, audio = new { data = Convert.ToBase64String(bytes.Span), sampleRate = 24000, numChannels = 1, samplesPerChannel = bytes.Length / 2 } }, token);
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception e) { ScheduleFailure(e.Message); }
    }
    void OnEvent(RuntimeEvent message)
    {
        if (State is "Starting" or "Listening" && message.Method == "account/updated") { ScheduleFailure("The account changed or signed out. Start voice again after checking Account."); return; }
        if (threadId is null || message.Generation != runtimeGeneration || message.Method is not { } method || !method.StartsWith("thread/realtime/", StringComparison.Ordinal) || message.Parameters.Str("threadId") != threadId) return;
        if (!incoming.Writer.TryWrite((Interlocked.Read(ref sessionEpoch), message))) ScheduleFailure("Voice playback paused because its event queue filled.");
    }
    void OnWorkspaceChanged()
    { if (State is "Starting" or "Listening" && (workspace.Runtime.RuntimeState != CodexRuntimeState.Ready || workspace.Runtime.Generation != runtimeGeneration)) ScheduleFailure("The local voice runtime disconnected or was replaced."); }
    async Task ReceiveAsync()
    {
        try
        {
            await foreach (var (epoch, message) in incoming.Reader.ReadAllAsync(lifetime.Token))
            {
                if (epoch != Interlocked.Read(ref sessionEpoch) || threadId is null || message.Generation != runtimeGeneration || message.Parameters.Str("threadId") != threadId || State is not ("Listening" or "Starting")) continue;
                var token = sessionLifetime?.Token ?? lifetime.Token;
                try
                {
                var p = message.Parameters;
                if (message.Method == "thread/realtime/outputAudio/delta" && activePreferences?.Output == "audio" && p.TryGetProperty("audio", out var chunk))
                {
                    var (bytes, rate, channels) = DecodeAudio(chunk);
                    if (audioReady is { } ready) await ready.Task.WaitAsync(token);
                    if (epoch == Interlocked.Read(ref sessionEpoch) && bytes.Length > 0) await audio.PlayAsync(bytes, rate, channels, token);
                }
                else if (message.Method == "thread/realtime/transcript/delta")
                { AppendTranscript(p.Str("delta") ?? ""); }
                else if (message.Method == "thread/realtime/transcript/done")
                { if (p.Str("text") is { Length: > 0 } text && !Transcript.EndsWith(text, StringComparison.Ordinal)) AppendTranscript((Transcript.Length > 0 ? "\n" : "") + text); }
                else if (message.Method == "thread/realtime/error") ScheduleFailure(p.Str("message") ?? "The realtime session failed.");
                else if (message.Method == "thread/realtime/closed") await StopAsync();
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { }
                catch (Exception e) { if (epoch == Interlocked.Read(ref sessionEpoch)) ScheduleFailure(e.Message); }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception e) { ScheduleFailure(e.Message); }
    }
    void AppendTranscript(string text)
    { Transcript += text; if (Transcript.Length > 65536) Transcript = "[Earlier realtime transcript omitted]\n" + Transcript[^65490..]; Changed?.Invoke(); }
    public static (byte[] Pcm, int SampleRate, int Channels) DecodeAudio(JsonElement chunk)
    {
        var data = chunk.Str("data") ?? throw new InvalidDataException("Audio chunk has no PCM data.");
        if (data.Length > 1024 * 1024) throw new InvalidDataException("Audio chunk exceeds the playback bound.");
        if (!chunk.TryGetProperty("sampleRate", out var r) || r.ValueKind != JsonValueKind.Number || !r.TryGetInt32(out var rate) || !chunk.TryGetProperty("numChannels", out var c) || c.ValueKind != JsonValueKind.Number || !c.TryGetInt32(out var channels)) throw new InvalidDataException("Audio metadata is invalid.");
        if (rate is < 8000 or > 192000 || channels is < 1 or > 8) throw new InvalidDataException("Unsupported audio format.");
        byte[] bytes; try { bytes = Convert.FromBase64String(data); } catch (FormatException e) { throw new InvalidDataException("Audio data is not valid base64 PCM.", e); }
        if (bytes.Length % (channels * 2) != 0 || bytes.Length > (long)rate * channels * 4) throw new InvalidDataException("Incomplete or oversized PCM16 audio frame.");
        if (chunk.TryGetProperty("samplesPerChannel", out var count) && count.ValueKind != JsonValueKind.Null && (count.ValueKind != JsonValueKind.Number || !count.TryGetInt32(out var samples) || samples != bytes.Length / (channels * 2))) throw new InvalidDataException("PCM sample count does not match the chunk.");
        return (bytes, rate, channels);
    }
    void OnAudioFault(Exception e) => ScheduleFailure(e.Message);
    void ScheduleFailure(string error)
    {
        if (disposed || State is not ("Starting" or "Listening") || Volatile.Read(ref userStopped) != 0) return;
        if (Interlocked.CompareExchange(ref faultScheduled, 1, 0) != 0) return;
        var epoch = Interlocked.Read(ref sessionEpoch);
        Error = DiagnosticRedactor.Redact(error);
        sessionLifetime?.Cancel(); audioReady?.TrySetCanceled();
        _ = Task.Run(async () => { await lifecycle.WaitAsync(); try { if (epoch != Interlocked.Read(ref sessionEpoch) || disposed) return; Error = DiagnosticRedactor.Redact(error); await StopCoreAsync(); State = "Failed"; Changed?.Invoke(); } finally { lifecycle.Release(); Interlocked.Exchange(ref faultScheduled, 0); } });
    }
    public async Task StopAsync()
    { Interlocked.Exchange(ref userStopped, 1); sessionLifetime?.Cancel(); audioReady?.TrySetCanceled(); await lifecycle.WaitAsync(); try { await StopCoreAsync(); State = "Stopped"; Changed?.Invoke(); } finally { lifecycle.Release(); } }
    async Task StopCoreAsync()
    {
        Interlocked.Increment(ref sessionEpoch); sessionLifetime?.Cancel(); audioReady?.TrySetCanceled(); capture?.Writer.TryComplete();
        try { await audio.StopAsync(); } catch (Exception e) { Error ??= DiagnosticRedactor.Redact(e.Message); }
        if (sender is not null) await sender; sender = null; capture = null;
        if (threadId is { } id && workspace.Runtime.RuntimeState == CodexRuntimeState.Ready && workspace.Runtime.Generation == runtimeGeneration)
        { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); try { await workspace.Runtime.RequestAsync("thread/realtime/stop", new { threadId = id }, timeout.Token); } catch (Exception e) when (e is OperationCanceledException or CodexRpcException or IOException or NotSupportedException or InvalidOperationException) { Error ??= DiagnosticRedactor.Redact(e.Message); } }
        threadId = null; sessionLifetime?.Dispose(); sessionLifetime = null;
    }
    public async ValueTask DisposeAsync()
    {
        if (disposed) return; disposed = true;
        workspace.RuntimeEventReceived -= OnEvent; workspace.Changed -= OnWorkspaceChanged; audio.Captured -= OnCaptured; audio.Faulted -= OnAudioFault;
        await StopAsync(); lifetime.Cancel(); incoming.Writer.TryComplete(); await receiver; await audio.DisposeAsync(); lifetime.Dispose();
    }
}
