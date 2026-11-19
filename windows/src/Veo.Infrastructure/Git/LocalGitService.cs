using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Veo.Infrastructure.Files;

namespace Veo.Infrastructure.Git;

/// <summary>Git for Windows adapter. Argument arrays and NUL records preserve literal filenames.</summary>
public sealed class LocalGitService
{
    private readonly string executable;
    private readonly string recoveryDirectory;
    private readonly SemaphoreSlim mutationGate = new(1, 1);
    private static readonly UTF8Encoding Utf8 = new(false, true);
    public LocalGitService(string recoveryDirectory, string gitExecutable = "git.exe")
    { this.recoveryDirectory = Path.GetFullPath(recoveryDirectory); executable = gitExecutable; }

    public async Task<GitRepositorySnapshot> SnapshotAsync(string workspacePath, CancellationToken token = default)
    {
        await mutationGate.WaitAsync(token);
        try { return await SnapshotCoreAsync(workspacePath, token); }
        finally { mutationGate.Release(); }
    }

    private async Task<GitRepositorySnapshot> SnapshotCoreAsync(string workspacePath, CancellationToken token)
    {
        var workspace = new WorkspacePathPolicy(workspacePath).RootPath;
        var rootResult = await RunAsync(workspace, ["rev-parse", "--show-toplevel"], token, requireSuccess: false);
        if (rootResult.ExitCode != 0)
        {
            if (rootResult.Stderr.Contains("not a git repository", StringComparison.OrdinalIgnoreCase)) throw new NotGitRepositoryException();
            throw new IOException("Git could not inspect this workspace: " + rootResult.Stderr.Trim());
        }
        var root = Text(rootResult);
        root = new WorkspacePathPolicy(root).RootPath;
        var policy = new WorkspacePathPolicy(root);
        var gitDirectory = Text(await RunAsync(root, ["rev-parse", "--absolute-git-dir"], token));
        var common = Text(await RunAsync(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"], token));
        var headResult = await RunAsync(root, ["rev-parse", "--verify", "HEAD"], token, requireSuccess: false);
        var head = headResult.ExitCode == 0 ? Text(headResult) : null;
        var branchResult = await RunAsync(root, ["symbolic-ref", "--quiet", "--short", "HEAD"], token, requireSuccess: false);
        var branch = branchResult.ExitCode == 0 ? Text(branchResult) : null;
        var status = await RunAsync(root, ["status", "--porcelain=v2", "-z", "--untracked-files=all"], token);
        var records = SplitNul(status.Stdout);
        var files = new List<GitFileChange>();
        for (var i = 0; i < records.Count; i++)
        {
            var record = records[i];
            if (record.Length == 0 || record[0] == '#') continue;
            string path; string? original = null; char x; char y; var untracked = false; var conflict = false;
            if (record.StartsWith("? ", StringComparison.Ordinal)) { path = record[2..]; x = '?'; y = '?'; untracked = true; }
            else if (record.StartsWith("1 ", StringComparison.Ordinal))
            { var fields = record.Split(' ', 9); RequireFields(fields, 9); path = fields[8]; x = fields[1][0]; y = fields[1][1]; }
            else if (record.StartsWith("2 ", StringComparison.Ordinal))
            { var fields = record.Split(' ', 10); RequireFields(fields, 10); path = fields[9]; x = fields[1][0]; y = fields[1][1]; original = ++i < records.Count ? records[i] : throw new InvalidDataException("Incomplete Git rename record."); }
            else if (record.StartsWith("u ", StringComparison.Ordinal))
            { var fields = record.Split(' ', 11); RequireFields(fields, 11); path = fields[10]; x = fields[1][0]; y = fields[1][1]; conflict = true; }
            else continue;
            bool inWorkspace;
            try { _ = new WorkspacePathPolicy(workspace).Resolve(Path.Combine(root, path), mustExist: false); inWorkspace = true; }
            catch (UnauthorizedAccessException) { inWorkspace = false; }
            files.Add(new(path, original, x, y, untracked, conflict, inWorkspace));
        }
        var entries = (await RunAsync(root, ["ls-files", "--stage", "-z"], token)).Stdout;
        var hashes = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var path in files.SelectMany(Paths).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal))
        {
            token.ThrowIfCancellationRequested();
            var target = policy.Resolve(path, mustExist: false);
            if (Directory.Exists(target)) hashes[path] = "directory";
            else if (!File.Exists(target)) hashes[path] = "absent";
            else
            {
                var info = new FileInfo(target);
                // Unsafe links are visible but cannot be mutated; never read an escaped target.
                if ((info.Attributes & FileAttributes.ReparsePoint) != 0) hashes[path] = "link:" + info.LinkTarget;
                else hashes[path] = await HashFileAsync(target, token);
            }
        }
        var busy = File.Exists(Path.Combine(gitDirectory, "index.lock")) ||
            new[] { "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer" }
                .Any(name => File.Exists(Path.Combine(gitDirectory, name)) || Directory.Exists(Path.Combine(gitDirectory, name)));
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        void Hash(string value) => digest.AppendData(Utf8.GetBytes(value + "\0"));
        Hash(root); Hash(workspace); Hash(common); Hash(head ?? ""); Hash(branch ?? "");
        digest.AppendData(status.Stdout); digest.AppendData(entries);
        foreach (var pair in hashes) { Hash(pair.Key); Hash(pair.Value); }
        return new(Convert.ToHexString(digest.GetHashAndReset()), root, workspace, common, gitDirectory,
            head, branch, !busy && !files.Any(f => f.IsConflict), files, entries, hashes);
    }

