using Microsoft.UI.Input;
using Veo.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Windows.System;

namespace Veo_Windows;

public sealed partial class MainPage
{
    const double UtilityMinimumWidth = 280;
    const double UtilityMaximumWidth = 800;
    const double UtilityMinimumConversationWidth = 560;
    const double UtilityDividerWidth = 7;
    static readonly (string Title, string Glyph)[] UtilityTabChoices =
    [
        ("Review", "\uE8A5"),
        ("Browser", "\uE774"),
        ("Files", "\uE8B7"),
        ("Side chat", "\uE90A"),
        ("Subagents", "\uE716"),
        ("Plan", "\uE9F9")
    ];
    const double SidebarMinimumWidth = 236;
    const double SidebarIdealWidth = 318;
    const double SidebarReferenceFraction = 467.0 / 2160;
    bool utilityLayoutReady;
    bool restoringUtilityTab;
    bool utilityFillsConversation;
    bool utilityExpanded;
    void UtilityExpand_Click(object sender, RoutedEventArgs e)
    {
        utilityExpanded = !utilityExpanded;
        ApplyUtilityLayout();
    }
    UtilityResizeSash? utilityResizeSash;

    void InitializeUtilityLayout()
    {
        _ = new Controls.JoinedTabSelection(UtilityTabs, UtilityTabBar);
        utilityResizeSash = new UtilityResizeSash(
            () => UtilityWidth.Width.Value,
            () => UtilityMinimumWidth,
            MaximumUtilityWidth,
            width =>
            {
                if (!utilityLayoutReady) return;
                workspace.Preferences.UtilityWidth = width;
                ApplyUtilityLayout();
            },
            () => _ = Run(PersistUtilityLayoutAsync));
        UtilitySashHost.Content = utilityResizeSash;
        utilityResizeSash.IsEnabled = false;
        for (var i = 0; i < 3; ++i) AddUtilityTab(i);
        UtilityTabs.AddTabButtonClick += (_, _) =>
        {
            var menu = new MenuFlyout();
            for (var i = 0; i < UtilityTabChoices.Length; ++i)
            {
                int kind = i;
                if (kind == 5 || kind == 4 && !SelectedAgents().Any()) continue;
                var item = new MenuFlyoutItem { IsEnabled = kind != 3 || current is not null, Text = kind == 1 ? "Browser Tab" : UtilityTabChoices[i].Title, Icon = new FontIcon { Glyph = UtilityTabChoices[i].Glyph } };
                item.Click += async (_, _) => await Run(async () =>
                {
                    if (kind == 1 && FindUtilityTab(1) is not null && current is not null)
                    {
                        await OpenUtilityPanelAsync(1);
                        await Browser().NewPageAsync();
                    }
                    else UtilityTabs.SelectedItem = kind == 3 ? FindUtilityTab(kind) ?? AddUtilityTab(kind) : AddUtilityTab(kind);
                });
                menu.Items.Add(item);
            }
            var anchor = Controls.MarkdownView.Descendants(UtilityTabs).OfType<Button>().FirstOrDefault(button => button.Name == "AddButton");
            menu.ShowAt(anchor ?? (FrameworkElement)UtilityTabs);
        };
        UtilityTabs.TabDragCompleted += async (_, _) => await Run(PersistBrowserOrderAsync);
        UtilityTabs.TabCloseRequested += async (_, args) => await Run(() => CloseUtilityTabAsync(args.Tab));
    }

    Task PersistBrowserOrderAsync() => browser?.ReorderPagesAsync(UtilityTabs.TabItems.OfType<TabViewItem>()
        .Where(browserPages.ContainsKey).Select(tab => browserPages[tab])) ?? Task.CompletedTask;

    async Task CloseUtilityTabAsync(TabViewItem closed)
    {
        syncingBrowserStrip = true;
        try
        {
            UtilityTabs.TabItems.Remove(closed);
            planTabs.Remove(closed);
            if (browserPages.Remove(closed, out var id) && browser is not null) await browser.ClosePageAsync(id);
        }
        finally { syncingBrowserStrip = false; }
        if (UtilityTabs.TabItems.Count == 0)
        {
            UtilityHost.Content = null;
            workspace.Preferences.UtilityVisible = false;
            ApplyUtilityLayout();
            await PersistUtilityLayoutAsync();
        }
        else
        {
            workspace.Preferences.UtilityTab = UtilityTabName(SelectedUtilityKind);
            await PersistUtilityLayoutAsync();
            await ShowUtilityAsync();
        }
    }

