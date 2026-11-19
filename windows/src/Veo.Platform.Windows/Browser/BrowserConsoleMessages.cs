using System.Text.Json;

namespace Veo.Platform.Windows.Browser;
public static class BrowserConsoleMessages
{
    public static string ParseDevTools(string json)
    {
        if (json.Length > 65536)
            return "[console message exceeded 64 KiB]";
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("args", out var args) || args.ValueKind != JsonValueKind.Array)
            throw new InvalidDataException("Malformed console event.");
        var level = root.TryGetProperty("type", out var type) && type.ValueKind == JsonValueKind.String ? type.GetString() : "log";
        var parts = new List<string>();
        var remaining = 4096;
        foreach (var arg in args.EnumerateArray().Take(32))
        {
            var text = arg.ValueKind == JsonValueKind.Object && arg.TryGetProperty("value", out var value) ? value.ToString() : arg.ValueKind == JsonValueKind.Object && arg.TryGetProperty("description", out var description) ? description.ToString() : "[object]";
            if (text.Length > remaining)
                text = text[..remaining] + "…";
            parts.Add(text);
            remaining -= Math.Min(remaining, text.Length);
            if (remaining == 0)
                break;
        }

        var result = level + ": " + string.Join(" ", parts);
        return result.Length > 4096 ? result[..4096] + "…" : result;
    }
}
