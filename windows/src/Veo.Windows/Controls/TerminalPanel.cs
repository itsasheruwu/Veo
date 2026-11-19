using System.Text;
using System.Text.RegularExpressions;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Veo.Core;
using Veo.Platform.Windows.Terminal;
using Veo.Protocol;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;
using Windows.UI.Core;

namespace Veo_Windows.Controls;

/// <summary>Native ConPTY tabs. Each shell retains its original cwd when chats change.</summary>
public sealed class TerminalPanel : Grid, IAsyncDisposable
{
    private readonly WorkspaceCoordinator workspace;
    private readonly TabView tabs = new() { TabWidthMode = TabViewWidthMode.SizeToContent, IsAddTabButtonVisible = true, CanDragTabs = true, CanReorderTabs = true, AllowDropTabs = true };
    private readonly System.Collections.ObjectModel.ObservableCollection<TerminalSessionDescriptor> sessions = [];
    private readonly Dictionary<string, TabViewItem> tabItems = new(StringComparer.Ordinal);
    private readonly Dictionary<string, TerminalHandle> handles = new(StringComparer.Ordinal);
    private readonly TerminalSessionOwnership<TerminalHandle> ownership = new();
    private readonly ListView sidebar = new()
    {
        SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true, CanDragItems = true,
        AllowDrop = true, CanReorderItems = true, MinWidth = 150,
        ItemContainerTransitions = new() { new ReorderThemeTransition() }
    };
    private readonly ContentControl viewport = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly List<ContentControl> holders = [];
    private readonly Dictionary<string, Border> paneFrames = new(StringComparer.Ordinal);
    private readonly InfoBar notice = new() { IsOpen = false, IsClosable = true };
    private readonly AppBarButton expand = new() { Label = "Expand terminal workspace", Icon = new SymbolIcon(Symbol.FullScreen) };
    private readonly DispatcherTimer persist = new() { Interval = TimeSpan.FromMilliseconds(200) };
    private readonly SemaphoreSlim actions = new(1, 1);
    private readonly string instanceId = Guid.NewGuid().ToString("N");
    private const string DragFormat = "Veo.Terminal.Session";
    private ThreadSession? context;
    private TerminalPaneNode? layout;
    private string? focusedId, scope;
    private bool disposed, restored, rendering;
    public bool IsExpanded { get; private set; }
    public event Action<bool>? ExpandedChanged;