    readonly Dictionary<TabViewItem, string> browserPages = new();
    readonly Dictionary<TabViewItem, (ThreadSession Session, TimelineItem Item)> planTabs = new();
    bool syncingBrowserStrip;

    Controls.BrowserPanel Browser()
    {
        if (browser is not null) return browser;
        browser = new(workspace);
        browser.WorkspaceTabsChanged += SyncBrowserStrip;
        return browser;
    }

    void SyncBrowserStrip()
    {
        if (syncingBrowserStrip || browser is null || FindUtilityTab(1) is null) return;
        var pages = browser.WorkspaceTabs.ToArray();
        if (pages.Length == 0) return;
        syncingBrowserStrip = true;
        try
        {
            var wasBrowser = SelectedUtilityKind == 1;
            var unbound = new Queue<TabViewItem>(UtilityTabs.TabItems.OfType<TabViewItem>()
                .Where(tab => Equals(tab.Tag, 1) && (!browserPages.TryGetValue(tab, out var id) || !pages.Any(page => page.Id == id))));
            foreach (var page in pages)
            {
                var tab = browserPages.FirstOrDefault(pair => pair.Value == page.Id).Key;
                if (tab is null) tab = unbound.TryDequeue(out var reuse) ? reuse : AddUtilityTab(1);
                browserPages[tab] = page.Id;
                var title = page.Title.Equals("New tab", StringComparison.OrdinalIgnoreCase) ? "New Tab" : page.Title;
                if (!Equals(tab.Header, title))
                {
                    tab.Header = title; AutomationProperties.SetName(tab, title); ToolTipService.SetToolTip(tab, title);
                }
                AutomationProperties.SetItemStatus(tab, page.Loading ? "Loading" : "");
                if (wasBrowser && page.Id == browser.SelectedPageId) UtilityTabs.SelectedItem = tab;
            }
            foreach (var stale in unbound) { browserPages.Remove(stale); UtilityTabs.TabItems.Remove(stale); }
        }
        finally { syncingBrowserStrip = false; }
    }

    IEnumerable<ConversationAgent> SelectedAgents() => current?.Timeline.Items
        .Where(item => item.Kind is "collabAgentToolCall" or "subAgentActivity")
        .SelectMany(item => TimelinePresentation.Item(item).Agents).GroupBy(agent => agent.ThreadId)
        .Select(group => group.Last()) ?? [];

    ConversationAgent[] displayedAgents = [];
    void UpdateAgentList()
    {
        if (SelectedUtilityKind != 4 || !workspace.Preferences.UtilityVisible) return;
        var agents = SelectedAgents().ToArray();
        if (UtilityHost.Content is ScrollViewer && agents.SequenceEqual(displayedAgents)) return;
        displayedAgents = agents;
        UtilityHost.Content = AgentList(agents);
    }

    FrameworkElement AgentList(ConversationAgent[] agents)
    {
        var stack = new StackPanel { Padding = new Thickness(14), Spacing = 8 };
        var parent = current;
        foreach (var finished in new[] { false, true })
        {
            var entries = agents.Where(agent => (agent.Status.ToLowerInvariant() is "completed" or "failed" or "shutdown") == finished).ToArray();
            if (finished && entries.Length == 0) continue;
            stack.Children.Add(new TextBlock { Text = $"{(finished ? "Finished" : "Active")}   {entries.Length}", FontSize = 12, Opacity = .72 });
            if (entries.Length == 0) stack.Children.Add(new TextBlock { Text = "No active subagents", FontSize = 12, Opacity = .65 });
            foreach (var agent in entries)
            {
                var face = new StackPanel { Spacing = 2, Children = { new TextBlock { Text = agent.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }, new TextBlock { Text = agent.Status, FontSize = 11, Opacity = .7 } } };
                var button = new Button { Content = face, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Style = (Style)Application.Current.Resources["SubtleButtonStyle"] };
                button.Click += async (_, _) => await Run(async () =>
                {
                    if (parent is null) return;
                    await using var activity = new ConversationActivityCoordinator(workspace, observeEvents: false);
                    await NavigateToThreadAsync(await activity.OpenChildAsync(parent, agent.ThreadId));
                });
                stack.Children.Add(button);
            }
        }
        return new ScrollViewer { Content = stack };
    }

    public async Task OpenPlanTabAsync(ThreadSession session, TimelineItem item)
    {
        var tab = planTabs.FirstOrDefault(pair => pair.Value.Session == session && pair.Value.Item.Id == item.Id).Key;
        if (tab is null) { tab = AddUtilityTab(5); planTabs[tab] = (session, item); }
        UtilityTabs.SelectedItem = tab;
        await OpenUtilityPanelAsync();
    }

