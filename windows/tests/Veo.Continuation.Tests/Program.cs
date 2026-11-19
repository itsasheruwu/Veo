using System.Text.Json;
using System.Xml.Linq;
using System.Runtime.InteropServices;
using Veo.Core;
using Veo.Platform.Windows.Activation;

if (args.Contains("--continuation-adapter-server")) { await WorkspaceContinuationChecks.ServerAsync(args); return; }
if (args.Contains("--quiet-wake-proof")) { await QuietWakeProof.RunAsync(args); return; }
var root = Path.Combine(Path.GetTempPath(), "veo-continuation-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
var now = DateTimeOffset.UtcNow;
var passed = 0;
try
{
    var coordinator = new ContinuationCoordinator(root);
    var disabled = Job() with { IsEnabled = false, ResetAt = now.AddMinutes(-1) };
    await coordinator.UpsertAsync(disabled);
    Assert((await coordinator.DueAsync(now)).Count == 0, "continuation is opt-in by default");
    var unknown = Job() with { ResetAt = null };
    Assert(!ContinuationCoordinator.IsDue(unknown, now.AddYears(1)), "unknown reset never invents a timer");
    var delayed = Job() with { ResetAt = now };
    Assert(!ContinuationCoordinator.IsDue(delayed, now.AddSeconds(7.999)) && ContinuationCoordinator.IsDue(delayed, now.AddSeconds(8)), "server reset plus exact eight-second safety delay");

    var saved = Job() with { Access = "ReadOnly", Model = "catalog-id", Effort = "max", Tier = "fast", InteractionMode = "Plan", RoutingMode = "auto", RouteSnapshot = JsonSerializer.SerializeToElement(new { future = new { item = "exact" }, stages = new[] { "implement", "review" } }) };
    await coordinator.UpsertAsync(saved);
    var relaunched = new ContinuationCoordinator(root);
    var readback = (await relaunched.ListAsync()).Single(x => x.Id == saved.Id);
    Assert(readback.Access == "ReadOnly" && readback.Model == saved.Model && readback.Effort == "max" && readback.Tier == "fast" && readback.InteractionMode == "Plan" && readback.RouteSnapshot!.Value.GetProperty("future").GetProperty("item").GetString() == "exact", "snapshot survives next-launch readback without permission broadening");

    var concurrent = Job(); await coordinator.UpsertAsync(concurrent);
    var barrier = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var inspected = 0;
    var once = new FakeRuntime(async _ => { if (Interlocked.Increment(ref inspected) == 2) barrier.TrySetResult(); await barrier.Task; return Ready(concurrent); });
    await Task.WhenAll(coordinator.TryResumeAsync(concurrent.Id, once, now), coordinator.TryResumeAsync(concurrent.Id, once, now));
    Assert(once.Sends == 1, "concurrent due evaluations dispatch exactly once");

    var account = Job(); await coordinator.UpsertAsync(account);
    var wrongAccount = new FakeRuntime(_ => Task.FromResult(Ready(account) with { AccountIdentity = "changed" }));
    Assert((await coordinator.TryResumeAsync(account.Id, wrongAccount, now))?.Status == ContinuationStatus.Cancelled && wrongAccount.Sends == 0, "changed account cancels stale continuation");
    var archive = Job(); await coordinator.UpsertAsync(archive);
    var archived = new FakeRuntime(_ => Task.FromResult(Ready(archive) with { IsArchived = true }));
    Assert((await coordinator.TryResumeAsync(archive.Id, archived, now))?.Status == ContinuationStatus.Cancelled && archived.Sends == 0, "archived thread cannot continue");
    var missing = Job(); await coordinator.UpsertAsync(missing);
    var missingRuntime = new FakeRuntime(_ => Task.FromResult(Ready(missing) with { ThreadExists = false }));
    Assert((await coordinator.TryResumeAsync(missing.Id, missingRuntime, now))?.Status == ContinuationStatus.Cancelled && missingRuntime.Sends == 0, "deleted thread cannot continue");
    var busy = Job(); await coordinator.UpsertAsync(busy);
    var busyRuntime = new FakeRuntime(_ => Task.FromResult(Ready(busy) with { IsRunning = true }));
    Assert((await coordinator.TryResumeAsync(busy.Id, busyRuntime, now))?.Status == ContinuationStatus.Blocked && busyRuntime.Sends == 0, "active turn cannot be displaced by continuation");
    var staleLimits = Job(); await coordinator.UpsertAsync(staleLimits);
    var limited = new FakeRuntime(_ => Task.FromResult(Ready(staleLimits) with { HasAvailableCapacity = false, NextResetAt = now.AddMinutes(30) }));
    var deferred = await coordinator.TryResumeAsync(staleLimits.Id, limited, now);
    Assert(deferred?.DispatchAt == now.AddMinutes(30).AddSeconds(8) && limited.Sends == 0, "fresh usage limits postpone rather than bypass a limit");

    var ambiguous = Job(); await coordinator.UpsertAsync(ambiguous);
    var uncertain = new FakeRuntime(_ => Task.FromResult(Ready(ambiguous)), throwsOnSend: true);
    try { await coordinator.TryResumeAsync(ambiguous.Id, uncertain, now); throw new Exception("Expected ambiguous transport failure."); } catch (IOException) { }
    await coordinator.SetEnabledAsync(ambiguous.Id, true);
    var recovery = new FakeRuntime(_ => Task.FromResult(Ready(ambiguous)));
    var ambiguousReadback = await new ContinuationCoordinator(root).TryResumeAsync(ambiguous.Id, recovery, now);
    Assert(ambiguousReadback?.RequiresSendReconciliation == true && ambiguousReadback.Status == ContinuationStatus.Blocked && recovery.Sends == 0, "uncertain send cannot replay after re-enable or relaunch");
    var matched = new FakeRuntime(_ => Task.FromResult(Ready(ambiguous) with { ExistingContinuationTurnId = "existing-turn" }));
    Assert((await new ContinuationCoordinator(root).TryResumeAsync(ambiguous.Id, matched, now))?.ContinuationTurnId == "existing-turn" && matched.Sends == 0, "durable client identity reconciles an existing send");

    var cancelled = Job(); await coordinator.UpsertAsync(cancelled);
    var inspectionStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var releaseInspection = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var cancelledRuntime = new FakeRuntime(async _ => { inspectionStarted.SetResult(); await releaseInspection.Task; return Ready(cancelled); });
    var resume = coordinator.TryResumeAsync(cancelled.Id, cancelledRuntime, now);
    await inspectionStarted.Task; await coordinator.CancelThreadAsync(cancelled.VeoThreadId); releaseInspection.SetResult(); await resume;
    Assert(cancelledRuntime.Sends == 0, "manual activity cancellation wins a pending eligibility check");

    var interrupted = Job() with { Status = ContinuationStatus.Dispatching, RequiresSendReconciliation = true }; await coordinator.UpsertAsync(interrupted);
    var crashState = (await coordinator.ListAsync()).Select(x => x.Id == interrupted.Id ? x with { Status = ContinuationStatus.Dispatching } : x).ToArray();
    await File.WriteAllTextAsync(coordinator.JobsFile, JsonSerializer.Serialize(new { Version = 1, Jobs = crashState }));
    var afterRestart = new ContinuationCoordinator(root);
    var interruptedRuntime = new FakeRuntime(_ => Task.FromResult(Ready(interrupted)));
    Assert((await afterRestart.TryResumeAsync(interrupted.Id, interruptedRuntime, now))?.Status == ContinuationStatus.Blocked && interruptedRuntime.Sends == 0, "restarted dispatch remains blocked until history proves delivery");
    await afterRestart.CancelAccountAsync(null);
    Assert((await afterRestart.ListAsync()).All(x => x.Status is ContinuationStatus.Cancelled or ContinuationStatus.Completed), "logout cancels all pending continuation identities");

    var options = new QuietWakeTaskOptions(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "veo-continuation.exe"), Path.Combine(root, "space & Ω's", "jobs.json"), "Veo.Test_abc123!App", now.AddHours(1));
    var xml = QuietWakeTaskService.BuildTaskXml(options, "S-1-5-21-123");
    var document = XDocument.Parse(xml); XNamespace ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";
    var taskArgs = document.Descendants(ns + "Arguments").Single().Value;
    Assert(taskArgs == "--jobs " + PackagedApplicationActivator.QuoteArgument(options.JobsFile) + " --aumid " + PackagedApplicationActivator.QuoteArgument(options.MainApplicationAumid), "task XML roundtrips ampersand Unicode apostrophe and argument quoting");
    Assert(NativeArguments.Parse("veo-continuation.exe " + taskArgs).Skip(1).SequenceEqual(new[] { "--jobs", options.JobsFile, "--aumid", options.MainApplicationAumid }), "Windows native argv parser rereads exact XML action arguments");
    var trickyArguments = new[] { @"C:\folder with spaces\", "quote\"inside", "Ω & apostrophe'" };
    Assert(NativeArguments.Parse("helper.exe " + string.Join(" ", trickyArguments.Select(PackagedApplicationActivator.QuoteArgument))).Skip(1).SequenceEqual(trickyArguments), "Windows native argv roundtrip preserves trailing slashes quotes and Unicode");
    Assert(document.Descendants(ns + "RunLevel").Single().Value == "LeastPrivilege" && document.Descendants(ns + "LogonType").Single().Value == "InteractiveToken" && !document.Descendants().Any(x => x.Name.LocalName.Contains("Password")), "task has signed-in user identity and no admin or password");
    Assert(document.Descendants(ns + "WakeToRun").Single().Value == "false" && !document.Descendants(ns + "Repetition").Any(), "sleep wake and repetition are not silently enabled");
    try { await new QuietWakeTaskService("Tests").RegisterAsync(options, explicitlyEnabled: false); throw new Exception("Expected opt-in rejection."); } catch (InvalidOperationException) { passed++; Console.WriteLine("PASS no task can register without explicit opt-in"); }
    try { QuietWakeTaskService.BuildTaskXml(options with { HelperExecutable = Path.Combine(root, "veo-continuation.exe") }, "S-1-5-21-123"); throw new Exception("Expected unstable helper rejection."); } catch (ArgumentException) { passed++; Console.WriteLine("PASS versioned and development helper paths refused"); }
    await WorkspaceContinuationChecks.RunAsync(root, Assert);
    Console.WriteLine($"{passed} continuation checks passed. No task was registered and no app was activated.");
}
finally
{
    // Only the exact GUID-named fixture created above is removed.
    if (Path.GetFileName(root).StartsWith("veo-continuation-tests-", StringComparison.Ordinal) && Path.GetDirectoryName(root) == Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar)) Directory.Delete(root, recursive: true);
}