    public TerminalPanel(WorkspaceCoordinator workspace)
    {
        this.workspace = workspace;
        MinHeight = 140;
        RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new());
        var commands = new CommandBar { DefaultLabelPosition = CommandBarDefaultLabelPosition.Collapsed };
        var add = new AppBarButton { Label = "New terminal session", Icon = new SymbolIcon(Symbol.Add) };
        var splitRight = new AppBarButton { Label = "Split terminal right", Icon = new SymbolIcon(Symbol.TwoPage) };
        var splitDown = new AppBarButton { Label = "Split terminal down", Icon = new SymbolIcon(Symbol.AlignCenter) };
        var layouts = new AppBarButton { Label = "Terminal grid layout", Icon = new SymbolIcon(Symbol.View) };
        var menu = new MenuFlyout();
        foreach (var preset in Enum.GetValues<TerminalGridPreset>())
        { var item = new MenuFlyoutItem { Text = PresetTitle(preset) }; item.Click += async (_, _) => await RunAsync(() => ApplyPresetAsync(preset)); menu.Items.Add(item); }
        layouts.Flyout = menu;
        commands.PrimaryCommands.Add(add); commands.PrimaryCommands.Add(splitRight); commands.PrimaryCommands.Add(splitDown); commands.PrimaryCommands.Add(layouts); commands.PrimaryCommands.Add(expand);
        var close = new AppBarButton { Label = "Close focused terminal", Icon = new SymbolIcon(Symbol.Cancel) }; commands.SecondaryCommands.Add(close);
        add.Click += async (_, _) => await RunAsync(async () => { if (context is not null) await AddAsync(context); });
        splitRight.Click += async (_, _) => await RunAsync(() => SplitAsync(TerminalSplitAxis.Horizontal));
        splitDown.Click += async (_, _) => await RunAsync(() => SplitAsync(TerminalSplitAxis.Vertical));
        expand.Click += async (_, _) => await RunAsync(async () => { IsExpanded = !IsExpanded; await RenderAsync(); SchedulePersist(); ExpandedChanged?.Invoke(IsExpanded); });
        close.Click += async (_, _) => await RunAsync(async () => { if (focusedId is not null) await CloseAsync(focusedId); });
        Children.Add(commands); SetRow(notice, 1); Children.Add(notice); SetRow(viewport, 2); Children.Add(viewport);
        sidebar.ItemsSource = sessions;
        AutomationProperties.SetName(tabs, "Terminal sessions");
        AutomationProperties.SetName(sidebar, "Terminal session sidebar");
        tabs.AddTabButtonClick += async (_, _) => await RunAsync(async () => { if (context is not null) await AddAsync(context); });
        tabs.TabCloseRequested += async (_, args) => await RunAsync(async () => { if (args.Tab.Tag is string id) await CloseAsync(id); });
        tabs.SelectionChanged += async (_, _) =>
        { if (!rendering && tabs.SelectedItem is TabViewItem { Tag: string id }) await RunAsync(() => ActivateAsync(id)); };
        tabs.TabDragCompleted += (_, _) =>
        {
            if (rendering) return;
            var ids = tabs.TabItems.Cast<TabViewItem>().Select(tab => (string)tab.Tag).ToArray();
            var ordered = ids.Select(id => sessions.Single(session => session.Id == id)).ToArray();
            rendering = true; sessions.Clear(); foreach (var descriptor in ordered) sessions.Add(descriptor); rendering = false; SchedulePersist();
        };
        sidebar.ItemClick += async (_, args) => { if (args.ClickedItem is TerminalSessionDescriptor descriptor) await RunAsync(() => ActivateAsync(descriptor.Id)); };
        sidebar.DragItemsStarting += (_, args) =>
        { if (args.Items.FirstOrDefault() is TerminalSessionDescriptor descriptor) { args.Data.SetData(DragFormat, instanceId + "|" + descriptor.Id); args.Data.RequestedOperation = DataPackageOperation.Move; } };
        sidebar.DragItemsCompleted += (_, _) => { SyncTabs(); SchedulePersist(); };
        persist.Tick += async (_, _) => { persist.Stop(); await PersistAsync(); };
    }

    public async Task OpenAsync(ThreadSession session, bool ensureSession = true)
    {
        if (disposed) return;
        await actions.WaitAsync();
        try
        {
        context = session;
        scope ??= session.Record.VeoId;
        if (!restored)
        {
            restored = true;
            var json = await workspace.Threads.ReadStateAsync(scope, "terminalWorkspace");
            if (json is not null)
            {
                try
                {
                    var state = System.Text.Json.JsonSerializer.Deserialize<TerminalWorkspaceSnapshot>(json) ?? throw new InvalidDataException("The saved terminal workspace was empty."); state.Validate();
                    foreach (var descriptor in state.Sessions) sessions.Add(descriptor);
                    layout = state.Layout; focusedId = state.FocusedSessionId; IsExpanded = state.Expanded;
                }
                catch (Exception error) when (error is InvalidDataException or System.Text.Json.JsonException) { ShowFailure("Saved terminal layout was preserved but could not be restored: " + error.Message); }
            }
        }
        if (sessions.Count == 0) { if (ensureSession) await AddAsync(session); }
        else { focusedId ??= sessions.First().Id; EnsureLayout(); await RenderAsync(); }
        ExpandedChanged?.Invoke(IsExpanded);
        }
        finally { actions.Release(); }
    }

    public async Task RunProjectActionAsync(ThreadSession session, string command)
    {
        if (string.IsNullOrWhiteSpace(command) || command.Contains('\0')) throw new ArgumentException("A project action needs a shell command.");
        await OpenAsync(session, false);
        await actions.WaitAsync();
        try
        {
            await AddAsync(session);
            await handles[focusedId!].Surface.SubmitCommandAsync(command);
        }
        finally { actions.Release(); }
    }

    private async Task<TerminalSessionDescriptor> CreateSessionAsync(ThreadSession session)
    {
        var header = System.IO.Path.GetFileName(session.Record.Cwd.TrimEnd(System.IO.Path.DirectorySeparatorChar));
        var descriptor = new TerminalSessionDescriptor(Guid.NewGuid().ToString("N"), session.Record.VeoId, session.Record.Cwd,
            (string.IsNullOrWhiteSpace(header) ? session.Record.Cwd : header) + (sessions.Count == 0 ? "" : " " + (sessions.Count + 1)));
        sessions.Add(descriptor); await EnsureHandleAsync(descriptor); return descriptor;
    }
    private async Task AddAsync(ThreadSession session)
    {
        var previous = focusedId; var descriptor = await CreateSessionAsync(session);
        EnsureLayout();
        if (IsExpanded && layout is not null && previous is not null && layout.Contains(previous) && layout.LeafCount < 6)
            layout = layout.Split(previous, descriptor.Id, TerminalSplitAxis.Horizontal);
        else if (layout is null) layout = new TerminalPaneLeaf(descriptor.Id);
        else if (!layout.Contains(descriptor.Id)) layout = layout.Replace(previous is not null && layout.Contains(previous) ? previous : layout.SessionIds[0], descriptor.Id);
        focusedId = descriptor.Id; await RenderAsync(); SchedulePersist();
    }
    private async Task SplitAsync(TerminalSplitAxis axis)
    {
        if (context is null) return; EnsureLayout();
        if (layout?.LeafCount >= 6) throw new InvalidOperationException("Six terminal panes are visible. Close a pane or choose another layout first.");
        if (focusedId is null || layout is null) { await AddAsync(context); return; }
        var descriptor = await CreateSessionAsync(context); layout = layout.Split(focusedId, descriptor.Id, axis); focusedId = descriptor.Id; IsExpanded = true;
        await RenderAsync(); SchedulePersist(); ExpandedChanged?.Invoke(true);
    }
    private async Task ApplyPresetAsync(TerminalGridPreset preset)
    {
        if (context is null) return;
        var count = TerminalPaneNode.Count(preset); var ids = (layout?.SessionIds ?? []).Concat(sessions.Select(session => session.Id)).Distinct(StringComparer.Ordinal).Take(count).ToList();
        while (ids.Count < count) ids.Add((await CreateSessionAsync(context)).Id);
        layout = TerminalPaneNode.Preset(preset, ids); focusedId = ids[0]; IsExpanded = true;
        await RenderAsync(); SchedulePersist(); ExpandedChanged?.Invoke(true);
    }
    private async Task<TerminalHandle> EnsureHandleAsync(TerminalSessionDescriptor descriptor)
    {
        var handle = await ownership.GetOrCreateAsync(descriptor, async () =>
        {
            var surface = new NativeTerminalSurface(workspace);
            surface.GotFocus += (_, _) => FocusSession(descriptor.Id);
            try { await surface.StartAsync(descriptor.Cwd); } catch (Exception error) { surface.ShowFailure(error.Message); }
            return new TerminalHandle(surface);
        });
        handles[descriptor.Id] = handle; return handle;
    }
    private void EnsureLayout()
    {
        var live = sessions.Select(session => session.Id).ToHashSet(StringComparer.Ordinal);
        layout = layout?.Prune(live);
        if (layout is null && sessions.Count > 0) layout = new TerminalPaneLeaf(focusedId is not null && live.Contains(focusedId) ? focusedId : sessions[0].Id);
        if (focusedId is null || !live.Contains(focusedId)) focusedId = layout?.SessionIds.FirstOrDefault();
    }
    private async Task ActivateAsync(string id)
    {
        if (!sessions.Any(session => session.Id == id)) return;
        EnsureLayout();
        if (layout is not null && !layout.Contains(id)) layout = layout.Replace(focusedId is not null && layout.Contains(focusedId) ? focusedId : layout.SessionIds[0], id);
        focusedId = id; await RenderAsync(); SchedulePersist();
    }
    private void FocusSession(string id)
    {
        if (rendering || focusedId == id) return; focusedId = id;
        sidebar.SelectedItem = sessions.FirstOrDefault(session => session.Id == id);
        foreach (var pair in paneFrames) pair.Value.BorderThickness = new Thickness(pair.Key == id ? 1 : 0);
        SchedulePersist();
    }
    private async Task CloseAsync(string id)
    {
        var descriptor = sessions.FirstOrDefault(session => session.Id == id); if (descriptor is null) return;
        DetachSurfaces(); sessions.Remove(descriptor); handles.Remove(id);
        if (tabItems.Remove(id, out var tab)) { tab.Content = null; tabs.TabItems.Remove(tab); }
        layout = layout?.Remove(id); if (focusedId == id) focusedId = layout?.SessionIds.FirstOrDefault() ?? sessions.FirstOrDefault()?.Id;
        await ownership.CloseAsync(id); EnsureLayout(); await RenderAsync(); SchedulePersist();
    }
    private void DetachSurfaces()
    {
        rendering = true;
        foreach (var holder in holders) holder.Content = null; holders.Clear(); paneFrames.Clear();
        foreach (var tab in tabItems.Values) tab.Content = null;
        viewport.Content = null;
    }
    private void SyncTabs()
    {
        var wasRendering = rendering; rendering = true;
        foreach (var descriptor in sessions)
            if (!tabItems.ContainsKey(descriptor.Id))
            { var tab = new TabViewItem { Header = descriptor.Title, Tag = descriptor.Id, IsClosable = true }; ToolTipService.SetToolTip(tab, descriptor.Cwd); tabItems[descriptor.Id] = tab; }
        tabs.TabItems.Clear(); foreach (var descriptor in sessions) tabs.TabItems.Add(tabItems[descriptor.Id]);
        rendering = wasRendering;
    }
    private async Task RenderAsync()
    {
        DetachSurfaces(); EnsureLayout(); SyncTabs();
        expand.Label = IsExpanded ? "Restore docked terminal" : "Expand terminal workspace";
        expand.Icon = new SymbolIcon(IsExpanded ? Symbol.BackToWindow : Symbol.FullScreen);
        if (IsExpanded && layout is not null)
        {
            foreach (var id in layout.SessionIds) await EnsureHandleAsync(sessions.Single(session => session.Id == id));
            var expanded = new Grid(); expanded.ColumnDefinitions.Add(new() { Width = new GridLength(168) }); expanded.ColumnDefinitions.Add(new());
            // A sidebar belongs to only one live visual tree at a time.
            if (sidebar.Parent is Panel oldParent) oldParent.Children.Remove(sidebar);
            expanded.Children.Add(sidebar); var panes = BuildNode(layout); SetColumn(panes, 1); expanded.Children.Add(panes); viewport.Content = expanded;
            sidebar.SelectedItem = sessions.FirstOrDefault(session => session.Id == focusedId);
        }
        else
        {
            if (focusedId is not null && sessions.FirstOrDefault(session => session.Id == focusedId) is { } descriptor)
            { tabItems[focusedId].Content = (await EnsureHandleAsync(descriptor)).Surface; tabs.SelectedItem = tabItems[focusedId]; }
            viewport.Content = tabs;
        }
        rendering = false;
        if (focusedId is not null && handles.TryGetValue(focusedId, out var active)) active.Surface.Focus(FocusState.Programmatic);
    }
    private FrameworkElement BuildNode(TerminalPaneNode node)
    {
        if (node is TerminalPaneLeaf leaf) return BuildPane(leaf.SessionId);
        var split = (TerminalPaneSplit)node; var grid = new Grid();
        var first = BuildNode(split.First); var second = BuildNode(split.Second);
        if (split.Axis == TerminalSplitAxis.Horizontal)
        {
            grid.ColumnDefinitions.Add(new() { Width = new GridLength(split.Ratio, GridUnitType.Star) }); grid.ColumnDefinitions.Add(new() { Width = new GridLength(6) }); grid.ColumnDefinitions.Add(new() { Width = new GridLength(1 - split.Ratio, GridUnitType.Star) });
            SetColumn(second, 2);
        }
        else
        {
            grid.RowDefinitions.Add(new() { Height = new GridLength(split.Ratio, GridUnitType.Star) }); grid.RowDefinitions.Add(new() { Height = new GridLength(6) }); grid.RowDefinitions.Add(new() { Height = new GridLength(1 - split.Ratio, GridUnitType.Star) });
            SetRow(second, 2);
        }
        var ratio = split.Ratio;
        var divider = new TerminalSplitThumb(split.Axis, () => ratio, next =>
        {
            ratio = next; layout = layout?.SetRatio(split.Id, next);
            if (split.Axis == TerminalSplitAxis.Horizontal) { grid.ColumnDefinitions[0].Width = new(next, GridUnitType.Star); grid.ColumnDefinitions[2].Width = new(1 - next, GridUnitType.Star); }
            else { grid.RowDefinitions[0].Height = new(next, GridUnitType.Star); grid.RowDefinitions[2].Height = new(1 - next, GridUnitType.Star); }
            SchedulePersist();
        }, () => split.Axis == TerminalSplitAxis.Horizontal ? grid.ActualWidth - 6 : grid.ActualHeight - 6);
        if (split.Axis == TerminalSplitAxis.Horizontal) SetColumn(divider, 1); else SetRow(divider, 1);
        grid.Children.Add(first); grid.Children.Add(divider); grid.Children.Add(second); return grid;
    }
    private FrameworkElement BuildPane(string id)
    {
        var descriptor = sessions.Single(session => session.Id == id);
        var pane = new Grid(); pane.RowDefinitions.Add(new() { Height = GridLength.Auto }); pane.RowDefinitions.Add(new());
        var header = new Grid { Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"], Padding = new Thickness(6, 2, 2, 2), CanDrag = true };
        header.ColumnDefinitions.Add(new()); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var title = new TextBlock { Text = descriptor.Title, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        header.Children.Add(title); ToolTipService.SetToolTip(header, descriptor.Cwd);
        var move = new Button { Content = "↔", Padding = new Thickness(5, 1, 5, 1) }; AutomationProperties.SetName(move, "Rearrange " + descriptor.Title);
        var moves = new MenuFlyout();
        foreach (var direction in new[] { -1, 1 })
        { var item = new MenuFlyoutItem { Text = direction < 0 ? "Swap with previous visible pane" : "Swap with next visible pane" }; item.Click += async (_, _) => await RunAsync(() => MoveAsync(id, direction)); moves.Items.Add(item); }
        move.Flyout = moves; SetColumn(move, 1); header.Children.Add(move);
        var close = new Button { Content = "×", Padding = new Thickness(5, 1, 5, 1) }; AutomationProperties.SetName(close, "Close terminal " + descriptor.Title); close.Click += async (_, _) => await RunAsync(() => CloseAsync(id)); SetColumn(close, 2); header.Children.Add(close);
        header.DragStarting += (_, args) => { args.Data.SetData(DragFormat, instanceId + "|" + id); args.Data.RequestedOperation = DataPackageOperation.Move; };
        var holder = new ContentControl { Content = handles[id].Surface, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch }; holders.Add(holder); SetRow(holder, 1);
        pane.Children.Add(header); pane.Children.Add(holder);
        var frame = new Border { Child = pane, BorderBrush = (Brush)Application.Current.Resources["SystemControlHighlightAccentBrush"], BorderThickness = new Thickness(id == focusedId ? 1 : 0), AllowDrop = true };
        paneFrames[id] = frame;
        frame.DragOver += (_, args) => { if (args.DataView.Contains(DragFormat)) { args.AcceptedOperation = DataPackageOperation.Move; args.Handled = true; } };
        frame.Drop += async (_, args) =>
        {
            if (!args.DataView.Contains(DragFormat)) return;
            var payload = await args.DataView.GetDataAsync(DragFormat) as string;
            if (payload is null || !payload.StartsWith(instanceId + "|", StringComparison.Ordinal)) return;
            var source = payload[(instanceId.Length + 1)..]; args.Handled = true;
            await RunAsync(async () =>
            {
                if (!sessions.Any(session => session.Id == source) || layout is null) return;
                layout = layout.Contains(source) ? layout.Swap(source, id) : layout.Replace(id, source); focusedId = source; await RenderAsync(); SchedulePersist();
            });
        };
        return frame;
    }
    private async Task MoveAsync(string id, int direction)
    {
        if (layout is null) return; var ids = layout.SessionIds; var current = ids.ToList().IndexOf(id); if (current < 0 || ids.Count < 2) return;
        var next = (current + direction + ids.Count) % ids.Count; layout = layout.Swap(id, ids[next]); focusedId = id; await RenderAsync(); SchedulePersist();
    }
    private void SchedulePersist() { if (disposed || scope is null) return; persist.Stop(); persist.Start(); }
    private async Task PersistAsync()
    {
        if (scope is null || disposed) return;
        try
        { var snapshot = new TerminalWorkspaceSnapshot(1, IsExpanded, focusedId, sessions.ToArray(), layout); snapshot.Validate(); await workspace.Threads.SaveStateAsync(scope, "terminalWorkspace", System.Text.Json.JsonSerializer.Serialize(snapshot)); }
        catch (Exception error) { ShowFailure("Terminal layout could not be saved: " + error.Message); }
    }
    private async Task RunAsync(Func<Task> action)
    {
        if (disposed || !await actions.WaitAsync(0)) return; notice.IsOpen = false;
        try { await action(); }
        catch (Exception error) { rendering = false; ShowFailure(error.Message); }
        finally { actions.Release(); }
    }
    private void ShowFailure(string message) { notice.Title = "Terminal action failed"; notice.Message = DiagnosticRedactor.Redact(message); notice.Severity = InfoBarSeverity.Error; notice.IsOpen = true; }
    private static string PresetTitle(TerminalGridPreset preset) => preset switch { TerminalGridPreset.TwoUp => "2-up", TerminalGridPreset.TwoStack => "2-stack", _ => preset.ToString() };

    private sealed class TerminalHandle(NativeTerminalSurface surface) : IAsyncDisposable
    {
        public NativeTerminalSurface Surface { get; } = surface;
        public ValueTask DisposeAsync() => Surface.DisposeAsync();
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        persist.Stop(); await PersistAsync();
        disposed = true;
        DetachSurfaces(); await ownership.DisposeAsync(); handles.Clear(); sessions.Clear(); tabItems.Clear(); tabs.TabItems.Clear();
    }
}

internal sealed class NativeTerminalSurface : UserControl, IAsyncDisposable
{
    private readonly WorkspaceCoordinator workspace;
    private readonly ConPtySession terminal = new();
    private readonly TerminalBuffer buffer = new();
    private readonly Canvas canvas = new();
    private readonly DispatcherTimer redraw = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private readonly Dictionary<uint, SolidColorBrush> brushes = [];
    private readonly StringBuilder line = new();
    private readonly TextBlock status = new() { Margin = new Thickness(8), TextWrapping = TextWrapping.Wrap, IsHitTestVisible = false };
    private TerminalSnapshot? lastSnapshot;
    private Point? selectionStart, selectionEnd;
    private bool selecting, lineUnknown, disposed, awaitingConsent;
    private int dirty = 1;
    private int scrollbackOffset;
    private long lastScrolledLines;
    private double cellWidth = 8, cellHeight = 19;
    private const double FontSizePoints = 13;
    private static readonly FontFamily TerminalFont = new("Cascadia Mono, Consolas");
    private static readonly uint DefaultForeground = 0xcccccc, DefaultBackground = 0x0c0c0c;

    public NativeTerminalSurface(WorkspaceCoordinator workspace)
    {
        this.workspace = workspace;
        IsTabStop = true; UseSystemFocusVisuals = false;
        HorizontalContentAlignment = HorizontalAlignment.Stretch; VerticalContentAlignment = VerticalAlignment.Stretch;
        AutomationProperties.SetName(this, "Interactive terminal");
        AutomationProperties.SetHelpText(this, "Type directly into the shell. Control Shift C copies selection; Control Shift V pastes. Drag to select text.");
        var root = new Grid { Background = Brush(DefaultBackground), Padding = new Thickness(8), Children = { canvas, status } };
        Content = root;
        canvas.IsHitTestVisible = false;
        terminal.OutputReceived += data => { buffer.Feed(data); Interlocked.Exchange(ref dirty, 1); };
        terminal.Faulted += error => DispatcherQueue.TryEnqueue(() => ShowFailure(DiagnosticRedactor.Redact(error.Message)));
        buffer.ResponseRequested += response => _ = WriteAsync(response);
        redraw.Tick += (_, _) => { if (Interlocked.Exchange(ref dirty, 0) != 0) Render(); };
        Loaded += (_, _) => { MeasureCells(); ResizeViewport(); redraw.Start(); Focus(FocusState.Programmatic); };
        Unloaded += (_, _) => redraw.Stop();
        SizeChanged += (_, _) => ResizeViewport();
        KeyDown += OnKeyDown;
        CharacterReceived += OnCharacterReceived;
        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += (_, e) => { selecting = false; ReleasePointerCapture(e.Pointer); };
        PointerWheelChanged += (_, e) =>
        {
            var snapshot = buffer.Snapshot();
            if (snapshot.AlternateScreen) return;
            scrollbackOffset = Math.Clamp(scrollbackOffset + e.GetCurrentPoint(this).Properties.MouseWheelDelta / 120 * 3, 0, snapshot.ScrollbackCount);
            selectionStart = selectionEnd = null;
            Interlocked.Exchange(ref dirty, 1); e.Handled = true;
        };
        var menu = new MenuFlyout();
        var copy = new MenuFlyoutItem { Text = "Copy selection" }; copy.Click += (_, _) => CopySelection();
        var copyAll = new MenuFlyoutItem { Text = "Copy terminal text" }; copyAll.Click += (_, _) => SetClipboard(buffer.CopyText(true));
        var paste = new MenuFlyoutItem { Text = "Paste" }; paste.Click += async (_, _) => await PasteAsync();
        menu.Items.Add(copy); menu.Items.Add(copyAll); menu.Items.Add(paste); ContextFlyout = menu;
    }

    public async Task StartAsync(string cwd)
    {
        var shell = FindShell();
        var script = BuildShellInitialization();
        var args = new[] { "-NoLogo", "-NoProfile", "-NoExit", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) };
        await Task.Run(() => terminal.Start(shell, cwd, buffer.Columns, buffer.Rows, args));
        status.Visibility = Visibility.Collapsed;
        ResizeViewport(); redraw.Start();
        _ = ObserveExitAsync();
    }

    private async Task ObserveExitAsync()
    {
        var code = await terminal.Completion;
        if (!disposed) DispatcherQueue.TryEnqueue(() => { status.Text = $"Shell exited ({code}). Open a new terminal to continue."; status.Visibility = Visibility.Visible; });
    }

    public void ShowFailure(string message)
    { status.Text = DiagnosticRedactor.Redact(message); status.Visibility = Visibility.Visible; }

    private static string FindShell()
    {
        foreach (var folder in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(System.IO.Path.PathSeparator))
        {
            try { var candidate = System.IO.Path.Combine(folder.Trim('"'), "pwsh.exe"); if (System.IO.File.Exists(candidate)) return System.IO.Path.GetFullPath(candidate); }
            catch (ArgumentException) { }
        }
        return System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
    }

    private string BuildShellInitialization()
    {
        var script = new StringBuilder("if (Get-Module PSReadLine) { Set-PSReadLineOption -PredictionSource None -ErrorAction SilentlyContinue }; ");
        foreach (var name in new[] { "codex", "claude" })
        {
            var explicitCodex = name == "codex" ? CodexExecutableDiscovery.Resolve(workspace.Preferences.CodexExecutable) : null;
            var resolver = explicitCodex is not null ? "'" + explicitCodex.Replace("'", "''") + "'" : $"(Get-Command '{name}' -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source";
            var flag = workspace.Preferences.AgentClis && (name == "codex" ? workspace.Preferences.CodexFullAccess : workspace.Preferences.ClaudeFullAccess)
                ? name == "codex" ? "'--dangerously-bypass-approvals-and-sandbox' " : "'--dangerously-skip-permissions' " : "";
            var consent = workspace.Preferences.AgentClis ? "" : $"$veoAnswer=Read-Host 'Veo: run {name} for this command? [y/N]'; if($veoAnswer -cnotmatch '^[yY]$') {{ return }}; ";
            foreach (var invocation in new[] { name, name + ".exe", name + ".cmd" })
                script.Append($"function global:{invocation} {{ {consent}$veoExecutable={resolver}; & $veoExecutable {flag}@args }}; ");
        }
        return script.ToString();
    }

    private void MeasureCells()
    {
        var probe = new TextBlock { Text = "M", FontFamily = TerminalFont, FontSize = FontSizePoints };
        probe.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        cellWidth = Math.Max(1, probe.DesiredSize.Width); cellHeight = Math.Max(16, Math.Ceiling(probe.DesiredSize.Height));
    }
    private void ResizeViewport()
    {
        if (ActualWidth < 20 || ActualHeight < 20) return;
        var columns = Math.Clamp((int)((ActualWidth - 16) / cellWidth), 10, 1000);
        var rows = Math.Clamp((int)((ActualHeight - 16) / cellHeight), 2, 500);
        if (columns == buffer.Columns && rows == buffer.Rows) return;
        buffer.Resize(columns, rows);
        if (terminal.IsRunning) terminal.Resize(columns, rows);
        Interlocked.Exchange(ref dirty, 1);
    }

    private void Render()
    {
        var snapshot = buffer.Snapshot();
        if (scrollbackOffset > 0) scrollbackOffset = Math.Clamp(scrollbackOffset + (int)Math.Min(int.MaxValue, snapshot.TotalScrolledLines - lastScrolledLines), 0, snapshot.ScrollbackCount);
        lastScrolledLines = snapshot.TotalScrolledLines;
        if (scrollbackOffset > 0) snapshot = buffer.Snapshot(scrollbackOffset);
        lastSnapshot = snapshot;
        canvas.Children.Clear();
        for (var y = 0; y < snapshot.Rows.Length; y++)
        {
            var row = snapshot.Rows[y];
            var x = 0;
            while (x < row.Length)
            {
                var start = x; var style = row[x]; var selected = IsSelected(x, y);
                var text = new StringBuilder();
                do { text.Append(row[x].Text); x++; }
                while (x < row.Length && SameStyle(style, row[x]) && selected == IsSelected(x, y));
                var foreground = style.Inverse ? style.Background ?? DefaultBackground : style.Foreground ?? DefaultForeground;
                var background = style.Inverse ? style.Foreground ?? DefaultForeground : style.Background ?? DefaultBackground;
                var label = new TextBlock { Text = text.ToString(), FontFamily = TerminalFont, FontSize = FontSizePoints, Foreground = Brush(selected ? 0xffffffu : foreground), FontWeight = style.Bold ? FontWeights.Bold : FontWeights.Normal, FontStyle = style.Italic ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal, TextDecorations = style.Underline ? Windows.UI.Text.TextDecorations.Underline : Windows.UI.Text.TextDecorations.None, IsHitTestVisible = false, Height = cellHeight };
                var segment = new Border { Child = label, Background = Brush(selected ? 0x264f78u : background), Width = (x - start) * cellWidth, Height = cellHeight, IsHitTestVisible = false };
                Canvas.SetLeft(segment, start * cellWidth); Canvas.SetTop(segment, y * cellHeight); canvas.Children.Add(segment);
            }
        }
        if (snapshot.CursorVisible && FocusState != FocusState.Unfocused)
        {
            var cursor = new Rectangle { Width = Math.Max(1, cellWidth - 1), Height = cellHeight, Stroke = Brush(DefaultForeground), StrokeThickness = 1, IsHitTestVisible = false };
            Canvas.SetLeft(cursor, snapshot.CursorColumn * cellWidth); Canvas.SetTop(cursor, snapshot.CursorRow * cellHeight); canvas.Children.Add(cursor);
        }
    }

    private static bool SameStyle(TerminalCell a, TerminalCell b) => a.Foreground == b.Foreground && a.Background == b.Background && a.Bold == b.Bold && a.Italic == b.Italic && a.Underline == b.Underline && a.Inverse == b.Inverse;
    private SolidColorBrush Brush(uint color)
    { if (!brushes.TryGetValue(color, out var brush)) brushes[color] = brush = new(Windows.UI.Color.FromArgb(255, (byte)(color >> 16), (byte)(color >> 8), (byte)color)); return brush; }
    private static bool Down(VirtualKey key) => (InputKeyboardSource.GetKeyStateForCurrentThread(key) & CoreVirtualKeyStates.Down) != 0;

    private async void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!terminal.IsRunning || awaitingConsent) return;
        var control = Down(VirtualKey.Control); var shift = Down(VirtualKey.Shift);
        if (control && e.Key == VirtualKey.C && (shift || selectionStart is Point first && selectionEnd is Point last && first != last)) { CopySelection(); e.Handled = true; return; }
        if (control && e.Key == VirtualKey.V) { e.Handled = true; await PasteAsync(); return; }
        string? input = e.Key switch
        {
            VirtualKey.Enter => "\r", VirtualKey.Back => "\u007f", VirtualKey.Tab => shift ? "\u001b[Z" : "\t", VirtualKey.Escape => "\u001b",
            VirtualKey.Up => Arrow("A"), VirtualKey.Down => Arrow("B"), VirtualKey.Right => Arrow("C"), VirtualKey.Left => Arrow("D"),
            VirtualKey.Home => "\u001b[H", VirtualKey.End => "\u001b[F", VirtualKey.Insert => "\u001b[2~", VirtualKey.Delete => "\u001b[3~", VirtualKey.PageUp => "\u001b[5~", VirtualKey.PageDown => "\u001b[6~",
            VirtualKey.F1 => "\u001bOP", VirtualKey.F2 => "\u001bOQ", VirtualKey.F3 => "\u001bOR", VirtualKey.F4 => "\u001bOS", VirtualKey.F5 => "\u001b[15~", VirtualKey.F6 => "\u001b[17~", VirtualKey.F7 => "\u001b[18~", VirtualKey.F8 => "\u001b[19~", VirtualKey.F9 => "\u001b[20~", VirtualKey.F10 => "\u001b[21~", VirtualKey.F11 => "\u001b[23~", VirtualKey.F12 => "\u001b[24~", _ => null
        };
        if (control && e.Key is >= VirtualKey.A and <= VirtualKey.Z) input = ((char)(e.Key - VirtualKey.A + 1)).ToString();
        if (input is null) return;
        e.Handled = true;
        scrollbackOffset = 0; Interlocked.Exchange(ref dirty, 1);
        if (e.Key == VirtualKey.Enter)
        {
            if (!lineUnknown && !await ConfirmAbsoluteAgentAsync(line.ToString())) { line.Clear(); await WriteAsync("\u0003"); return; }
            line.Clear(); lineUnknown = false;
        }
        else if (e.Key == VirtualKey.Back && !lineUnknown && line.Length > 0) line.Length--;
        else if (e.Key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down or VirtualKey.Home or VirtualKey.End or VirtualKey.Delete) lineUnknown = true;
        else if (control && e.Key is VirtualKey.C or VirtualKey.U) { line.Clear(); lineUnknown = false; }
        selectionStart = selectionEnd = null;
        await WriteAsync(input);
    }
    private string Arrow(string suffix) => lastSnapshot?.ApplicationCursorKeys == true ? "\u001bO" + suffix : "\u001b[" + suffix;

    private async void OnCharacterReceived(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        if (!terminal.IsRunning || awaitingConsent || Down(VirtualKey.Control) || e.Character < 32 || e.Character == 127) return;
        var text = Rune.IsValid((int)e.Character) ? char.ConvertFromUtf32((int)e.Character) : ((char)e.Character).ToString();
        scrollbackOffset = 0; Interlocked.Exchange(ref dirty, 1);
        if (!lineUnknown) line.Append(text);
        selectionStart = selectionEnd = null;
        e.Handled = true;
        await WriteAsync(Down(VirtualKey.Menu) ? "\u001b" + text : text);
    }

    private async Task<bool> ConfirmAbsoluteAgentAsync(string command)
    {
        if (workspace.Preferences.AgentClis) return true;
        var match = Regex.Match(command.Trim(), "^(?:&\\s*)?(?:'([^']+)'|\"([^\"]+)\"|([^\\s]+))");
        if (!match.Success) return true;
        var executable = match.Groups.Cast<Group>().Skip(1).FirstOrDefault(g => g.Success)?.Value ?? "";
        if (!executable.Contains('\\') && !executable.Contains('/')) return true; // Named invocations are guarded by the shell functions.
        var name = System.IO.Path.GetFileNameWithoutExtension(executable);
        if (!name.Equals("codex", StringComparison.OrdinalIgnoreCase) && !name.Equals("claude", StringComparison.OrdinalIgnoreCase)) return true;
        awaitingConsent = true;
        try
        {
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = $"Run {name} in this terminal?", Content = "Agent CLIs are disabled in Terminal settings. Allow this command to run once?", PrimaryButtonText = "Allow once", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
            return await dialog.ShowAsync() == ContentDialogResult.Primary;
        }
        finally { awaitingConsent = false; }
    }

    private async Task WriteAsync(string text)
    { try { if (terminal.IsRunning) await terminal.WriteAsync(text); } catch (Exception error) { DispatcherQueue.TryEnqueue(() => ShowFailure(error.Message)); } }
    public async Task SubmitCommandAsync(string command)
    {
        if (!terminal.IsRunning) throw new InvalidOperationException("The new project shell exited before the action could run.");
        if (!workspace.Preferences.AgentClis && Regex.IsMatch(command, "(?i)(?<![a-z0-9_-])(codex|claude)(?![a-z0-9_-])"))
        {
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Run this Agent CLI action?", Content = "Agent CLIs are disabled. This project action contains Codex or Claude. Allow this action once?", PrimaryButtonText = "Allow once", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        }
        if (!await ConfirmAbsoluteAgentAsync(command)) return;
        line.Clear(); lineUnknown = false;
        var payload = buffer.Snapshot().BracketedPaste ? "\u001b[200~" + command + "\u001b[201~\r" : command.Replace("\r\n", "\n").Replace('\n', '\r') + "\r";
        await terminal.WriteAsync(payload);
    }
    private async Task PasteAsync()
    {
        var clipboard = Clipboard.GetContent();
        if (!clipboard.Contains(StandardDataFormats.Text)) return;
        var text = await clipboard.GetTextAsync();
        // Multiline paste can execute commands. Use the same explicit consent boundary.
        if (!workspace.Preferences.AgentClis && text.Split(['\r', '\n']).Any(x => Regex.IsMatch(x, "(?i)(?<![a-z0-9_-])(codex|claude)(?![a-z0-9_-])")))
        {
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Paste Agent CLI commands?", Content = "This paste contains Codex or Claude. Allow this paste once?", PrimaryButtonText = "Allow paste", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        }
        if (!lineUnknown) line.Append(text);
        var snapshot = buffer.Snapshot();
        await WriteAsync(snapshot.BracketedPaste ? "\u001b[200~" + text + "\u001b[201~" : text);
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        Focus(FocusState.Pointer); selectionStart = selectionEnd = CellAt(e.GetCurrentPoint(canvas).Position); selecting = true;
        CapturePointer(e.Pointer); Interlocked.Exchange(ref dirty, 1); e.Handled = true;
    }
    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    { if (!selecting) return; selectionEnd = CellAt(e.GetCurrentPoint(canvas).Position); Interlocked.Exchange(ref dirty, 1); e.Handled = true; }
    private Point CellAt(Point point) => new(Math.Clamp((int)(point.X / cellWidth), 0, buffer.Columns - 1), Math.Clamp((int)(point.Y / cellHeight), 0, buffer.Rows - 1));
    private bool IsSelected(int x, int y)
    {
        if (selectionStart is not Point start || selectionEnd is not Point end || start == end) return false;
        var index = y * buffer.Columns + x; var first = (int)(start.Y * buffer.Columns + start.X); var last = (int)(end.Y * buffer.Columns + end.X);
        return index >= Math.Min(first, last) && index <= Math.Max(first, last);
    }
    private void CopySelection()
    {
        if (lastSnapshot is null || selectionStart is null || selectionEnd is null) return;
        var text = new StringBuilder();
        for (var y = 0; y < lastSnapshot.Rows.Length; y++)
        {
            var lineText = string.Concat(lastSnapshot.Rows[y].Where((_, x) => IsSelected(x, y)).Select(c => c.Text));
            if (lineText.Length == 0) continue;
            if (text.Length > 0) text.AppendLine();
            text.Append(lineText.TrimEnd());
        }
        SetClipboard(text.ToString());
    }
    private static void SetClipboard(string text) { var data = new DataPackage(); data.SetText(text); Clipboard.SetContent(data); }
    public async ValueTask DisposeAsync()
    { if (disposed) return; disposed = true; redraw.Stop(); await terminal.DisposeAsync(); }
}
