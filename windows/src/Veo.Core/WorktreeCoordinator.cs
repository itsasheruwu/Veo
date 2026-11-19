using System.Text;
using Veo.Infrastructure.Files;
using Veo.Infrastructure.Git;
using Veo.Infrastructure.Projects;

namespace Veo.Core;

public sealed record WorktreeContext(GitRepositorySnapshot Snapshot, IReadOnlyList<GitWorktree> Worktrees, IReadOnlyList<string> Bases, ProjectConfiguration Configuration);
public sealed class WorktreeCoordinator(WorkspaceCoordinator workspace, ProjectPreferencesService projects)
{
    readonly LocalGitService git = new(Path.Combine(workspace.DataRoot, "GitRecovery"));
    public async Task<WorktreeContext> InspectAsync(string path, CancellationToken token = default) =>
        new(await git.SnapshotAsync(path, token), await git.ListWorktreesAsync(path, token),
            await git.WorktreeBaseBranchesAsync(path, token), await projects.ConfigurationAsync(path, token));
    public static string SuggestedDestination(string projectPath, string branch)
    {
        var project = Path.TrimEndingDirectorySeparator(Path.GetFullPath(projectPath)); var name = Path.GetFileName(project);
        var safe = string.Concat(branch.Select(c => Path.GetInvalidFileNameChars().Contains(c) || c is '/' or '\\' ? '-' : c));
        if (string.IsNullOrWhiteSpace(safe) || safe is "." or ".." || safe.Length > 120) throw new ArgumentException("Choose a short branch name for the worktree folder.");
        return Path.Combine(Path.GetDirectoryName(project) ?? throw new ArgumentException("Choose a project below a drive root."), name + "-" + safe);
    }
    public static string SuggestedBranch(WorktreeContext context)
    {
        for (var number = 1; number < 100000; number++)
        { var name = "codex/task-" + number; if (!context.Bases.Contains(name, StringComparer.Ordinal) && !Path.Exists(SuggestedDestination(context.Snapshot.RootPath, name))) return name; }
        throw new IOException("No unused task branch name is available.");
    }
    public async Task<ThreadSession> CreateAsync(GitRepositorySnapshot expected, string branch, string destination, string baseRef = "HEAD", CancellationToken token = default)
    {
        var created = await git.CreateWorktreeAsync(expected, destination, branch, baseRef, token);
        await projects.RegisterWorktreeAsync(created.Path, expected.WorkspacePath, token); return await workspace.CreateAsync(created.Path);
    }
    public async Task<ThreadSession> ReuseAsync(GitRepositorySnapshot expected, string path, CancellationToken token = default)
    {
        var current = await git.SnapshotAsync(expected.WorkspacePath, token);
        if (current.CommonDirectory != expected.CommonDirectory || current.RootPath != expected.RootPath) throw new StaleGitSnapshotException();
        var canonical = new WorkspacePathPolicy(path).RootPath;
        var tree = (await git.ListWorktreesAsync(expected.WorkspacePath, token)).FirstOrDefault(x => x.Path.Equals(canonical, StringComparison.OrdinalIgnoreCase) && !x.IsBare) ?? throw new InvalidOperationException("The chosen directory is no longer a worktree of this repository.");
        if (!tree.Path.Equals(expected.WorkspacePath, StringComparison.OrdinalIgnoreCase))
            await projects.RegisterWorktreeAsync(tree.Path, expected.WorkspacePath, token);
        return await workspace.CreateAsync(tree.Path);
    }
    public static ProjectAction? SetupAction(ProjectConfiguration configuration)
    {
        var actions = (configuration.Actions ?? []).Where(x => x.OfferOnWorktreeCreate).ToArray(); if (actions.Length == 0) return null;
        var script = "& {\n$ErrorActionPreference = 'Stop'\n" + string.Join("\n", actions.Select(action => "& {\n" + action.Command + "\n}\nif (-not $?) { throw 'Project setup action failed.' }")) + "\n}";
        if (Encoding.UTF8.GetByteCount(script) > 32768) throw new ArgumentException("Combined setup actions exceed 32 KB. Create without setup, or save a project script.");
        return new("worktree-setup", "Worktree setup", script, true);
    }
}
