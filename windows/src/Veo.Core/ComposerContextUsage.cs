using System.Text.Json;
using Veo.Protocol;

namespace Veo.Core;

public sealed record ComposerContextUsage(long Used, long Window)
{
    public int Percent => (int)Math.Round(Math.Clamp(Used / (double)Window, 0, 1) * 100);

    public static ComposerContextUsage? Parse(JsonElement usage)
    {
        if (usage.ValueKind != JsonValueKind.Object
            || !usage.TryGetProperty("modelContextWindow", out var maximum)
            || maximum.ValueKind != JsonValueKind.Number || !maximum.TryGetInt64(out var window) || window <= 0
            || !usage.TryObjectProperty("last", out var last)
            || !last.TryGetProperty("totalTokens", out var count)
            || count.ValueKind != JsonValueKind.Number || !count.TryGetInt64(out var used) || used < 0)
            return null;
        return new(used, window);
    }
}
