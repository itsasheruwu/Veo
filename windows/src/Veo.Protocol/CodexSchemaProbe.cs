using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Veo.Protocol;

public sealed record CodexSchemaProvenance(string Owner, string ExecutablePath, string BinarySha256, string CliVersion, DateTimeOffset GeneratedAt, string SchemaDirectory);
internal sealed record CodexSchemaExport(CapabilityRegistry Registry, CodexSchemaProvenance Provenance);

/// <summary>Transient, bounded CLI introspection; never starts a conversation or reads authentication files.</summary>
internal static class CodexSchemaProbe
{
    private const string Owner = "Veo.SelectedCliSchema.v1";
    private const int MaximumProbeCharacters = 65536;

    internal static async Task<CodexSchemaExport> GenerateAsync(string executable, CodexRuntimeOptions options, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(options.SchemaDirectory) || !Path.IsPathFullyQualified(options.SchemaDirectory)) throw new ArgumentException("Select an absolute, writable protocol-schema directory.");
        if (options.SchemaGenerationTimeout <= TimeSpan.Zero || options.VersionProbeTimeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(options), "CLI probe timeouts must be positive.");
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(options.SchemaDirectory));
        Directory.CreateDirectory(root);
        if ((new DirectoryInfo(root).Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("The schema output directory must not be a junction or symlink.");
        var directory = Path.Combine(root, "generation-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var successful = false;
        try
        {
            var beforeHash = await HashAsync(executable, cancellationToken).ConfigureAwait(false);
            var version = (await RunAsync(executable, ["--version"], root, options.VersionProbeTimeout, cancellationToken).ConfigureAwait(false)).Trim();
            if (string.IsNullOrWhiteSpace(version)) throw new InvalidDataException("The selected executable returned no version.");
            await RunAsync(executable, ["app-server", "generate-json-schema", "--experimental", "--out", directory], root, options.SchemaGenerationTimeout, cancellationToken).ConfigureAwait(false);
            var afterHash = await HashAsync(executable, cancellationToken).ConfigureAwait(false);
            if (beforeHash != afterHash) throw new IOException("The selected executable changed during schema export. Reconnect after its update finishes.");
            foreach (var direction in Enum.GetValues<ProtocolDirection>())
            {
                var file = new FileInfo(Path.Combine(directory, direction + ".json"));
                if (!file.Exists || file.Length is < 2 or > 64 * 1024 * 1024) throw new InvalidDataException($"The selected CLI did not export a usable {direction}.json contract.");
            }
            var registry = CapabilityRegistry.Load(directory);
            foreach (var method in new[] { "initialize", "thread/start", "thread/read", "turn/start", "turn/interrupt" })
                if (registry.Availability(method) != CapabilityAvailability.Available) throw new NotSupportedException($"The selected CLI schema lacks the required {method} method.");
            if (registry.Availability("initialized", ProtocolDirection.ClientNotification) != CapabilityAvailability.Available) throw new NotSupportedException("The selected CLI schema lacks the initialized notification.");
            var provenance = new CodexSchemaProvenance(Owner, executable, beforeHash, version, DateTimeOffset.UtcNow, directory);
            await File.WriteAllTextAsync(Path.Combine(directory, "schema-provenance.json"), JsonSerializer.Serialize(provenance, new JsonSerializerOptions { WriteIndented = true }), cancellationToken).ConfigureAwait(false);
            successful = true;
            RemovePreviousGenerations(root, directory);
            return new(registry, provenance);
        }
        finally { if (!successful) DeleteOwnedDirectory(root, directory); }
    }

    private static async Task<string> HashAsync(string executable, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(executable, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        return Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false));
    }

    internal static Task<string> ReadBundledCatalogAsync(string executable, CancellationToken token) => RunAsync(executable, ["debug", "models", "--bundled"], Path.GetDirectoryName(executable)!, TimeSpan.FromSeconds(20), token, 16 * 1024 * 1024);

    private static async Task<string> RunAsync(string executable, IReadOnlyList<string> arguments, string cwd, TimeSpan timeout, CancellationToken cancellationToken, int maximumOutput = MaximumProbeCharacters)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false), WorkingDirectory = cwd };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new IOException("The selected CLI probe did not start.");
        using var job = OperatingSystem.IsWindows() ? new ProbeJob(process) : null;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        var stdout = CaptureAsync(process.StandardOutput, deadline.Token, maximumOutput); var stderr = CaptureAsync(process.StandardError, deadline.Token, MaximumProbeCharacters);
        try
        {
            await process.WaitForExitAsync(deadline.Token).ConfigureAwait(false);
            var output = await stdout.ConfigureAwait(false); var diagnostics = await stderr.ConfigureAwait(false);
            if (output.Truncated || diagnostics.Truncated) throw new InvalidDataException("The selected CLI probe exceeded its bounded diagnostic output limit.");
            if (process.ExitCode != 0) throw new IOException($"The selected CLI probe exited with status {process.ExitCode}: {DiagnosticRedactor.Redact(diagnostics.Text)}");
            return output.Text;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new TimeoutException($"The selected CLI probe exceeded its {timeout.TotalSeconds:g}-second timeout."); }
        finally
        {
            job?.Dispose(); // Kill remaining owned descendants even if the original probe already exited.
            if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false); }
            try { await Task.WhenAll(stdout, stderr).ConfigureAwait(false); } catch (OperationCanceledException) { }
        }
    }

    private static async Task<(string Text, bool Truncated)> CaptureAsync(StreamReader reader, CancellationToken cancellationToken, int limit)
    {
        var text = new StringBuilder(); var buffer = new char[4096]; var truncated = false;
        int length;
        while ((length = await reader.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false)) != 0)
        {
            text.Append(buffer, 0, length);
            if (text.Length > limit) { text.Remove(0, text.Length - limit); truncated = true; }
        }
        return (text.ToString(), truncated);
    }

    private static void RemovePreviousGenerations(string root, string current)
    {
        foreach (var path in Directory.EnumerateDirectories(root, "generation-*"))
        {
            if (path == current) continue;
            var manifest = Path.Combine(path, "schema-provenance.json");
            try
            {
                if (!File.Exists(manifest) || new FileInfo(manifest).Length > 16384) continue;
                var metadata = JsonSerializer.Deserialize<CodexSchemaProvenance>(File.ReadAllText(manifest));
                if (metadata?.Owner == Owner && Path.GetFullPath(metadata.SchemaDirectory) == Path.GetFullPath(path)) DeleteOwnedDirectory(root, path);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException) { }
        }
    }

    private static void DeleteOwnedDirectory(string root, string directory)
    {
        // Only the exact child GUID generation under the explicitly selected output root can be removed.
        var full = Path.GetFullPath(directory);
        var name = Path.GetFileName(full);
        if (Path.GetDirectoryName(full) != root || !name.StartsWith("generation-", StringComparison.Ordinal) || !Guid.TryParseExact(name[11..], "N", out _)) throw new IOException("Refused to clean a schema directory outside the selected output root.");
        if (Directory.Exists(full) && (new DirectoryInfo(full).Attributes & FileAttributes.ReparsePoint) == 0) Directory.Delete(full, recursive: true);
    }

    private sealed class ProbeJob : IDisposable
    {
        private nint handle;
        internal ProbeJob(Process process)
        {
            handle = CreateJobObjectW(0, null);
            try
            {
                Check(handle != 0);
                var limits = new ExtendedLimits { Basic = new() { Flags = 0x2000 } };
                Check(SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>()));
                Check(AssignProcessToJobObject(handle, process.Handle));
            }
            catch { if (!process.HasExited) process.Kill(entireProcessTree: true); Dispose(); throw; }
        }
        public void Dispose() { var owned = Interlocked.Exchange(ref handle, 0); if (owned != 0) CloseHandle(owned); }
        private static void Check(bool success) { if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), "Own the selected CLI probe process"); }
        [StructLayout(LayoutKind.Sequential)] private struct BasicLimits { internal long ProcessTime, JobTime; internal uint Flags; internal nuint MinimumWorkingSet, MaximumWorkingSet; internal uint ProcessCount; internal nuint Affinity; internal uint Priority, Scheduling; }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters { internal ulong ReadCount, WriteCount, OtherCount, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits { internal BasicLimits Basic; internal IoCounters Io; internal nuint ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern nint CreateJobObjectW(nint attributes, string? name);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(nint job, int informationClass, ref ExtendedLimits limits, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(nint job, nint process);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(nint handle);
    }
}