    public async Task<string> DiffAsync(GitRepositorySnapshot expected, string path, bool staged = false,
        bool ignoreWhitespace = false, CancellationToken token = default)
    {
        await mutationGate.WaitAsync(token);
        try
        {
            var current = await ValidateAsync(expected, token, mutation: false);
            var selected = SelectPaths(current, [path]);
            var args = new List<string> { "diff", "--no-ext-diff", "--no-textconv", "--binary", "--no-color" };
            if (staged) args.Add("--cached"); if (ignoreWhitespace) args.Add("--ignore-all-space");
            args.Add("--"); args.AddRange(selected);
            return Utf8.GetString((await RunAsync(current.RootPath, args, token)).Stdout);
        }
        finally { mutationGate.Release(); }
    }

    public Task<GitMutationResult> StageAsync(GitRepositorySnapshot expected, IReadOnlyList<string> paths,
        CancellationToken token = default) => MutateIndexAsync(expected, paths, stage: true, token);
    public Task<GitMutationResult> UnstageAsync(GitRepositorySnapshot expected, IReadOnlyList<string> paths,
        CancellationToken token = default) => MutateIndexAsync(expected, paths, stage: false, token);

    public async Task<GitMutationResult> ApplyHunkAsync(GitRepositorySnapshot expected, string path,
        int hunkIndex, string expectedPatchSha256, bool unstage = false, CancellationToken token = default)
    {
        await mutationGate.WaitAsync(token);
        try
        {
            var before = await ValidateAsync(expected, token);
            var paths = SelectPaths(before, [path]);
            var change = before.Files.Single(file => file.Path == path);
            if (change.IsUntracked || change.OriginalPath is not null || change.IndexStatus is 'A' or 'D' or 'R' or 'C' || change.WorktreeStatus is 'A' or 'D' or 'R' or 'C')
                throw new IOException("Hunk actions are available for ordinary modified tracked files. Stage or unstage other file types as a whole.");
            var args = new List<string> { "diff", "--no-ext-diff", "--no-textconv", "--no-color" };
            if (unstage) args.Add("--cached"); args.Add("--"); args.Add(path);
            var document = UnifiedDiff.Parse(Utf8.GetString((await RunAsync(before.RootPath, args, token)).Stdout));
            if (document.IsBinary || document.IsNewFile || document.IsDeletedFile || document.IsRename || hunkIndex < 0 || hunkIndex >= document.Hunks.Count)
                throw new IOException("That hunk cannot be changed safely. Refresh the review.");
            var hunk = document.Hunks[hunkIndex];
            if (hunk.Sha256 != expectedPatchSha256) throw new StaleGitSnapshotException();
            var apply = new List<string> { "apply", "--cached", "--whitespace=nowarn" };
            if (unstage) apply.Add("--reverse");
            var check = new List<string>(apply) { "--check", "-" };
            await RunAsync(before.RootPath, check, token, input: Utf8.GetBytes(hunk.Patch));
            await ValidateAsync(before, token);
            apply.Add("-"); await RunAsync(before.RootPath, apply, token, input: Utf8.GetBytes(hunk.Patch));
            var after = await SnapshotCoreAsync(before.WorkspacePath, token);
            VerifyUnrelated(before, after, paths);
            if (before.ChangedFileHashes[path] != await HashFileAsync(ValidateMutationPath(after, path), token))
                throw new IOException("The working file changed during the hunk action. Inspect the repository before continuing.");
            return new(after);
        }
        finally { mutationGate.Release(); }
    }

