using System.Diagnostics;
using System.Text.Json;
using Veo.Protocol;

namespace Veo.Core;

/// <summary>Reads context limits from the selected CLI's bundled catalog; never refreshes over the network.</summary>
public static class BundledModelCatalog
{
    public static async Task<IReadOnlyDictionary<string, ModelContextLimits>> ReadAsync(string executable, CancellationToken cancellation = default)
    {
        var start = new ProcessStartInfo(executable) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in new[] { "debug", "models", "--bundled" }) start.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = start };
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation); timeout.CancelAfter(TimeSpan.FromSeconds(15));
        process.Start();
        try
        {
            var output = ReadLimitedAsync(process.StandardOutput, 16 * 1024 * 1024, timeout.Token);
            var error = ReadLimitedAsync(process.StandardError, 64 * 1024, timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            var text = await output; var diagnostics = await error;
            if (process.ExitCode != 0) throw new IOException("Could not read the selected Codex bundled catalog: " + DiagnosticRedactor.Redact(diagnostics));
            using var document = JsonDocument.Parse(text); return Parse(document.RootElement);
        }
        catch { try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { } throw; }
    }
    static async Task<string> ReadLimitedAsync(StreamReader reader, int limit, CancellationToken cancellation)
    {
        var output = new System.Text.StringBuilder(); var buffer = new char[8192];
        while (await reader.ReadAsync(buffer.AsMemory(), cancellation) is var count && count > 0)
        {
            if (output.Length + count > limit) throw new InvalidDataException("The bundled catalog command exceeded its output budget.");
            output.Append(buffer, 0, count);
        }
        return output.ToString();
    }
    public static IReadOnlyDictionary<string, ModelContextLimits> Parse(JsonElement root)
    {
        var result = new Dictionary<string, ModelContextLimits>(StringComparer.Ordinal);
        if (!root.TryGetProperty("models", out var models) || models.ValueKind != JsonValueKind.Array) throw new InvalidDataException("The bundled model catalog has no model rows.");
        foreach (var model in models.EnumerateArray())
            if (model.Str("slug") is { } slug && model.TryGetProperty("context_window", out var suggested) && suggested.TryGetInt64(out var tokens)
                && model.TryGetProperty("max_context_window", out var maximum) && maximum.TryGetInt64(out var max) && ModelContextLimits.Validated(tokens, max) is { } limits)
                result[slug] = limits;
        return result;
    }
}
