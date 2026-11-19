namespace Veo.Core;

/// <summary>Matches DesktopParagraphStreaming: an unfinished Markdown fence never leaks partial code.</summary>
public static class ParagraphStreaming
{
    public static string Visible(TimelineItem item, bool running, string mode)
    {
        if (!running || item.Status is "completed" or "failed" or "interrupted" || item.Kind is not ("agentMessage" or "reasoning")) return item.Text;
        return mode switch { "None" => "", "Paragraph" => CompletedPrefix(item.Text), _ => item.Text };
    }
    public static string CompletedPrefix(string source)
    {
        var lineStart = 0; var visibleEnd = 0; char fence = '\0'; var fenceLength = 0;
        for (var index = 0; index < source.Length; index++)
        {
            if (source[index] is not ('\r' or '\n' or '\u0085' or '\u2028' or '\u2029')) continue;
            var end = index; if (source[index] == '\r' && index + 1 < source.Length && source[index + 1] == '\n') index++;
            var next = index + 1; var line = source.AsSpan(lineStart, end - lineStart).Trim();
            if (line.Length > 0 && line[0] is '`' or '~')
            {
                var marker = line[0]; var length = 0; while (length < line.Length && line[length] == marker) length++;
                if (fence != '\0')
                {
                    if (marker == fence && length >= fenceLength && line[length..].Trim().IsEmpty) { fence = '\0'; visibleEnd = next; }
                }
                else if (length >= 3) { visibleEnd = lineStart; fence = marker; fenceLength = length; }
            }
            else if (line.IsEmpty && fence == '\0') visibleEnd = next;
            lineStart = next;
        }
        return source[..visibleEnd];
    }
}
