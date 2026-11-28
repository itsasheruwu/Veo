using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Veo.Infrastructure.Git;
using Windows.ApplicationModel.DataTransfer;

namespace Veo_Windows.Controls;

public sealed class NativeDiffRow
{
    public string OldLine { get; init; } = "";
    public string NewLine { get; init; } = "";
    public string Text { get; init; } = "";
    public string OldText { get; init; } = "";
    public string NewText { get; init; } = "";
    public Brush? Background { get; init; }
    public Brush? OldBackground { get; init; }
    public Brush? NewBackground { get; init; }
}

/// <summary>Virtualized native line rendering. WebView2 is not involved in review.</summary>
public sealed class NativeDiffView : UserControl
{
    private readonly ListView lines = new() { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = false, ItemContainerTransitions = new() };
    private readonly TextBox raw = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap,
        FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12 };
    private string text = "";
    private bool split;
    private UnifiedDiff? document;
    private readonly Grid host = new();
    public string PlaceholderText { get => raw.PlaceholderText; set => raw.PlaceholderText = value; }
    public string Text { get => text; set { text = value; document = UnifiedDiff.Parse(value); Render(); } }
    public bool IsSplit
    {
        get => split;
        set
        {
            if (split == value) return;
            split = value;
            Render();
        }
    }
    public void ShowRawText(string value) { text = value; document = null; Render(); }
    public NativeDiffView()
    {
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 20d));
        lines.ItemContainerStyle = style;
        ScrollViewer.SetHorizontalScrollBarVisibility(lines, ScrollBarVisibility.Auto);
        ScrollViewer.SetHorizontalScrollBarVisibility(raw, ScrollBarVisibility.Auto);
        var menu = new MenuFlyout(); var copy = new MenuFlyoutItem { Text = "Copy complete patch" };
        copy.Click += (_, _) => { var data = new DataPackage(); data.SetText(text); Clipboard.SetContent(data); };
        menu.Items.Add(copy); lines.ContextFlyout = menu; raw.ContextFlyout = menu;
        host.Children.Add(lines); host.Children.Add(raw); Content = host;
        ActualThemeChanged += (_, _) => Render();
    }
    private void Render()
    {
        if (document is null || document.Hunks.Count == 0)
        { raw.Text = text; raw.Visibility = Visibility.Visible; lines.Visibility = Visibility.Collapsed; return; }
        raw.Visibility = Visibility.Collapsed; lines.Visibility = Visibility.Visible;
        lines.ItemTemplate = (DataTemplate)XamlReader.Load(split ? SplitTemplate : UnifiedTemplate);
        Brush? BrushFor(string key) => Application.Current.Resources.TryGetValue(key, out var value) ? value as Brush : null;
        var added = BrushFor("SystemFillColorSuccessBackgroundBrush"); var removed = BrushFor("SystemFillColorCriticalBackgroundBrush");
        var neutral = BrushFor("SubtleFillColorSecondaryBrush");
        var rows = new List<NativeDiffRow>();
        foreach (var hunk in document.Hunks)
        {
            rows.Add(new() { Text = hunk.Header, OldText = hunk.Header, Background = neutral, OldBackground = neutral, NewBackground = neutral });
            foreach (var line in hunk.Lines)
            {
                var prefix = line.Kind switch { DiffLineKind.Added => "+", DiffLineKind.Removed => "-", DiffLineKind.Context => " ", _ => "" };
                rows.Add(new()
                {
                    OldLine = line.OldLine?.ToString() ?? "", NewLine = line.NewLine?.ToString() ?? "",
                    Text = prefix + line.Text.TrimEnd('\r'),
                    OldText = line.Kind is DiffLineKind.Context or DiffLineKind.Removed ? line.Text.TrimEnd('\r') : "",
                    NewText = line.Kind is DiffLineKind.Context or DiffLineKind.Added or DiffLineKind.NoFinalNewline ? line.Text.TrimEnd('\r') : "",
                    Background = line.Kind == DiffLineKind.Added ? added : line.Kind == DiffLineKind.Removed ? removed : null,
                    OldBackground = line.Kind == DiffLineKind.Removed ? removed : null,
                    NewBackground = line.Kind == DiffLineKind.Added ? added : null
                });
            }
        }
        lines.ItemsSource = rows;
    }
    private const string UnifiedTemplate = """
        <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
          <Grid Background="{Binding Background}">
            <Grid.ColumnDefinitions><ColumnDefinition Width="42"/><ColumnDefinition Width="42"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Text="{Binding OldLine}" Foreground="{ThemeResource TextFillColorSecondaryBrush}" FontFamily="Consolas" FontSize="12" Margin="4,1"/>
            <TextBlock Grid.Column="1" Text="{Binding NewLine}" Foreground="{ThemeResource TextFillColorSecondaryBrush}" FontFamily="Consolas" FontSize="12" Margin="4,1"/>
            <TextBlock Grid.Column="2" Text="{Binding Text}" IsTextSelectionEnabled="True" FontFamily="Consolas" FontSize="12" Margin="4,1"/>
          </Grid>
        </DataTemplate>
        """;
    private const string SplitTemplate = """
        <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="42"/><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Text="{Binding OldLine}" Foreground="{ThemeResource TextFillColorSecondaryBrush}" FontFamily="Consolas" FontSize="12" Margin="4,1"/>
            <Border Grid.Column="1" Background="{Binding OldBackground}"><TextBlock Text="{Binding OldText}" IsTextSelectionEnabled="True" FontFamily="Consolas" FontSize="12" Margin="4,1"/></Border>
            <TextBlock Grid.Column="2" Text="{Binding NewLine}" Foreground="{ThemeResource TextFillColorSecondaryBrush}" FontFamily="Consolas" FontSize="12" Margin="4,1"/>
            <Border Grid.Column="3" Background="{Binding NewBackground}"><TextBlock Text="{Binding NewText}" IsTextSelectionEnabled="True" FontFamily="Consolas" FontSize="12" Margin="4,1"/></Border>
          </Grid>
        </DataTemplate>
        """;
}
