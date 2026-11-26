using System.Text.RegularExpressions;

namespace Veo.Core;

public sealed partial record InlineChatContext(int Start, int Length, string Label, Uri Target, string Source)
{
    [GeneratedRegex(@"\[([^\]\n]+)\]\(((?:veo-(?:context|quote)|plugin)://[^\s)]+)\)", RegexOptions.CultureInvariant)]
    private static partial Regex Marker();

    public static IReadOnlyList<InlineChatContext> Scan(string text) => Marker().Matches(text)
        .Where(match => Uri.TryCreate(match.Groups[2].Value, UriKind.Absolute, out _))
        .Select(match => new InlineChatContext(match.Index, match.Length, VisibleLabel(match), new Uri(match.Groups[2].Value), match.Value))
        .ToArray();

    [GeneratedRegex(@"^[a-zA-Z0-9_.-]+@[a-zA-Z0-9_.-]+$", RegexOptions.CultureInvariant)]
    private static partial Regex PluginId();
    public static bool ValidPluginId(string id) => PluginId().IsMatch(id);
    public static string PluginProtocolText(string text)
    {
        foreach (var chip in Scan(text).Reverse().Where(chip => chip.Target.Host == "plugin"))
        {
            var id = Value(chip.Target);
            var visible = id is not null && ValidPluginId(id) ? $"[{chip.Label.TrimStart('@')}](plugin://{id})" : chip.Label;
            text = text.Remove(chip.Start, chip.Length).Insert(chip.Start, visible);
        }
        return text.Replace("](plugin://browser@openai-bundled?browserFamily=chrome)", "](plugin://chrome@openai-bundled)", StringComparison.Ordinal);
    }

    static string VisibleLabel(Match match) => match.Groups[2].Value.StartsWith("plugin://", StringComparison.Ordinal)
        ? "@" + match.Groups[1].Value.TrimStart('@') : match.Groups[1].Value;

    public static string DisplayText(string text) => Marker().Replace(text, VisibleLabel);

    public static string Link(string label, string kind, string value, int? line = null)
        => $"[{label.Replace(']', '）').ReplaceLineEndings(" ")}](veo-context://{kind}?value={Uri.EscapeDataString(value)}{(line is null ? "" : "&line=" + line.Value)})";

    public static string? Value(Uri uri) => QueryValue(uri, "value");

    public static int? Line(Uri uri) => int.TryParse(QueryValue(uri, "line"), out var line) && line > 0 ? line : null;

    static string? QueryValue(Uri uri, string name)
    {
        if (uri.Scheme != "veo-context") return null;
        var prefix = name + "=";
        var value = uri.Query.TrimStart('?').Split('&').FirstOrDefault(part => part.StartsWith(prefix, StringComparison.Ordinal));
        return value is null ? null : Uri.UnescapeDataString(value[prefix.Length..]);
    }
}