    private async Task<GitMutationResult> MutateIndexAsync(GitRepositorySnapshot expected, IReadOnlyList<string> requested,
        bool stage, CancellationToken token)
    {
        await mutationGate.WaitAsync(token);
        try
        {
            var before = await ValidateAsync(expected, token);
            var paths = SelectPaths(before, requested);
            var args = stage ? new List<string> { "add", "--all", "--" } : before.Head is null
                ? new List<string> { "update-index", "--force-remove", "--" }
                : new List<string> { "restore", "--staged", "--no-recurse-submodules", "--" };
            args.AddRange(paths);
            await RunAsync(before.RootPath, args, token);
            var after = await SnapshotCoreAsync(before.WorkspacePath, token);
            VerifyUnrelated(before, after, paths);
            return new(after);
        }
        finally { mutationGate.Release(); }
    }

    public async Task<GitMutationResult> DiscardAsync(GitRepositorySnapshot expected, IReadOnlyList<string> requested,
        GitDiscardMode mode = GitDiscardMode.UnstagedOnly, CancellationToken token = default)
    {
        await mutationGate.WaitAsync(token);
        GitRecoveryReceipt? savedRecovery = null;
        try
        {
            var before = await ValidateAsync(expected, token);
            var paths = SelectPaths(before, requested);
            var selected = before.Files.Where(f => requested.Contains(f.Path, StringComparer.Ordinal)).ToList();
            var receipt = await CreateRecoveryAsync(before, paths, token);
            savedRecovery = receipt;
            // Saving recovery can take time; no mutation uses an earlier, now stale snapshot.
            await ValidateAsync(before, token);
            var tracked = selected.Where(f => !f.IsUntracked).SelectMany(Paths).Distinct(StringComparer.Ordinal).ToList();
            if (tracked.Count > 0)
            {
                var args = mode == GitDiscardMode.UnstagedOnly
                    ? new List<string> { "restore", "--worktree", "--no-recurse-submodules", "--" }
                    : before.Head is null ? new List<string> { "update-index", "--force-remove", "--" }
                    : new List<string> { "restore", "--source=HEAD", "--staged", "--worktree", "--no-recurse-submodules", "--" };
                args.AddRange(tracked); await RunAsync(before.RootPath, args, token);
            }
            var deletions = selected.Where(f => f.IsUntracked || (mode == GitDiscardMode.AllChanges && before.Head is null)).SelectMany(Paths);
            foreach (var path in deletions.Distinct(StringComparer.Ordinal))
            {
                var target = ValidateMutationPath(before, path);
                if (File.Exists(target)) File.Delete(target);
            }
            var after = await SnapshotCoreAsync(before.WorkspacePath, token);
            VerifyUnrelated(before, after, paths);
            if (mode == GitDiscardMode.UnstagedOnly && !before.IndexEntries.AsSpan().SequenceEqual(after.IndexEntries))
                throw new IOException("Discard unexpectedly changed the index. The recovery bundle is intact at " + receipt.BundlePath);
            receipt = receipt with { AfterSnapshotId = after.Id };
            await WriteManifestAsync(receipt, token);
            return new(after, receipt);
        }
        catch (Exception error) when (savedRecovery is not null)
        { throw await RecoverableFailureAsync(savedRecovery, error); }
        finally { mutationGate.Release(); }
    }

