using System.Security.Cryptography;
using Veo.Platform.Windows.Shell;

namespace Veo.Platform.Windows.Browser;
public sealed record VerifiedBrowserDownload(string Path, long Length, string Sha256);
public static class BrowserDownloadDestination
{
    public static string SafeFilename(string suggested)
    {
        var invalid = Path.GetInvalidFileNameChars().ToHashSet();
        var name = string.Concat(suggested.Take(240).Select(c => invalid.Contains(c) || char.IsControl(c) ? '-' : c)).Trim().TrimEnd('.', ' ');
        if (name.Length == 0 || name is "." or "..")
            name = "Download";
        var stem = name.Split('.')[0].ToUpperInvariant();
        if (stem is "CON" or "PRN" or "AUX" or "NUL" || stem.Length == 4 && (stem.StartsWith("COM") || stem.StartsWith("LPT")) && stem[3] is >= '0' and <= '9')
            name = "Download-" + name;
        return name;
    }

    public static string Reserve(string suggested, string? downloads = null)
    {
        var directory = Path.GetFullPath(downloads ?? KnownFolders.Downloads);
        Directory.CreateDirectory(directory);
        var name = SafeFilename(suggested);
        for (var suffix = 0; suffix < 10000; suffix++)
        {
            var candidate = Path.Combine(directory, suffix == 0 ? name : Path.GetFileNameWithoutExtension(name) + " (" + suffix + ")" + Path.GetExtension(name));
            try
            {
                using var reservation = new FileStream(candidate, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                return candidate;
            }
            catch (IOException)when (File.Exists(candidate) || Directory.Exists(candidate))
            {
            }
        }

        throw new IOException("No unused download filename is available.");
    }

    public static async Task<VerifiedBrowserDownload> VerifyAsync(string destination, CancellationToken cancellationToken = default)
    {
        await using var stream = SafePreviewFiles.OpenVerifiedRead(Path.GetDirectoryName(Path.GetFullPath(destination))!, destination, long.MaxValue);
        var length = stream.Length;
        var hash = await SHA256.HashDataAsync(stream, cancellationToken);
        return new(Path.GetFullPath(destination), length, Convert.ToHexString(hash));
    }
}