    int SelectedUtilityKind => UtilityTabs.SelectedItem is TabViewItem { Tag: int kind } ? kind : -1;
    TabViewItem? FindUtilityTab(int kind) => UtilityTabs.TabItems.OfType<TabViewItem>().FirstOrDefault(tab => Equals(tab.Tag, kind));
    TabViewItem AddUtilityTab(int kind)
    {
        var (title, glyph) = UtilityTabChoices[kind];
        var tab = new TabViewItem { Header = title, Tag = kind, IconSource = new FontIconSource { Glyph = glyph } };
        if (kind == 1) tab.Header = "New Tab";
        AutomationProperties.SetName(tab, tab.Header.ToString());
        var menu = new MenuFlyout();
        foreach (var offset in new[] { -1, 1 })
        {
            var move = new MenuFlyoutItem { Text = offset < 0 ? "Move Left" : "Move Right" };
            menu.Opening += (_, _) => { int target = UtilityTabs.TabItems.IndexOf(tab) + offset; move.IsEnabled = target >= 0 && target < UtilityTabs.TabItems.Count; };
            move.Click += async (_, _) =>
            {
                int target = UtilityTabs.TabItems.IndexOf(tab) + offset;
                if (target < 0 || target >= UtilityTabs.TabItems.Count) return;
                var selected = UtilityTabs.SelectedItem;
                restoringUtilityTab = true;
                try { UtilityTabs.TabItems.Remove(tab); UtilityTabs.TabItems.Insert(target, tab); UtilityTabs.SelectedItem = selected; }
                finally { restoringUtilityTab = false; }
                await Run(PersistBrowserOrderAsync);
            };
            menu.Items.Add(move);
        }
        var close = new MenuFlyoutItem { Text = "Close Tab" }; close.Click += async (_, _) => await Run(() => CloseUtilityTabAsync(tab)); menu.Items.Add(close);
        tab.ContextFlyout = menu;
        UtilityTabs.TabItems.Add(tab);
        return tab;
    }
    void RestoreUtilityLayout()
    {
        var preferences = workspace.Preferences;
        preferences.UtilityWidth = double.IsFinite(preferences.UtilityWidth)
            ? Math.Clamp(preferences.UtilityWidth, UtilityMinimumWidth, UtilityMaximumWidth) : 360;
        restoringUtilityTab = true;
        try
        {
            var kind = preferences.UtilityTab switch { "Browser" => 1, "Files" => 2, "Side chat" => 3, _ => 0 };
            UtilityTabs.SelectedItem = FindUtilityTab(kind) ?? AddUtilityTab(kind);
        }
        finally { restoringUtilityTab = false; }
        utilityLayoutReady = true;
        ApplyUtilityLayout();
    }

    double UtilityWindowWidth() => ActualWidth > 0 ? ActualWidth : workspace.Preferences.WindowWidth;

    double PreferredSidebarWidth() => Math.Clamp(UtilityWindowWidth() * SidebarReferenceFraction, SidebarMinimumWidth, SidebarIdealWidth);

    void ApplyWorkspaceWidth()
    {
        var width = sidebarVisible ? PreferredSidebarWidth() : 0;
        SidebarWidth.Width = new GridLength(width);
        settingsPanel?.SetWorkspaceWidth(UtilityWindowWidth(), PreferredSidebarWidth());
        SidebarLayoutChanged?.Invoke(width, sidebarVisible);
        ApplyUtilityLayout();
    }

    double MaximumUtilityWidth() => Math.Max(UtilityMinimumWidth,
        Math.Min(UtilityMaximumWidth, UtilityWindowWidth() - SidebarWidth.Width.Value - UtilityDividerWidth - UtilityMinimumConversationWidth));

