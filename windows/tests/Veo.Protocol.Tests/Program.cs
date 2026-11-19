using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Veo.Protocol;

if (await SchemaProbeChecks.TryRunFixtureAsync(args)) return;
if (args.Contains("--fake-server")) { await FakeServer(); return; }
var passed = 0;
await Check("split UTF-8, CRLF and multiple frames", () =>
{
    using var framer = new NdjsonFramer();
    var payload = Encoding.UTF8.GetBytes("{\"method\":\"第一🙂\"}\r\n{\"id\":4,\"result\":null}\n");
    var frames = new List<JsonElement>();
    foreach (var value in payload) frames.AddRange(framer.Append([value]));
    framer.Complete();
    Assert(frames.Count == 2 && frames[0].GetProperty("method").GetString() == "第一🙂", "Framing changed Unicode.");
    return Task.CompletedTask;
});
await Check("oversized and truncated frames fail explicitly", () =>
{
    using var framer = new NdjsonFramer(4);
    Throws<InvalidDataException>(() => framer.Append("12345"u8));
    using var truncated = new NdjsonFramer();
    truncated.Append("{\"id\":"u8);
    Throws<EndOfStreamException>(truncated.Complete);
    return Task.CompletedTask;
});
await Check("diagnostics redact credentials", () =>
{
    var redacted = DiagnosticRedactor.Redact("Authorization: Bearer abcdefghijklmnop; api_key=sk-abcdefghijklmnopqrst password='secret123'");
    Assert(!redacted.Contains("abcdefghijklmnop") && !redacted.Contains("secret123"), "Credential leaked.");
    return Task.CompletedTask;
});
await Check("explicit missing executable does not fall back", () =>
{
    Assert(CodexExecutableDiscovery.Resolve(Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".exe")) is null, "Explicit invalid path fell back.");
    return Task.CompletedTask;
});