    public async Task<GitMutationResult> RestoreRecoveryAsync(GitRecoveryReceipt receipt, CancellationToken token = default)
    {
        await mutationGate.WaitAsync(token);
        GitRecoveryReceipt? preRestore = null;
        try
        {
            var before = await SnapshotCoreAsync(receipt.WorkspacePath, token);
            if (before.Id != receipt.AfterSnapshotId || before.RootPath != receipt.RepositoryRoot ||
                before.Head != receipt.Head || before.Branch != receipt.Branch || !before.CanMutate) throw new StaleGitSnapshotException();
            var bundlePolicy = new WorkspacePathPolicy(recoveryDirectory);
            _ = bundlePolicy.Resolve(receipt.BundlePath);
            var verifiedFiles = new List<(GitRecoveryFile Metadata, string? BackupPath)>();
            foreach (var file in receipt.Files)
            {
                ValidateMutationPath(before, file.Path);
                string? source = null;
                if (file.BackupName is not null)
                {
                    source = new WorkspacePathPolicy(receipt.BundlePath).Resolve(file.BackupName);
                    if (await HashFileAsync(source, token) != file.Sha256) throw new InvalidDataException("Recovery data failed its integrity check.");
                }
                verifiedFiles.Add((file, source));
            }
            var indexPath = new WorkspacePathPolicy(receipt.BundlePath).Resolve("index-entries.bin");
            var index = await File.ReadAllBytesAsync(indexPath, token);
            var paths = receipt.Files.Select(f => f.Path).ToList();
            if (Convert.ToHexString(SHA256.HashData(index)) != receipt.IndexSha256)
                throw new InvalidDataException("Recovery index data failed its integrity check.");
            if (SplitNul(index).Any(entry => !paths.Contains(IndexPath(entry), StringComparer.Ordinal)))
                throw new InvalidDataException("Recovery index data contains an unrelated path.");
            // Capture the current state too, so a failed restore never loses its starting point.
            var reversal = await CreateRecoveryAsync(before, paths, token);
            preRestore = reversal;
            await ValidateAsync(before, token);
            foreach (var (file, source) in verifiedFiles)
            {
                var target = ValidateMutationPath(before, file.Path);
                if (source is null) { if (File.Exists(target)) File.Delete(target); }
                else
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                    if (File.Exists(target) && (File.GetAttributes(target) & FileAttributes.ReadOnly) != 0)
                        File.SetAttributes(target, File.GetAttributes(target) & ~FileAttributes.ReadOnly);
                    File.Copy(source, target, overwrite: true); File.SetAttributes(target, file.Attributes);
                }
            }
            await RunAsync(before.RootPath, ["update-index", "--force-remove", "--", .. paths], token);
            if (index.Length > 0) await RunAsync(before.RootPath, ["update-index", "-z", "--index-info"], token, input: index);
            var after = await SnapshotCoreAsync(before.WorkspacePath, token);
            VerifyUnrelated(before, after, paths);
            foreach (var file in receipt.Files)
            {
                var target = ValidateMutationPath(after, file.Path);
                if (file.Sha256 is null ? File.Exists(target) : !File.Exists(target) || await HashFileAsync(target, token) != file.Sha256)
                    throw new IOException("Recovery verification failed; the pre-restore backup remains at " + reversal.BundlePath);
            }
            reversal = reversal with { AfterSnapshotId = after.Id }; await WriteManifestAsync(reversal, token);
            return new(after, reversal);
        }
        catch (Exception error) when (preRestore is not null)
        { throw await RecoverableFailureAsync(preRestore, error); }
        finally { mutationGate.Release(); }
    }

    private async Task<GitRecoveryOperationException> RecoverableFailureAsync(GitRecoveryReceipt receipt, Exception error)
    {
        try
        {
            var current = await SnapshotCoreAsync(receipt.WorkspacePath, CancellationToken.None);
            receipt = receipt with { AfterSnapshotId = current.Id };
            await WriteManifestAsync(receipt, CancellationToken.None);
        }
        catch (Exception recoveryError) when (recoveryError is IOException or UnauthorizedAccessException or OperationCanceledException)
        { /* Exact-byte backup remains even if repository state is unavailable for automatic recovery. */ }
        return new("Git could not finish the action. Recovery is saved at " + receipt.BundlePath + ". " + error.Message, receipt, error);
    }

    private async Task<GitRecoveryReceipt> CreateRecoveryAsync(GitRepositorySnapshot snapshot, IReadOnlyList<string> paths, CancellationToken token)
    {
        var id = Guid.NewGuid().ToString("N"); var bundle = Path.Combine(recoveryDirectory, id);
        Directory.CreateDirectory(bundle);
        var files = new List<GitRecoveryFile>();
        foreach (var path in paths)
        {
            var target = ValidateMutationPath(snapshot, path);
            if (!File.Exists(target)) { files.Add(new(path, null, null, 0)); continue; }
            var name = files.Count.ToString("D6") + ".bin";
            var backupPath = Path.Combine(bundle, name);
            await using (var source = File.OpenRead(target))
            await using (var destination = new FileStream(backupPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                await source.CopyToAsync(destination, token);
            files.Add(new(path, name, await HashFileAsync(backupPath, token), File.GetAttributes(target)));
        }
        var selected = new HashSet<string>(paths, StringComparer.Ordinal);
        var index = SplitNul(snapshot.IndexEntries).Where(record => selected.Contains(IndexPath(record)));
        var indexBytes = Utf8.GetBytes(string.Concat(index.Select(record => record + "\0")));
        await File.WriteAllBytesAsync(Path.Combine(bundle, "index-entries.bin"), indexBytes, token);
        var receipt = new GitRecoveryReceipt(id, bundle, snapshot.RootPath, snapshot.WorkspacePath, snapshot.Head, snapshot.Branch, "", files,
            Convert.ToHexString(SHA256.HashData(indexBytes)));
        await WriteManifestAsync(receipt, token);
        return receipt;
    }

    private static async Task WriteManifestAsync(GitRecoveryReceipt receipt, CancellationToken token) =>
        await File.WriteAllTextAsync(Path.Combine(receipt.BundlePath, "manifest.json"), JsonSerializer.Serialize(receipt, new JsonSerializerOptions { WriteIndented = true }), token);

    public async Task<GitCommitResult> CommitSelectedAsync(GitRepositorySnapshot expected, IReadOnlyList<string> requested,
        string message, CancellationToken token = default)
    {
        if (string.IsNullOrWhiteSpace(message) || message.Contains('\0')) throw new ArgumentException("Enter a commit message.", nameof(message));
        await mutationGate.WaitAsync(token);
        try
        {
            var before = await ValidateAsync(expected, token);
            if (before.Branch is null) throw new IOException("Create or switch to a branch before committing selected files.");
            var paths = SelectPaths(before, requested);
            var selected = before.Files.Where(file => requested.Contains(file.Path, StringComparer.Ordinal)).ToList();
            if (selected.Any(file => !file.HasStagedChanges || file.HasUnstagedChanges))
                throw new IOException("Selected files must be fully staged with no unstaged changes before committing.");
            if (before.Head is null && before.Files.Where(file => file.HasStagedChanges).SelectMany(Paths).Except(paths, StringComparer.Ordinal).Any())
                throw new IOException("The first commit must include every staged file. Unstage files to exclude first.");
            var emptyHooks = Path.Combine(recoveryDirectory, "disabled-hooks"); Directory.CreateDirectory(emptyHooks);
            var args = new List<string> { "-c", "core.hooksPath=" + emptyHooks, "-c", "commit.gpgSign=false",
                "commit", "--no-verify", "--no-gpg-sign", "--cleanup=verbatim", "-m", message };
            if (before.Head is not null) { args.Add("--only"); args.Add("--"); args.AddRange(paths); }
            await RunAsync(before.RootPath, args, token);
            var after = await SnapshotCoreAsync(before.WorkspacePath, token);
            var committed = SplitNul((await RunAsync(before.RootPath,
                ["diff-tree", "--root", "--no-commit-id", "--name-only", "-r", "-z", "--no-renames", "HEAD"], token)).Stdout);
            if (!new HashSet<string>(committed, StringComparer.Ordinal).SetEquals(paths))
                throw new IOException("The new commit's paths differ from the explicit selection. Inspect Git before continuing.");
            VerifyIndexOutsideSelection(before, after, paths);
            foreach (var path in paths)
                if (before.ChangedFileHashes.TryGetValue(path, out var hash) && hash != "absent" &&
                    await HashFileAsync(ValidateMutationPath(after, path), token) != hash)
                    throw new IOException("A selected working file changed during commit.");
            return new(after.Head!, after);
        }
        finally { mutationGate.Release(); }
    }

    public async Task<GitRepositorySnapshot> CreateBranchAsync(GitRepositorySnapshot expected, string branch,
        CancellationToken token = default)
    {
        await mutationGate.WaitAsync(token);
        try
        {
            var before = await ValidateAsync(expected, token);
            if (before.Head is null) throw new IOException("Create the initial commit before creating a branch.");
            await RunAsync(before.RootPath, ["check-ref-format", "--branch", branch], token);
            await RunAsync(before.RootPath, ["switch", "-c", branch, "--no-guess"], token);
            var after = await SnapshotCoreAsync(before.WorkspacePath, token);
            if (after.Branch != branch || after.Head != before.Head || !after.IndexEntries.AsSpan().SequenceEqual(before.IndexEntries))
                throw new IOException("The new branch did not preserve the expected repository state.");
            return after;
        }
        finally { mutationGate.Release(); }
    }

    public async Task<IReadOnlyList<string>> WorktreeBaseBranchesAsync(string workspace, CancellationToken token = default)
    {
        var output = (await RunAsync(workspace, ["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"], token)).Stdout;
        return Utf8.GetString(output).Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).Where(name => !name.EndsWith("/HEAD", StringComparison.Ordinal)).Distinct(StringComparer.Ordinal).ToArray();
    }
    public async Task<IReadOnlyList<GitWorktree>> ListWorktreesAsync(string workspace, CancellationToken token = default)
    {
        var records = SplitNul((await RunAsync(workspace, ["worktree", "list", "--porcelain", "-z"], token)).Stdout);
        var results = new List<GitWorktree>(); string? path = null, head = null, branch = null; bool bare = false, detached = false;
        void Add() { if (path is not null) results.Add(new(new WorkspacePathPolicy(path).RootPath, head, branch, bare, detached)); }
        foreach (var record in records)
        {
            if (record.StartsWith("worktree ", StringComparison.Ordinal)) { Add(); path = record[9..]; head = branch = null; bare = detached = false; }
            else if (record.StartsWith("HEAD ", StringComparison.Ordinal)) head = record[5..];
            else if (record.StartsWith("branch ", StringComparison.Ordinal)) branch = record[7..];
            else if (record == "bare") bare = true; else if (record == "detached") detached = true;
        }
        Add(); return results;
    }

    public async Task<GitWorktree> CreateWorktreeAsync(GitRepositorySnapshot expected, string destination,
        string branch, string baseRef = "HEAD", CancellationToken token = default)
    {
        await mutationGate.WaitAsync(token);
        try
        {
            var before = await ValidateAsync(expected, token);
            if (before.Head is null) throw new IOException("Worktrees need an existing commit.");
            destination = Path.GetFullPath(destination);
            if (File.Exists(destination) || Directory.Exists(destination)) throw new IOException("Choose a new directory for the worktree.");
            await RunAsync(before.RootPath, ["check-ref-format", "--branch", branch], token);
            var commit = Text(await RunAsync(before.RootPath, ["rev-parse", "--verify", "--end-of-options", baseRef + "^{commit}"], token));
            await RunAsync(before.RootPath, ["worktree", "add", "-b", branch, "--", destination, commit], token);
            var canonicalDestination = new WorkspacePathPolicy(destination).RootPath;
            return (await ListWorktreesAsync(before.RootPath, token)).SingleOrDefault(w => w.Path == canonicalDestination)
                ?? throw new IOException("Git created the worktree but it could not be verified. Refresh before retrying.");
        }
        finally { mutationGate.Release(); }
    }

    public async Task<WorkspaceCheckpoint> CaptureCheckpointAsync(GitRepositorySnapshot expected,
        string threadId, string payloadId, CancellationToken token = default)
    {
        await mutationGate.WaitAsync(token);
        try { return await CaptureCheckpointCoreAsync(expected, threadId, payloadId, token); }
        finally { mutationGate.Release(); }
    }
    private async Task<WorkspaceCheckpoint> CaptureCheckpointCoreAsync(GitRepositorySnapshot expected,
        string threadId, string payloadId, CancellationToken token)
    {
        var before = await ValidateAsync(expected, token);
        if (before.Head is null) throw new IOException("Checkpoints need an existing commit.");
        var scope = Path.GetRelativePath(before.RootPath, before.WorkspacePath).Replace('\\', '/');
        var entries = SplitNul((await RunAsync(before.RootPath, ["ls-files", "--stage", "-z", "--", scope], token)).Stdout);
        if (entries.Any(e => e.StartsWith("160000 ", StringComparison.Ordinal) || e.StartsWith("120000 ", StringComparison.Ordinal)))
            throw new IOException("Checkpoints cannot include submodules or symbolic links.");
        var paths = SplitNul((await RunAsync(before.RootPath, ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", scope], token)).Stdout).Distinct(StringComparer.Ordinal).ToList();
        foreach (var path in paths) ValidateMutationPath(before, path);
        var recovery = await CreateRecoveryAsync(before, paths, token);
        var indexTree = Text(await RunAsync(before.RootPath, ["write-tree"], token));
        var tempIndex = Path.Combine(recovery.BundlePath, "capture-index");
        await RunAsync(before.RootPath, ["read-tree", indexTree], token, indexFile: tempIndex);
        await RunAsync(before.RootPath, ["add", "--all", "--", scope], token, indexFile: tempIndex);
        var filesTree = Text(await RunAsync(before.RootPath, ["write-tree"], token, indexFile: tempIndex));
        var after = await ValidateAsync(before, token);
        // Dirty state alone cannot detect a clean tracked file changing while it was copied.
        foreach (var file in recovery.Files.Where(f => f.Sha256 is not null))
            if (!File.Exists(ValidateMutationPath(after, file.Path)) || await HashFileAsync(ValidateMutationPath(after, file.Path), token) != file.Sha256)
                throw new StaleGitSnapshotException();
        var id = Guid.NewGuid().ToString("N");
        var filesRef = "refs/veo/checkpoints/" + id + "/files"; var indexRef = "refs/veo/checkpoints/" + id + "/index";
        await RunAsync(before.RootPath, ["update-ref", filesRef, filesTree], token);
        await RunAsync(before.RootPath, ["update-ref", indexRef, indexTree], token);
        var checkpoint = new WorkspaceCheckpoint(id, threadId, payloadId, before.WorkspacePath, before.RootPath,
            before.Head, before.Branch, filesRef, indexRef, filesTree, indexTree, recovery, DateTimeOffset.UtcNow);
        await File.WriteAllTextAsync(Path.Combine(recovery.BundlePath, "checkpoint.json"), JsonSerializer.Serialize(checkpoint), token);
        return checkpoint;
    }

    public Task<GitMutationResult> RestoreCheckpointAsync(WorkspaceCheckpoint checkpoint, CancellationToken token = default) =>
        RestoreCheckpointAsync(checkpoint, expected: null, token);

    public async Task<GitMutationResult> RestoreCheckpointAsync(WorkspaceCheckpoint checkpoint, GitRepositorySnapshot? expected, CancellationToken token = default)
    {
        // RestoreRecovery owns the mutation gate; first gather immutable checkpoint validation.
        var current = await SnapshotAsync(checkpoint.WorkspacePath, token);
        if (expected is not null && (current.Id != expected.Id || current.CommonDirectory != expected.CommonDirectory))
            throw new StaleGitSnapshotException();
        if (current.RootPath != checkpoint.RepositoryRoot || current.Head != checkpoint.Head || current.Branch != checkpoint.Branch || !current.CanMutate)
            throw new IOException("The branch or HEAD changed. Return to the checkpoint's original branch and commit before restoring files.");
        var filesTree = Text(await RunAsync(current.RootPath, ["rev-parse", "--verify", checkpoint.FilesRef], token));
        var indexTree = Text(await RunAsync(current.RootPath, ["rev-parse", "--verify", checkpoint.IndexRef], token));
        if (filesTree != checkpoint.FilesTree || indexTree != checkpoint.IndexTree) throw new InvalidDataException("Checkpoint refs changed after capture.");
        var scope = Path.GetRelativePath(current.RootPath, current.WorkspacePath).Replace('\\', '/');
        var nowPaths = SplitNul((await RunAsync(current.RootPath, ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", scope], token)).Stdout);
        var savedPaths = new HashSet<string>(checkpoint.Recovery.Files.Select(file => file.Path), StringComparer.Ordinal);
        foreach (var file in checkpoint.Recovery.Files)
        {
            var target = ValidateMutationPath(current, file.Path);
            if (File.Exists(target) && !nowPaths.Contains(file.Path, StringComparer.Ordinal))
                throw new IOException("A saved checkpoint path is now ignored. Restore it manually to preserve that file.");
        }
        var files = checkpoint.Recovery.Files.Concat(nowPaths.Distinct(StringComparer.Ordinal).Where(path => !savedPaths.Contains(path)).Select(path => new GitRecoveryFile(path, null, null, 0))).ToList();
        var receipt = checkpoint.Recovery with { AfterSnapshotId = current.Id, Files = files };
        return await RestoreRecoveryAsync(receipt, token);
    }

    private static void VerifyIndexOutsideSelection(GitRepositorySnapshot before, GitRepositorySnapshot after, IReadOnlyList<string> paths)
    {
        var affected = new HashSet<string>(paths, StringComparer.Ordinal);
        if (!SplitNul(before.IndexEntries).Where(record => !affected.Contains(IndexPath(record))).SequenceEqual(
            SplitNul(after.IndexEntries).Where(record => !affected.Contains(IndexPath(record)))))
            throw new IOException("Unrelated index entries changed during the operation.");
    }

    private async Task<GitRepositorySnapshot> ValidateAsync(GitRepositorySnapshot expected, CancellationToken token, bool mutation = true)
    {
        var current = await SnapshotCoreAsync(expected.WorkspacePath, token);
        if (current.Id != expected.Id || current.RootPath != expected.RootPath || current.CommonDirectory != expected.CommonDirectory)
            throw new StaleGitSnapshotException();
        if (mutation && !current.CanMutate) throw new IOException("Resolve conflicts or finish the current Git operation before changing files.");
        return current;
    }
    private static List<string> SelectPaths(GitRepositorySnapshot snapshot, IReadOnlyList<string> requested)
    {
        if (requested.Count == 0) throw new ArgumentException("Choose at least one changed file.", nameof(requested));
        var result = new HashSet<string>(StringComparer.Ordinal);
        foreach (var path in requested)
        {
            var file = snapshot.Files.SingleOrDefault(f => f.Path == path) ?? throw new StaleGitSnapshotException();
            if (!file.IsInWorkspace || file.IsConflict) throw new UnauthorizedAccessException("The selected file cannot be changed in this workspace.");
            foreach (var item in Paths(file)) { ValidateMutationPath(snapshot, item); result.Add(item); }
        }
        return result.Order(StringComparer.Ordinal).ToList();
    }
    private static string ValidateMutationPath(GitRepositorySnapshot snapshot, string path)
    {
        var repoPolicy = new WorkspacePathPolicy(snapshot.RootPath);
        var target = repoPolicy.Resolve(path, mustExist: false);
        _ = new WorkspacePathPolicy(snapshot.WorkspacePath).Resolve(target, mustExist: false);
        if (Directory.Exists(target)) throw new IOException("Directory and submodule mutation is not supported.");
        if (File.Exists(target) && (File.GetAttributes(target) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Symbolic-link mutation is not supported.");
        // Symlink/junction ancestors are already resolved by policy. Refuse rewriting their alias paths.
        var literal = Path.GetFullPath(path, snapshot.RootPath);
        if (!string.Equals(literal, target, StringComparison.Ordinal)) throw new IOException("Linked paths cannot be changed by Git recovery.");
        return target;
    }
    private static void VerifyUnrelated(GitRepositorySnapshot before, GitRepositorySnapshot after, IReadOnlyList<string> paths)
    {
        if (before.Head != after.Head || before.Branch != after.Branch || before.CommonDirectory != after.CommonDirectory)
            throw new IOException("The repository context changed during the operation.");
        var affected = new HashSet<string>(paths, StringComparer.Ordinal);
        var a = SplitNul(before.IndexEntries).Where(r => !affected.Contains(IndexPath(r)));
        var b = SplitNul(after.IndexEntries).Where(r => !affected.Contains(IndexPath(r)));
        if (!a.SequenceEqual(b)) throw new IOException("Unrelated staged files changed during the operation.");
        foreach (var pair in before.ChangedFileHashes.Where(p => !affected.Contains(p.Key)))
            if (!after.ChangedFileHashes.TryGetValue(pair.Key, out var hash) || hash != pair.Value)
                throw new IOException("Unrelated working files changed during the operation.");
    }
    private static IEnumerable<string> Paths(GitFileChange file) => file.OriginalPath is null ? [file.Path] : [file.Path, file.OriginalPath];
    private static string IndexPath(string entry) => entry[(entry.IndexOf('\t') + 1)..];
    private static void RequireFields(string[] fields, int count)
    { if (fields.Length != count || fields[1].Length != 2) throw new InvalidDataException("Malformed Git status record."); }
    private static List<string> SplitNul(byte[] bytes) => Utf8.GetString(bytes).Split('\0', StringSplitOptions.RemoveEmptyEntries).ToList();
    private static string Text(GitProcessResult result) => Utf8.GetString(result.Stdout).TrimEnd('\r', '\n');
    private static async Task<string> HashFileAsync(string path, CancellationToken token)
    { await using var stream = File.OpenRead(path); return Convert.ToHexString(await SHA256.HashDataAsync(stream, token)); }

    private sealed record GitProcessResult(int ExitCode, byte[] Stdout, string Stderr);
    private async Task<GitProcessResult> RunAsync(string cwd, IReadOnlyList<string> arguments, CancellationToken token,
        bool requireSuccess = true, byte[]? input = null, string? indexFile = null)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromMinutes(2));
        var start = new ProcessStartInfo(executable) { WorkingDirectory = cwd, UseShellExecute = false,
            CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true };
        // Inherited GIT_DIR/GIT_INDEX_FILE must not retarget a user's review or mutate a different index.
        foreach (var key in start.Environment.Keys.Where(k => k.StartsWith("GIT_", StringComparison.OrdinalIgnoreCase)).ToArray()) start.Environment.Remove(key);
        start.Environment["GIT_TERMINAL_PROMPT"] = "0";
        start.Environment["LC_ALL"] = "C";
        if (indexFile is not null) start.Environment["GIT_INDEX_FILE"] = indexFile;
        start.ArgumentList.Add("--no-optional-locks"); start.ArgumentList.Add("--literal-pathspecs");
        start.ArgumentList.Add("-c"); start.ArgumentList.Add("core.longpaths=true");
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new IOException("Git could not be started.");
        using var registration = timeout.Token.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
        using var output = new MemoryStream();
        var stdout = process.StandardOutput.BaseStream.CopyToAsync(output, timeout.Token);
        var stderr = process.StandardError.ReadToEndAsync(timeout.Token);
        if (input is not null) await process.StandardInput.BaseStream.WriteAsync(input, timeout.Token);
        process.StandardInput.Close();
        await Task.WhenAll(stdout, process.WaitForExitAsync(timeout.Token));
        var errors = await stderr;
        var result = new GitProcessResult(process.ExitCode, output.ToArray(), errors);
        if (requireSuccess && result.ExitCode != 0) throw new IOException("Git failed: " + errors.Trim());
        return result;
    }
}
