using Markdig.Extensions.Tables;
using Markdig.Extensions.TaskLists;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Windows.ApplicationModel.DataTransfer;
namespace Veo_Windows.Controls;

/// <summary>Native selectable Markdown. Streaming retains unchanged prefix controls and their selection.</summary>
public sealed class MarkdownView : StackPanel
{
    public static readonly DependencyProperty MarkdownProperty = DependencyProperty.Register(nameof(Markdown), typeof(string), typeof(MarkdownView), new PropertyMetadata("", Changed));
    public string Markdown { get => (string)GetValue(MarkdownProperty); set => SetValue(MarkdownProperty, value); }
    public bool IsStreaming { get; set; }
    public ThreadSession? Session { get; set; }
    public Func<string, Task>? OpenLinkAsync { get; set; }
    public event Action? Rendered;
    readonly List<(string Key, UIElement Element)> rendered = [];
    readonly InfoBar notice = new() { Severity = InfoBarSeverity.Warning, IsClosable = true };
    Microsoft.UI.Dispatching.DispatcherQueueTimer? timer;
    string pending = "", source = "";
    public MarkdownView()
    {
        Spacing = 8; AutomationProperties.SetLiveSetting(this, AutomationLiveSetting.Off);
        Unloaded += (_, _) => timer?.Stop(); Loaded += (_, _) => { if (pending != source) Render(pending); };
    }
    static void Changed(DependencyObject owner, DependencyPropertyChangedEventArgs args)
    {
        var view = (MarkdownView)owner; view.pending = args.NewValue as string ?? "";
        if (!view.IsStreaming || view.rendered.Count == 0) { view.timer?.Stop(); view.Render(view.pending); return; }
        if (view.timer is null) { view.timer = view.DispatcherQueue.CreateTimer(); view.timer.Interval = TimeSpan.FromMilliseconds(50); view.timer.IsRepeating = false; view.timer.Tick += (_, _) => view.Render(view.pending); }
        if (!view.timer.IsRunning) view.timer.Start();
    }
    void Render(string value)
    {
        source = value; var blocks = NativeMarkdownDocument.Parse(value).ToArray(); var stable = 0;
        while (stable < blocks.Length && stable < rendered.Count && rendered[stable].Key == Key(blocks[stable])) stable++;
        while (rendered.Count > stable) { Children.Remove(rendered[^1].Element); rendered.RemoveAt(rendered.Count - 1); }
        if (Children.Contains(notice)) Children.Remove(notice);
        for (var index = stable; index < blocks.Length; index++) { var element = Block(blocks[index]); rendered.Add((Key(blocks[index]), element)); Children.Add(element); }
        Children.Add(notice); Rendered?.Invoke();
    }
    string Key(Markdig.Syntax.Block block) => block.GetType().Name + "|" + block.Span.Start + "|" + NativeMarkdownDocument.Source(source, block);
    UIElement Block(Markdig.Syntax.Block block)
    {
        if (block is CodeBlock code)
        {
            var exact = NativeMarkdownDocument.Code(code); var body = new StackPanel { Spacing = 4 };
            var commands = new CommandBar { DefaultLabelPosition = CommandBarDefaultLabelPosition.Right, IsOpen = false };
            if (code is FencedCodeBlock fenced && !string.IsNullOrWhiteSpace(fenced.Info)) commands.Content = new TextBlock { Text = fenced.Info, FontSize = 11 };
            var copy = new AppBarButton { Label = "Copy code", Icon = new SymbolIcon(Symbol.Copy) }; copy.Click += (_, _) => { Copy(exact); copy.Label = "Copied"; }; commands.PrimaryCommands.Add(copy); body.Children.Add(commands);
            var text = new TextBox { Text = exact, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, FontFamily = new("Cascadia Mono"), FontSize = 12, BorderThickness = new(0), Padding = new(10), MaxHeight = 500 };
            AutomationProperties.SetName(text, "Code" + (code is FencedCodeBlock language ? " · " + language.Info : "")); ScrollViewer.SetHorizontalScrollBarVisibility(text, ScrollBarVisibility.Auto); body.Children.Add(text); return body;
        }
        if (block is Table table) return RenderTable(table);
        if (block is ListBlock list)
        {
            var body = new StackPanel { Spacing = list.IsLoose ? 8 : 3 }; _ = int.TryParse(list.OrderedStart, out var ordinal); if (ordinal <= 0) ordinal = 1;
            foreach (var entry in list.OfType<ListItemBlock>())
            {
                var row = new Grid { ColumnSpacing = 8 }; row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
                row.Children.Add(new TextBlock { Text = list.IsOrdered ? ordinal++ + "." : "•", MinWidth = 16, HorizontalAlignment = HorizontalAlignment.Right }); var content = Container(entry); Grid.SetColumn(content, 1); row.Children.Add(content); body.Children.Add(row);
            }
            return body;
        }
        if (block is QuoteBlock quote) return new Border { BorderThickness = new(3, 0, 0, 0), BorderBrush = Resource("DividerStrokeColorDefaultBrush"), Padding = new(12, 2, 0, 2), Child = Container(quote) };
        if (block is ThematicBreakBlock) return new Border { Height = 1, Background = Resource("DividerStrokeColorDefaultBrush"), Margin = new(0, 6, 0, 6) };
        if (block is LeafBlock leaf && leaf.Inline is { } inline)
        {
            var rich = new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontSize = block is HeadingBlock heading ? Math.Max(14, 26 - heading.Level * 2) : 14 };
            if (block is HeadingBlock) rich.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; var paragraph = new Paragraph(); Inlines(inline, paragraph.Inlines); rich.Blocks.Add(paragraph); return rich;
        }
        if (block is ContainerBlock container) return Container(container);
        return new TextBlock { Text = NativeMarkdownDocument.Source(source, block), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    }
    StackPanel Container(ContainerBlock block) { var panel = new StackPanel { Spacing = 6 }; foreach (var child in block) panel.Children.Add(Block(child)); return panel; }
    UIElement RenderTable(Table table)
    {
        var rows = table.OfType<TableRow>().ToArray();
        if (rows.Sum(x => x.Count) > 500) return new Expander { Header = "Large table · selectable Markdown source", Content = new TextBox { Text = NativeMarkdownDocument.Source(source, table), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, MaxHeight = 420 } };
        var grid = new Grid(); var columns = rows.SelectMany(x => x.OfType<TableCell>()).Select(x => x.ColumnIndex + Math.Max(1, x.ColumnSpan)).DefaultIfEmpty(1).Max();
        for (var index = 0; index < columns; index++) grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        for (var row = 0; row < rows.Length; row++)
        {
            grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
            foreach (var cell in rows[row].OfType<TableCell>())
            {
                var content = Container(cell); var border = new Border { Child = content, BorderThickness = new(0, 0, 1, 1), BorderBrush = Resource("DividerStrokeColorDefaultBrush"), Padding = new(8), MinWidth = 70, MaxWidth = 380 };
                Grid.SetRow(border, row); Grid.SetColumn(border, Math.Max(0, cell.ColumnIndex)); Grid.SetColumnSpan(border, Math.Max(1, cell.ColumnSpan)); Grid.SetRowSpan(border, Math.Max(1, cell.RowSpan)); grid.Children.Add(border);
            }
        }
        return new ScrollViewer { Content = grid, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollMode = ScrollMode.Disabled };
    }
    void Inlines(ContainerInline container, InlineCollection output)
    {
        foreach (var inline in container)
            switch (inline)
            {
                case LiteralInline literal: output.Add(new Run { Text = literal.Content.ToString() }); break;
                case CodeInline code: output.Add(new Run { Text = code.Content, FontFamily = new("Cascadia Mono") }); break;
                case LineBreakInline: output.Add(new LineBreak()); break;
                case TaskList task: output.Add(new Run { Text = task.Checked ? "☑ " : "☐ " }); break;
                case EmphasisInline emphasis: Span span = emphasis.DelimiterCount >= 2 ? new Bold() : new Italic(); Inlines(emphasis, span.Inlines); output.Add(span); break;
                case LinkInline link when link.IsImage:
                    var alt = string.Join("", link.OfType<LiteralInline>().Select(x => x.Content.ToString())); var target = link.Url ?? "";
                    if (Session is { } session) output.Add(new InlineUIContainer { Child = new ConversationArtifactView(session, new("markdown:" + link.Span.Start, Uri.TryCreate(target, UriKind.Absolute, out var imageUri) && imageUri.Scheme == "https" ? "remoteImage" : target.StartsWith("data:", StringComparison.OrdinalIgnoreCase) ? "dataImage" : "localImage", target, alt.Length == 0 ? "Image" : alt)) });
                    else output.Add(new Run { Text = "[Image: " + (alt.Length > 0 ? alt : target) + "]" }); break;
                case LinkInline link:
                    var hyperlink = new Hyperlink(); Inlines(link, hyperlink.Inlines); if (hyperlink.Inlines.Count == 0) hyperlink.Inlines.Add(new Run { Text = link.Url ?? "Link" }); var url = link.Url ?? ""; hyperlink.Click += (_, _) => Open(url); output.Add(hyperlink); break;
                case AutolinkInline auto: var automatic = new Hyperlink(); automatic.Inlines.Add(new Run { Text = auto.Url }); automatic.Click += (_, _) => Open(auto.Url); output.Add(automatic); break;
                case ContainerInline nested: Inlines(nested, output); break;
                default: output.Add(new Run { Text = NativeMarkdownDocument.Source(source, inline) }); break;
            }
    }
    async void Open(string target)
    {
        try
        {
            if (OpenLinkAsync is not null) { await OpenLinkAsync(target); return; }
            if (Uri.TryCreate(target, UriKind.Absolute, out var uri) && QuoteReference.Parse(uri) is { } quote) { if (App.Main is { } window) await window.NavigateQuoteAsync(quote); return; }
            if (IntegrationCoordinator.SecureUri(target) is { } secure) { if (App.Main is { } window) await window.NavigateBrowserAsync(secure); return; }
            if (Session is { } session && !target.Contains("://", StringComparison.Ordinal)) { await new ContentDialog { Title = "Source", Content = new ConversationSourceView(session, new("markdown", target, target)), CloseButtonText = "Done", XamlRoot = XamlRoot }.ShowAsync(); return; }
            throw new InvalidOperationException("This link has no supported secure target.");
        }
        catch (Exception error) { notice.Message = Veo.Protocol.DiagnosticRedactor.Redact(error.Message); notice.IsOpen = true; }
    }
    public string SelectedText() => string.Join("\n", Descendants(this).Select(x => x switch { RichTextBlock text => text.SelectedText, TextBox text => text.SelectedText, _ => "" }).Where(x => x.Length > 0));
    public static IEnumerable<DependencyObject> Descendants(DependencyObject parent) { for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++) { var child = VisualTreeHelper.GetChild(parent, index); yield return child; foreach (var nested in Descendants(child)) yield return nested; } }
    static Brush Resource(string key) => (Brush)Application.Current.Resources[key];
    static void Copy(string text) { var package = new DataPackage(); package.SetText(text); Clipboard.SetContent(package); }
}
