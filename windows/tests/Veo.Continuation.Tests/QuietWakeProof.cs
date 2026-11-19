using System.Diagnostics;
using System.Text.Json;
using Veo.Platform.Windows.Activation;

static class QuietWakeProof
{
    public static async Task RunAsync(string[] arguments)
    {
        if (!arguments.Contains("--enable-proof")) throw new InvalidOperationException("Pass --enable-proof explicitly to create a temporary per-user proof task.");
        var profile = Path.GetFullPath(Value("--live-profile="));
        var aumid = Value("--aumid="); PackagedApplicationActivator.ValidateAumid(aumid);
        if (!Directory.Exists(profile)) throw new DirectoryNotFoundException("Select the exact running Veo profile before proving activation.");
        var realJobs = Path.Combine(profile, "Continuation", "jobs.json");
        if (File.Exists(realJobs))
        {
            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(realJobs));
            if (document.RootElement.GetProperty("Jobs").EnumerateArray().Any(x => x.GetProperty("IsEnabled").GetBoolean() && x.GetProperty("Status").GetString() is not ("Completed" or "Cancelled"))) throw new InvalidOperationException("Disable pending real continuation jobs before running the isolated activation proof.");
        }
        var alias = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "veo-continuation.exe");
        if (!File.Exists(alias)) throw new FileNotFoundException("Install and verify Veo's continuation execution alias first.", alias);
        var proofId = Guid.NewGuid();
        var temporary = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "veo-wake-proof-" + proofId.ToString("N")));
        Directory.CreateDirectory(temporary);
        var jobs = Path.Combine(temporary, "jobs.json");
        var service = new QuietWakeTaskService("Proof-" + proofId.ToString("N"));
        var log = Path.Combine(profile, "Logs", "last-continuation-activation.json");
        try
        {
            await File.WriteAllTextAsync(jobs, JsonSerializer.Serialize(new { Version = 1, Jobs = new[] { new { Id = proofId, IsEnabled = true, Status = "Waiting", RequiresSendReconciliation = false, ResetAt = DateTimeOffset.UtcNow.AddMinutes(-1) } } }));
            var directStarted = DateTimeOffset.UtcNow;
            var info = new ProcessStartInfo(alias) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var value in new[] { "--jobs", jobs, "--aumid", aumid }) info.ArgumentList.Add(value);
            using (var helper = Process.Start(info) ?? throw new IOException("The installed helper alias did not start."))
            {
                try { await helper.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20)); }
                catch { if (!helper.HasExited) helper.Kill(entireProcessTree: true); throw; }
                if (helper.ExitCode != 0) throw new IOException("The installed helper could not activate Veo: " + helper.ExitCode);
            }
            var first = await ReadActivationAsync(log, proofId, directStarted);
            Console.WriteLine("PASS installed helper alias activated an unknown synthetic job without sending a turn");
            await service.RegisterAsync(new(alias, jobs, aumid, DateTimeOffset.UtcNow.AddMinutes(5)), explicitlyEnabled: true);
            if (await service.ReadXmlAsync() is null) throw new IOException("The proof task was not registered.");
            Console.WriteLine("PASS temporary signed-in-user task registration reread");
            await service.RunNowAsync();
            var second = await ReadActivationAsync(log, proofId, first.ReceivedAtUtc);
            if (first.ProcessId != second.ProcessId || first.RuntimeGeneration != second.RuntimeGeneration) throw new IOException("Continuation activation created another workspace runtime owner.");
            Console.WriteLine("PASS scheduled helper handed off to the same app process and runtime generation");
        }
        finally
        {
            await service.RemoveAsync();
            if (await service.ReadXmlAsync() is not null) throw new IOException("Proof cleanup failed for task " + service.TaskName);
            Console.WriteLine("PASS temporary task removed and absence reread: " + service.TaskName);
            // Remove only the one file/directory created by this exact GUID proof.
            if (Path.GetDirectoryName(temporary) == Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar) && Path.GetFileName(temporary) == "veo-wake-proof-" + proofId.ToString("N"))
            { File.Delete(jobs); Directory.Delete(temporary); }
        }
        string Value(string prefix) => arguments.SingleOrDefault(x => x.StartsWith(prefix, StringComparison.Ordinal))?[prefix.Length..] ?? throw new ArgumentException("Missing " + prefix);
    }

    private static async Task<Activation> ReadActivationAsync(string file, Guid expected, DateTimeOffset after)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        while (true)
        {
            timeout.Token.ThrowIfCancellationRequested();
            try
            {
                if (File.Exists(file))
                {
                    using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    var activation = await JsonSerializer.DeserializeAsync<Activation>(stream, cancellationToken: timeout.Token);
                    if (activation is { KnownJob: false } && activation.JobId == expected && activation.ReceivedAtUtc > after) return activation;
                }
            }
            catch (JsonException) { }
            await Task.Delay(100, timeout.Token);
        }
    }
    private sealed record Activation(Guid JobId, bool KnownJob, int ProcessId, long RuntimeGeneration, DateTimeOffset ReceivedAtUtc);
}
