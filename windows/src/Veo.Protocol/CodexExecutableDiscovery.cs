namespace Veo.Protocol;

public static class CodexExecutableDiscovery
{
    public static string? Resolve(string? explicitPath = null)
    {
        explicitPath = string.IsNullOrWhiteSpace(explicitPath) ? Environment.GetEnvironmentVariable("CODEX_EXECUTABLE") : explicitPath;
        // An explicit broken selection must produce a repair path instead of silently selecting another CLI.
        if (!string.IsNullOrWhiteSpace(explicitPath)) return ResolveCandidate(explicitPath);
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = ResolveCandidate(Path.Combine(directory.Trim('"'), OperatingSystem.IsWindows() ? "codex.exe" : "codex"));
            if (candidate != null) return candidate;
            if (OperatingSystem.IsWindows())
            {
                candidate = ResolveCandidate(Path.Combine(directory.Trim('"'), "codex.cmd"));
                if (candidate != null) return candidate;
            }
        }
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        foreach (var path in new[] {
            Path.Combine(local, "Programs", "OpenAI", "Codex", "bin", "codex.exe"),
            Path.Combine(home, ".local", "bin", "codex.exe"),
            Path.Combine(roaming, "npm", "codex.cmd") })
        {
            var candidate = ResolveCandidate(path);
            if (candidate != null) return candidate;
        }
        return null;
    }

    private static string? ResolveCandidate(string path)
    {
        try
        {
            path = Path.GetFullPath(Environment.ExpandEnvironmentVariables(path.Trim().Trim('"')));
            if (!File.Exists(path)) return null;
            if (!OperatingSystem.IsWindows()) return path;
            if (Path.GetExtension(path).Equals(".exe", StringComparison.OrdinalIgnoreCase)) return path;
            if (!Path.GetExtension(path).Equals(".cmd", StringComparison.OrdinalIgnoreCase)) return null;
            // npm's shim is never executed through cmd.exe. Resolve its installed native vendor binary.
            var package = Path.Combine(Path.GetDirectoryName(path)!, "node_modules", "@openai", "codex");
            var arch = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "aarch64" : "x86_64";
            var native = Path.Combine(package, "vendor", $"{arch}-pc-windows-msvc", "codex", "codex.exe");
            if (File.Exists(native)) return native;
            var optionalPackage = Path.Combine(package, "node_modules", "@openai", $"codex-win32-{(arch == "aarch64" ? "arm64" : "x64")}", "vendor", $"{arch}-pc-windows-msvc", "codex", "codex.exe");
            return File.Exists(optionalPackage) ? optionalPackage : null;
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or UnauthorizedAccessException or NotSupportedException) { return null; }
    }
}
