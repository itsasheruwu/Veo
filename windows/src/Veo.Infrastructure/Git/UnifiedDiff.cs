using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Veo.Infrastructure.Git;

public enum DiffLineKind { Context, Added, Removed, NoFinalNewline }
public sealed record DiffLine(DiffLineKind Kind, int? OldLine, int? NewLine, string Text);
public sealed record DiffHunk(int Index, string Header, int OldStart, int OldCount, int NewStart,
    int NewCount, IReadOnlyList<DiffLine> Lines, string Patch, string Sha256)
{ public override string ToString() => Header; }
public sealed record UnifiedDiff(string Raw, bool IsBinary, bool IsRename, bool IsNewFile, bool IsDeletedFile,
    IReadOnlyList<DiffHunk> Hunks)
{
    private static readonly Regex HunkHeader = new(@"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    public static UnifiedDiff Parse(string raw)
    {
        if (!raw.StartsWith("diff --git ", StringComparison.Ordinal)) return new(raw, false, false, false, false, []);
        var lines = new List<string>();
        for (var position = 0; position < raw.Length;)
        {
            var newline = raw.IndexOf('\n', position); var end = newline < 0 ? raw.Length : newline + 1;
            lines.Add(raw[position..end]); position = end;
        }
        var starts = lines.Select((text, index) => (text, index)).Where(pair => HunkHeader.IsMatch(pair.text)).Select(pair => pair.index).ToArray();
        var header = string.Concat(lines.Take(starts.FirstOrDefault(lines.Count)));
        var hunks = new List<DiffHunk>();
        for (var i = 0; i < starts.Length; i++)
        {
            var start = starts[i]; var end = i + 1 < starts.Length ? starts[i + 1] : lines.Count;
            var match = HunkHeader.Match(lines[start]);
            var oldStart = int.Parse(match.Groups[1].Value); var oldCount = match.Groups[2].Success ? int.Parse(match.Groups[2].Value) : 1;
            var newStart = int.Parse(match.Groups[3].Value); var newCount = match.Groups[4].Success ? int.Parse(match.Groups[4].Value) : 1;
            var rows = new List<DiffLine>(); var oldLine = oldStart; var newLine = newStart;
            for (var line = start + 1; line < end; line++)
            {
                var text = lines[line].TrimEnd('\n');
                if (text.Length == 0) continue;
                switch (text[0])
                {
                    case ' ': rows.Add(new(DiffLineKind.Context, oldLine++, newLine++, text[1..])); break;
                    case '-': rows.Add(new(DiffLineKind.Removed, oldLine++, null, text[1..])); break;
                    case '+': rows.Add(new(DiffLineKind.Added, null, newLine++, text[1..])); break;
                    case '\\': rows.Add(new(DiffLineKind.NoFinalNewline, null, null, text)); break;
                    default: throw new InvalidDataException("The Git patch contains an unsupported combined or multi-file hunk.");
                }
            }
            if (oldLine - oldStart != oldCount || newLine - newStart != newCount)
                throw new InvalidDataException("The Git hunk line counts do not match its content.");
            var patch = header + string.Concat(lines.Skip(start).Take(end - start));
            hunks.Add(new(i, lines[start].TrimEnd('\r', '\n'), oldStart, oldCount, newStart, newCount, rows, patch,
                Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(patch)))));
        }
        return new(raw, header.Contains("GIT binary patch", StringComparison.Ordinal) || header.Contains("Binary files ", StringComparison.Ordinal),
            header.Contains("rename from ", StringComparison.Ordinal), header.Contains("new file mode ", StringComparison.Ordinal),
            header.Contains("deleted file mode ", StringComparison.Ordinal), hunks);
    }
}
