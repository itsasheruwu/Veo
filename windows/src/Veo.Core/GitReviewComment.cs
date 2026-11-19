using Veo.Infrastructure.Git;

namespace Veo.Core;

/// <summary>The patch as shown when the comment editor opened, including its staged and whitespace modes.</summary>
public sealed class GitReviewComment(string path, bool staged, bool ignoreWhitespace, DiffHunk hunk)
{
    public string Location { get; } = path + (staged ? " (staged)" : " (unstaged)")
        + (ignoreWhitespace ? " · whitespace ignored" : "");
    public IReadOnlyList<DiffLine> Lines { get; } = Array.AsReadOnly(hunk.Lines
        .Where(line => line.Kind != DiffLineKind.NoFinalNewline).ToArray());

    public string FormatDraft(IEnumerable<DiffLine> selection, string comment)
    {
        if (string.IsNullOrWhiteSpace(comment)) throw new ArgumentException("Enter a review comment.");
        var selected = selection.ToHashSet();
        var lines = Lines.Where(selected.Contains).ToArray();
        if (lines.Length == 0 || lines.Length != selected.Count)
            throw new ArgumentException("Select lines from the displayed hunk.");

        var oldRanges = LineRanges(lines.Select(line => line.OldLine));
        var newRanges = LineRanges(lines.Select(line => line.NewLine));
        var excerpt = string.Join("\n", lines.Select(line => "> " + LineLabel(line)));
        var target = InlineChatContext.Link("Review · " + path + (newRanges == "–" ? "" : ":" + newRanges), "review", path, lines[0].NewLine);
        return $"Review comment on {target} ({(staged ? "staged" : "unstaged")})\nOld lines: {oldRanges}\nNew lines: {newRanges}\n\n"
            + comment.Trim() + "\n\nSelected patch lines:\n" + excerpt;
    }

    public static string LineLabel(DiffLine line)
    {
        var prefix = line.Kind switch { DiffLineKind.Added => '+', DiffLineKind.Removed => '-', _ => ' ' };
        var text = line.Text.EndsWith('\r') ? line.Text[..^1] : line.Text;
        return $"old:{line.OldLine?.ToString() ?? "–"} new:{line.NewLine?.ToString() ?? "–"} {prefix}{text}";
    }

    private static string LineRanges(IEnumerable<int?> numbers)
    {
        var ranges = new List<(int Start, int End)>();
        foreach (var number in numbers.OfType<int>())
        {
            if (ranges.Count > 0 && number == ranges[^1].End + 1)
                ranges[^1] = (ranges[^1].Start, number);
            else
                ranges.Add((number, number));
        }
        return ranges.Count == 0 ? "–" : string.Join(", ", ranges.Select(range =>
            range.Start == range.End ? range.Start.ToString() : $"{range.Start}–{range.End}"));
    }
}