var self = Path.Combine(AppContext.BaseDirectory, "Veo.Protocol.Tests.exe");
if (!OperatingSystem.IsWindows()) self = Path.Combine(AppContext.BaseDirectory, "Veo.Protocol.Tests");
CodexRuntimeOptions FakeOptions() => new() { ExecutablePath = self, AdditionalArguments = ["--fake-server"], EventCapacity = 16 };
await SchemaProbeChecks.RunAsync(self, (name, test) => Check(name, test));
await Check("real pipes initialize, correlate concurrent replies and preserve raw unknown fields", async () =>
{
    await using var runtime = new CodexRuntimeService(FakeOptions());
    await runtime.StartAsync();
    Assert(runtime.State == "Ready", "Initialize did not become ready.");
    var replies = await Task.WhenAll(Enumerable.Range(0, 100).Select(i => runtime.RequestAsync("test/echo", new { i })));
    for (var i = 0; i < replies.Length; i++) Assert(replies[i].GetProperty("i").GetInt32() == i, "Wrong request reply.");
    var reversed = await Task.WhenAll(Enumerable.Range(0, 10).Select(i => runtime.RequestAsync("test/reverse", new { i })));
    for (var i = 0; i < reversed.Length; i++) Assert(reversed[i].GetProperty("i").GetInt32() == i, "Out-of-order response had wrong owner.");
    var unknown = await runtime.RequestAsync("test/unknown");
    Assert(unknown.GetProperty("future").GetProperty("value").GetString() == "retained", "Unknown JSON was lost.");
});
await Check("bounded event stream retains order and string server IDs", async () =>
{
    await using var runtime = new CodexRuntimeService(FakeOptions());
    await runtime.StartAsync();
    using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(15));
    var seen = new List<int>();
    var consume = Task.Run(async () =>
    {
        await foreach (var item in runtime.ReadEventsAsync(cancellation.Token))
        {
            if (item.Method == "test/event") seen.Add(item.Parameters.GetProperty("sequence").GetInt32());
            if (item.IsServerRequest) await runtime.RespondAsync(item, new { answered = true }, cancellation.Token);
            if (seen.Count == 100 && item.Method == "test/done") return;
        }
    });
    await runtime.RequestAsync("test/events", cancellationToken: cancellation.Token);
    await consume;
    Assert(seen.SequenceEqual(Enumerable.Range(0, 100)), "Notification order changed.");
});
await Check("cancellation removes request without replay or stopping runtime", async () =>
{
    await using var runtime = new CodexRuntimeService(FakeOptions());
    await runtime.StartAsync();
    using var cancellation = new CancellationTokenSource(150);
    await ThrowsAsync<OperationCanceledException>(() => runtime.RequestAsync("test/wait", cancellationToken: cancellation.Token));
    var response = await runtime.RequestAsync("test/echo", new { i = 7 });
    Assert(response.GetProperty("i").GetInt32() == 7, "Cancellation damaged subsequent requests.");
});
await Check("process death fails pending requests; reconnect invalidates server generations", async () =>
{
    await using var runtime = new CodexRuntimeService(FakeOptions());
    await runtime.StartAsync();
    var oldGeneration = runtime.Generation;
    var processId = runtime.ProcessId!.Value;
    var pending = runtime.RequestAsync("test/wait");
    await ThrowsAsync<IOException>(() => runtime.RequestAsync("test/die"));
    await ThrowsAsync<IOException>(() => pending);
    await runtime.StartAsync();
    Assert(runtime.Generation != oldGeneration && runtime.State == "Ready", "Reconnect did not replace the generation.");
    using var id = JsonDocument.Parse("\"old-request\"");
    await ThrowsAsync<InvalidOperationException>(() => runtime.RespondAsync(oldGeneration, id.RootElement, new { ok = true }));
    try { using var oldProcess = Process.GetProcessById(processId); Assert(oldProcess.HasExited, "Old runtime remains alive."); } catch (ArgumentException) { }
});
await Check("method-not-found marks capability unavailable", async () =>
{
    await using var runtime = new CodexRuntimeService(FakeOptions());
    await runtime.StartAsync();
    await ThrowsAsync<CodexRpcException>(() => runtime.RequestAsync("test/missing"));
    Assert(runtime.Capabilities.Availability("test/missing") == CapabilityAvailability.Unavailable, "Method remained available.");
    await ThrowsAsync<NotSupportedException>(() => runtime.RequestAsync("test/missing"));
});
await Check("replacing the runtime service invalidates stale UI server requests across instances", async () =>
{
    RuntimeEvent stale;
    await using (var original = new CodexRuntimeService(FakeOptions()))
    {
        await original.StartAsync();
        stale = new(original.Generation, JsonSerializer.SerializeToElement(new { id = "old-instance-question", method = "test/question", @params = new { } }));
    }
    await using var replacement = new CodexRuntimeService(FakeOptions());
    await replacement.StartAsync();
    Assert(replacement.Generation != stale.Generation, "A new service reused its predecessor's generation.");
    await ThrowsAsync<InvalidOperationException>(() => replacement.RespondAsync(stale, new { answered = true }));
    await ThrowsAsync<InvalidOperationException>(() => replacement.RespondErrorAsync(stale, -32601, "stale"));
    var echo = await replacement.RequestAsync("test/echo", new { i = 99 });
    Assert(echo.GetProperty("i").GetInt32() == 99, "Stale rejection damaged the replacement runtime.");
});

