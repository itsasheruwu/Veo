using System.Text;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Veo.Core;
using Windows.System;

namespace Veo_Windows.Controls;

public sealed class ChatComposerBox : RichEditBox
{
    sealed record Chip(int Position, string Label, InlineChatContext Context)
    { public int End => Position + Label.Length; }

    List<Chip> chips = [];
    string rendered = "";
    bool updating;
    public event Action<Uri>? OpenContext;
    public event KeyEventHandler? EditorKeyDown;

    public ChatComposerBox()
    {
        IsColorFontEnabled = true;
        ActualThemeChanged += (_, _) => PaintChips();
        TextChanged += (_, _) => ObserveEdit();
        AddHandler(TappedEvent, new TappedEventHandler((_, args) =>
        {
            if (SelectionLength != 0) return;
            var offset = Document.Selection.StartPosition;
            var chip = chips.FirstOrDefault(candidate => offset > candidate.Position && offset < candidate.End);
            if (chip is null) return;
            args.Handled = true;
            OpenContext?.Invoke(chip.Context.Target);
        }), true);
    }

    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        if (SelectionLength == 0 && e.Key is VirtualKey.Back or VirtualKey.Delete)
        {
            var position = Document.Selection.StartPosition;
            var chip = chips.FirstOrDefault(candidate => e.Key == VirtualKey.Back
                ? position > candidate.Position && position <= candidate.End
                : position >= candidate.Position && position < candidate.End);
            if (chip is not null)
            {
                var offset = SourceOffset(chip.Position);
                Text = Text.Remove(offset, chip.Context.Source.Length);
                SelectionStart = offset;
                e.Handled = true;
                return;
            }
        }
        EditorKeyDown?.Invoke(this, e);
        if (!e.Handled) base.OnKeyDown(e);
    }

    public string Text
    {
        get
        {
            var result = new StringBuilder(rendered);
            for (var index = chips.Count - 1; index >= 0; index--)
            {
                var chip = chips[index];
                result.Remove(chip.Position, chip.Label.Length).Insert(chip.Position, chip.Context.Source);
            }
            return result.ToString();
        }
        set
        {
            if (Text == value) return;
            var visible = new StringBuilder();
            var positions = new List<Chip>();
            var offset = 0;
            foreach (var context in InlineChatContext.Scan(value))
            {
                visible.Append(value, offset, context.Start - offset);
                var label = "[" + context.Label + "]";
                positions.Add(new(visible.Length, label, context));
                visible.Append(label);
                offset = context.Start + context.Length;
            }
            visible.Append(value, offset, value.Length - offset);
            updating = true;
            try
            {
                chips = positions;
                rendered = visible.ToString();
                Document.SetText(TextSetOptions.None, rendered.Replace('\n', '\r'));
                PaintChips();
            }
            finally { updating = false; }
        }
    }

    public int SelectionStart
    {
        get => SourceOffset(Document.Selection.StartPosition);
        set
        {
            var offset = Math.Clamp(value, 0, Text.Length);
            var added = 0;
            foreach (var chip in chips)
            {
                var start = chip.Position + added;
                if (offset <= start) break;
                if (offset < start + chip.Context.Source.Length)
                {
                    offset = start + (offset - start < chip.Context.Source.Length / 2 ? 0 : chip.Label.Length);
                    break;
                }
                added += chip.Context.Source.Length - chip.Label.Length;
            }
            var position = Math.Clamp(offset - added, 0, rendered.Length);
            Document.Selection.SetRange(position, position);
        }
    }

    public int SelectionLength => SourceOffset(Document.Selection.EndPosition) - SelectionStart;

    void ObserveEdit()
    {
        if (updating) return;
        Document.GetText(TextGetOptions.None, out var text);
        if (text.EndsWith('\r')) text = text[..^1];
        var next = text.Replace('\r', '\n');
        if (rendered == next) return;
        var start = 0;
        while (start < rendered.Length && start < next.Length && rendered[start] == next[start]) start++;
        var suffix = 0;
        while (suffix < rendered.Length - start && suffix < next.Length - start && rendered[^(suffix + 1)] == next[^(suffix + 1)]) suffix++;
        var previousEnd = rendered.Length - suffix;
        var adjustment = next.Length - rendered.Length;
        chips = chips.Where(chip => chip.End <= start || chip.Position >= previousEnd)
            .Select(chip => chip.Position >= previousEnd ? chip with { Position = chip.Position + adjustment } : chip)
            .ToList();
        rendered = next;
        if (chips.Count == 0) return;
        updating = true;
        try { PaintChips(); } finally { updating = false; }
    }

    int SourceOffset(int visible)
    {
        visible = Math.Clamp(visible, 0, rendered.Length);
        var offset = visible;
        foreach (var chip in chips)
        {
            if (visible >= chip.End) offset += chip.Context.Source.Length - chip.Label.Length;
            else if (visible > chip.Position)
            {
                offset += visible - chip.Position < chip.Label.Length / 2 ? chip.Position - visible : chip.Context.Source.Length - (visible - chip.Position);
                break;
            }
            else break;
        }
        return offset;
    }

    void PaintChips()
    {
        foreach (var chip in chips)
        {
            var format = Document.GetRange(chip.Position, chip.End).CharacterFormat;
            format.BackgroundColor = ActualTheme == ElementTheme.Dark
                ? Windows.UI.Color.FromArgb(255, 49, 58, 73) : Windows.UI.Color.FromArgb(255, 224, 237, 250);
        }
    }
}
