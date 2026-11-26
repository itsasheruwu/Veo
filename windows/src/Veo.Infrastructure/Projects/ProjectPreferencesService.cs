using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using Veo.Infrastructure.Files;
using Veo.Infrastructure.Git;
using Veo.Infrastructure.Storage;

namespace Veo.Infrastructure.Projects;

public sealed record ProjectAction(string Id, string Name, string Command, bool OfferOnWorktreeCreate = false);
public sealed record ProjectConfiguration(string? ModelId = null, string? ReasoningEffort = null, bool UsesWorktree = false,
    bool? CheckpointsEnabled = null, ProjectAction[]? Actions = null)
{
    public ProjectConfiguration Freeze() => this with { Actions = Actions?.ToArray() ?? [] };
}
public interface IProjectRepositoryIdentity
{
    Task<string?> GetAsync(string path, CancellationToken token = default);
}
public sealed class GitProjectRepositoryIdentity : IProjectRepositoryIdentity
{
    readonly LocalGitService git = new(Path.Combine(Path.GetTempPath(), "Veo.ReadOnlyGitIdentity"));
    public async Task<string?> GetAsync(string path, CancellationToken token = default)
    {
        try
        {
            var common = await git.CommonDirectoryAsync(path, token);
            if (!OperatingSystem.IsWindows()) return common + ":" + Directory.GetCreationTimeUtc(common).Ticks;
            using var handle = CreateFileW(common.StartsWith("\\\\", StringComparison.Ordinal) ? "\\\\?\\UNC\\" + common[2..] : "\\\\?\\" + common, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
            if (handle.IsInvalid || !GetFileInformationByHandle(handle, out var info)) throw new IOException("The repository directory identity could not be verified.");
            return $"{common}:{info.VolumeSerial:X8}:{info.FileIndexHigh:X8}{info.FileIndexLow:X8}:{info.CreationHigh:X8}{info.CreationLow:X8}";
        }
        catch (Exception error) when (error is NotGitRepositoryException or DirectoryNotFoundException) { return null; }
    }
    [StructLayout(LayoutKind.Sequential)] struct Information
    { public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh, VolumeSerial, SizeHigh, SizeLow, Links, FileIndexHigh, FileIndexLow; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Information info);
}
public sealed class ProjectPreferencesService(ThreadRepository repository, IProjectRepositoryIdentity? repositoryIdentity = null)
{
    sealed record WorktreeMapping(string ProjectPath, string Identity);
    sealed record Preferences(Dictionary<string, ProjectConfiguration> Configurations, Dictionary<string, WorktreeMapping> Worktrees);
    static readonly ConcurrentDictionary<string, SemaphoreSlim> Gates = new(StringComparer.OrdinalIgnoreCase);
    readonly SemaphoreSlim gate = Gates.GetOrAdd(repository.DatabasePath, _ => new(1, 1));
    readonly IProjectRepositoryIdentity identity = repositoryIdentity ?? new GitProjectRepositoryIdentity();
    public async Task<string> ProjectPathAsync(string path, CancellationToken token = default)
    { await gate.WaitAsync(token); try { return await ProjectPathCoreAsync(path, await ReadAsync(token), token); } finally { gate.Release(); } }
    public async Task<ProjectConfiguration> ConfigurationAsync(string path, CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        try { var preferences = await ReadAsync(token); var key = await ProjectPathCoreAsync(path, preferences, token); return (preferences.Configurations.GetValueOrDefault(key) ?? new()).Freeze(); }
        finally { gate.Release(); }
    }
    public async Task SetAsync(string path, ProjectConfiguration configuration, CancellationToken token = default)
    {
        Validate(configuration); var frozen = configuration.Freeze(); await gate.WaitAsync(token);
        try { var preferences = await ReadAsync(token); var key = await ProjectPathCoreAsync(path, preferences, token); preferences.Configurations[key] = frozen; await WriteAsync(preferences, token); }
        finally { gate.Release(); }
    }
    public async Task ResetDefaultsAsync(string path, CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        try
        {
            var preferences = await ReadAsync(token); var key = await ProjectPathCoreAsync(path, preferences, token); var current = preferences.Configurations.GetValueOrDefault(key) ?? new();
            preferences.Configurations[key] = current with { ModelId = null, ReasoningEffort = null, UsesWorktree = false, CheckpointsEnabled = null }; await WriteAsync(preferences, token);
        }
        finally { gate.Release(); }
    }
    public async Task RegisterWorktreeAsync(string worktree, string project, CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        try
        {
            var preferences = await ReadAsync(token); var key = Normalize(worktree); var parent = await ProjectPathCoreAsync(project, preferences, token);
            var worktreeId = await identity.GetAsync(key, token); var projectId = await identity.GetAsync(parent, token);
            if (worktreeId is null || worktreeId != projectId) throw new InvalidOperationException("A worktree can inherit settings only from its verified common Git repository.");
            preferences.Worktrees[key] = new(parent, worktreeId); await WriteAsync(preferences, token);
        }
        finally { gate.Release(); }
    }
    public async Task<IReadOnlyList<string>> ConfiguredPathsAsync(CancellationToken token = default)
    { await gate.WaitAsync(token); try { return (await ReadAsync(token)).Configurations.Keys.Order(StringComparer.OrdinalIgnoreCase).ToArray(); } finally { gate.Release(); } }
    public async Task<IReadOnlyDictionary<string, string>> RegisteredProjectPathsAsync(IEnumerable<string> paths, CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        try
        {
            var preferences = await ReadAsync(token);
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var path in paths.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                if (!preferences.Worktrees.ContainsKey(Path.TrimEndingDirectorySeparator(path)) || !Directory.Exists(path)) continue;
                var projectPath = await ProjectPathCoreAsync(path, preferences, token);
                if (!projectPath.Equals(path, StringComparison.OrdinalIgnoreCase)) result[path] = projectPath;
            }
            return result;
        }
        finally { gate.Release(); }
    }
    async Task<string> ProjectPathCoreAsync(string path, Preferences preferences, CancellationToken token)
    {
        var key = Normalize(path);
        if (preferences.Worktrees.TryGetValue(key, out var mapping) && await identity.GetAsync(key, token) == mapping.Identity && await identity.GetAsync(mapping.ProjectPath, token) == mapping.Identity) return mapping.ProjectPath;
        return key;
    }
    static string Normalize(string path) => new WorkspacePathPolicy(path).RootPath;
    async Task<Preferences> ReadAsync(CancellationToken token)
    {
        var json = await repository.ReadStateAsync("projects", "preferences", token); var saved = json is null ? null : JsonSerializer.Deserialize<Preferences>(json);
        return new(new(saved?.Configurations ?? [], StringComparer.OrdinalIgnoreCase), new(saved?.Worktrees ?? [], StringComparer.OrdinalIgnoreCase));
    }
    Task WriteAsync(Preferences value, CancellationToken token) => repository.SaveStateAsync("projects", "preferences", JsonSerializer.Serialize(value), token);
    public static void Validate(ProjectConfiguration configuration)
    {
        if (configuration.ModelId?.IndexOf('\0') >= 0 || configuration.ReasoningEffort?.IndexOf('\0') >= 0) throw new ArgumentException("Project defaults contain an invalid value.");
        if (configuration.ModelId is null && configuration.ReasoningEffort is not null) throw new ArgumentException("A reasoning default needs an explicit project model.");
        var actions = configuration.Actions ?? [];
        if (actions.Select(x => x.Id).Distinct(StringComparer.Ordinal).Count() != actions.Length) throw new ArgumentException("Project action identities must be distinct.");
        foreach (var action in actions)
        {
            if (string.IsNullOrWhiteSpace(action.Id) || action.Id.Length > 128 || string.IsNullOrWhiteSpace(action.Name) || action.Name.Length > 100 || string.IsNullOrWhiteSpace(action.Command) || action.Command.Contains('\0') || Encoding.UTF8.GetByteCount(action.Command) > 32768)
                throw new ArgumentException("Actions need a name, stable identity, and a shell command under 32 KB without NUL characters.");
        }
    }
}
