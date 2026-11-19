using System.Text.RegularExpressions;

namespace Veo.Core;

public sealed partial record InlineChatContext(int Start, int Length, string Label, Uri Target, string Source)
{
    [GeneratedRegex(@"\[([^\]\n]+)\]\((veo-(?:context|quote)://[^\s)]+)\)", RegexOptions.CultureInvariant)]
    private static partial Regex Marker();

    public static IReadOnlyList<InlineChatContext> Scan(string text) => Marker().Matches(text)
        .Where(match => Uri.TryCreate(match.Groups[2].Value, UriKind.Absolute, out _))
        .Select(match => new InlineChatContext(match.Index, match.Length, match.Groups[1].Value, new Uri(match.Groups[2].Value), match.Value))
        .ToArray();

    public static string DisplayText(string text) => Marker().Replace(text, match => match.Groups[1].Value);

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