    void ApplyUtilityLayout()
    {
        if (!utilityLayoutReady) return;
        var visible = workspace.Preferences.UtilityVisible && !terminalWorkspaceExpanded;
        if (!workspace.Preferences.UtilityVisible) utilityExpanded = false;
        var fillsConversation = visible && (utilityExpanded || UtilityWindowWidth() - SidebarWidth.Width.Value <
            UtilityMinimumConversationWidth + UtilityDividerWidth + UtilityMinimumWidth);
        var docked = visible && !fillsConversation;
        var enteringCompact = fillsConversation && !utilityFillsConversation;
        utilityFillsConversation = fillsConversation;
        UtilityWidth.Width = new GridLength(docked
            ? Math.Clamp(workspace.Preferences.UtilityWidth, UtilityMinimumWidth, MaximumUtilityWidth()) : 0);
        UtilitySashWidth.Width = new GridLength(docked ? UtilityDividerWidth : 0);
        UtilitySashHost.Visibility = docked ? Visibility.Visible : Visibility.Collapsed;
        if (utilityResizeSash is not null) utilityResizeSash.IsEnabled = docked;
        var fullWidth = visible && utilityExpanded;
        SidebarPanel.Visibility = terminalWorkspaceExpanded || fullWidth ? Visibility.Collapsed : Visibility.Visible;
        Grid.SetColumn(UtilityPanel, fullWidth ? 0 : fillsConversation ? 1 : 3);
        Grid.SetColumnSpan(UtilityPanel, fullWidth ? 4 : fillsConversation ? 3 : 1);
        var action = fullWidth ? "Restore right panel" : "Expand right panel";
        AutomationProperties.SetName(UtilityExpand, action);
        ToolTipService.SetToolTip(UtilityExpand, action);
        UtilityExpandIcon.Glyph = fullWidth ? "\uE73F" : "\uE740";
        UtilityBackRow.Visibility = fillsConversation && !fullWidth ? Visibility.Visible : Visibility.Collapsed;
        UtilityPanel.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        ConversationPane.Visibility = fillsConversation ? Visibility.Collapsed : Visibility.Visible;
        if (enteringCompact && !fullWidth) UtilityBackButton.Focus(FocusState.Programmatic);
    }

    async Task PersistUtilityLayoutAsync()
    {
        if (utilityLayoutReady) await workspace.SavePreferencesAsync();
    }

    async Task OpenUtilityPanelAsync(int? selectedTab = null)
    {
        workspace.Preferences.UtilityVisible = true;
        if (selectedTab is { } index)
        {
            index = Math.Clamp(index, 0, 3);
            restoringUtilityTab = true;
            try { UtilityTabs.SelectedItem = FindUtilityTab(index) ?? AddUtilityTab(index); }
            finally { restoringUtilityTab = false; }
            workspace.Preferences.UtilityTab = UtilityTabName(index);
        }
        ApplyUtilityLayout();
        await PersistUtilityLayoutAsync();
        await ShowUtilityAsync();
    }

    async Task ToggleUtilityPanelAsync()
    {
        var returnToComposer = utilityFillsConversation;
        workspace.Preferences.UtilityVisible = !workspace.Preferences.UtilityVisible;
        if (workspace.Preferences.UtilityVisible && SelectedUtilityKind < 0) UtilityTabs.SelectedItem = FindUtilityTab(0) ?? AddUtilityTab(0);
        ApplyUtilityLayout();
        if (returnToComposer) Composer.Focus(FocusState.Programmatic);
        await PersistUtilityLayoutAsync();
        if (workspace.Preferences.UtilityVisible) await ShowUtilityAsync();
    }

    async void CloseCompactUtility_Click(object sender, RoutedEventArgs e) => await Run(ToggleUtilityPanelAsync);

    static string UtilityTabName(int index) => index >= 0 && index < UtilityTabChoices.Length
        ? UtilityTabChoices[index].Title : UtilityTabChoices[0].Title;

    async void Utility_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!utilityLayoutReady || restoringUtilityTab || syncingBrowserStrip || SelectedUtilityKind < 0) return;
        await Run(async () =>
        {
            workspace.Preferences.UtilityTab = UtilityTabName(SelectedUtilityKind);
            await PersistUtilityLayoutAsync();
            await ShowUtilityAsync();
        });
    }
}

/// <summary>A visible native separator with captured pointer input and a UI Automation width range.</summary>
internal sealed class UtilityResizeSash : Control
{
    readonly Func<double> value;
    readonly Func<double> minimum;
    readonly Func<double> maximum;
    readonly Action<double> change;
    readonly Action commit;
    uint? pointer;
    double startX;
    double startWidth;