ContinuationJob Job() => new() { Id = Guid.NewGuid().ToString(), VeoThreadId = Guid.NewGuid().ToString(), RuntimeThreadId = Guid.NewGuid().ToString(), FailedTurnId = Guid.NewGuid().ToString(), ClientMessageId = "auto-continue-" + Guid.NewGuid(), AccountIdentity = "opaque-account-identity", Cwd = root, IsEnabled = true, Status = ContinuationStatus.Waiting, ResetAt = now.AddSeconds(-30) };
ContinuationInspection Ready(ContinuationJob job) => new() { RuntimeReady = true, ThreadExists = true, WorkspaceAvailable = true, IsLoggedIn = true, AccountIdentity = job.AccountIdentity, RuntimeThreadId = job.RuntimeThreadId, HistoryReconciled = true, RateLimitsRechecked = true, HasAvailableCapacity = true };
void Assert(bool condition, string label) { if (!condition) throw new Exception("FAIL " + label); passed++; Console.WriteLine("PASS " + label); }

sealed class FakeRuntime(Func<ContinuationJob, Task<ContinuationInspection>> inspect, bool throwsOnSend = false) : IContinuationRuntime
{
    public int Sends;
    public Task<ContinuationInspection> InspectAsync(ContinuationJob job, CancellationToken cancellationToken) => inspect(job);
    public Task<string> StartAsync(ContinuationJob job, string prompt, CancellationToken cancellationToken)
    { Interlocked.Increment(ref Sends); if (throwsOnSend) throw new IOException("Synthetic ambiguous send."); return Task.FromResult("continued-turn"); }
}

static class NativeArguments
{
    public static string[] Parse(string command)
    {
        var argv = CommandLineToArgvW(command, out var count);
        if (argv == 0) throw new InvalidOperationException("Windows could not parse test arguments.");
        try { return Enumerable.Range(0, count).Select(i => Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * nint.Size))!).ToArray(); }
        finally { LocalFree(argv); }
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern nint CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")] private static extern nint LocalFree(nint pointer);
}
