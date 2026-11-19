namespace Veo_Windows.Controls;

internal sealed record ConversationPatch(string Name, string Text)
{
    public static IReadOnlyList<ConversationPatch> Files(string diff)
    {
        var files = new List<ConversationPatch>();
        var lines = diff.ReplaceLineEndings("\n").Split('\n');
        var start = 0;
        for (var index = 1; index < lines.Length; index++)
        {
            if (!lines[index].StartsWith("diff --git ", StringComparison.Ordinal)) continue;
            Add(start, index);
            start = index;
        }
        if (!string.IsNullOrWhiteSpace(diff)) Add(start, lines.Length);
        return files;

        void Add(int first, int end)
        {
            var header = lines[first];
            var path = header.IndexOf(" b/", StringComparison.Ordinal);
            var name = path >= 0 ? header[(path + 3)..] : "Changes";
            files.Add(new(name, string.Join("\n", lines[first..end])));
        }
    }
}