    internal UtilityResizeSash(Func<double> value, Func<double> minimum, Func<double> maximum, Action<double> change, Action commit)
    {
        this.value = value;
        this.minimum = minimum;
        this.maximum = maximum;
        this.change = change;
        this.commit = commit;
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        AutomationProperties.SetName(this, "Resize right panel");
        AutomationProperties.SetAutomationId(this, "UtilityResizeSash");
        AutomationProperties.SetHelpText(this, "Drag left or right. Arrow keys resize by 10 pixels; Page Up and Page Down by 50. Home and End choose the minimum and maximum width.");
        Template = (ControlTemplate)XamlReader.Load("""
            <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Control">
              <Grid Background="Transparent">
                <Border Width="1" HorizontalAlignment="Center" Background="{ThemeResource DividerStrokeColorDefaultBrush}" IsHitTestVisible="False"/>
                <Border x:Name="FocusOutline" BorderBrush="{ThemeResource TextFillColorPrimaryBrush}" BorderThickness="0" IsHitTestVisible="False"/>
              </Grid>
            </ControlTemplate>
            """);
        GotFocus += (_, _) => RefreshFocus();
        LostFocus += (_, _) => RefreshFocus();
    }

    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        RefreshFocus();
    }

    void RefreshFocus()
    {
        if (GetTemplateChild("FocusOutline") is Border outline)
            outline.BorderThickness = new Thickness(FocusState == FocusState.Keyboard ? 1 : 0);
    }

    protected override void OnPointerPressed(PointerRoutedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (!IsEnabled || pointer is not null || !e.GetCurrentPoint(null).Properties.IsLeftButtonPressed) return;
        Focus(FocusState.Pointer);
        if (!CapturePointer(e.Pointer)) return;
        pointer = e.Pointer.PointerId;
        startX = e.GetCurrentPoint(null).Position.X;
        startWidth = CurrentWidth;
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerRoutedEventArgs e)
    {
        base.OnPointerMoved(e);
        if (pointer != e.Pointer.PointerId) return;
        SetWidth(startWidth - (e.GetCurrentPoint(null).Position.X - startX), false);
        e.Handled = true;
    }

    protected override void OnPointerReleased(PointerRoutedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (pointer != e.Pointer.PointerId) return;
        FinishPointer();
        e.Handled = true;
    }

    protected override void OnPointerCaptureLost(PointerRoutedEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        FinishPointer();
    }

    protected override void OnPointerCanceled(PointerRoutedEventArgs e)
    {
        base.OnPointerCanceled(e);
        FinishPointer();
    }

    void FinishPointer()
    {
        if (pointer is null) return;
        pointer = null;
        ReleasePointerCaptures();
        commit();
    }

    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        base.OnKeyDown(e);
        var next = e.Key switch
        {
            VirtualKey.Left => CurrentWidth + 10,
            VirtualKey.Right => CurrentWidth - 10,
            VirtualKey.PageUp => CurrentWidth + 50,
            VirtualKey.PageDown => CurrentWidth - 50,
            VirtualKey.Home => minimum(),
            VirtualKey.End => maximum(),
            _ => double.NaN
        };
        if (double.IsNaN(next)) return;
        SetWidth(next, true);
        e.Handled = true;
    }

    internal double CurrentWidth => Math.Clamp(value(), minimum(), maximum());

    internal void SetWidth(double width, bool persist)
    {
        if (!double.IsFinite(width)) throw new ArgumentOutOfRangeException(nameof(width));
        var previous = CurrentWidth;
        var next = Math.Clamp(Math.Round(width), minimum(), maximum());
        change(next);
        if (FrameworkElementAutomationPeer.FromElement(this) is UtilitySashPeer peer) peer.Notify(previous, next);
        if (persist) commit();
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new UtilitySashPeer(this);

    sealed class UtilitySashPeer(UtilityResizeSash owner) : FrameworkElementAutomationPeer(owner), IRangeValueProvider
    {
        protected override string GetClassNameCore() => "UtilityPanelDivider";
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Thumb;
        protected override object GetPatternCore(PatternInterface patternInterface) => patternInterface == PatternInterface.RangeValue ? this : base.GetPatternCore(patternInterface);
        public bool IsReadOnly => !owner.IsEnabled;
        public double LargeChange => 50;
        public double SmallChange => 10;
        public double Minimum => owner.minimum();
        public double Maximum => owner.maximum();
        public double Value => owner.CurrentWidth;
        public void SetValue(double value)
        {
            if (!double.IsFinite(value) || value < Minimum || value > Maximum) throw new ArgumentOutOfRangeException(nameof(value));
            if (IsReadOnly) throw new InvalidOperationException("The right panel divider is unavailable while the panel is hidden.");
            if (owner.DispatcherQueue.HasThreadAccess) owner.SetWidth(value, true);
            else if (!owner.DispatcherQueue.TryEnqueue(() => owner.SetWidth(value, true))) throw new InvalidOperationException("The window is closing.");
        }
        internal void Notify(double previous, double next) => RaisePropertyChangedEvent(RangeValuePatternIdentifiers.ValueProperty, previous, next);
    }
}
