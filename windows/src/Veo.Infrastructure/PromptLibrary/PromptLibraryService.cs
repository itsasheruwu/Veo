using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;
using Veo.Infrastructure.Files;

namespace Veo.Infrastructure.PromptLibrary;

public enum PromptAttachmentKind { LocalImage, Image, LocalAudio, Audio, FileMention, Skill }
public sealed record PromptAttachment(PromptAttachmentKind Kind, string Source, string Name,
    string? LibraryFile = null, string? Sha256 = null);
public sealed record SavedPrompt(string Id, string WorkspacePath, string Text,
    IReadOnlyList<PromptAttachment> Attachments, DateTimeOffset CreatedAt)
{
    public string Title => Text.Split('\n').FirstOrDefault(line => line.Length > 0)?.TrimEnd('\r') ?? "Attachments";
    public override string ToString() => Title;
}
public sealed record RestoredPrompt(string Text, IReadOnlyList<PromptAttachment> Attachments);

/// <summary>Saved media is independent of original files and of every later restored draft.</summary>
public sealed class PromptLibraryService
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> Gates = new(StringComparer.OrdinalIgnoreCase);
    private readonly string root;
    private readonly string manifest;
    private readonly SemaphoreSlim gate;
    public PromptLibraryService(string dataRoot)
    {
        root = Path.GetFullPath(Path.Combine(dataRoot, "PromptLibrary")); Directory.CreateDirectory(root);
        root = new WorkspacePathPolicy(root).RootPath; manifest = Path.Combine(root, "prompts.json"); gate = Gates.GetOrAdd(root, _ => new(1, 1));
    }
    public async Task<IReadOnlyList<SavedPrompt>> ListAsync(string? search = null, CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        try
        {
            var all = await ReadAsync(token);
            return string.IsNullOrWhiteSpace(search) ? all : all.Where(prompt => prompt.Text.Contains(search, StringComparison.CurrentCultureIgnoreCase) || prompt.WorkspacePath.Contains(search, StringComparison.CurrentCultureIgnoreCase) || prompt.Attachments.Any(a => a.Name.Contains(search, StringComparison.CurrentCultureIgnoreCase))).ToArray();
        }
        finally { gate.Release(); }
    }
    public async Task<SavedPrompt> SaveAsync(string text, IReadOnlyList<PromptAttachment> attachments, string workspace,
        CancellationToken token = default)
    {
        if (string.IsNullOrWhiteSpace(text) && attachments.Count == 0) throw new ArgumentException("Write a prompt or attach media before saving it.");
        _ = new WorkspacePathPolicy(workspace);
        await gate.WaitAsync(token);
        var id = Guid.NewGuid().ToString("N"); var directory = Path.Combine(root, id); var copied = new List<string>();
        try
        {
            var before = await ReadAsync(token); Directory.CreateDirectory(directory);
            var savedAttachments = new List<PromptAttachment>();
            foreach (var attachment in attachments)
            {
                token.ThrowIfCancellationRequested(); ValidateAttachment(attachment);
                if (attachment.Kind is not (PromptAttachmentKind.LocalImage or PromptAttachmentKind.LocalAudio))
                { savedAttachments.Add(attachment with { LibraryFile = null, Sha256 = null }); continue; }
                var filename = Guid.NewGuid().ToString("N") + SafeExtension(attachment.Source);
                var destination = new WorkspacePathPolicy(root).Resolve(Path.Combine(id, filename), mustExist: false);
                var hash = await CopyMediaAsync(attachment.Source, destination, token); copied.Add(destination);
                savedAttachments.Add(attachment with { LibraryFile = filename, Sha256 = hash });
            }
            var saved = new SavedPrompt(id, Path.GetFullPath(workspace), text, savedAttachments, DateTimeOffset.UtcNow);
            await PersistAsync(new[] { saved }.Concat(before).ToArray(), token); return saved;
        }
        catch
        {
            foreach (var path in copied) DeleteOwnedFile(path, directory);
            if (Directory.Exists(directory) && !Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory, recursive: false);
            throw;
        }
        finally { gate.Release(); }
    }

    public async Task<RestoredPrompt> RestoreAsync(string promptId, string workspace, CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        string? restoreDirectory = null; var copied = new List<string>();
        try
        {
            var prompt = (await ReadAsync(token)).SingleOrDefault(prompt => prompt.Id == promptId) ?? throw new FileNotFoundException("This saved prompt was removed.");
            var workspacePolicy = new WorkspacePathPolicy(workspace);
            var restored = new List<PromptAttachment>();
            foreach (var attachment in prompt.Attachments)
            {
                token.ThrowIfCancellationRequested(); ValidateAttachment(attachment);
                if (attachment.Kind is not (PromptAttachmentKind.LocalImage or PromptAttachmentKind.LocalAudio))
                { restored.Add(attachment); continue; }
                var source = SavedMediaPath(prompt, attachment);
                if (await HashAsync(source, token) != attachment.Sha256) throw new InvalidDataException("Saved prompt media failed its integrity check. The library and source files were preserved.");
                if (restoreDirectory is null)
                {
                    var relative = Path.Combine("Attachments", "SavedPrompt-" + Guid.NewGuid().ToString("N"));
                    restoreDirectory = workspacePolicy.Resolve(relative, mustExist: false);
                    Directory.CreateDirectory(restoreDirectory); _ = workspacePolicy.Resolve(restoreDirectory);
                }
                var destination = workspacePolicy.Resolve(Path.Combine(restoreDirectory, Guid.NewGuid().ToString("N") + SafeExtension(attachment.Source)), mustExist: false);
                var hash = await CopyMediaAsync(source, destination, token); copied.Add(destination);
                if (hash != attachment.Sha256) throw new InvalidDataException("Saved media changed while it was being restored.");
                restored.Add(attachment with { Source = destination, LibraryFile = null, Sha256 = hash });
            }
            return new(prompt.Text, restored);
        }
        catch
        {
            if (restoreDirectory is not null)
            {
                foreach (var path in copied) DeleteOwnedFile(path, restoreDirectory);
                if (Directory.Exists(restoreDirectory) && !Directory.EnumerateFileSystemEntries(restoreDirectory).Any()) Directory.Delete(restoreDirectory, recursive: false);
            }
            throw;
        }
        finally { gate.Release(); }
    }
    public async Task RemoveAsync(string promptId, CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        try
        {
            var before = await ReadAsync(token); var prompt = before.SingleOrDefault(prompt => prompt.Id == promptId);
            if (prompt is null) return;
            var owned = prompt.Attachments.Where(attachment => attachment.Kind is PromptAttachmentKind.LocalImage or PromptAttachmentKind.LocalAudio)
                .Select(attachment => SavedMediaPath(prompt, attachment, mustExist: false)).ToArray();
            await PersistAsync(before.Where(prompt => prompt.Id != promptId).ToArray(), token);
            var directory = new WorkspacePathPolicy(root).Resolve(promptId, mustExist: false);
            foreach (var path in owned) if (File.Exists(path)) DeleteOwnedFile(path, directory);
            // Never recursively delete an unrecognized file or follow a reparse point during removal.
            if (Directory.Exists(directory) && !Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory, recursive: false);
        }
        finally { gate.Release(); }
    }
    private string SavedMediaPath(SavedPrompt prompt, PromptAttachment attachment, bool mustExist = true)
    {
        ValidateId(prompt.Id);
        if (string.IsNullOrEmpty(attachment.LibraryFile) || Path.GetFileName(attachment.LibraryFile) != attachment.LibraryFile || attachment.Sha256 is not { Length: 64 })
            throw new InvalidDataException("Saved prompt media has invalid library metadata.");
        return new WorkspacePathPolicy(root).Resolve(Path.Combine(prompt.Id, attachment.LibraryFile), mustExist);
    }
    private async Task<SavedPrompt[]> ReadAsync(CancellationToken token)
    {
        if (!File.Exists(manifest)) return [];
        SavedPrompt[] prompts;
        try { prompts = JsonSerializer.Deserialize<SavedPrompt[]>(await File.ReadAllTextAsync(manifest, token)) ?? throw new InvalidDataException("The saved prompt library is invalid."); }
        catch (JsonException) { throw new InvalidDataException("The saved prompt library is unreadable; its files were preserved."); }
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var prompt in prompts)
        { ValidateId(prompt.Id); if (!ids.Add(prompt.Id)) throw new InvalidDataException("The saved prompt library contains duplicate identities."); foreach (var attachment in prompt.Attachments) ValidateAttachment(attachment); }
        return prompts.OrderByDescending(prompt => prompt.CreatedAt).ThenBy(prompt => prompt.Id, StringComparer.Ordinal).ToArray();
    }
    private async Task PersistAsync(IReadOnlyList<SavedPrompt> prompts, CancellationToken token)
    {
        var temporary = manifest + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(prompts, new JsonSerializerOptions { WriteIndented = true }), token);
            File.Move(temporary, manifest, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private static async Task<string> CopyMediaAsync(string source, string destination, CancellationToken token)
    {
        var info = new FileInfo(source);
        if (!info.Exists || (info.Attributes & FileAttributes.Directory) != 0) throw new FileNotFoundException("An attached media file is unavailable.", source);
        await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
        try
        {
            await using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan))
                await input.CopyToAsync(output, token);
            return await HashAsync(destination, token);
        }
        catch { if (File.Exists(destination)) File.Delete(destination); throw; }
    }
    private static async Task<string> HashAsync(string path, CancellationToken token)
    { await using var file = File.OpenRead(path); return Convert.ToHexString(await SHA256.HashDataAsync(file, token)); }
    private static string SafeExtension(string path)
    {
        var extension = Path.GetExtension(path);
        return extension.Length is > 0 and <= 12 && extension.All(c => char.IsAsciiLetterOrDigit(c) || c == '.') ? extension : ".media";
    }
    private static void ValidateId(string id)
    { if (!Guid.TryParseExact(id, "N", out _)) throw new InvalidDataException("The saved prompt identity is invalid."); }
    private static void ValidateAttachment(PromptAttachment attachment)
    {
        if (!Enum.IsDefined(attachment.Kind) || string.IsNullOrWhiteSpace(attachment.Source) || attachment.Source.Contains('\0')) throw new InvalidDataException("The prompt contains an invalid attachment.");
        if (attachment.Kind is PromptAttachmentKind.Image or PromptAttachmentKind.Audio &&
            (!Uri.TryCreate(attachment.Source, UriKind.Absolute, out var uri) || uri.Scheme is not ("https" or "http")))
            throw new InvalidDataException("Remote media must use an HTTP or HTTPS URL.");
    }
    private static void DeleteOwnedFile(string file, string directory)
    {
        var policy = new WorkspacePathPolicy(directory); var resolved = policy.Resolve(file);
        if ((File.GetAttributes(resolved) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) throw new UnauthorizedAccessException("Veo refused to delete an unexpected library item.");
        File.Delete(resolved);
    }
}
