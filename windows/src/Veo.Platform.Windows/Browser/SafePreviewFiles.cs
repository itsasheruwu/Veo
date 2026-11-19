using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Veo.Platform.Windows.Browser;
/// <summary>Validate final paths on open handles, with no write/delete sharing during reads.</summary>
public static class SafePreviewFiles
{
    public const long MaximumBytes = 8 * 1024 * 1024;
    public const string ContentSecurityPolicy = "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'none'";
    public static string ResolveRequest(string root, Uri request, string expectedHost)
    {
        if (request.Scheme != "https" || !request.Host.Equals(expectedHost, StringComparison.OrdinalIgnoreCase) || !request.IsDefaultPort)
            throw new UnauthorizedAccessException("The preview request has another origin.");
        var path = Uri.UnescapeDataString(request.AbsolutePath);
        if (path.IndexOfAny(['\\', ':', '\0']) >= 0 || path.Split('/').Any(p => p is "." or ".."))
            throw new UnauthorizedAccessException("Preview traversal is not allowed.");
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var candidate = Path.GetFullPath(Path.Combine(fullRoot, path.TrimStart('/').Replace('/', Path.DirectorySeparatorChar)));
        if (!candidate.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase))
            throw new UnauthorizedAccessException("The preview is outside this workspace.");
        return candidate;
    }

    public static string Mime(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".html" or ".htm" => "text/html; charset=utf-8",
        ".css" => "text/css; charset=utf-8",
        ".js" or ".mjs" => "text/javascript; charset=utf-8",
        ".json" or ".map" => "application/json",
        ".txt" => "text/plain; charset=utf-8",
        ".svg" => "image/svg+xml",
        ".png" => "image/png",
        ".jpg" or ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".ico" => "image/x-icon",
        ".woff" => "font/woff",
        ".woff2" => "font/woff2",
        ".ttf" => "font/ttf",
        _ => throw new UnauthorizedAccessException("This file type is not approved for browser preview.")};
    public static FileStream OpenVerifiedRead(string root, string path, long maximumBytes = MaximumBytes)
    {
        if (path.IndexOf(':', Path.GetPathRoot(path)?.Length ?? 0) >= 0)
            throw new UnauthorizedAccessException("Alternate data streams are not preview resources.");
        var rootPath = Path.GetFullPath(root);
        using var rootHandle = CreateFileW(rootPath, 0, 7, 0, 3, 0x02000000, 0);
        if (rootHandle.IsInvalid)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Open preview workspace");
        var boundary = FinalPath(rootHandle).TrimEnd('\\') + "\\";
        var stream = new FileStream(Path.GetFullPath(path), FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
        try
        {
            if (!FinalPath(stream.SafeFileHandle).StartsWith(boundary, StringComparison.OrdinalIgnoreCase))
                throw new UnauthorizedAccessException("A junction or symbolic link leaves this workspace.");
            if (stream.Length > maximumBytes)
                throw new InvalidDataException("Preview resource exceeds the size limit.");
            return stream;
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    public static async Task<byte[]> ReadAsync(string root, string path, CancellationToken cancellationToken = default)
    {
        _ = Mime(path);
        await using var source = OpenVerifiedRead(root, path);
        var bytes = new byte[checked((int)source.Length)];
        await source.ReadExactlyAsync(bytes, cancellationToken);
        return bytes;
    }

    static string FinalPath(SafeFileHandle handle)
    {
        var buffer = new StringBuilder(32768);
        var result = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
        if (result == 0 || result >= buffer.Capacity)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Resolve final preview path");
        return buffer.ToString();
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, nint security, uint disposition, uint flags, nint template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
}
