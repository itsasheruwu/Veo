namespace Veo.Core;

public sealed record QuoteReference(string ThreadId, string ItemId)
{
    public Uri Uri => new("veo-quote://source?thread=" + System.Uri.EscapeDataString(ThreadId) + "&item=" + System.Uri.EscapeDataString(ItemId));
    public string Markdown(string passage, string? comment = null)
    {
        var quoted = string.Join("\n", passage.Trim().Split('\n').Select(line => "> " + line.TrimEnd('\r')));
        return quoted + "\n\n[Source](" + Uri.AbsoluteUri + ")" + (string.IsNullOrWhiteSpace(comment) ? "" : "\n\n" + comment.Trim());
    }
    public static QuoteReference? Parse(Uri uri)
    {
        if (uri.Scheme != "veo-quote" || uri.Host != "source") return null;
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in uri.Query.TrimStart('?').Split('&').Select(part => part.Split('=', 2)).Where(pair => pair.Length == 2))
            if (!values.TryAdd(System.Uri.UnescapeDataString(pair[0]), System.Uri.UnescapeDataString(pair[1]))) return null;
        return values.TryGetValue("thread", out var thread) && values.TryGetValue("item", out var item) && thread.Length > 0 && item.Length > 0 ? new(thread, item) : null;
    }
}
