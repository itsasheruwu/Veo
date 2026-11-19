using System.Text.Json;
using Veo.Core;
using Veo.Protocol;
using Veo.Platform.Windows.Audio;

if (args.Contains("--voice-server")) { await ServerAsync(args); return; }
var passed = 0;
var parent = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Veo-Voice-Tests"));
var root = Path.Combine(parent, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
var self = Path.Combine(AppContext.BaseDirectory, "Veo.Voice.Tests.exe");
try
{
    var frames = Enumerable.Range(0, 24576).Select(x => (byte)x).ToArray();
    var packets = Pcm16Packets.Split(frames, 3).ToArray();
    Assert(packets.All(p => p.Length <= 4096 && p.Length % 6 == 0) && packets.SelectMany(p => p.ToArray()).SequenceEqual(frames), "bounded playback packetization preserves exact interleaved PCM16 frames");
    Throws(() => Pcm16Packets.Split(new byte[5], 2).ToArray(), "partial multichannel playback frame refused");
    var decoded = RealtimeVoiceCoordinator.DecodeAudio(Json(new { data = Convert.ToBase64String(new byte[] { 0, 128, 255, 127 }), sampleRate = 44100, numChannels = 2, samplesPerChannel = 1 }));
    Assert(decoded.SampleRate == 44100 && decoded.Channels == 2 && decoded.Pcm.SequenceEqual(new byte[] { 0, 128, 255, 127 }), "incoming rate channels and signed PCM bytes preserved");
    foreach (var invalid in new object[]
    {
        new { data = "invalid%%", sampleRate = 24000, numChannels = 1 },
        new { data = "AA==", sampleRate = 24000, numChannels = 1 },
        new { data = "AAAAAA==", sampleRate = 24000, numChannels = 0 },
        new { data = "AAAAAA==", sampleRate = 7999, numChannels = 1 },
        new { data = "AAAAAA==", sampleRate = 24000, numChannels = 1, samplesPerChannel = 99 },
        new { data = new string('A', 1024 * 1024 + 4), sampleRate = 24000, numChannels = 1 }
    }) Throws(() => RealtimeVoiceCoordinator.DecodeAudio(Json(invalid)), "invalid or oversized incoming audio refused");

    await Scenario("normal", async (workspace, voice, audio, thread, trace) =>
    {
        Assert(audio.Starts == 0 && !audio.Active, "constructing the voice surface/coordinator never starts capture");
        await voice.StartAsync(thread, Settings());
        await Until(() => audio.Played.Count > 0 && Trace(trace, "thread/realtime/appendAudio").Count > 0 && voice.Transcript == "hello");
        var sent = Trace(trace, "thread/realtime/appendAudio").First().GetProperty("params").GetProperty("audio");
        Assert(sent.GetProperty("sampleRate").GetInt32() == 24000 && sent.GetProperty("numChannels").GetInt32() == 1 && sent.GetProperty("samplesPerChannel").GetInt32() == 2 && Convert.FromBase64String(sent.Str("data")!).SequenceEqual(new byte[] { 10, 0, 20, 0 }), "first synchronous capture while Starting sends exact PCM24k mono metadata and copied bytes");
        Assert(!audio.PlayedBeforeStart && audio.Played.First().Rate == 48000 && audio.Played.First().Channels == 2, "pre-ack output audio waits for the audio-ready barrier with its actual format");
        Assert(voice.Transcript == "hello", "transcript done does not duplicate the same completed passage");
        try { await voice.StartAsync(thread, Settings()); throw new Exception("Expected duplicate start refusal."); } catch (InvalidOperationException) { }
        Assert(voice.State == "Listening" && audio.Active, "duplicate Start refusal leaves the current voice session active");
        await voice.StopAsync(); Assert(!audio.Active && voice.State == "Stopped" && Trace(trace, "thread/realtime/stop").Count > 0, "explicit stop closes capture playback and the matching remote session");
    });
    await Scenario("slow-start", async (_, voice, audio, thread, trace) =>
    {
        var starting = voice.StartAsync(thread, Settings());
        await Until(() => Trace(trace, "thread/realtime/start").Count > 0);
        await voice.StopAsync(); await starting;
        Assert(audio.Starts == 0 && !audio.Active && voice.State == "Stopped", "Stop cancels a pending start before microphone capture can begin");
    });
    await Scenario("bad-first", async (_, voice, audio, thread, _) =>
    {
        try { await voice.StartAsync(thread, Settings()); } catch (Exception error) when (error is OperationCanceledException or InvalidDataException) { }
        await Until(() => voice.State == "Failed" && !audio.Active);
        await voice.StartAsync(thread, Settings());
        await Until(() => audio.Played.Count > 0 && voice.Transcript == "hello");
        Assert(voice.State == "Listening", "bad audio ends only its session and the receiver serves the next explicit start");
    });
    await Scenario("normal", async (workspace, voice, audio, thread, _) =>
    {
        await voice.StartAsync(thread, Settings());
        try { await workspace.Runtime.RequestAsync("fixture/die"); } catch (IOException) { }
        await Until(() => voice.State == "Failed" && !audio.Active);
        Assert(audio.Stops > 0, "runtime death stops capture without requiring another microphone packet");
    });
    await Scenario("normal", async (workspace, voice, audio, thread, _) =>
    {
        await voice.StartAsync(thread, Settings()); await workspace.Runtime.RequestAsync("fixture/logout");
        await Until(() => voice.State == "Failed" && !audio.Active);
        Assert(audio.Stops > 0, "global logout notification stops capture even without a thread ID");
    });
    await Scenario("normal", async (workspace, voice, audio, thread, _) =>
    {
        await voice.StartAsync(thread, Settings()); await workspace.Runtime.RequestAsync("fixture/closed");
        await Until(() => voice.State == "Stopped" && !audio.Active);
        Assert(audio.Stops > 0, "remote close stops capture and playback");
    });
    await Scenario("normal", async (_, voice, audio, thread, _) =>
    {
        await voice.StartAsync(thread, Settings()); audio.Fail(new IOException("Synthetic microphone unplugged"));
        await Until(() => voice.State == "Failed" && !audio.Active);
        Assert(voice.Error!.Contains("unplugged"), "device failure retains a useful error and stops capture");
    });
    await Scenario("hold-capture", async (_, voice, audio, thread, _) =>
    {
        await voice.StartAsync(thread, Settings());
        for (var i = 0; i < 20; i++) audio.Emit(new byte[2400]);
        await Until(() => voice.State == "Failed" && !audio.Active);
        Assert(voice.Error!.Contains("queue"), "capture queue overflow ends capture with bounded backlog");
    });
    await Scenario("fallback", async (_, voice, audio, thread, trace) =>
    {
        await voice.StartAsync(thread, Settings());
        Assert(Trace(trace, "thread/realtime/start").Select(x => x.GetProperty("params").Str("version")).SequenceEqual(new[] { "v3", "v2" }), "Automatic falls back only after a protocol-version rejection");
        await voice.DisposeAsync(); Assert(!audio.Active && audio.Disposed, "application disposal closes audio ownership");
    });
    Console.WriteLine($"{passed} voice checks passed using fixture pipes and FakeAudio. No microphone was captured and no speaker was played.");
}
finally { if (Path.GetDirectoryName(root) == parent && Guid.TryParseExact(Path.GetFileName(root), "N", out _)) Directory.Delete(root, true); }

async Task Scenario(string name, Func<WorkspaceCoordinator, RealtimeVoiceCoordinator, FakeAudio, ThreadSession, string, Task> test)
{
    var directory = Path.Combine(root, name + "-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory); var trace = Path.Combine(directory, "trace.jsonl");
    await using var workspace = new WorkspaceCoordinator(directory, _ => new(new CodexRuntimeOptions { ExecutablePath = self, AdditionalArguments = ["--voice-server", "--scenario=" + name, "--trace=" + trace] }));
    await workspace.InitializeAsync(); var thread = await workspace.CreateAsync(); var audio = new FakeAudio();
    await using var voice = new RealtimeVoiceCoordinator(workspace, audio); await voice.InitializeAsync();
    await test(workspace, voice, audio, thread, trace).WaitAsync(TimeSpan.FromSeconds(15));
}
ComposerSnapshot Settings() => new("unused", "", "fixture-model", "medium", null, "Workspace", "Agentic", []);
static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value);
static List<JsonElement> Trace(string file, string method)
{
    if (!File.Exists(file)) return [];
    using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
    using var reader = new StreamReader(stream); var text = reader.ReadToEnd(); var last = text.LastIndexOf('\n');
    return last < 0 ? [] : text[..last].Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(x => JsonSerializer.Deserialize<JsonElement>(x)).Where(x => x.Str("method") == method).ToList();
}
void Assert(bool condition, string label) { if (!condition) throw new Exception("FAIL " + label); passed++; Console.WriteLine("PASS " + label); }
void Throws(Action action, string label) { try { action(); } catch (InvalidDataException) { Assert(true, label); return; } throw new Exception("FAIL " + label); }
static async Task Until(Func<bool> condition) { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(6)); while (!condition()) await Task.Delay(20, timeout.Token); }