var schema = args.FirstOrDefault(argument => argument.StartsWith("--schema="))?[9..];
if (schema != null)
{
    await Check("installed CLI schema inventories all directions", () =>
    {
        var registry = CapabilityRegistry.Load(schema);
        Assert(registry.Availability("initialize") == CapabilityAvailability.Available, "Initialize missing from schema.");
        Assert(registry.Availability("thread/start") == CapabilityAvailability.Available, "thread/start missing from schema.");
        Assert(registry.Methods(ProtocolDirection.ServerRequest).Contains("item/tool/call"), "Dynamic tool server request missing.");
        Assert(CodexCapabilities.All.Count == 43, "Mac capability inventory incomplete.");
        Assert(registry.Availability(CodexCapabilities.All.Single(capability => capability.Name == "dynamicTools")) == CapabilityAvailability.Available, "Server-request workflow was treated as a client method.");
        var login = CodexCapabilities.All.Single(capability => capability.Name == "accountLogin");
        registry.RecordUnavailable("account/login/cancel", "test rejection");
        Assert(registry.Availability(login) == CapabilityAvailability.Unavailable, "Partial all-method workflow remained available.");
        foreach (var direction in Enum.GetValues<ProtocolDirection>()) Console.WriteLine($"  {direction}: {registry.Methods(direction).Count} methods");
        return Task.CompletedTask;
    });
}
if (args.Contains("--real"))
{
    await Check("installed Codex stdio initialize and live model inventory (no turn)", async () =>
    {
        await using var runtime = new CodexRuntimeService(new CodexRuntimeOptions { SchemaDirectory = schema ?? Path.Combine(AppContext.BaseDirectory, "LiveSchema"), GenerateSchemaOnStart = args.Contains("--probe-real-schema") });
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        await runtime.StartAsync(timeout.Token);
        var models = await runtime.RequestAsync("model/list", new { limit = 100 }, timeout.Token);
        Assert(models.TryGetProperty("data", out var data) && data.GetArrayLength() > 0, "No live models.");
        Console.WriteLine($"  Runtime {runtime.ExecutablePath}; models {data.GetArrayLength()}; generation {runtime.Generation}");
        if (runtime.SchemaProvenance is { } provenance) Console.WriteLine($"  Selected CLI {provenance.CliVersion}; SHA256 {provenance.BinarySha256}; exported client methods {runtime.Capabilities.Methods(ProtocolDirection.ClientRequest).Count}");
    });
}
Console.WriteLine($"PASS: {passed} protocol checks.");

async Task Check(string name, Func<Task> test)
{
    await test().WaitAsync(TimeSpan.FromSeconds(75));
    passed++;
    Console.WriteLine("PASS " + name);
}
static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
static void Throws<T>(Action action) where T : Exception
{
    try { action(); } catch (T) { return; }
    throw new InvalidOperationException($"Expected {typeof(T).Name}.");
}
static async Task ThrowsAsync<T>(Func<Task> action) where T : Exception
{
    try { await action(); } catch (T) { return; }
    throw new InvalidOperationException($"Expected {typeof(T).Name}.");
}

static async Task FakeServer()
{
    // A real child process fixture exercises OS pipes and process ownership without touching credentials or real threads.
    long? eventsRequest = null;
    var reverseRequests = new List<(long Id, JsonElement Parameters)>();
    while (await Console.In.ReadLineAsync() is { } line)
    {
        using var document = JsonDocument.Parse(line);
        var message = document.RootElement;
        if (!message.TryGetProperty("method", out var method))
        {
            if (eventsRequest is { } original)
            {
                await Write(new { id = original, result = new { ok = true } });
                await Write(new { method = "test/done", @params = new { } });
                eventsRequest = null;
            }
            continue;
        }
        var name = method.GetString();
        if (!message.TryGetProperty("id", out var requestId)) continue;
        var id = requestId.GetInt64();
        switch (name)
        {
            case "initialize":
                await Console.Error.WriteLineAsync("fixture diagnostics: api_key=sk-not-a-real-secret-abcdefghijklmnop");
                await Write(new { id, result = new { userAgent = "fixture 0.169.0", future = true } }); break;
            case "test/echo": await Write(new { id, result = message.GetProperty("params").Clone() }); break;
            case "test/reverse":
                reverseRequests.Add((id, message.GetProperty("params").Clone()));
                if (reverseRequests.Count == 10)
                {
                    foreach (var reverse in reverseRequests.AsEnumerable().Reverse()) await Write(new { id = reverse.Id, result = reverse.Parameters });
                    reverseRequests.Clear();
                }
                break;
            case "test/unknown": await Write(new { id, result = new { future = new { value = "retained" } } }); break;
            case "test/events":
                for (var i = 0; i < 100; i++) await Write(new { method = "test/event", @params = new { sequence = i } });
                eventsRequest = id;
                await Write(new { id = "question-string-id", method = "test/question", @params = new { } }); break;
            case "test/wait": break;
            case "test/die": Environment.Exit(42); break;
            default: await Write(new { id, error = new { code = -32601, message = "Method unavailable" } }); break;
        }
    }
    static async Task Write(object value) { await Console.Out.WriteLineAsync(JsonSerializer.Serialize(value)); await Console.Out.FlushAsync(); }
}
