using System.Diagnostics;
using System.Text.Json;
using Veo.Core;
using Veo.Infrastructure.Files;
using Veo.Infrastructure.Git;
using Veo.Infrastructure.Projects;
using Veo.Infrastructure.Storage;

var count = 0;
void Check(bool value, string name) { if (!value) throw new Exception("FAILED " + name); count++; Console.WriteLine("PASS " + name); }
async Task Refuses(Func<Task> action, string name) { try { await action(); } catch (Exception error) when (error is ArgumentException or InvalidOperationException or IOException or NotSupportedException) { Check(true, name); return; } throw new Exception("FAILED accepted " + name); }
var root = Path.Combine(Path.GetTempPath(), "Veo.ProjectCommands.Tests-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
var project = Path.Combine(root, "project ü"); var tree = Path.Combine(root, "worktree with space"); var other = Path.Combine(root, "other"); Directory.CreateDirectory(project); Directory.CreateDirectory(other);
await Git(project, "init"); await File.WriteAllTextAsync(Path.Combine(project, "fixture.txt"), "original\r\n"); await Git(project, "add", "--", "fixture.txt"); await Git(project, "-c", "user.name=Fixture", "-c", "user.email=fixture@invalid", "commit", "--no-gpg-sign", "--no-verify", "-m", "fixture");
await Git(project, "worktree", "add", "-b", "fixture/worktree", tree);
await using var repository = new ThreadRepository(Path.Combine(root, "veo.sqlite")); await repository.InitializeAsync();
var preferences = new ProjectPreferencesService(repository);
var actions = new[] { new ProjectAction("setup", "Install dependencies", "Write-Output 'fixture only; not executed'\nWrite-Output '🦊'", true), new ProjectAction("test", "Test project", "Write-Output test") };
await preferences.SetAsync(project, new("fixture-live-model", "high", true, false, actions));
actions[0] = actions[0] with { Command = "mutated caller" };
var reopened = new ProjectPreferencesService(repository); var saved = await reopened.ConfigurationAsync(project);
Check(saved.ModelId == "fixture-live-model" && saved.ReasoningEffort == "high" && saved.UsesWorktree && saved.CheckpointsEnabled == false, "project model/effort/worktree/checkpoint defaults persist independently");
Check(saved.Actions![0].Command.Contains("🦊") && !saved.Actions[0].Command.Contains("mutated caller"), "saved action retains exact multiline Unicode command without executing or sharing caller array");
saved.Actions[0] = saved.Actions[0] with { Name = "mutated read" };
Check((await reopened.ConfigurationAsync(project)).Actions![0].Name == "Install dependencies", "project reads isolate mutable action arrays");
await reopened.RegisterWorktreeAsync(tree, project);
Check(await reopened.ProjectPathAsync(tree) == new WorkspacePathPolicy(project).RootPath && (await reopened.ConfigurationAsync(tree)).ModelId == "fixture-live-model", "real Git worktree inherits parent defaults through verified common-directory Windows identity");
await reopened.SetAsync(tree, (await reopened.ConfigurationAsync(tree)) with { ReasoningEffort = "medium" });
Check((await reopened.ConfigurationAsync(project)).ReasoningEffort == "medium", "editing linked worktree settings updates its verified project configuration");
await reopened.ResetDefaultsAsync(tree); var reset = await reopened.ConfigurationAsync(project);
Check(reset.ModelId is null && reset.ReasoningEffort is null && !reset.UsesWorktree && reset.CheckpointsEnabled is null && reset.Actions!.Length == 2, "reset defaults preserves saved actions and restores inherited checkpoint enabled state");
await Refuses(() => reopened.RegisterWorktreeAsync(other, project), "unrelated nongit directory cannot inherit another project's settings");
await Refuses(() => reopened.SetAsync(project, new(ReasoningEffort: "high")), "reasoning override without explicit model is refused");
await Refuses(() => reopened.SetAsync(project, new(Actions: [new("a", "Large", string.Concat(Enumerable.Repeat("🦊", 9000)))])), "project command limit measures UTF8 bytes rather than characters");
await Refuses(() => reopened.SetAsync(project, new(Actions: [new("a", "NUL", "echo\0bad")])), "project action refuses embedded NUL");
await Refuses(() => reopened.SetAsync(project, new(Actions: [new("a", "First", "echo 1"), new("a", "Second", "echo 2")])), "duplicate action identities are refused");
Check((await reopened.ConfigurationAsync(project)).Actions!.Length == 2, "invalid project save preserves prior durable configuration");
await Task.WhenAll(preferences.SetAsync(project, reset with { ModelId = "project-one" }), reopened.SetAsync(other, new("project-two")));
Check((await reopened.ConfigurationAsync(project)).ModelId == "project-one" && (await reopened.ConfigurationAsync(other)).ModelId == "project-two", "concurrent preferences instances preserve unrelated project writes");
var fake = new FakeIdentity(); var projectKey = new WorkspacePathPolicy(project).RootPath; var treeKey = new WorkspacePathPolicy(tree).RootPath;
fake.Values[projectKey] = "old-common-id"; fake.Values[treeKey] = "old-common-id"; var guarded = new ProjectPreferencesService(repository, fake);
await guarded.RegisterWorktreeAsync(tree, project); fake.Values[treeKey] = "replacement-repository-id";
Check(await guarded.ProjectPathAsync(tree) == treeKey && (await guarded.ConfigurationAsync(tree)).ModelId is null, "reused worktree path does not inherit configuration after repository identity changes");
Check((await reopened.ConfiguredPathsAsync()).Contains(projectKey), "configured project paths remain discoverable for native settings");

var commands = new CommandRegistry(repository); await commands.InitializeAsync();
var exactSource = new[] { "model", "reasoning", "permissions", "review", "rename", "new", "temporary", "archive", "delete", "fork", "init", "compact", "agentic", "plan", "debug", "goal", "copy", "diff", "mention", "status", "usage", "skills", "mcp", "apps", "plugins", "appearance", "browser", "terminal", "runtime", "reconnect", "reveal", "refresh", "stop", "clear" };
Check(CommandRegistry.Definitions.Where(x => x.SlashName is not null).Select(x => x.SlashName!).SequenceEqual(exactSource), "one registry retains all 34 source slash routes in source order");
Check(CommandRegistry.Definitions.Count(x => x.DefaultBinding is not null) == 8 && commands.Binding("terminal") == new CommandKeyBinding(192, ShortcutModifiers.Control), "eight native Windows shortcut defaults match source actions");
Check(CommandRegistry.ParseSlash("/PlAn  investigate\nwith evidence  ") is { Arguments: "investigate\nwith evidence", Command.Id: "plan" } && CommandRegistry.ParseSlash("//server/path") is null, "slash parser handles case and multiline arguments without capturing paths");
Check(CommandRegistry.ParseSlash("ordinary input") is null && CommandRegistry.ParseSlash("/unknown hello") is null && commands.Suggestions("/re").Select(x => x.SlashName).Contains("reasoning"), "unknown slash or ordinary input remains composer text and suggestions use same registry");
var firstWindow = new CommandDispatcher(); var secondWindow = new CommandDispatcher(); string? firstInput = null; string? secondInput = null;
firstWindow.Register("plan", (invocation, _) => { firstInput = invocation.Arguments; return Task.CompletedTask; }); secondWindow.Register("plan", (invocation, _) => { secondInput = invocation.Arguments; return Task.CompletedTask; });
await firstWindow.ExecuteSlashAsync("/plan first"); await secondWindow.ExecuteSlashAsync("/plan second");
Check(firstInput == "first" && secondInput == "second", "window-scoped dispatcher keeps command context isolated");
await Refuses(() => firstWindow.ExecuteSlashAsync("/goal investigate"), "known but unbound command reports unavailable without consuming draft");
Check(!await firstWindow.ExecuteSlashAsync("/unknown investigate"), "unknown slash command does not execute a guessed route");
await Refuses(() => commands.SetBindingAsync("plan", new('P', ShortcutModifiers.None)), "bare typing shortcut is refused");
await Refuses(() => commands.SetBindingAsync("plan", new('C', ShortcutModifiers.Control)), "clipboard and terminal interrupt shortcut is reserved");
await Refuses(() => commands.SetBindingAsync("plan", new('P', ShortcutModifiers.Control | ShortcutModifiers.Alt)), "AltGr typing combination is reserved");
await Refuses(() => commands.SetBindingAsync("plan", new(13, ShortcutModifiers.Control)), "nonprintable shortcut key is refused");
await Refuses(() => commands.SetBindingAsync("unknown-command", null), "unknown shortcut command is refused");
await Refuses(() => commands.SetBindingAsync("plan", commands.Binding("newChat")), "duplicate effective default shortcut is refused");
await commands.SetBindingAsync("plan", new('P', ShortcutModifiers.Control | ShortcutModifiers.Shift));
Check(commands.Resolve(new('P', ShortcutModifiers.Control | ShortcutModifiers.Shift))?.Id == "plan", "custom shortcut resolves its registry action");
await commands.SetBindingAsync("newChat", null); var readback = new CommandRegistry(repository); await readback.InitializeAsync();
Check(readback.Binding("newChat") is null && readback.Binding("plan") == new CommandKeyBinding('P', ShortcutModifiers.Control | ShortcutModifiers.Shift), "clear and custom binding persist across registry reopen");
await commands.SetBindingAsync("plan", new('N', ShortcutModifiers.Control));
await Refuses(() => commands.ResetAsync("newChat"), "reset detects conflict with another command override");
await commands.ResetAsync(); Check(commands.Binding("newChat") == new CommandKeyBinding('N', ShortcutModifiers.Control) && commands.Binding("plan") is null, "reset all restores defaults and clears custom shortcuts transactionally");
Check(await File.ReadAllTextAsync(Path.Combine(project, "fixture.txt")) == "original\r\n", "preferences and command fixtures preserve project file bytes");

await using (var workspace = new WorkspaceCoordinator(Path.Combine(root, "test-profile")))
{
    await workspace.Threads.InitializeAsync();
    var source = await workspace.CreateAsync(project);
    var config = new ProjectPreferencesService(workspace.Threads);
    await config.SetAsync(project, reset with { UsesWorktree = true });
    var worktrees = new WorktreeCoordinator(workspace, config);
    var context = await worktrees.InspectAsync(project);
    var createdPath = Path.Combine(root, "created worktree");
    var created = await worktrees.CreateAsync(context.Snapshot, "fixture/created", createdPath);
    var reused = await worktrees.ReuseAsync(await new LocalGitService(Path.Combine(root, "recovery")).SnapshotAsync(project), createdPath);
    Check(created.Record.Cwd == reused.Record.Cwd && created.Record.VeoId != reused.Record.VeoId &&
          source.Record.Cwd != created.Record.Cwd && context.Configuration.UsesWorktree, "worktree create and reuse open separate chats and preserve the original chat cwd");
    var paths = await config.RegisteredProjectPathsAsync([project, createdPath]);
    Check(paths[createdPath] == projectKey && (await config.ConfigurationAsync(createdPath)).Actions!.Length == 2,
        "new worktree retains its parent project's verified group and saved setup actions");
    Check(new ThreadCatalogCoordinator(workspace).Group(
            (await workspace.CatalogAsync()).Select(thread => new CatalogEntry(thread.VeoId, CatalogOrigin.Veo, thread)), paths).Single().Entries.Count == 3,
        "project grouping includes original and worktree chats without replacing their recorded directories");

    var git = new LocalGitService(Path.Combine(workspace.DataRoot, "GitRecovery"));
    var checkpointRpc = new CheckpointRpc();
    var checkpoints = new CheckpointCoordinator(workspace, config, checkpointRpc);
    var file = Path.Combine(createdPath, "fixture.txt");
    await File.WriteAllTextAsync(file, "staged\r\n");
    await Git(createdPath, "add", "--", "fixture.txt");
    await File.WriteAllTextAsync(file, "unstaged\r\n");
    var before = await git.SnapshotAsync(createdPath);
    await checkpoints.CaptureManualAsync(created);
    var savedCheckpoint = (await checkpoints.WorkspaceEntriesAsync(reused)).Single().Checkpoint;
    var localFile = Path.Combine(createdPath, "later.txt");
    await File.WriteAllTextAsync(localFile, "later");
    await File.WriteAllTextAsync(file, "later file content");
    checkpointRpc.ActiveWorkspace = createdPath;
    await Refuses(() => checkpoints.RestoreFilesAsync(reused, savedCheckpoint), "checkpoint restore refuses another active runtime chat in the same repository");
    Check(File.Exists(localFile) && (await checkpoints.WorkspaceEntriesAsync(reused)).Count == 1, "active restore refusal leaves files and checkpoint list unchanged");
    checkpointRpc.ActiveWorkspace = null;
    await checkpoints.RestoreFilesAsync(reused, savedCheckpoint);
    var restored = await git.SnapshotAsync(createdPath);
    Check(await File.ReadAllTextAsync(file) == "unstaged\r\n" && !File.Exists(localFile) && before.IndexEntries.SequenceEqual(restored.IndexEntries)
          && before.Head == restored.Head && before.Branch == restored.Branch, "files-only checkpoint restore returns exact bytes and staging without changing branch or HEAD");
    var recovery = (await checkpoints.WorkspaceEntriesAsync(created)).Single(entry => entry.State == "recovery").Checkpoint;
    await checkpoints.RestoreFilesAsync(created, recovery);
    Check(await File.ReadAllTextAsync(file) == "later file content" && File.Exists(localFile), "a separate chat can reverse a restore using the persisted workspace recovery checkpoint");

    var runtimeRecord = created.Record with { VeoId = "runtime-fixture", CodexThreadId = "runtime-fixture-id" };
    await workspace.Threads.UpsertThreadAsync(runtimeRecord);
    var runtimeSession = await workspace.LoadAsync(runtimeRecord);
    var payload = new ComposerSnapshot("client-payload-identity", "test", null, null, null, "Workspace", "Agentic", []);
    await checkpoints.BeforeDispatchAsync(runtimeSession, payload);
    await checkpoints.AfterDispatchAsync(runtimeSession, payload, "turn-id-returned-by-start");
    var readbackCheckpoints = new CheckpointCoordinator(workspace, config, checkpointRpc);
    Check((await readbackCheckpoints.ForTurnAsync(runtimeSession, "turn-id-returned-by-start"))?.PayloadId == payload.ClientId &&
          await readbackCheckpoints.ForTurnAsync(reused, "turn-id-returned-by-start") is null,
        "turn checkpoint is durably bound to its exact runtime turn and original chat");
}
Console.WriteLine($"{count} project/command checks passed; real disposable Git worktree identities were read, no project action or remote command ran.");

static async Task Git(string cwd, params string[] args)
{
    var start = new ProcessStartInfo("git.exe") { WorkingDirectory = cwd, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (var key in start.Environment.Keys.Where(x => x.StartsWith("GIT_", StringComparison.OrdinalIgnoreCase)).ToArray()) start.Environment.Remove(key);
    foreach (var arg in args) start.ArgumentList.Add(arg); using var process = Process.Start(start)!; var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync(); await process.WaitForExitAsync(); await stdout;
    if (process.ExitCode != 0) throw new Exception(await stderr);
}
sealed class FakeIdentity : IProjectRepositoryIdentity
{
    public Dictionary<string, string> Values { get; } = new(StringComparer.OrdinalIgnoreCase);
    public Task<string?> GetAsync(string path, CancellationToken token = default) => Task.FromResult(Values.GetValueOrDefault(path));
}
sealed class CheckpointRpc : ICoordinatorRpc
{
    public string? ActiveWorkspace { get; set; }
    public long Generation => 1;
    public bool Supports(string method) => method is "thread/list" or "thread/read" or "thread/revert";
    public Task<JsonElement> RequestAsync(string method, object? parameters, CancellationToken token = default)
    {
        token.ThrowIfCancellationRequested();
        return Task.FromResult(method switch
        {
            "thread/list" => JsonSerializer.SerializeToElement(new
            {
                data = ActiveWorkspace is null ? [] : new[] { new { id = "other-runtime", cwd = ActiveWorkspace, status = new { type = "active" } } }
            }),
            "thread/read" => JsonSerializer.SerializeToElement(new { thread = new { historyMode = "paginated" } }),
            _ => throw new InvalidOperationException("Unexpected fixture request " + method)
        });
    }
}
