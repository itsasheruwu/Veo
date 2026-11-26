using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Platform.Windows.Browser;

namespace Veo_Windows.Controls;

public sealed partial class BrowserPanel
{
    const double CompactBrowserWidth = 350;
    readonly Grid navigation = new() { ColumnSpacing = 4, Padding = new Thickness(6, 4, 6, 6) };
    readonly TextBox address = new()
    {
        PlaceholderText = "Search or enter address",
        FontSize = 13,
        MinWidth = 0,
        CornerRadius = new CornerRadius(7),
        VerticalAlignment = VerticalAlignment.Center,
        IsSpellCheckEnabled = false,
        IsTextPredictionEnabled = false
    };
    readonly Button back = NavigationButton(Symbol.Back, "Back", "BrowserBack");
    readonly Button forward = NavigationButton(Symbol.Forward, "Forward", "BrowserForward");
    readonly Button reload = NavigationButton(Symbol.Refresh, "Reload", "BrowserReload");
    readonly Button go = NavigationButton(Symbol.Go, "Go to address", "BrowserGo");
    readonly MenuFlyoutItem forwardMenuItem = new() { Text = "Forward", Icon = new SymbolIcon(Symbol.Forward) };
    readonly MenuFlyoutItem reloadMenuItem = new() { Text = "Reload", Icon = new SymbolIcon(Symbol.Refresh) };
    readonly MenuFlyoutSeparator navigationSeparator = new();
    readonly Dictionary<string, RadioMenuFlyoutItem> viewportOptions = new(StringComparer.Ordinal);
    string viewportMode = "Responsive";

    void BuildNavigation()
    {
        back.Click += (_, _) => Guard(() => NavigateHistoryAsync(backward: true));
        forward.Click += (_, _) => Guard(() => NavigateHistoryAsync(backward: false));
        forwardMenuItem.Click += (_, _) => Guard(() => NavigateHistoryAsync(backward: false));
        reload.Click += (_, _) => Guard(ReloadAsync);
        reloadMenuItem.Click += (_, _) => Guard(ReloadAsync);
        go.Click += (_, _) => Guard(NavigateAddressAsync);
        var leading = new StackPanel { Orientation = Orientation.Horizontal };
        leading.Children.Add(back);
        leading.Children.Add(forward);
        leading.Children.Add(reload);

        AutomationProperties.SetName(address, "Browser address");
        AutomationProperties.SetAutomationId(address, "BrowserAddress");
        address.TextChanging += (_, _) =>
        {
            if (!showingAddress && Current is { } tab)
            {
                tab.AddressDraft = address.Text;
                RefreshAddressSubmit();
            }
        };
        address.KeyDown += (_, e) =>
        {
            if (e.Key == global::Windows.System.VirtualKey.Enter && !string.IsNullOrWhiteSpace(address.Text))
            {
                e.Handled = true;
                Guard(NavigateAddressAsync);
            }
            else if (e.Key == global::Windows.System.VirtualKey.Escape && Current is { AddressDraft: not null } tab)
            {
                e.Handled = true;
                tab.AddressDraft = null;
                ShowAddress(tab);
            }
        };
        var more = NavigationButton(Symbol.More, "Browser options", "BrowserOptions");
        more.Flyout = BuildBrowserOptions();
        var trailing = new StackPanel { Orientation = Orientation.Horizontal };
        trailing.Children.Add(go);
        trailing.Children.Add(more);

        navigation.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        navigation.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        navigation.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        navigation.Children.Add(leading);
        SetColumn(address, 1);
        navigation.Children.Add(address);
        SetColumn(trailing, 2);
        navigation.Children.Add(trailing);
        SizeChanged += (_, e) => SetNavigationWidth(e.NewSize.Width);
        SetNavigationWidth(ActualWidth);
        RefreshAddressSubmit();
        RefreshNavigationAvailability();
    }

