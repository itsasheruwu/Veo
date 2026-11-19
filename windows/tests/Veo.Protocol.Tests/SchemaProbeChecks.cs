using System.Diagnostics;
using System.Text.Json;
using Veo.Protocol;

static class SchemaProbeChecks
{
    public static async Task RunAsync(string self, Func<string, Func<Task>, Task> check)
    {
        var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Veo-Schema-Tests", Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(root);
        var copied = Path.Combine(AppContext.BaseDirectory, "selected-schema-fixture-" + Guid.NewGuid().ToString("N") + ".exe");
        var versionFailure = Path.Combine(AppContext.BaseDirectory, "version-failure-" + Guid.NewGuid().ToString("N") + ".exe");
        try
        {
            File.Copy(self, copied); File.Copy(self, versionFailure);
            CodexRuntimeOptions Options(string directory, string? executable = null) => new() { ExecutablePath = executable ?? self, SchemaDirectory = Path.Combine(root, directory), GenerateSchemaOnStart = true, SchemaGenerationTimeout = TimeSpan.FromSeconds(5), VersionProbeTimeout = TimeSpan.FromSeconds(5), AdditionalArguments = ["--fake-server"] };
            await check("exact selected CLI version, binary provenance and exported schema replace shipped assumptions", async () =>
            {
                var options = Options("selected", copied);
                await using var runtime = new CodexRuntimeService(options);
                Assert(!runtime.Capabilities.HasSchema, "Unproven startup schema was advertised.");
                await runtime.StartAsync();
                Assert(runtime.State == "Ready" && runtime.SelectedCliVersion!.Contains(Path.GetFileName(copied)), "The selected native CLI did not supply its own version.");
                var provenance = runtime.SchemaProvenance ?? throw new InvalidOperationException("Missing schema provenance.");
                Assert(provenance.ExecutablePath == copied && provenance.BinarySha256.Length == 64, "Missing exact selected executable provenance.");
                Assert(runtime.Capabilities.Availability("test/selected-schema") == CapabilityAvailability.Available && runtime.Capabilities.SchemaDirectory == provenance.SchemaDirectory, "Capabilities were loaded from another schema.");
                Assert(File.Exists(Path.Combine(provenance.SchemaDirectory, "schema-provenance.json")), "Schema provenance was not persisted.");
                var echo = await runtime.RequestAsync("test/echo", new { i = 42 }); Assert(echo.GetProperty("i").GetInt32() == 42, "Schema probing corrupted stdio runtime initialization.");
                await runtime.StopAsync(); await runtime.StartAsync();
                Assert(Directory.GetDirectories(options.SchemaDirectory!, "generation-*").Length == 1, "Old owned schema generations accumulated.");
            });
            await check("version probe failure faults with repair and never starts a conversation runtime", async () =>
            {
                await using var runtime = new CodexRuntimeService(Options("version", versionFailure));
                await FailureAsync(runtime);
                Assert(runtime.State == "Faulted" && runtime.ProcessId is null && runtime.LastError!.Contains("Runtime settings") && !runtime.LastError.Contains("secret-value"), "Version failure silently fell back or exposed diagnostics.");
            });
            await check("schema export failure cannot reuse stale capability evidence", async () =>
            {
                var options = Options("schema-export-failure"); Directory.CreateDirectory(options.SchemaDirectory!);
                await WriteSchemaAsync(options.SchemaDirectory!);
                await using var runtime = new CodexRuntimeService(options);
                await FailureAsync(runtime);
                Assert(!runtime.Capabilities.HasSchema && runtime.State == "Faulted" && runtime.ProcessId is null, "Failed export reused stale methods or launched the server.");
                Assert(!Directory.GetDirectories(options.SchemaDirectory!, "generation-*").Any(), "Partial owned export directory was retained.");
            });
            await check("schema probe timeout kills the owned process and preserves explicit unavailable state", async () =>
            {
                var options = Options("schema-export-timeout") with { SchemaGenerationTimeout = TimeSpan.FromSeconds(1) };
                await using var runtime = new CodexRuntimeService(options);
                await FailureAsync(runtime);
                Assert(runtime.State == "Faulted" && runtime.LastError!.Contains("timeout") && runtime.ProcessId is null, "Schema timeout was not surfaced as a startup repair.");
                var pidPath = Path.Combine(options.SchemaDirectory!, "probe-pid.txt");
                Assert(File.Exists(pidPath), "The timeout fixture never reached its owned process.");
                var pid = int.Parse(await File.ReadAllTextAsync(pidPath));
                try { using var process = Process.GetProcessById(pid); Assert(process.HasExited, "Timed-out CLI probe remains alive."); } catch (ArgumentException) { }
            });
            await check("bounded probe output rejects flooding without poisoning protocol stdout", async () =>
            {
                await using var runtime = new CodexRuntimeService(Options("schema-export-flood"));
                await FailureAsync(runtime);
                Assert(runtime.State == "Faulted" && runtime.LastError!.Contains("output limit") && runtime.ProcessId is null, "Probe output was unbounded or mixed into app-server parsing.");
            });
        }
        finally
        {
            File.Delete(copied); File.Delete(versionFailure);
            var expectedParent = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Veo-Schema-Tests"));
            if (Path.GetDirectoryName(root) == expectedParent && Guid.TryParseExact(Path.GetFileName(root), "N", out _)) Directory.Delete(root, recursive: true);
        }
    }

