using System.Text;
using Markdig;
using Markdig.Helpers;
using Markdig.Syntax;
namespace Veo_Windows.Controls;
public static class NativeMarkdownDocument
{
    static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder().UseAdvancedExtensions().Build();
    public static MarkdownDocument Parse(string source) => Markdig.Markdown.Parse(source, Pipeline);
    public static string Source(string source, MarkdownObject value) { var start = Math.Clamp(value.Span.Start, 0, source.Length); return source[start..Math.Clamp(value.Span.End + 1, start, source.Length)]; }
    public static string Code(CodeBlock code)
    {
        var result = new StringBuilder();
        for (var index = 0; index < code.Lines.Count; index++) { var line = code.Lines.Lines[index]; result.Append(line.Slice.ToString()); result.Append(line.NewLine switch { NewLine.CarriageReturnLineFeed => "\r\n", NewLine.CarriageReturn => "\r", NewLine.LineFeed => "\n", _ => "" }); }
        return result.ToString();
    }
}
