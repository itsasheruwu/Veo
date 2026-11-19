using System.Security.Cryptography;
using System.Text;

namespace Veo.Infrastructure.Files;

public sealed record WorkspaceFileEntry(string Name, string RelativePath, bool IsDirectory, bool IsLink, long ByteCount);
public enum WorkspaceTextEncoding { Utf8, Utf8Bom, Utf16LittleEndian, Utf16BigEndian }
public sealed record FileFingerprint(string Sha256, long Length, long LastWriteTicks, FileAttributes Attributes);
public sealed record WorkspaceTextDocument(string Path, string RelativePath, string Text,
    WorkspaceTextEncoding Encoding, string PreferredNewline, bool MixedNewlines, FileFingerprint Fingerprint);

public sealed class WorkspaceFileService
{
    public const int MaximumTextBytes = 8 * 1024 * 1024;
    private readonly WorkspacePathPolicy paths;
    private readonly SemaphoreSlim writer = new(1, 1);
    public WorkspaceFileService(string workspacePath) => paths = new(workspacePath);

    public async Task<IReadOnlyList<WorkspaceFileEntry>> SearchAsync(string query, int limit = 100, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(query)) return [];
        limit = Math.Clamp(limit, 1, 500);
        return await Task.Run(async () =>
        {
            var result = new List<WorkspaceFileEntry>(); var queue = new Queue<string>(); queue.Enqueue(".");
            while (queue.Count > 0 && result.Count < limit)
            {
                cancellationToken.ThrowIfCancellationRequested();
                IReadOnlyList<WorkspaceFileEntry> entries;
                try { entries = await ListChildrenAsync(queue.Dequeue(), cancellationToken); }
                catch (Exception e) when (e is UnauthorizedAccessException or IOException) { continue; }
                foreach (var entry in entries)
                {
                    if (entry.IsDirectory && !entry.IsLink) queue.Enqueue(entry.RelativePath);
                    if (!entry.IsDirectory && entry.RelativePath.Contains(query, StringComparison.CurrentCultureIgnoreCase)) result.Add(entry);
                    if (result.Count >= limit) break;
                }
            }
            return (IReadOnlyList<WorkspaceFileEntry>)result;
        }, cancellationToken);
    }

    public Task<IReadOnlyList<WorkspaceFileEntry>> ListChildrenAsync(string relativePath = ".", CancellationToken cancellationToken = default)
    {
        var directory = paths.Resolve(relativePath);
        if (!Directory.Exists(directory)) throw new DirectoryNotFoundException();
        var entries = new List<WorkspaceFileEntry>();
        foreach (var info in new DirectoryInfo(directory).EnumerateFileSystemInfos())
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (info.Name == ".git") continue;
            var isDirectory = (info.Attributes & FileAttributes.Directory) != 0;
            entries.Add(new(info.Name, Path.GetRelativePath(paths.RootPath, info.FullName), isDirectory,
                (info.Attributes & FileAttributes.ReparsePoint) != 0, info is FileInfo file ? file.Length : 0));
        }
        return Task.FromResult<IReadOnlyList<WorkspaceFileEntry>>(entries.OrderByDescending(e => e.IsDirectory).ThenBy(e => e.Name, StringComparer.CurrentCultureIgnoreCase).ToList());
    }

    public async Task<WorkspaceTextDocument> ReadTextAsync(string relativePath, CancellationToken cancellationToken = default)
    {
        var path = paths.Resolve(relativePath);
        var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException("Only regular workspace files can be edited.");
        if (info.Length > MaximumTextBytes) throw new IOException("Text files larger than 8 MiB are preview-only.");
        var bytes = await File.ReadAllBytesAsync(path, cancellationToken);
        if (bytes.Length > MaximumTextBytes) throw new IOException("Text files larger than 8 MiB are preview-only.");
        var (encoding, text) = Decode(bytes);
        var crlf = text.Contains("\r\n", StringComparison.Ordinal);
        var stripped = text.Replace("\r\n", "", StringComparison.Ordinal);
        var lf = stripped.Contains('\n');
        var cr = stripped.Contains('\r');
        return new(path, Path.GetRelativePath(paths.RootPath, path), text, encoding, crlf ? "\r\n" : cr && !lf ? "\r" : "\n",
            (crlf && (lf || cr)) || (lf && cr), Fingerprint(path, bytes));
    }

    public async Task<WorkspaceTextDocument> SaveTextAsync(WorkspaceTextDocument document, string text,
        CancellationToken cancellationToken = default)
    {
        await writer.WaitAsync(cancellationToken);
        string? temporary = null;
        try
        {
            var target = paths.Resolve(document.RelativePath);
            if (!string.Equals(target, document.Path, StringComparison.Ordinal))
                throw new IOException("The file location changed after it was opened.");
            var before = await File.ReadAllBytesAsync(target, cancellationToken);
            if (Fingerprint(target, before) != document.Fingerprint) throw new IOException("This file changed on disk after it was opened.");
            if (text == document.Text) return document; // Opening/saving never normalizes mixed newlines or BOM bytes.
            if (!document.MixedNewlines)
                text = text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Replace("\n", document.PreferredNewline, StringComparison.Ordinal);
            var bytes = Encode(text, document.Encoding);
            if (bytes.Length > MaximumTextBytes) throw new IOException("Text files larger than 8 MiB cannot be saved.");
            temporary = Path.Combine(Path.GetDirectoryName(target)!, ".veo-save-" + Guid.NewGuid().ToString("N"));
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.WriteThrough | FileOptions.Asynchronous))
            { await output.WriteAsync(bytes, cancellationToken); await output.FlushAsync(cancellationToken); output.Flush(true); }
            // Repeat validation after preparing the replacement, rather than trusting the editor's old snapshot.
            target = paths.Resolve(document.RelativePath);
            var latest = await File.ReadAllBytesAsync(target, cancellationToken);
            if (Fingerprint(target, latest) != document.Fingerprint) throw new IOException("This file changed while the save was being prepared.");
            File.Replace(temporary, target, null, ignoreMetadataErrors: false); // preserves destination ACLs on Windows
            temporary = null;
            File.SetAttributes(target, document.Fingerprint.Attributes);
            var saved = await ReadTextAsync(document.RelativePath, cancellationToken);
            if (saved.Fingerprint.Sha256 != Convert.ToHexString(SHA256.HashData(bytes))) throw new IOException("The saved file changed during verification.");
            return saved;
        }
        finally
        {
            if (temporary is not null && File.Exists(temporary)) File.Delete(temporary);
            writer.Release();
        }
    }

    private static FileFingerprint Fingerprint(string path, byte[] bytes)
    {
        var info = new FileInfo(path); info.Refresh();
        return new(Convert.ToHexString(SHA256.HashData(bytes)), bytes.LongLength, info.LastWriteTimeUtc.Ticks, info.Attributes);
    }
    private static (WorkspaceTextEncoding, string) Decode(byte[] bytes)
    {
        var span = bytes.AsSpan();
        if (span.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF })) return (WorkspaceTextEncoding.Utf8Bom, new UTF8Encoding(false, true).GetString(span[3..]));
        if (span.StartsWith(new byte[] { 0xFF, 0xFE })) return (WorkspaceTextEncoding.Utf16LittleEndian, new UnicodeEncoding(false, false, true).GetString(span[2..]));
        if (span.StartsWith(new byte[] { 0xFE, 0xFF })) return (WorkspaceTextEncoding.Utf16BigEndian, new UnicodeEncoding(true, false, true).GetString(span[2..]));
        var text = new UTF8Encoding(false, true).GetString(bytes);
        if (text.Contains('\0')) throw new InvalidDataException("Binary files cannot be edited as text.");
        return (WorkspaceTextEncoding.Utf8, text);
    }
    private static byte[] Encode(string text, WorkspaceTextEncoding encoding)
    {
        Encoding codec = encoding switch
        {
            WorkspaceTextEncoding.Utf8 => new UTF8Encoding(false, true),
            WorkspaceTextEncoding.Utf8Bom => new UTF8Encoding(true, true),
            WorkspaceTextEncoding.Utf16LittleEndian => new UnicodeEncoding(false, true, true),
            WorkspaceTextEncoding.Utf16BigEndian => new UnicodeEncoding(true, true, true),
            _ => throw new ArgumentOutOfRangeException(nameof(encoding))
        };
        return [.. codec.GetPreamble(), .. codec.GetBytes(text)];
    }
}