    MenuFlyout BuildBrowserOptions()
    {
        var options = new MenuFlyout();
        options.Items.Add(forwardMenuItem);
        options.Items.Add(reloadMenuItem);
        options.Items.Add(navigationSeparator);
        AddMenu(options, "Open in default browser", async () =>
        {
            if (Current is { PreviewRoot: null } tab && BrowserOrigin.IsWeb(tab.Address))
                await Windows.System.Launcher.LaunchUriAsync(new(tab.Address));
        });
        AddMenu(options, "Downloads", () =>
        {
            downloadsPanel.Visibility = downloadsPanel.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
            return Task.CompletedTask;
        });

        var viewport = new MenuFlyoutSubItem { Text = "Viewport" };
        foreach (var name in new[] { "Responsive", "Desktop", "Tablet", "Mobile" })
        {
            var choice = new RadioMenuFlyoutItem { Text = name, GroupName = "BrowserViewport" };
            choice.Click += (_, _) =>
            {
                SetViewport(name);
                if (Current is { } tab)
                    ApplyViewport(tab);
                Guard(PersistAsync);
            };
            viewport.Items.Add(choice);
            viewportOptions.Add(name, choice);
        }
        SetViewport(viewportMode);
        options.Items.Add(viewport);

        var passwords = new MenuFlyoutSubItem { Text = "Passwords" };
        AutomationProperties.SetAutomationId(passwords, "BrowserPasswords");
        passwords.Items.Add(BrowserMenuItem("Fill saved password…", FillAsync));
        passwords.Items.Add(BrowserMenuItem("Remove saved password…", RemovePasswordAsync));
        options.Items.Add(passwords);

        var tools = new MenuFlyoutSubItem { Text = "Developer" };
        AddMenu(tools.Items, "WebView developer tools", async () =>
        {
            if (Current is { } tab)
            {
                await EnsureAsync(tab);
                tab.View.CoreWebView2.OpenDevToolsWindow();
            }
        });
        AddMenu(tools.Items, "Console", () =>
        {
            consolePanel.Visibility = consolePanel.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
            RefreshConsole();
            return Task.CompletedTask;
        });
        AddMenu(tools.Items, "Open workspace HTML…", ChoosePreviewAsync);

        options.Items.Add(tools);
        options.Items.Add(new MenuFlyoutSeparator());
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
        return options;
    }

    void SetNavigationWidth(double width)
    {
        var compact = width < CompactBrowserWidth;
        forward.Visibility = reload.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        forwardMenuItem.Visibility = reloadMenuItem.Visibility = navigationSeparator.Visibility =
            compact ? Visibility.Visible : Visibility.Collapsed;
    }

    void SetViewport(string? mode)
    {
        viewportMode = BrowserStateStore.NormalizeViewport(mode);
        foreach (var (name, item) in viewportOptions)
            item.IsChecked = name == viewportMode;
    }

    Task NavigateHistoryAsync(bool backward)
    {
        if (Current is { Failed: false, Closed: false } tab && tab.View.CoreWebView2 is { } core)
        {
            if (backward && core.CanGoBack)
                core.GoBack();
            else if (!backward && core.CanGoForward)
                core.GoForward();
        }
        return Task.CompletedTask;
    }

    void RefreshAddressSubmit() =>
        go.Visibility = string.IsNullOrWhiteSpace(Current?.AddressDraft) ? Visibility.Collapsed : Visibility.Visible;

    void RefreshNavigationAvailability()
    {
        var tab = Current;
        var core = tab is { Failed: false, Closed: false } ? tab.View.CoreWebView2 : null;
        back.IsEnabled = core?.CanGoBack == true;
        forward.IsEnabled = forwardMenuItem.IsEnabled = core?.CanGoForward == true;
        reload.IsEnabled = reloadMenuItem.IsEnabled = tab is { Failed: true } ||
            core is not null && tab?.Address.Length > 0;
        var loading = tab?.LoadingNavigationId is not null;
        var symbol = loading ? Symbol.Stop : Symbol.Refresh;
        var title = loading ? "Stop loading" : "Reload";
        ((SymbolIcon)((Viewbox)reload.Content).Child).Symbol = symbol;
        ((SymbolIcon)reloadMenuItem.Icon).Symbol = symbol;
        reloadMenuItem.Text = title;
        AutomationProperties.SetName(reload, title);
        ToolTipService.SetToolTip(reload, title);
    }

    static Button NavigationButton(Symbol symbol, string title, string automationId)
    {
        var button = new Button
        {
            Content = new Viewbox { Width = 15, Height = 15, Child = new SymbolIcon(symbol) },
            MinWidth = 0,
            MinHeight = 0,
            Width = 26,
            Height = 30,
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

    MenuFlyoutItem BrowserMenuItem(string title, Func<Task> action)
    {
        var item = new MenuFlyoutItem { Text = title };
        item.Click += (_, _) => Guard(action);
        return item;
    }

    void AddMenu(IList<MenuFlyoutItemBase> items, string title, Func<Task> action) =>
        items.Add(BrowserMenuItem(title, action));

    void AddMenu(MenuFlyout menu, string title, Func<Task> action) =>
        AddMenu(menu.Items, title, action);
}
