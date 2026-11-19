using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Veo.Infrastructure.Files;

namespace Veo.Core;

public sealed record ArtifactReadResult(byte[] Bytes, string MimeType, string Name, string? CanonicalPath);

/// <summary>Read-only native artifact access. Outside previews are explicit per item and never change runtime permissions.</summary>
public sealed class ConversationArtifactAccess(string dataRoot)
{
    const int ImageLimit = 16 * 1024 * 1024, AudioLimit = 32 * 1024 * 1024, TextLimit = 1024 * 1024;
    static readonly UTF8Encoding Utf8 = new(false, true);
    IEnumerable<string> Roots(ThreadSession session) => new[] { session.Record.Cwd, Path.Combine(dataRoot, "Attachments"), Path.Combine(dataRoot, "GeneratedImages") }.Where(Directory.Exists);
    public bool IsInsideApprovedRoots(ThreadSession session, string path)
    { try { var candidate = Normalize(session, path); foreach (var root in Roots(session)) try { _ = new WorkspacePathPolicy(root).Resolve(candidate); return true; } catch (UnauthorizedAccessException) { } return false; } catch (Exception ex) when (ex is IOException or ArgumentException or UnauthorizedAccessException or NotSupportedException) { return false; } }
    public async Task<ArtifactReadResult> ReadAsync(ThreadSession session, ConversationArtifact artifact, bool allowOutside = false, CancellationToken cancellation = default)
    {
        var kind = artifact.Kind; if (kind.StartsWith("remote", StringComparison.Ordinal) || IntegrationCoordinator.SecureUri(artifact.Source) is not null) throw new NotSupportedException("Remote artifacts open only after an explicit browser action. Veo does not fetch them for previews.");
        if (kind == "text") { var bytes = Utf8.GetBytes(artifact.Source); if (bytes.Length > TextLimit) throw new InvalidDataException("The text result exceeds the 1 MiB preview limit."); return new(bytes, artifact.MimeType ?? "text/plain", artifact.Name, null); }
        if (kind.StartsWith("inline", StringComparison.Ordinal) || kind.StartsWith("data", StringComparison.Ordinal))
        {
            var encoded = artifact.Source; var mime = artifact.MimeType;
            if (encoded.StartsWith("data:", StringComparison.OrdinalIgnoreCase)) { var comma = encoded.IndexOf(','); if (comma < 0 || !encoded[..comma].EndsWith(";base64", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("This inline artifact is not a base64 data URL."); mime = encoded[5..comma].Split(';')[0]; encoded = encoded[(comma + 1)..]; }
            var limit = kind.Contains("Image", StringComparison.Ordinal) ? ImageLimit : AudioLimit; if (encoded.Length > (long)limit * 4 / 3 + 8) throw new InvalidDataException("The inline artifact exceeds its native preview limit.");
            var bytes = Convert.FromBase64String(encoded); if (bytes.Length > limit) throw new InvalidDataException("The inline artifact exceeds its native preview limit."); return Validate(bytes, mime, artifact, null);
        }
        if (kind is not ("localImage" or "localAudio" or "localText")) throw new NotSupportedException(artifact.UnavailableReason ?? "This artifact has no verified local or inline content representation.");
        var candidate = Normalize(session, artifact.Source); string? approved = null;
        foreach (var root in Roots(session)) try { approved = new WorkspacePathPolicy(root).Resolve(candidate); break; } catch (UnauthorizedAccessException) { }
        if (approved is null)
        {
            if (!allowOutside) throw new UnauthorizedAccessException("This source is outside the chat's approved preview folders. Allow this one preview explicitly to read it.");
            var parent = Path.GetDirectoryName(candidate) ?? throw new UnauthorizedAccessException("The source path has no local parent."); approved = new WorkspacePathPolicy(parent).Resolve(candidate);
        }
        if (!File.Exists(approved) || Directory.Exists(approved)) throw new FileNotFoundException("The source is not a regular local file.");
        var maximum = kind == "localImage" ? ImageLimit : kind == "localAudio" ? AudioLimit : TextLimit;
        await using var stream = new FileStream(approved, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
        var identity = Identity(stream.SafeFileHandle, approved); if (stream.Length > maximum) throw new InvalidDataException($"This source exceeds the {maximum / 1024 / 1024} MiB native preview limit.");
        using var output = new MemoryStream(); var buffer = new byte[65536]; int read;
        while ((read = await stream.ReadAsync(buffer, cancellation)) != 0) { if (output.Length + read > maximum) throw new InvalidDataException("The source grew beyond its preview limit."); await output.WriteAsync(buffer.AsMemory(0, read), cancellation); }
        if (identity != Identity(stream.SafeFileHandle, approved)) throw new IOException("The source identity changed while it was being read.");
        var bytesRead = output.ToArray(); if (kind == "localText") { _ = Utf8.GetString(bytesRead); if (bytesRead.Contains((byte)0)) throw new InvalidDataException("This source is binary and has no UTF-8 text preview."); return new(bytesRead, "text/plain", artifact.Name, approved); }
        return Validate(bytesRead, artifact.MimeType, artifact, approved);
    }
    static ArtifactReadResult Validate(byte[] bytes, string? declared, ConversationArtifact artifact, string? path)
    {
        var image = artifact.Kind.Contains("Image", StringComparison.Ordinal); var audio = artifact.Kind.Contains("Audio", StringComparison.Ordinal); var actual = ImageMime(bytes);
        if (image && actual is null) throw new InvalidDataException("The artifact is not a supported PNG, JPEG, GIF, WebP or bitmap image.");
        if (image && declared is not null && !declared.StartsWith("image/", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The image's declared type does not match its content.");
        if (audio && declared is not null && !declared.StartsWith("audio/", StringComparison.OrdinalIgnoreCase) && declared != "application/ogg") throw new InvalidDataException("The audio's declared type does not match its content.");
        if (audio) actual = declared ?? (bytes.AsSpan().StartsWith("RIFF"u8) ? "audio/wav" : bytes.AsSpan().StartsWith("fLaC"u8) ? "audio/flac" : bytes.AsSpan().StartsWith("OggS"u8) ? "audio/ogg" : path is not null && Path.GetExtension(path).Equals(".m4a", StringComparison.OrdinalIgnoreCase) ? "audio/mp4" : "audio/mpeg");
        if (!image && !audio && declared?.StartsWith("text/", StringComparison.OrdinalIgnoreCase) == true) { if (bytes.Length > TextLimit) throw new InvalidDataException("The text resource exceeds 1 MiB."); _ = Utf8.GetString(bytes); }
        return new(bytes, actual ?? declared ?? "application/octet-stream", artifact.Name, path);
    }
    static string? ImageMime(byte[] bytes)
    {
        if (bytes.AsSpan().StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) return "image/png";
        if (bytes.Length >= 3 && bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255) return "image/jpeg";
        if (bytes.AsSpan().StartsWith("GIF87a"u8) || bytes.AsSpan().StartsWith("GIF89a"u8)) return "image/gif";
        if (bytes.Length >= 12 && bytes.AsSpan(0, 4).SequenceEqual("RIFF"u8) && bytes.AsSpan(8, 4).SequenceEqual("WEBP"u8)) return "image/webp";
        return bytes.AsSpan().StartsWith("BM"u8) ? "image/bmp" : null;
    }
    static string Normalize(ThreadSession session, string value)
    {
        if (value.IndexOf('\0') >= 0 || value.StartsWith("\\\\", StringComparison.Ordinal) || value.StartsWith("//", StringComparison.Ordinal)) throw new UnauthorizedAccessException("Network and device paths are not native preview sources.");
        if (Uri.TryCreate(value, UriKind.Absolute, out var uri)) { if (uri.IsFile) value = uri.LocalPath; else if (uri.Scheme.Length != 1) throw new UnauthorizedAccessException("This source is not a local file."); }
        var full = Path.GetFullPath(value, session.Record.Cwd); if (full.StartsWith("\\\\", StringComparison.Ordinal)) throw new UnauthorizedAccessException("Network paths are not native preview sources.");
        var root = Path.GetPathRoot(full) ?? ""; if (full[root.Length..].Contains(':')) throw new UnauthorizedAccessException("Alternate data streams are not preview sources.");
        return full;
    }
    static string Identity(SafeFileHandle handle, string expected)
    {
        if (!OperatingSystem.IsWindows()) return expected;
        var buffer = new StringBuilder(32768); var count = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0); if (count == 0 || count >= buffer.Capacity) throw new IOException("The opened source path could not be verified.");
        var final = buffer.ToString(); if (final.StartsWith("\\\\?\\", StringComparison.Ordinal)) final = final[4..];
        if (!string.Equals(Path.GetFullPath(final), Path.GetFullPath(expected), StringComparison.Ordinal) || !GetFileInformationByHandle(handle, out var info) || (info.Attributes & 16) != 0) throw new UnauthorizedAccessException("The opened source differs from its approved regular file.");
        return final + "|" + info.Volume + "|" + info.IndexHigh + "|" + info.IndexLow + "|" + info.SizeHigh + "|" + info.SizeLow;
    }
    [StructLayout(LayoutKind.Sequential, Pack = 4)] struct FileIdentity { public uint Attributes; public long Creation, Access, Write; public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint length, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileIdentity info);
}
