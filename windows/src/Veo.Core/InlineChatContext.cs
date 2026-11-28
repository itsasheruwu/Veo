using System.Globalization;
using System.Text.RegularExpressions;

namespace Veo.Core;

public sealed partial record InlineChatContext(int Start, int Length, string Label, Uri Target, string Source)
{
    // Only a quote link owns the following Markdown blockquote.
    [GeneratedRegex(@"\[(?<label>[^\]\n]+)\]\((?<url>veo-quote://[^\s)]+)\):\r?\n(?<passage>>[^\r\n]*(?:\r?\n>[^\r\n]*)*)(?:\r?\n\r?\n)?|\[(?<label>[^\]\n]+)\]\((?<url>(?:veo-(?:context|quote)|plugin)://[^\s)]+)\)", RegexOptions.CultureInvariant)]
    private static partial Regex Marker();

    public static IReadOnlyList<InlineChatContext> Scan(string text)
    {
        if (!text.Contains("](", StringComparison.Ordinal)) return [];
        var results = new List<InlineChatContext>();
        foreach (Match match in Marker().Matches(text))
        {
            if (!Uri.TryCreate(match.Groups["url"].Value, UriKind.Absolute, out var uri)) continue;
            var label = VisibleLabel(match);
            if (match.Groups["passage"].Success)
            {
                var excerpt = string.Join(" ", match.Groups["passage"].Value.Split('\n')
                    .Select(line => line[1..].Trim()).Where(line => line.Length > 0));
                var starts = StringInfo.ParseCombiningCharacters(excerpt);
                label = "“" + (starts.Length > 36 ? excerpt[..starts[35]] + "…" : excerpt) + "”";
            }
            results.Add(new(match.Index, match.Length, label, uri, match.Value));
        }
        return results;
    }

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

    static string VisibleLabel(Match match) => match.Groups["url"].Value.StartsWith("plugin://", StringComparison.Ordinal)
        ? "@" + match.Groups["label"].Value.TrimStart('@') : match.Groups["label"].Value;

    public static string DisplayText(string text)
    {
        var contexts = Scan(text);
        if (contexts.Count == 0) return text;
        var output = new System.Text.StringBuilder(text.Length);
        var offset = 0;
        foreach (var context in contexts)
        {
            output.Append(text, offset, context.Start - offset).Append(context.Label);
            offset = context.Start + context.Length;
        }
        return output.Append(text, offset, text.Length - offset).ToString();
    }

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
