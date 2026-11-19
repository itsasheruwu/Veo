using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Veo.Core;
using Veo.Platform.Windows.Browser;

namespace Veo_Windows.Controls;
public sealed partial class BrowserPanel : Grid, IAsyncDisposable
{
    readonly WorkspaceCoordinator workspace;
    readonly BrowserStateStore state;
    readonly BrowserCredentialStore credentials;
    readonly TabView tabs = new()
    {
        IsAddTabButtonVisible = true,
        TabWidthMode = TabViewWidthMode.SizeToContent,
        CanReorderTabs = true,
        CanDragTabs = true
    };
    readonly TextBox address = new()
    {
        PlaceholderText = "Search or address",
        MinWidth = 0,
        VerticalAlignment = VerticalAlignment.Center
    };
    readonly Button back, forward;
    readonly TextBlock progress = new()
    {
        FontSize = 11,
        TextWrapping = TextWrapping.Wrap
    };
    readonly ComboBox viewport = new()
    {
        ItemsSource = new[]
        {
            "Responsive",
            "Desktop",
            "Tablet",
            "Mobile"
        },
        SelectedIndex = 0
    };
    readonly ToggleMenuFlyoutItem desktop = new()
    {
        Text = "Request desktop site",
        IsChecked = true
    };
    readonly Dictionary<TabViewItem, Tab> browsers = [];
    readonly Dictionary<string, NativeBrowserWorkspace> states = new(StringComparer.OrdinalIgnoreCase);
    readonly SemaphoreSlim dialogs = new(1, 1), switching = new(1, 1);
    CoreWebView2Environment? environment;
    Task<CoreWebView2Environment>? environmentTask;
    string? scope;
    bool restoring, loaded, disposed, showingAddress;
    sealed class Tab(string id, TabViewItem item, Grid content, WebView2 view, StackPanel start)
    {
        public readonly string Id = id;
        public readonly TabViewItem Item = item;
        public readonly Grid Content = content;
        public readonly StackPanel Start = start;
        public WebView2 View = view;
        public string Address = "", OriginalAgent = "";
        public string? AddressDraft;
        public long Epoch, PreviewBytes;
        public string? PreviewRoot, PreviewHost;
        public bool Failed, Closed;
        public Task? Initialization;
        public readonly List<string> Console = [];
    }

    Tab? Current => tabs.SelectedItem is TabViewItem item ? browsers.GetValueOrDefault(item) : null;

