using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Veo.Infrastructure.Files;
using Windows.System;

namespace Veo_Windows.Controls;

/// <summary>Native lazy workspace tree and text editor; editor buffers survive utility-tab changes.</summary>
public sealed class FilesPanel : UserControl
{
    private readonly Button back = new();
    private readonly WorkspaceCoordinator coordinator;
    private readonly TreeView tree = new() { SelectionMode = TreeViewSelectionMode.Single, ItemContainerTransitions = new() };
    private readonly TextBox editor = new() { AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap,
        FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 13, IsSpellCheckEnabled = false,
        IsTextPredictionEnabled = false, PlaceholderText = "Select a text file", VerticalAlignment = VerticalAlignment.Stretch,
        HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBlock location = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private readonly InfoBar notice = new() { IsOpen = false, IsClosable = true };
    private readonly TextBox find = new() { PlaceholderText = "Find in file", MinWidth = 100, Visibility = Visibility.Collapsed };
    private readonly AutoSuggestBox searchFiles = new() { PlaceholderText = "Search workspace files", QueryIcon = new SymbolIcon(Symbol.Find) };
    private readonly AppBarButton save = new() { Label = "Save", Icon = new SymbolIcon(Symbol.Save), IsEnabled = false };
    private readonly Dictionary<string, EditorBuffer> buffers = new(StringComparer.Ordinal);
    private WorkspaceFileService? files;
    private EditorBuffer? active;
    private string? cwd;
    private bool settingText;
    private int loadGeneration;
    private CancellationTokenSource? searchCancellation;
    private sealed class EditorBuffer(WorkspaceTextDocument document)
    {
        public WorkspaceTextDocument Document { get; set; } = document;
        public string Text { get; set; } = document.Text;
        public bool Dirty => Text != Document.Text;
    }
    private sealed record NodeData(WorkspaceFileEntry Entry)
    { public override string ToString() => Entry.Name; }

    public FilesPanel(WorkspaceCoordinator coordinator)
    {
        this.coordinator = coordinator;
        AutomationProperties.SetName(tree, "Workspace files"); AutomationProperties.SetName(editor, "File editor");
        AutomationProperties.SetName(find, "Find in file");
        AutomationProperties.SetName(searchFiles, "Search workspace files");
        ScrollViewer.SetHorizontalScrollBarVisibility(editor, ScrollBarVisibility.Auto);
        ScrollViewer.SetVerticalScrollBarVisibility(editor, ScrollBarVisibility.Auto);
        var commands = new CommandBar { DefaultLabelPosition = CommandBarDefaultLabelPosition.Collapsed };
        var refresh = new AppBarButton { Label = "Refresh files", Icon = new SymbolIcon(Symbol.Refresh) };
        var search = new AppBarButton { Label = "Find in file", Icon = new SymbolIcon(Symbol.Find) };
        commands.PrimaryCommands.Add(refresh); commands.PrimaryCommands.Add(save); commands.PrimaryCommands.Add(search);
        commands.Content = location;
        refresh.Click += async (_, _) => await GuardAsync(RefreshTreeAsync);
        save.Click += async (_, _) => await SaveAsync();
        search.Click += (_, _) => { find.Visibility = Visibility.Visible; find.Focus(FocusState.Keyboard); };
        searchFiles.TextChanged += async (_, args) =>
        {
            if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
            searchCancellation?.Cancel(); searchCancellation?.Dispose(); searchCancellation = new();
            var token = searchCancellation.Token; var generation = loadGeneration; var service = files;
            if (service is null || searchFiles.Text.Length == 0) { searchFiles.ItemsSource = null; return; }
            try
            {
                var results = await service.SearchAsync(searchFiles.Text, cancellationToken: token);
                if (!token.IsCancellationRequested && generation == loadGeneration) searchFiles.ItemsSource = results.Select(entry => new NodeData(entry)).ToArray();
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { notice.Severity = InfoBarSeverity.Error; notice.Title = "File search failed"; notice.Message = error.Message; notice.IsOpen = true; }
        };
        searchFiles.QuerySubmitted += async (_, args) =>
        { if (args.ChosenSuggestion is NodeData data) await GuardAsync(() => OpenAsync(data.Entry.RelativePath)); };
        find.KeyDown += (_, args) => { if (args.Key == VirtualKey.Enter) { FindNext(); args.Handled = true; } else if (args.Key == VirtualKey.Escape) find.Visibility = Visibility.Collapsed; };
        editor.TextChanged += (_, _) =>
        {
            if (!settingText && active is not null) { active.Text = editor.Text; save.IsEnabled = active.Dirty; UpdateLocation(); }
        };
        editor.KeyDown += async (_, args) =>
        {
            var control = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (control && args.Key == VirtualKey.S) { args.Handled = true; await SaveAsync(); }
            else if (control && args.Key == VirtualKey.F) { args.Handled = true; find.Visibility = Visibility.Visible; find.Focus(FocusState.Keyboard); }
        };
        tree.Expanding += async (_, args) =>
        {
            if (args.Node.Content is NodeData data && args.Node.HasUnrealizedChildren)
                await GuardAsync(async () =>
                {
                    var generation = loadGeneration; var service = files;
                    if (service is null) return;
                    var entries = await service.ListChildrenAsync(data.Entry.RelativePath);
                    if (generation != loadGeneration) return;
                    args.Node.Children.Clear(); foreach (var entry in entries) args.Node.Children.Add(Node(entry)); args.Node.HasUnrealizedChildren = false;
                });
        };
        tree.ItemInvoked += async (_, args) =>
        {
            var data = args.InvokedItem is TreeViewNode node ? node.Content as NodeData : args.InvokedItem as NodeData;
            if (data is not null && !data.Entry.IsDirectory) await GuardAsync(() => OpenAsync(data.Entry.RelativePath));
        };
        var toolbar = new Grid { ColumnSpacing = 5, Padding = new Thickness(8, 3, 4, 3) };
        toolbar.ColumnDefinitions.Add(new()); toolbar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        searchFiles.PlaceholderText = "Filter files";
        toolbar.Children.Add(searchFiles);
        commands.Content = null; commands.HorizontalAlignment = HorizontalAlignment.Right;
        commands.IsDynamicOverflowEnabled = false;
        commands.PrimaryCommands.Remove(save); commands.SecondaryCommands.Add(save);
        commands.PrimaryCommands.Remove(search); commands.SecondaryCommands.Add(search);
        Grid.SetColumn(commands, 1); toolbar.Children.Add(commands);
        var grid = new Grid();
        grid.RowDefinitions.Add(new() { Height = GridLength.Auto }); grid.RowDefinitions.Add(new() { Height = GridLength.Auto }); grid.RowDefinitions.Add(new());
        Add(grid, toolbar, 0); Add(grid, notice, 1); Add(grid, body, 2);
        body.ColumnDefinitions.Add(new()); body.ColumnDefinitions.Add(new());
        treePanel.Children.Add(tree); treePanel.Children.Add(emptyTree); body.Children.Add(treePanel);
        var detail = new Grid { Padding = new Thickness(5) };
        detail.RowDefinitions.Add(new() { Height = GridLength.Auto }); detail.RowDefinitions.Add(new() { Height = GridLength.Auto }); detail.RowDefinitions.Add(new());
        back.Content = "‹  Files"; back.Style = (Style)Application.Current.Resources["SubtleButtonStyle"];
        back.Click += (_, _) => { showsDetail = false; UpdateLayoutMode(); };
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, Children = { back, location } };
        Add(detail, header, 0); Add(detail, find, 1); Add(detail, editor, 2);
        detailPanel.Children.Add(detail); detailPanel.Children.Add(emptyDetail); body.Children.Add(detailPanel);
        SizeChanged += (_, _) => UpdateLayoutMode();
        Content = grid;
        UpdateLayoutMode();
    }

    readonly Grid body = new(), treePanel = new(), detailPanel = new();
    readonly InspectorEmptyState emptyTree = new("\uE8B7", "No files", "Files in this workspace appear here.");
    readonly InspectorEmptyState emptyDetail = new("\uE8A5", "Select a file", "Preview files or open text files for manual editing.");
    bool showsDetail;
    void UpdateLayoutMode()
    {
        var compact = ActualWidth < 590;
        back.Visibility = compact && showsDetail ? Visibility.Visible : Visibility.Collapsed;
        var detailVisible = !compact || showsDetail;
        treePanel.Visibility = !compact || !showsDetail ? Visibility.Visible : Visibility.Collapsed;
        detailPanel.Visibility = detailVisible ? Visibility.Visible : Visibility.Collapsed;
        body.ColumnDefinitions[0].Width = compact ? new GridLength(1, GridUnitType.Star) : new GridLength(210);
        body.ColumnDefinitions[1].Width = compact ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        Grid.SetColumn(detailPanel, compact ? 0 : 1);
        detailPanel.Children[0].Visibility = active is null ? Visibility.Collapsed : Visibility.Visible;
        emptyDetail.Visibility = active is null ? Visibility.Visible : Visibility.Collapsed;
        emptyTree.Visibility = tree.RootNodes.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    public async Task LoadAsync(ThreadSession session)
    {
        if (cwd == session.Record.Cwd) return;
        searchCancellation?.Cancel(); searchFiles.Text = ""; searchFiles.ItemsSource = null;
        showsDetail = false; cwd = session.Record.Cwd; files = new(cwd); active = null; settingText = true; editor.Text = ""; settingText = false;
        save.IsEnabled = false; location.Text = Path.GetFileName(cwd); loadGeneration++;
        await GuardAsync(RefreshTreeAsync);
    }
    private static TreeViewNode Node(WorkspaceFileEntry entry) => new() { Content = new NodeData(entry), HasUnrealizedChildren = entry.IsDirectory };
    private async Task RefreshTreeAsync()
    {
        if (files is null) return;
        var generation = loadGeneration; var entries = await files.ListChildrenAsync();
        if (generation != loadGeneration) return;
        tree.RootNodes.Clear(); foreach (var entry in entries) tree.RootNodes.Add(Node(entry));
        UpdateLayoutMode();
    }
    public async Task OpenAsync(string relativePath)
    {
        if (files is null || cwd is null) return;
        var generation = loadGeneration; var key = Path.GetFullPath(relativePath, cwd);
        if (!buffers.TryGetValue(key, out var buffer))
        {
            buffer = new(await files.ReadTextAsync(relativePath));
            if (generation != loadGeneration) return;
            buffers[key] = buffer;
        }
        active = buffer; showsDetail = true; UpdateLayoutMode(); settingText = true; editor.Text = buffer.Text; settingText = false;
        save.IsEnabled = buffer.Dirty; UpdateLocation();
    }
    private async Task SaveAsync() => await GuardAsync(async () =>
    {
        if (files is null || active is null) return;
        var buffer = active;
        buffer.Document = await files.SaveTextAsync(buffer.Document, buffer.Text);
        buffer.Text = buffer.Document.Text;
        if (active == buffer) { settingText = true; editor.Text = buffer.Text; settingText = false; save.IsEnabled = false; UpdateLocation(); }
    });
    private void FindNext()
    {
        if (find.Text.Length == 0) return;
        var start = Math.Min(editor.Text.Length, editor.SelectionStart + editor.SelectionLength);
        var index = editor.Text.IndexOf(find.Text, start, StringComparison.CurrentCultureIgnoreCase);
        if (index < 0) index = editor.Text.IndexOf(find.Text, StringComparison.CurrentCultureIgnoreCase);
        if (index >= 0) { editor.Select(index, find.Text.Length); editor.Focus(FocusState.Keyboard); }
    }
    private void UpdateLocation() => location.Text = active is null ? "Files" : active.Document.RelativePath + (active.Dirty ? " •" : "");
    private async Task GuardAsync(Func<Task> action)
    { try { await action(); notice.IsOpen = false; } catch (Exception error) { notice.Severity = InfoBarSeverity.Error; notice.Title = "File action failed"; notice.Message = error.Message; notice.IsOpen = true; } }
    private static void Add(Grid grid, FrameworkElement child, int row) { Grid.SetRow(child, row); grid.Children.Add(child); }
}