static async Task ServerAsync(string[] arguments)
{
    var scenario = arguments.Single(x => x.StartsWith("--scenario="))[11..]; var trace = arguments.Single(x => x.StartsWith("--trace="))[8..]; var starts = 0;
    while (await Console.In.ReadLineAsync() is { } line)
    {
        using var document = JsonDocument.Parse(line); var request = document.RootElement; if (!request.TryGetProperty("id", out var id)) continue;
        await File.AppendAllTextAsync(trace, line + "\n"); var method = request.Str("method");
        switch (method)
        {
            case "initialize": await Write(new { id, result = new { userAgent = "voice-fixture0.169.0" } }); break;
            case "model/list": await Write(new { id, result = new { data = new[] { new { id = "fixture-model", model = "fixture-model", displayName = "Fixture" } } } }); break;
            case "account/read": await Write(new { id, result = new { account = (object?)null, requiresOpenaiAuth = false } }); break;
            case "thread/start": await Write(new { id, result = new { thread = new { id = "runtime-thread" } } }); break;
            case "thread/realtime/start":
                starts++;
                if (scenario == "fallback" && request.GetProperty("params").Str("version") == "v3") { await Write(new { id, error = new { code = -32602, message = "Synthetic unsupported v3" } }); break; }
                if (scenario == "slow-start") await Task.Delay(350);
                await Write(new { method = "thread/realtime/outputAudio/delta", @params = new { threadId = "runtime-thread", audio = new { data = scenario == "bad-first" && starts == 1 ? "bad%%" : "AQACAA==", sampleRate = 48000, numChannels = 2, samplesPerChannel = 1 } } });
                await Write(new { method = "thread/realtime/transcript/delta", @params = new { threadId = "runtime-thread", delta = "hello", role = "assistant" } });
                await Write(new { method = "thread/realtime/transcript/done", @params = new { threadId = "runtime-thread", text = "hello" } });
                await Task.Delay(80); await Write(new { id, result = new { } }); break;
            case "thread/realtime/appendAudio": if (scenario != "hold-capture") await Write(new { id, result = new { } }); break;
            case "fixture/die": Environment.Exit(42); break;
            case "fixture/logout": await Write(new { method = "account/updated", @params = new { authMode = (string?)null } }); await Write(new { id, result = new { } }); break;
            case "fixture/closed": await Write(new { method = "thread/realtime/closed", @params = new { threadId = "runtime-thread" } }); await Write(new { id, result = new { } }); break;
            default: await Write(new { id, result = new { } }); break;
        }
    }
    static async Task Write(object value) { await Console.Out.WriteLineAsync(JsonSerializer.Serialize(value)); await Console.Out.FlushAsync(); }
}

