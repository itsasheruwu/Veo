using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;

namespace Veo_Windows;

public sealed partial class MainPage
{
    void InsertAtComposerCaret(string text)
    {
        var previous = Composer.Text;
        var start = Math.Min(Composer.SelectionStart, previous.Length);
        var end = Math.Min(start + Composer.SelectionLength, previous.Length);
        var left = previous[..start];
        var right = previous[end..];
        var leading = left.Length > 0 && !char.IsWhiteSpace(left[^1]) ? " " : "";
        var trailing = right.Length == 0 || !char.IsWhiteSpace(right[0]) ? " " : "";
        Composer.Text = left + leading + text + trailing + right;
        Composer.SelectionStart = left.Length + leading.Length + text.Length + trailing.Length;
    }

    static IEnumerable<ComposerAttachment> InlineFileReferences(ThreadSession session, string draft)
    {
        foreach (var context in InlineChatContext.Scan(draft))
            if (context.Target.Host == "file" && InlineChatContext.Value(context.Target) is { } path)
                yield return ComposerAttachment.FileMention(session.Record.Cwd, path);
    }

    async Task AddTerminalSelectionToComposerAsync(string text)
    {
        if (current is null || string.IsNullOrWhiteSpace(text)) return;
        var excerpt = text.Length > 4000 ? text[..4000] : text;
        var link = InlineChatContext.Link("Terminal excerpt", "terminal", excerpt);
        var quotation = string.Join("\n", excerpt.ReplaceLineEndings("\n").Split('\n').Select(line => "> " + line));
        InsertAtComposerCaret(link + "\n" + quotation + "\n");
        await SaveTypedComposerAsync();
        Composer.Focus(FocusState.Programmatic);
    }

    async Task OpenComposerContextAsync(Uri uri)
    {
        if (QuoteReference.Parse(uri) is { } quote) { await NavigateQuoteAsync(quote); return; }
        if (current is { } session && InlineChatContext.Value(uri) is { } value)
            await Controls.InlineContextPreview.ShowAsync(session, uri.Host, value, XamlRoot, InlineChatContext.Line(uri));
    }
}