    public BrowserPanel(WorkspaceCoordinator workspace)
    {
        this.workspace = workspace;
        state = new(workspace.DataRoot);
        credentials = new(workspace.DataRoot);
        AutomationProperties.SetName(address, "Browser address");
        AutomationProperties.SetAutomationId(address, "BrowserAddress");
        for (var i = 0; i < 4; i++)
            RowDefinitions.Add(new() { Height = i == 1 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
        var leading = new StackPanel { Orientation = Orientation.Horizontal };
        back = NavigationButton(Symbol.Back, "Back", "BrowserBack");
        back.Click += (_, _) => Guard(() =>
        {
            if (Current?.View.CanGoBack == true)
                Current.View.GoBack();
            return Task.CompletedTask;
        });
        forward = NavigationButton(Symbol.Forward, "Forward", "BrowserForward");
        forward.Click += (_, _) => Guard(() =>
        {
            if (Current?.View.CanGoForward == true)
                Current.View.GoForward();
            return Task.CompletedTask;
        });
        var reload = NavigationButton(Symbol.Refresh, "Reload", "BrowserReload");
        reload.Click += (_, _) => Guard(ReloadAsync);
        leading.Children.Add(back);
        leading.Children.Add(forward);
        leading.Children.Add(reload);
        RefreshNavigationAvailability();

        var passwords = new MenuFlyout();
        AddMenu(passwords, "Fill saved password…", FillAsync);
        AddMenu(passwords, "Remove saved password…", RemovePasswordAsync);
        var passwordButton = NavigationButton(Symbol.Permissions, "Passwords", "BrowserPasswords");
        passwordButton.Flyout = passwords;

        var options = new MenuFlyout();
        AddMenu(options, "Open in default browser", async () =>
        {
            if (Current is { PreviewRoot: null } tab && BrowserOrigin.IsWeb(tab.Address))
                await Windows.System.Launcher.LaunchUriAsync(new(tab.Address));
        });
        AddMenu(options, "Developer tools", async () =>
        {
            if (Current is { } tab)
            {
                await EnsureAsync(tab);
                tab.View.CoreWebView2.OpenDevToolsWindow();
            }
        });
        AddMenu(options, "Console", () =>
        {
            consolePanel.Visibility = consolePanel.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
            RefreshConsole();
            return Task.CompletedTask;
        });
        AddMenu(options, "Downloads", () =>
        {
            downloadsPanel.Visibility = downloadsPanel.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
            return Task.CompletedTask;
        });
        AddMenu(options, "Open workspace HTML…", ChoosePreviewAsync);
        desktop.Click += (_, _) => Guard(async () =>
        {
            state.Value.DesktopSite = desktop.IsChecked == true;
            await state.SaveAsync();
            foreach (var tab in browsers.Values)
                if (tab.View.CoreWebView2 is { } core)
                    ApplyPreferences(tab, core);
        });
        options.Items.Add(desktop);
        AddMenu(options, "Clear website data…", async () =>
        {
            if (Current is not { } tab)
                return;
            var dialog = new ContentDialog
            {
                Title = "Clear website data?",
                Content = "Clear cookies, cache and site storage in this Veo profile. Saved Veo passwords are managed separately.",
                PrimaryButtonText = "Clear data",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close
            };
            if (await ShowAsync(dialog) == ContentDialogResult.Primary)
            {
                await EnsureAsync(tab);
                await tab.View.CoreWebView2.Profile.ClearBrowsingDataAsync();
                progress.Text = "Website data cleared.";
            }
        });
        var more = NavigationButton(Symbol.More, "Browser options", "BrowserOptions");
        more.Flyout = options;
        var go = NavigationButton(Symbol.Go, "Navigate browser address", "BrowserGo");
        go.Click += (_, _) => Guard(NavigateAddressAsync);
        var trailing = new StackPanel { Orientation = Orientation.Horizontal };
        trailing.Children.Add(go);
        trailing.Children.Add(passwordButton);
        trailing.Children.Add(more);

        var navigation = new Grid { ColumnSpacing = 4, Padding = new Thickness(6, 2, 6, 2) };
        navigation.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        navigation.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        navigation.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        navigation.Children.Add(leading);
        SetColumn(address, 1);
        navigation.Children.Add(address);
        SetColumn(trailing, 2);
        navigation.Children.Add(trailing);
        Children.Add(navigation);
        address.TextChanging += (_, _) =>
        {
            if (!showingAddress && Current is { } tab)
                tab.AddressDraft = address.Text;
        };
        address.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                Guard(NavigateAddressAsync);
            }
        };
        tabs.AddTabButtonClick += (_, _) => Guard(async () =>
        {
            await AddTabAsync();
            await PersistAsync();
        });
        tabs.TabCloseRequested += (_, e) =>
        {
            if (e.Tab is TabViewItem item)
                Guard(() => CloseAsync(item));
        };
        tabs.SelectionChanged += (_, _) =>
        {
            RefreshNavigationAvailability();
            if (Current is { } tab)
            {
                ShowAddress(tab);
                ApplyViewport(tab);
                RefreshConsole();
            }

            Guard(PersistAsync);
        };
        tabs.TabItemsChanged += (_, _) => Guard(PersistAsync);
        SetRow(tabs, 1);
        Children.Add(tabs);
        var lower = new StackPanel
        {
            Spacing = 6,
            Margin = new Thickness(8, 0, 8, 0)
        };
        var layout = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8
        };
        layout.Children.Add(new TextBlock { Text = "Viewport", VerticalAlignment = VerticalAlignment.Center });
        layout.Children.Add(viewport);
        lower.Children.Add(layout);
        viewport.SelectionChanged += (_, _) =>
        {
            if (Current is { } tab)
                ApplyViewport(tab);
            Guard(PersistAsync);
        };
        BuildConsole(lower);
        BuildDownloads(lower);
        SetRow(lower, 2);
        Children.Add(lower);
        SetRow(progress, 3);
        progress.Margin = new Thickness(8);
        Children.Add(progress);
    }

    public async Task LoadAsync(ThreadSession session)
    {
        await switching.WaitAsync();
        try
        {
            if (disposed)
                return;
            if (!loaded)
            {
                await state.LoadAsync();
                desktop.IsChecked = state.Value.DesktopSite;
                loaded = true;
            }

            var key = BrowserStateStore.WorkspaceKey(session.Record.Cwd);
            if (scope == key)
            {
                foreach (var tab in browsers.Values)
                    if (tab.View.CoreWebView2 is { } core)
                        ApplyPreferences(tab, core);
                return;
            }

            if (scope is not null)
                await PersistAsync();
            restoring = true;
            foreach (var tab in browsers.Values)
                Close(tab);
            browsers.Clear();
            tabs.TabItems.Clear();
            scope = key;
            var saved = states.GetValueOrDefault(key) ?? state.Restore(key, workspace.Preferences.RestoreBrowserTabs);
            if (saved is null && workspace.Preferences.RestoreBrowserTabs && workspace.Preferences.BrowserTabs.TryGetValue(session.Record.Cwd, out var old))
                saved = new(old.Where(t => BrowserOrigin.IsWeb(t.Url)).Select(t => new NativeBrowserTab(t.Id, t.Url, t.Title)).Take(32).ToArray(), old.FirstOrDefault()?.Id);
            viewport.SelectedItem = BrowserStateStore.NormalizeViewport(saved?.Viewport);
            if (saved is not null)
                foreach (var tab in saved.Tabs)
                    await AddTabAsync(tab.Url, tab.Id, tab.Title);
            if (browsers.Count == 0)
                await AddTabAsync();
            else if (saved?.SelectedId is { } selected && browsers.Values.FirstOrDefault(t => t.Id == selected)is { } chosen)
                tabs.SelectedItem = chosen.Item;
        }
        finally
        {
            restoring = false;
            switching.Release();
        }
    }

    void ShowAddress(Tab tab)
    {
        var previous = showingAddress;
        showingAddress = true;
        try { address.Text = tab.AddressDraft ?? tab.Address; }
        finally { showingAddress = previous; }
    }

    Task NavigateAddressAsync() => NavigateAsync(address.Text, consumeAddressDraft: true);

    public Task NavigateAsync(string input) => NavigateAsync(input, consumeAddressDraft: false);

    async Task NavigateAsync(string input, bool consumeAddressDraft)
    {
        var destination = BrowserSearch.Resolve(input, workspace.Preferences.SearchEngine);
        if (Current is null)
            await AddTabAsync();
        var tab = Current!;
        var submittedDraft = tab.AddressDraft;
        await EnsureAsync(tab);
        ApplyPreferences(tab, tab.View.CoreWebView2);
        tab.PreviewRoot = tab.PreviewHost = null;
        if (consumeAddressDraft && tab.AddressDraft == submittedDraft)
            tab.AddressDraft = null;
        ShowPage(tab);
        tab.View.Source = destination;
    }

    async Task ReloadAsync()
    {
        if (Current is not { } tab)
            return;
        if (!tab.Failed)
        {
            tab.View.Reload();
            return;
        }

        tab.View.Close();
        tab.Content.Children.Remove(tab.View);
        tab.View = new WebView2();
        tab.Content.Children.Insert(0, tab.View);
        tab.Initialization = null;
        tab.Failed = false;
        RefreshNavigationAvailability();
        await EnsureAsync(tab);
        ShowPage(tab);
        if (BrowserOrigin.IsWeb(tab.Address))
            tab.View.Source = new(tab.Address);
    }

    async Task EnsureAsync(Tab tab)
    {
        var pending = tab.Initialization ??= InitializeAsync(tab);
        try
        {
            await pending;
        }
        catch
        {
            if (tab.Initialization == pending)
                tab.Initialization = null;
            throw;
        }
    }

    async Task<CoreWebView2Environment> CreateEnvironmentAsync() => await CoreWebView2Environment.CreateWithOptionsAsync(null, Path.Combine(workspace.DataRoot, "Browser", "Profile"), null);
    async Task InitializeAsync(Tab tab)
    {
        environment ??= await (environmentTask ??= CreateEnvironmentAsync());
        var view = tab.View;
        await view.EnsureCoreWebView2Async(environment);
        if (tab.Closed || disposed)
            throw new OperationCanceledException("This browser tab has closed.");
        var core = view.CoreWebView2 ?? throw new InvalidOperationException("WebView2 did not initialize.");
        tab.OriginalAgent = core.Settings.UserAgent;
        ApplyPreferences(tab, core);
        core.HistoryChanged += (_, _) =>
        {
            if (Current == tab && tab.View == view)
                RefreshNavigationAvailability();
        };
        core.NavigationStarting += (_, e) =>
        {
            tab.Epoch++;
            tab.PreviewBytes = 0;
            if ((!BrowserOrigin.IsWeb(e.Uri) && e.Uri != "about:blank") || (tab.PreviewHost is not null && (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var local) || local.Host != tab.PreviewHost)))
            {
                e.Cancel = true;
                progress.Text = "Navigation is outside this tab's approved boundary.";
                return;
            }

            tab.Address = e.Uri;
            if (Current == tab)
            {
                ShowAddress(tab);
                progress.Text = "Loading…";
            }
        };
        core.NavigationCompleted += (_, e) => Guard(async () =>
        {
            if (tab.Closed || tab.View != view)
                return;
            tab.Address = core.Source;
            if (Current == tab)
            {
                ShowAddress(tab);
                progress.Text = e.IsSuccess ? "" : "Page failed: " + e.WebErrorStatus;
            }

            await PersistAsync();
        });
        core.DocumentTitleChanged += (_, _) => Guard(async () =>
        {
            if (!tab.Closed && tab.View == view)
            {
                tab.Item.Header = string.IsNullOrWhiteSpace(core.DocumentTitle) ? "New tab" : core.DocumentTitle;
                await PersistAsync();
            }
        });
        core.NewWindowRequested += async (_, e) =>
        {
            var deferral = e.GetDeferral();
            e.Handled = true;
            try
            {
                if (tab.PreviewRoot is not null || !BrowserOrigin.IsWeb(e.Uri))
                    return;
                var popup = await AddTabAsync();
                await EnsureAsync(popup);
                ShowPage(popup);
                e.NewWindow = popup.View.CoreWebView2;
            }
            catch (Exception error)
            {
                progress.Text = error.Message;
            }
            finally
            {
                deferral.Complete();
            }
        };
        core.WindowCloseRequested += (_, _) => Guard(() => CloseAsync(tab.Item));
        core.ProcessFailed += (_, e) =>
        {
            if (!tab.Closed)
            {
                tab.Failed = true;
                if (Current == tab)
                    RefreshNavigationAvailability();
                progress.Text = "Browser process stopped: " + e.ProcessFailedKind + ". Reload this tab to recover.";
            }
        };
        WireAuthentication(tab, core);
        WirePermissions(tab, core);
        WirePreview(tab, core);
        await WireConsoleAsync(tab, core);
        core.DownloadStarting += (_, e) => StartDownload(tab, e);
    }

    void ApplyPreferences(Tab tab, CoreWebView2 core)
    {
        core.Settings.IsScriptEnabled = workspace.Preferences.JavaScript;
        core.Settings.IsGeneralAutofillEnabled = workspace.Preferences.BrowserAutoFill;
        core.Settings.IsPasswordAutosaveEnabled = false;
        core.Settings.IsReputationCheckingRequired = workspace.Preferences.BrowserFraudWarning;
        core.Settings.AreHostObjectsAllowed = false;
        core.Settings.UserAgent = state.Value.DesktopSite ? tab.OriginalAgent : tab.OriginalAgent.Replace("Windows NT 10.0; Win64; x64", "Linux; Android 14; Mobile");
    }

    async Task<Tab> AddTabAsync(string? url = null, string? id = null, string? title = null)
    {
        if (browsers.Count >= 32)
            throw new InvalidOperationException("Close a tab before opening another (32 maximum).");
        var item = new TabViewItem
        {
            Header = title ?? "New tab",
            IsClosable = true
        };
        var content = new Grid();
        var view = new WebView2
        {
            Visibility = Visibility.Collapsed
        };
        content.Children.Add(view);
        var start = new StackPanel
        {
            Spacing = 12,
            Margin = new Thickness(24),
            VerticalAlignment = VerticalAlignment.Center
        };
        start.Children.Add(new TextBlock { Text = "Search the web", FontSize = 22, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var search = new TextBox
        {
            PlaceholderText = "Search"
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(search, "BrowserStartSearch");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(search, "Start page search");
        start.Children.Add(search);
        content.Children.Add(start);
        item.Content = content;
        var tab = new Tab(Guid.TryParse(id, out _) ? id! : Guid.NewGuid().ToString("N"), item, content, view, start);
        browsers[item] = tab;
        tabs.TabItems.Add(item);
        tabs.SelectedItem = item;
        ApplyViewport(tab);
        search.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                Guard(async () =>
                {
                    tabs.SelectedItem = item;
                    await NavigateAsync(search.Text);
                });
            }
        };
        var menu = new MenuFlyout();
        AddMenu(menu, "Move tab left", () => MoveAsync(tab, -1));
        AddMenu(menu, "Move tab right", () => MoveAsync(tab, 1));
        item.ContextFlyout = menu;
        if (url is not null && BrowserOrigin.IsWeb(url))
            await NavigateAsync(url);
        return tab;
    }

    async Task MoveAsync(Tab tab, int delta)
    {
        var index = tabs.TabItems.IndexOf(tab.Item);
        var target = index + delta;
        if (index < 0 || target < 0 || target >= tabs.TabItems.Count)
            return;
        restoring = true;
        try
        {
            tabs.TabItems.RemoveAt(index);
            tabs.TabItems.Insert(target, tab.Item);
            tabs.SelectedItem = tab.Item;
        }
        finally
        {
            restoring = false;
        }

        await PersistAsync();
    }

    async Task CloseAsync(TabViewItem item)
    {
        if (!browsers.Remove(item, out var tab))
            return;
        var index = tabs.TabItems.IndexOf(item);
        Close(tab);
        tabs.TabItems.Remove(item);
        if (browsers.Count == 0)
            await AddTabAsync();
        else if (tabs.SelectedItem is null)
            tabs.SelectedIndex = Math.Clamp(index, 0, browsers.Count - 1);
        await PersistAsync();
    }

    static void Close(Tab tab)
    {
        tab.Closed = true;
        tab.Epoch++;
        tab.View.Close();
    }

    static void ShowPage(Tab tab)
    {
        tab.View.Visibility = Visibility.Visible;
        tab.Start.Visibility = Visibility.Collapsed;
    }

    void ApplyViewport(Tab tab)
    {
        var width = viewport.SelectedItem?.ToString() switch
        {
            "Desktop" => 1280,
            "Tablet" => 834,
            "Mobile" => 390,
            _ => double.NaN
        };
        tab.View.Width = width;
        tab.View.HorizontalAlignment = double.IsNaN(width) ? HorizontalAlignment.Stretch : HorizontalAlignment.Left;
    }

    async Task PersistAsync()
    {
        if (restoring || disposed || scope is null)
            return;
        var snapshot = new NativeBrowserWorkspace(tabs.TabItems.OfType<TabViewItem>().Where(browsers.ContainsKey).Select(t => new NativeBrowserTab(browsers[t].Id, browsers[t].PreviewRoot is null ? browsers[t].Address : "", t.Header?.ToString() ?? "")).ToArray(), Current?.Id, BrowserStateStore.NormalizeViewport(viewport.SelectedItem?.ToString()));
        states[scope] = snapshot;
        await state.SaveWorkspaceAsync(scope, snapshot, workspace.Preferences.RestoreBrowserTabs);
    }

    async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        await dialogs.WaitAsync();
        try
        {
            if (disposed)
                return ContentDialogResult.None;
            dialog.XamlRoot = XamlRoot;
            return await dialog.ShowAsync();
        }
        finally
        {
            dialogs.Release();
        }
    }

    async void Guard(Func<Task> action)
    {
        try
        {
            if (!disposed)
                await action();
        }
        catch (Exception error)
        {
            if (!disposed)
                progress.Text = error.Message;
        }
    }

    void RefreshNavigationAvailability()
    {
        var core = Current is { Failed: false, Closed: false } tab ? tab.View.CoreWebView2 : null;
        back.IsEnabled = core?.CanGoBack == true;
        forward.IsEnabled = core?.CanGoForward == true;
    }

    static Button NavigationButton(Symbol symbol, string title, string automationId)
    {
        var button = new Button
        {
            Content = new SymbolIcon(symbol),
            Width = 28,
            Height = 32,
            Padding = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center
        };
        if (Application.Current.Resources.TryGetValue("SubtleButtonStyle", out var style) && style is Style subtle)
            button.Style = subtle;
        AutomationProperties.SetName(button, title);
        AutomationProperties.SetAutomationId(button, automationId);
        ToolTipService.SetToolTip(button, title);
        return button;
    }

    void AddMenu(MenuFlyout menu, string title, Func<Task> action)
    {
        var item = new MenuFlyoutItem
        {
            Text = title
        };
        item.Click += (_, _) => Guard(action);
        menu.Items.Add(item);
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed)
            return;
        await PersistAsync();
        disposed = true;
        CancelDownloads();
        foreach (var tab in browsers.Values)
            Close(tab);
        browsers.Clear();
    }
}