sealed class FakeAudio : IVoiceAudio
{
    public event Action<ReadOnlyMemory<byte>>? Captured;
    public event Action<Exception>? Faulted;
    public int Starts, Stops;
    public bool Active, Disposed, PlayedBeforeStart;
    public System.Collections.Concurrent.ConcurrentQueue<(byte[] Bytes, int Rate, int Channels)> Played { get; } = new();
    public Task StartAsync(string? inputDevice, string? outputDevice, CancellationToken token)
    { token.ThrowIfCancellationRequested(); Starts++; Active = true; var bytes = new byte[] { 10, 0, 20, 0 }; Captured?.Invoke(bytes); Array.Fill<byte>(bytes, 255); return Task.CompletedTask; }
    public Task PlayAsync(ReadOnlyMemory<byte> pcm, int rate, int channels, CancellationToken token)
    { token.ThrowIfCancellationRequested(); if (!Active) PlayedBeforeStart = true; Played.Enqueue((pcm.ToArray(), rate, channels)); return Task.CompletedTask; }
    public Task StopAsync() { Stops++; Active = false; return Task.CompletedTask; }
    public void Emit(byte[] bytes) => Captured?.Invoke(bytes);
    public void Fail(Exception error) => Faulted?.Invoke(error);
    public async ValueTask DisposeAsync() { await StopAsync(); Disposed = true; }
}