    public static async Task<bool> TryRunFixtureAsync(string[] arguments)
    {
        if (arguments.Length == 1 && arguments[0] == "--version")
        {
            if (Path.GetFileName(Environment.ProcessPath!).StartsWith("version-failure-", StringComparison.Ordinal))
            { await Console.Error.WriteLineAsync("Synthetic version failure password='secret-value'"); Environment.ExitCode = 9; return true; }
            await Console.Out.WriteLineAsync("codex-cli fixture-0.169.0 " + Path.GetFileName(Environment.ProcessPath)); return true;
        }
        if (arguments.Length >= 2 && arguments[0] == "app-server" && arguments[1] == "generate-json-schema")
        {
            var outIndex = Array.IndexOf(arguments, "--out");
            if (outIndex < 0 || outIndex + 1 >= arguments.Length) { Environment.ExitCode = 3; return true; }
            var directory = arguments[outIndex + 1];
            if (directory.Contains("schema-export-failure", StringComparison.Ordinal)) { await Console.Error.WriteLineAsync("Synthetic schema export rejected"); Environment.ExitCode = 17; return true; }
            if (directory.Contains("schema-export-timeout", StringComparison.Ordinal))
            { await File.WriteAllTextAsync(Path.Combine(Path.GetDirectoryName(directory)!, "probe-pid.txt"), Environment.ProcessId.ToString()); await Task.Delay(TimeSpan.FromMinutes(10)); return true; }
            if (directory.Contains("schema-export-flood", StringComparison.Ordinal)) await Console.Out.WriteAsync(new string('x', 100000));
            await WriteSchemaAsync(directory); return true;
        }
        return false;
    }

    private static async Task WriteSchemaAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        foreach (var (direction, methods) in new[]
        {
            ("ClientRequest", new[] { "initialize", "thread/start", "thread/read", "turn/start", "turn/interrupt", "test/selected-schema", "test/echo" }),
            ("ClientNotification", new[] { "initialized" }), ("ServerRequest", new[] { "test/question" }), ("ServerNotification", new[] { "test/event" })
        })
            await File.WriteAllTextAsync(Path.Combine(directory, direction + ".json"), JsonSerializer.Serialize(new { oneOf = methods.Select(method => new { properties = new { method = new { @enum = new[] { method } } } }) }));
    }
    private static async Task FailureAsync(CodexRuntimeService runtime)
    { try { await runtime.StartAsync(); } catch (InvalidOperationException) { return; } throw new InvalidOperationException("The invalid probe unexpectedly initialized."); }
    private static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
