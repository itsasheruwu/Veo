using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Veo.Infrastructure.Files;

/// <summary>Component-aware boundary validation, including junctions and symlinks.</summary>
public sealed class WorkspacePathPolicy
{
    public string RootPath { get; }
    public WorkspacePathPolicy(string rootPath)
    {
        var full = Path.GetFullPath(rootPath);
        if (!Directory.Exists(full)) throw new DirectoryNotFoundException("The workspace directory is unavailable.");
        RootPath = ResolveExisting(full);
    }

    public string Resolve(string relativeOrAbsolutePath, bool mustExist = true)
    {
        if (string.IsNullOrWhiteSpace(relativeOrAbsolutePath) || relativeOrAbsolutePath.IndexOf('\0') >= 0)
            throw new UnauthorizedAccessException("The workspace path is invalid.");
        // Alternate data streams and device names are not editor or Git paths.
        var candidate = ResolveExisting(Path.GetFullPath(relativeOrAbsolutePath, RootPath), mustExist);
        var relative = Path.GetRelativePath(RootPath, candidate);
        ValidateRelative(relative);
        EnsureContained(candidate);
        return candidate;
    }

    public string Relative(string path) => Path.GetRelativePath(RootPath, Resolve(path));

    private void EnsureContained(string path)
    {
        ValidateRelative(Path.GetRelativePath(RootPath, path));
        // GetRelativePath uses case-insensitive Windows comparisons even for case-sensitive directories.
        // Handle-derived names let component equality distinguish two real directories differing only by case.
        var rootParts = RootPath.Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries);
        var targetParts = path.Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries);
        if (targetParts.Length < rootParts.Length || !rootParts.SequenceEqual(targetParts.Take(rootParts.Length), StringComparer.Ordinal))
            throw new UnauthorizedAccessException("Veo refused a path outside the selected workspace.");
    }

    private static void ValidateRelative(string relative)
    {
        if (Path.IsPathRooted(relative) || relative == ".." ||
            relative.Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar]).Any(part => part == ".."))
            throw new UnauthorizedAccessException("Veo refused a path outside the selected workspace.");
        foreach (var part in relative.Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar]))
        {
            if (part.Contains(':') || part.EndsWith(' ') || (part.EndsWith('.') && part != "."))
                throw new UnauthorizedAccessException("Veo refused an ambiguous Windows path.");
            var stem = part.Split('.')[0];
            if (new[] { "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }.Contains(stem, StringComparer.OrdinalIgnoreCase))
                throw new UnauthorizedAccessException("Veo refused a reserved Windows filename.");
        }
    }

    private static string ResolveExisting(string path, bool mustExist = true)
    {
        // Resolve all ancestors, not only a final junction. Do not lowercase paths:
        // Windows supports case-sensitive directories and GetRelativePath retains them.
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full)!;
        var current = root;
        foreach (var component in full[root.Length..].Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            if (!File.Exists(current) && !Directory.Exists(current))
            {
                if (mustExist) throw new FileNotFoundException("The workspace item is unavailable.", current);
                continue;
            }
            FileSystemInfo info = Directory.Exists(current) ? new DirectoryInfo(current) : new FileInfo(current);
            if ((info.Attributes & FileAttributes.ReparsePoint) != 0)
                current = info.ResolveLinkTarget(true)?.FullName ?? throw new UnauthorizedAccessException("The workspace link could not be resolved safely.");
            if (OperatingSystem.IsWindows()) current = CanonicalWindowsName(current);
        }
        return Path.TrimEndingDirectorySeparator(current);
    }

    private static string CanonicalWindowsName(string path)
    {
        var nativePath = path.StartsWith("\\\\?\\", StringComparison.Ordinal) ? path :
            path.StartsWith("\\\\", StringComparison.Ordinal) ? "\\\\?\\UNC\\" + path[2..] : "\\\\?\\" + path;
        using var handle = CreateFileW(nativePath, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException("The workspace path could not be opened safely.", new Win32Exception(Marshal.GetLastWin32Error()));
        var buffer = new StringBuilder(32768);
        var length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
        if (length == 0 || length >= buffer.Capacity) throw new IOException("The workspace path could not be resolved safely.");
        var result = buffer.ToString();
        return result.StartsWith("\\\\?\\UNC\\", StringComparison.Ordinal) ? "\\\\" + result[8..] :
            result.StartsWith("\\\\?\\", StringComparison.Ordinal) ? result[4..] : result;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
}
