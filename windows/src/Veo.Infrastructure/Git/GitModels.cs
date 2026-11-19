namespace Veo.Infrastructure.Git;

public sealed record GitFileChange(string Path, string? OriginalPath, char IndexStatus, char WorktreeStatus,
    bool IsUntracked, bool IsConflict, bool IsInWorkspace)
{
    public bool HasStagedChanges => IndexStatus is not '.' and not ' ' and not '?';
    public bool HasUnstagedChanges => IsUntracked || WorktreeStatus is not '.' and not ' ';
}
public sealed record GitRepositorySnapshot(string Id, string RootPath, string WorkspacePath, string CommonDirectory,
    string GitDirectory, string? Head, string? Branch, bool CanMutate, IReadOnlyList<GitFileChange> Files,
    byte[] IndexEntries, IReadOnlyDictionary<string, string> ChangedFileHashes);
public enum GitDiscardMode { UnstagedOnly, AllChanges }
public sealed record GitRecoveryFile(string Path, string? BackupName, string? Sha256, FileAttributes Attributes);
public sealed record GitRecoveryReceipt(string Id, string BundlePath, string RepositoryRoot, string WorkspacePath,
    string? Head, string? Branch, string AfterSnapshotId, IReadOnlyList<GitRecoveryFile> Files,
    string IndexSha256 = "");
public sealed record GitMutationResult(GitRepositorySnapshot Snapshot, GitRecoveryReceipt? Recovery = null);
public sealed record GitCommitResult(string CommitId, GitRepositorySnapshot Snapshot);
public sealed record GitWorktree(string Path, string? Head, string? Branch, bool IsBare, bool IsDetached);
public sealed record WorkspaceCheckpoint(string Id, string ThreadId, string PayloadId, string WorkspacePath,
    string RepositoryRoot, string? Head, string? Branch, string FilesRef, string IndexRef,
    string FilesTree, string IndexTree, GitRecoveryReceipt Recovery, DateTimeOffset CreatedAt);
public sealed class StaleGitSnapshotException() : IOException("The repository changed after this review was loaded. Refresh before changing files.");
public sealed class NotGitRepositoryException() : IOException("This workspace has no Git repository.");
public sealed class GitRecoveryOperationException(string message, GitRecoveryReceipt recovery, Exception inner)
    : IOException(message, inner)
{ public GitRecoveryReceipt Recovery { get; } = recovery; }
