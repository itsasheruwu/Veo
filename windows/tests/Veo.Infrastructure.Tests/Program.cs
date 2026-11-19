using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using Veo.Infrastructure.Files;
using Veo.Infrastructure.Git;
using Veo.Infrastructure.Storage;

var testRoot = Path.Combine(Path.GetTempPath(), "Veo.Infrastructure.Tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(testRoot);
var passed = new List<string>();
void Check(bool condition, string scenario)
{ if (!condition) throw new InvalidOperationException("FAILED: " + scenario); passed.Add(scenario); Console.WriteLine("PASS " + scenario); }
async Task Refuses(Func<Task> action, string scenario)
{ try { await action(); } catch (Exception e) when (e is IOException or UnauthorizedAccessException or SqliteException) { Check(true, scenario); return; } throw new Exception("FAILED: accepted " + scenario); }

var database = Path.Combine(testRoot, "Threads", "veo.sqlite");
await using (var repository = new ThreadRepository(database))
{
    await repository.InitializeAsync();
    await repository.UpsertThreadAsync(new("veo-a", "runtime-a", "C:\\Project α", "First project"));
    await repository.UpsertThreadAsync(new("veo-b", "runtime-b", "D:\\Second", "Second project"));
    await repository.SaveTimelineAsync("veo-a", [new("turn", "started", DateTimeOffset.UtcNow, null, 0)],
        [new("reasoning", "turn", "reasoning", null, "streaming", "{\"unknownFutureField\":true}", 0, DateTimeOffset.UtcNow),
         new("assistant-1", "turn", "agentMessage", null, "complete", "{\"text\":\"first\"}", 1, DateTimeOffset.UtcNow),
         new("assistant-2", "turn", "agentMessage", null, "complete", "{\"text\":\"second\"}", 2, DateTimeOffset.UtcNow)]);
    await repository.SaveItemAsync("veo-a", new("reasoning", "turn", "reasoning", null, "complete", "{\"unknownFutureField\":true,\"late\":\"delta\"}", 0, DateTimeOffset.UtcNow));
    await repository.SaveDraftAsync("veo-a", new("A draft 🦊", "[{\"path\":\"media.png\"}]", "{\"access\":\"workspace-write\"}"));
    await repository.SaveDraftAsync("veo-b", new("Other draft"));
    await repository.SavePlanAsync(new("veo-a", "plan", "turn", "# Original", "# Edited", "implementing", "client-id"));
    await repository.SaveStateAsync("queue:veo-a", "payload", "{\"model\":\"live-id\",\"clientId\":\"durable-id\"}");
    Check((await repository.ListThreadsAsync()).Count == 2, "all projects coexist in catalog");
    Check((await repository.ReadItemsAsync("veo-a")).Select(i => i.ItemId).SequenceEqual(["reasoning", "assistant-1", "assistant-2"]), "items retain item identity/order inside one turn");
    Check((await repository.ReadItemsAsync("veo-a"))[0].RawJson.Contains("unknownFutureField"), "unknown raw item fields survive update");
    await repository.SaveItemAsync("veo-a", new("optimistic", "turn", "userMessage", "client", "pending", "{}", 3, DateTimeOffset.UtcNow));
    await repository.DeleteItemsAsync("veo-a", ["optimistic"]);
    Check((await repository.ReadItemsAsync("veo-a")).Count == 3, "optimistic identity deletion preserves other item rows");
    await Refuses(() => repository.UpsertThreadAsync(new("veo-c", "runtime-a", "E:\\Third", "Bad duplicate")), "unique runtime ID mapping enforced");
    await repository.BackupAsync(Path.Combine(testRoot, "live-backup.sqlite"));
}
await using (var reopened = new ThreadRepository(database))
{
    Check((await reopened.ReadDraftAsync("veo-a"))?.Text == "A draft 🦊" && (await reopened.ReadDraftAsync("veo-b"))?.Text == "Other draft", "per-thread draft/media/options persist across reopen");
    Check((await reopened.ReadPlansAsync("veo-a")).Single().Lifecycle == "implementing", "edited plan lifecycle persists across reopen");
    Check((await reopened.ReadStateAsync("queue:veo-a", "payload"))!.Contains("durable-id"), "durable queue snapshot persists across reopen");
}
await using (var backup = new ThreadRepository(Path.Combine(testRoot, "live-backup.sqlite")))
    Check((await backup.ReadItemsAsync("veo-a")).Count == 3, "online SQLite backup includes committed WAL timeline");
using (var db = new SqliteConnection($"Data Source={database};Pooling=False"))
{
    db.Open(); using var cmd = db.CreateCommand(); cmd.CommandText = "PRAGMA user_version=1;"; cmd.ExecuteNonQuery();
}
await using (var migrated = new ThreadRepository(database))
{ await migrated.InitializeAsync(); Check((await migrated.ListThreadsAsync()).Count == 2, "versioned migration retains catalog"); }
Check(Directory.GetFiles(Path.GetDirectoryName(database)!, "*.pre-v3-*.bak").Length == 1, "migration creates consistent pre-migration backup");
using (var db = new SqliteConnection($"Data Source={database};Pooling=False"))
{
    db.Open(); using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT sqlite_version();"; Console.WriteLine("SQLite=" + cmd.ExecuteScalar());
}

var workspace = Path.Combine(testRoot, "workspace"); Directory.CreateDirectory(workspace);
var files = new WorkspaceFileService(workspace);
var bomFile = Path.Combine(workspace, "日本語.txt");
var original = new byte[] { 0xEF, 0xBB, 0xBF }.Concat(Encoding.UTF8.GetBytes("first\r\nsecond\r\n")).ToArray();
await File.WriteAllBytesAsync(bomFile, original);
var document = await files.ReadTextAsync("日本語.txt");
await files.SaveTextAsync(document, document.Text);
Check((await File.ReadAllBytesAsync(bomFile)).SequenceEqual(original), "no-op edit preserves BOM and CRLF exact bytes");
document = await files.SaveTextAsync(document, "first\nchanged\n");
Check((await File.ReadAllBytesAsync(bomFile)).SequenceEqual(new byte[] { 0xEF, 0xBB, 0xBF }.Concat(Encoding.UTF8.GetBytes("first\r\nchanged\r\n"))), "edited UTF8 BOM file retains original newline convention");
await File.WriteAllTextAsync(bomFile, "external writer");
await Refuses(async () => { await files.SaveTextAsync(document, "overwrite"); }, "external file write is refused");
Check(await File.ReadAllTextAsync(bomFile) == "external writer", "refused save leaves external bytes intact");
await File.WriteAllBytesAsync(Path.Combine(workspace, "mixed.txt"), Encoding.UTF8.GetBytes("a\r\nb\nc\r"));
var mixed = await files.ReadTextAsync("mixed.txt"); await files.SaveTextAsync(mixed, mixed.Text);
Check((await File.ReadAllBytesAsync(mixed.Path)).SequenceEqual(Encoding.UTF8.GetBytes("a\r\nb\nc\r")), "mixed newline no-op save remains byte exact");
var utf16 = new UnicodeEncoding(true, true, true);
await File.WriteAllBytesAsync(Path.Combine(workspace, "utf16.txt"), [.. utf16.GetPreamble(), .. utf16.GetBytes("one\r\ntwo")]);
var unicode = await files.ReadTextAsync("utf16.txt");
unicode = await files.SaveTextAsync(unicode, "one\nthree");
Check(unicode.Encoding == WorkspaceTextEncoding.Utf16BigEndian && unicode.Text == "one\r\nthree", "UTF16 big-endian encoding survives edit");
await Refuses(() => files.ReadTextAsync("..\\outside.txt"), "parent traversal refused");
var sibling = workspace + "-sibling"; Directory.CreateDirectory(sibling); await File.WriteAllTextAsync(Path.Combine(sibling, "secret.txt"), "outside");
await Refuses(() => files.ReadTextAsync(Path.Combine(sibling, "secret.txt")), "sibling with shared path prefix refused");
Directory.CreateDirectory(Path.Combine(workspace, "nested"));
await File.WriteAllTextAsync(Path.Combine(workspace, "nested", "search-needle.txt"), "search content");
Check((await files.SearchAsync("search-needle")).Single().RelativePath.EndsWith("search-needle.txt"), "workspace file search returns nested result");
var link = Path.Combine(workspace, "escape");
try
{
    Directory.CreateSymbolicLink(link, sibling);
    await Refuses(() => files.ReadTextAsync("escape\\secret.txt"), "junction/symlink outside approved root refused");
}
catch (UnauthorizedAccessException) { Console.WriteLine("GAP symbolic-link creation requires developer mode or privilege on this test host"); }

var repo = Path.Combine(testRoot, "git repo ü"); Directory.CreateDirectory(repo);
async Task<byte[]> Git(params string[] args)
{
    var start = new ProcessStartInfo("git.exe") { WorkingDirectory = repo, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (var arg in args) start.ArgumentList.Add(arg);
    using var p = Process.Start(start)!; using var output = new MemoryStream(); var read = p.StandardOutput.BaseStream.CopyToAsync(output); var err = p.StandardError.ReadToEndAsync();
    await Task.WhenAll(read, p.WaitForExitAsync()); if (p.ExitCode != 0) throw new Exception(await err); return output.ToArray();
}
await Git("init"); await Git("config", "user.name", "Veo Tests"); await Git("config", "user.email", "test@example.invalid"); await Git("config", "core.autocrlf", "false");
const string selected = "draft [a] ü.txt"; const string other = "other.txt";
await File.WriteAllTextAsync(Path.Combine(repo, selected), "base\r\n"); await File.WriteAllTextAsync(Path.Combine(repo, other), "base other\n");
await Git("add", "--all"); await Git("commit", "-m", "Disposable baseline");
await File.WriteAllTextAsync(Path.Combine(repo, selected), "staged\r\n"); await Git("--literal-pathspecs", "add", "--", selected);
await File.WriteAllTextAsync(Path.Combine(repo, selected), "unstaged 🦊\r\n");
await File.WriteAllTextAsync(Path.Combine(repo, other), "unrelated staged\n"); await Git("add", "--", other);
var service = new LocalGitService(Path.Combine(testRoot, "Recovery"));
var snapshot = await service.SnapshotAsync(repo);
Check(snapshot.Files.Single(f => f.Path == selected).HasStagedChanges && snapshot.Files.Single(f => f.Path == selected).HasUnstagedChanges, "porcelain parses Unicode literal path with split staged state");
var beforeIndex = await Git("ls-files", "--stage", "-z");
var discarded = await service.DiscardAsync(snapshot, [selected]);
Check(await File.ReadAllTextAsync(Path.Combine(repo, selected)) == "staged\r\n", "unstaged discard restores index bytes with CRLF");
Check((await Git("ls-files", "--stage", "-z")).SequenceEqual(beforeIndex), "unstaged discard preserves complete index split");
Check(File.Exists(Path.Combine(discarded.Recovery!.BundlePath, "manifest.json")), "destructive Git operation saves recovery before mutation");
var restored = await service.RestoreRecoveryAsync(discarded.Recovery);
Check(await File.ReadAllTextAsync(Path.Combine(repo, selected)) == "unstaged 🦊\r\n", "recovery restores exact working bytes");
Check((await Git("ls-files", "--stage", "-z")).SequenceEqual(beforeIndex), "recovery restores selected index while preserving unrelated stage");
var stage = await service.StageAsync(restored.Snapshot, [selected]);
Check(Encoding.UTF8.GetString(await Git("show", ":" + selected)) == "unstaged 🦊\r\n", "literal-path stage reads back exact blob bytes");
var unstage = await service.UnstageAsync(stage.Snapshot, [selected]);
Check(Encoding.UTF8.GetString(await Git("show", ":" + selected)) == "base\r\n", "unstage returns selected index to HEAD");
Check(Encoding.UTF8.GetString(await Git("show", ":" + other)) == "unrelated staged\n", "stage and unstage leave unrelated index entry intact");
await File.WriteAllTextAsync(Path.Combine(repo, selected), "new external write\r\n");
await Refuses(() => service.DiscardAsync(unstage.Snapshot, [selected]), "stale review refuses changed working file");
snapshot = await service.SnapshotAsync(repo);
await Git("checkout", "-b", "changed-context");
await Refuses(() => service.DiscardAsync(snapshot, [selected]), "stale review refuses branch context change");
await File.WriteAllTextAsync(Path.Combine(repo, "untracked [x].txt"), "untracked bytes\r\n");
snapshot = await service.SnapshotAsync(repo);
var untracked = await service.DiscardAsync(snapshot, ["untracked [x].txt"]);
Check(!File.Exists(Path.Combine(repo, "untracked [x].txt")), "untracked discard removes only selected recovered file");
await service.RestoreRecoveryAsync(untracked.Recovery!);
Check(await File.ReadAllTextAsync(Path.Combine(repo, "untracked [x].txt")) == "untracked bytes\r\n", "untracked recovery restores exact file bytes");
snapshot = await service.SnapshotAsync(repo);
await Refuses(() => service.StageAsync(snapshot, ["..\\outside.txt"]), "Git mutations reject paths absent from reviewed snapshot");

var fullyStaged = await service.StageAsync(snapshot, [selected]);
var committed = await service.CommitSelectedAsync(fullyStaged.Snapshot, [selected], "Commit only explicit selection");
Check(Encoding.UTF8.GetString(await Git("diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "HEAD")).TrimEnd('\0') == selected,
    "selected commit excludes unrelated staged file");
Check(Encoding.UTF8.GetString(await Git("show", ":" + other)) == "unrelated staged\n", "selected commit retains unrelated staged blob");
var branchSnapshot = await service.CreateBranchAsync(committed.Snapshot, "veo-test-branch");
Check(branchSnapshot.Branch == "veo-test-branch" && branchSnapshot.Head == committed.CommitId, "branch creation preserves HEAD and index");
var worktree = await service.CreateWorktreeAsync(branchSnapshot, Path.Combine(testRoot, "new worktree"), "veo-worktree-branch");
Check(File.Exists(Path.Combine(worktree.Path, ".git")) && worktree.Head == committed.CommitId, "worktree creation verifies real .git indirection and base commit");
Check((await service.ListWorktreesAsync(repo)).Count == 2, "worktree inventory lists both working directories");

snapshot = await service.SnapshotAsync(repo);
var checkpointIndex = await Git("ls-files", "--stage", "-z");
var checkpointBytes = await File.ReadAllBytesAsync(Path.Combine(repo, selected));
var checkpoint = await service.CaptureCheckpointAsync(snapshot, "thread", "payload");
Check((await Git("rev-parse", checkpoint.FilesRef)).Length > 0 && (await Git("rev-parse", checkpoint.IndexRef)).Length > 0,
    "checkpoint records local file and index refs");
await File.WriteAllTextAsync(Path.Combine(repo, selected), "changed after checkpoint\r\n"); await Git("--literal-pathspecs", "add", "--", selected);
await File.WriteAllTextAsync(Path.Combine(repo, "untracked [x].txt"), "modified untracked");
await File.WriteAllTextAsync(Path.Combine(repo, "new-after.txt"), "new after checkpoint");
await File.AppendAllTextAsync(Path.Combine(repo, ".git", "info", "exclude"), "\nignored.tmp\n");
await File.WriteAllTextAsync(Path.Combine(repo, "ignored.tmp"), "preserve ignored");
var checkpointRestore = await service.RestoreCheckpointAsync(checkpoint);
Check((await File.ReadAllBytesAsync(Path.Combine(repo, selected))).SequenceEqual(checkpointBytes), "checkpoint restores exact CRLF worktree bytes");
Check((await Git("ls-files", "--stage", "-z")).SequenceEqual(checkpointIndex), "checkpoint restores staged split exactly");
Check(!File.Exists(Path.Combine(repo, "new-after.txt")) && await File.ReadAllTextAsync(Path.Combine(repo, "untracked [x].txt")) == "untracked bytes\r\n",
    "checkpoint restores untracked files and recovers/removes later additions");
Check(await File.ReadAllTextAsync(Path.Combine(repo, "ignored.tmp")) == "preserve ignored", "checkpoint leaves ignored files intact");
Check(checkpointRestore.Snapshot.Head == committed.CommitId && checkpointRestore.Snapshot.Branch == "veo-test-branch", "file-only checkpoint never moves HEAD or branch");
await Git("switch", "changed-context");
await Refuses(() => service.RestoreCheckpointAsync(checkpoint), "checkpoint refuses changed branch context");

var hunkName = "hunks.txt";
var baseLines = Enumerable.Range(1, 24).Select(i => "line " + i).ToArray();
await File.WriteAllTextAsync(Path.Combine(repo, hunkName), string.Join('\n', baseLines) + "\n");
await Git("add", "--", hunkName); await Git("commit", "--only", "-m", "Hunk fixture", "--", hunkName);
var changedLines = baseLines.ToArray(); changedLines[1] = "changed first"; changedLines[21] = "changed second";
await File.WriteAllTextAsync(Path.Combine(repo, hunkName), string.Join('\n', changedLines) + "\n");
snapshot = await service.SnapshotAsync(repo);
var patch = UnifiedDiff.Parse(await service.DiffAsync(snapshot, hunkName));
Check(patch.Hunks.Count == 2 && patch.Hunks[0].Lines.Any(line => line.Kind == DiffLineKind.Removed && line.OldLine == 2)
    && patch.Hunks[1].Lines.Any(line => line.Kind == DiffLineKind.Added && line.NewLine == 22), "native diff model preserves two hunk ranges and old/new line numbers");
var hunkResult = await service.ApplyHunkAsync(snapshot, hunkName, 0, patch.Hunks[0].Sha256);
var stagedHunkText = Encoding.UTF8.GetString(await Git("show", ":" + hunkName));
Check(stagedHunkText.Contains("changed first") && !stagedHunkText.Contains("changed second"), "stage hunk modifies only chosen index range");
Check(await File.ReadAllTextAsync(Path.Combine(repo, hunkName)) == string.Join('\n', changedLines) + "\n", "stage hunk leaves complete working text intact");
var reversePatch = UnifiedDiff.Parse(await service.DiffAsync(hunkResult.Snapshot, hunkName, staged: true));
var reversed = await service.ApplyHunkAsync(hunkResult.Snapshot, hunkName, 0, reversePatch.Hunks[0].Sha256, unstage: true);
Check(Encoding.UTF8.GetString(await Git("show", ":" + hunkName)) == string.Join('\n', baseLines) + "\n", "unstage hunk restores only chosen staged patch");
await Refuses(() => service.ApplyHunkAsync(reversed.Snapshot, hunkName, 0, "stale-patch-hash"), "hunk action refuses stale captured patch identity");
var noNewline = UnifiedDiff.Parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n");
Check(noNewline.Hunks[0].Lines.Count(line => line.Kind == DiffLineKind.NoFinalNewline) == 2, "diff model preserves no-final-newline markers without advancing line counts");
Check(UnifiedDiff.Parse("diff --git a/b b/b\nBinary files a/b and b/b differ\n").IsBinary, "diff model distinguishes binary file changes");

var firstPartial = Path.Combine(repo, "a-partial.txt"); var secondPartial = Path.Combine(repo, "z-readonly.txt");
await File.WriteAllTextAsync(firstPartial, "first saved bytes\r\n"); await File.WriteAllTextAsync(secondPartial, "readonly saved bytes\r\n");
File.SetAttributes(secondPartial, File.GetAttributes(secondPartial) | FileAttributes.ReadOnly);
snapshot = await service.SnapshotAsync(repo);
GitRecoveryReceipt? partialRecovery = null;
try { await service.DiscardAsync(snapshot, ["a-partial.txt", "z-readonly.txt"]); }
catch (GitRecoveryOperationException failure) { partialRecovery = failure.Recovery; }
Check(partialRecovery is not null && !File.Exists(firstPartial) && File.Exists(secondPartial), "partial discard failure returns durable recovery after a completed first deletion");
await service.RestoreRecoveryAsync(partialRecovery!);
Check(await File.ReadAllTextAsync(firstPartial) == "first saved bytes\r\n" && await File.ReadAllTextAsync(secondPartial) == "readonly saved bytes\r\n"
    && (File.GetAttributes(secondPartial) & FileAttributes.ReadOnly) != 0, "partial-failure recovery restores both exact files and readonly attribute");

Console.WriteLine(JsonSerializer.Serialize(new { Passed = passed.Count, Root = testRoot, Scenarios = passed }));
