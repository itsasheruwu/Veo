using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Veo.Core;
using Veo.Platform.Windows.Terminal;

var passed = new List<string>();
void Check(bool condition, string label) { if (!condition) throw new Exception("FAILED " + label); passed.Add(label); Console.WriteLine("PASS " + label); }
async Task Refuses(Func<Task> action, string label)
{ try { await action(); } catch (Exception error) when (error is InvalidOperationException or InvalidDataException or ArgumentException or AggregateException) { Check(true, label); return; } throw new Exception("FAILED accepted " + label); }
var ids = Enumerable.Range(0, 6).Select(i => "session" + i).ToArray();
var all = ids.ToHashSet(StringComparer.Ordinal);
foreach (var preset in Enum.GetValues<TerminalGridPreset>())
{
    var tree = TerminalPaneNode.Preset(preset, ids);
    Check(tree.LeafCount == TerminalPaneNode.Count(preset) && tree.SessionIds.Distinct().Count() == tree.LeafCount, "preset " + preset + " references distinct existing sessions");
}
var six = TerminalPaneNode.Preset(TerminalGridPreset.Six, ids);
Check(six is TerminalPaneSplit { Axis: TerminalSplitAxis.Horizontal, Ratio: > 0.333 and < 0.334 }, "six-pane preset gives each of three columns one third width");
var swapped = six.Swap(ids[0], ids[5]);
Check(swapped.SessionIds.Count == 6 && swapped.SessionIds.SequenceEqual(six.SessionIds.Select(id => id == ids[0] ? ids[5] : id == ids[5] ? ids[0] : id)), "pane rearrangement swaps identities without duplicating or dropping sessions");
var removed = swapped.Remove(ids[2])!;
Check(removed.LeafCount == 5 && !removed.Contains(ids[2]), "closing a pane collapses only its empty branch");
var pruned = six.Prune(new HashSet<string>([ids[0], ids[4]]))!;
Check(pruned.LeafCount == 2 && pruned.Contains(ids[0]) && pruned.Contains(ids[4]), "missing-session pruning keeps remaining pane identities");
var splitRoot = (TerminalPaneSplit)six;
Check(six.SetRatio(splitRoot.Id, -1) is TerminalPaneSplit { Ratio: 0.2 } && six.SetRatio(splitRoot.Id, 2) is TerminalPaneSplit { Ratio: 0.8 }, "pane resize clamps persisted ratios to usable dimensions");
await Refuses(() => Task.Run(() => six.Split(ids[0], "seventh", TerminalSplitAxis.Vertical)), "seventh visible pane is refused without creating a session");
await Refuses(() => Task.Run(() => six.SetRatio(splitRoot.Id, double.NaN)), "invalid resize ratio cannot corrupt persisted layout");
var directory = Path.Combine(Path.GetTempPath(), "Veo.TerminalWorkspace.Tests-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
var descriptors = ids.Select((id, index) => new TerminalSessionDescriptor(id, "thread" + index, Path.Combine(directory, "Project " + index), "Shell " + index)).ToArray();
foreach (var descriptor in descriptors) Directory.CreateDirectory(descriptor.Cwd);
var state = new TerminalWorkspaceSnapshot(1, true, ids[5], descriptors, six);
state.Validate(); var json = JsonSerializer.Serialize(state); var reopened = JsonSerializer.Deserialize<TerminalWorkspaceSnapshot>(json)!; reopened.Validate();
Check(reopened.Layout == six && reopened.FocusedSessionId == ids[5] && reopened.Expanded && reopened.Sessions.Select(d => d.Cwd).SequenceEqual(descriptors.Select(d => d.Cwd)), "layout, focus, expansion and fixed cwd metadata survive JSON persistence");
await Refuses(() => Task.Run(() => (state with { Layout = new TerminalPaneLeaf("missing") }).Validate()), "saved layout cannot reference an unknown terminal");

var created = 0; var fake = new FakeOwned(); var owner = new TerminalSessionOwnership<FakeOwned>();
var first = await owner.GetOrCreateAsync(descriptors[0], () => { created++; return Task.FromResult(fake); });
var duplicates = await Task.WhenAll(Enumerable.Range(0, 20).Select(_ => owner.GetOrCreateAsync(descriptors[0], () => { created++; return Task.FromResult(new FakeOwned()); })));
Check(created == 1 && duplicates.All(item => ReferenceEquals(item, first)), "concurrent terminal selection creates exactly one owned shell handle");
await Refuses(async () => { await owner.GetOrCreateAsync(descriptors[0] with { Cwd = descriptors[1].Cwd }, () => Task.FromResult(new FakeOwned())); }, "selecting another chat cannot relocate an existing terminal cwd");
await owner.CloseAsync(descriptors[0].Id); await owner.CloseAsync(descriptors[0].Id); await owner.DisposeAsync(); await owner.DisposeAsync();
Check(fake.Disposals == 1, "closing and repeated shutdown dispose each owned session exactly once");
var failingOwner = new TerminalSessionOwnership<FakeOwned>(); var bad = new FakeOwned { ThrowOnDispose = true }; var good = new FakeOwned();
await failingOwner.GetOrCreateAsync(descriptors[0], () => Task.FromResult(bad)); await failingOwner.GetOrCreateAsync(descriptors[1], () => Task.FromResult(good));
await Refuses(async () => { await failingOwner.DisposeAsync(); }, "terminal shutdown reports aggregated disposal failures");
Check(good.Disposals == 1 && bad.Disposals == 1, "one failed close does not skip the other owned sessions");

if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 26100))
{
    var realOwner = new TerminalSessionOwnership<RealOwned>(); var real = new List<RealOwned>(); var processIds = new Dictionary<string, int>(); var starts = 0;
    try
    {
        foreach (var descriptor in descriptors)
        {
            var owned = await realOwner.GetOrCreateAsync(descriptor, () => { starts++; var terminal = new RealOwned(); terminal.Start(descriptor.Cwd); return Task.FromResult(terminal); }); real.Add(owned); processIds[descriptor.Id] = owned.Terminal.ProcessId!.Value;
            var marker = Guid.NewGuid().ToString("N");
            await owned.Terminal.WriteAsync("[Console]::WriteLine('READY_'+'" + marker + "'); [Console]::WriteLine('CWD='+(Get-Location).Path)\r");
            await WaitUntil(() => owned.Text.Contains("READY_" + marker) && owned.Text.Contains("CWD=" + descriptor.Cwd));
        }
        Check(real.Count == 6 && processIds.Values.Distinct().Count() == 6 && real.All(session => session.Terminal.IsRunning), "six real ConPTY shells start in six recorded working directories");
        foreach (var id in swapped.SessionIds)
        {
            var descriptor = descriptors.Single(d => d.Id == id);
            var owned = await realOwner.GetOrCreateAsync(descriptor, () => { starts++; throw new Exception("Unexpected duplicate shell."); });
            Check(owned.Terminal.ProcessId == processIds[id], "pane reorder retains actual shell PID for " + id);
        }
        Check(starts == 6, "repeated layout/selection does not spawn duplicate ConPTY processes");
        for (var i = 0; i < real.Count; i++)
        {
            var columns = 85 + i; var rows = 20 + i; real[i].Terminal.Resize(columns, rows);
            await real[i].Terminal.WriteAsync("[Console]::WriteLine('SIZE='+[Console]::WindowWidth+'x'+[Console]::WindowHeight)\r");
            var index = i; await WaitUntil(() => real[index].Text.Contains("SIZE=" + columns + "x" + rows));
        }
        Check(true, "all six shell viewports read back their own resized rows and columns");
        await realOwner.CloseAsync(descriptors[0].Id);
        Check(!real[0].Terminal.IsRunning && real.Skip(1).All(item => item.Terminal.IsRunning), "closing one pane terminates only its owned shell");
    }
    finally { await realOwner.DisposeAsync(); }
    Check(real.All(item => !item.Terminal.IsRunning) && processIds.Values.All(Exited), "workspace shutdown terminates all six known owned shell processes");
}
Console.WriteLine(JsonSerializer.Serialize(new { Passed = passed.Count, Root = directory, Scenarios = passed }));
static bool Exited(int pid) { try { using var process = Process.GetProcessById(pid); return process.HasExited; } catch (ArgumentException) { return true; } }
static async Task WaitUntil(Func<bool> predicate)
{ using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20)); while (!predicate()) await Task.Delay(50, timeout.Token); }
sealed class FakeOwned : IAsyncDisposable
{
    public int Disposals { get; private set; }
    public bool ThrowOnDispose { get; init; }
    public ValueTask DisposeAsync() { Disposals++; if (ThrowOnDispose) throw new IOException("Fixture close failure"); return ValueTask.CompletedTask; }
}
sealed class RealOwned : IAsyncDisposable
{
    private readonly object gate = new(); private readonly StringBuilder text = new();
    public ConPtySession Terminal { get; } = new();
    public string Text { get { lock (gate) return text.ToString(); } }
    public RealOwned() => Terminal.OutputReceived += value => { lock (gate) text.Append(value); };
    public void Start(string cwd) => Terminal.Start(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"), cwd, 80, 24, ["-NoLogo", "-NoProfile"]);
    public ValueTask DisposeAsync() => Terminal.DisposeAsync();
}
