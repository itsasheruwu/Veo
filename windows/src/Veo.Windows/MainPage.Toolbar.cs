using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Veo_Windows;

public sealed partial class MainPage
{
    bool sidebarVisible = true;

    internal event Action<double, bool>? SidebarLayoutChanged;
    internal event Action? ToolbarContextChanged;

    internal void ToggleSidebar()
    {
        sidebarVisible = !sidebarVisible;
        SidebarPanel.Visibility = sidebarVisible ? Visibility.Visible : Visibility.Collapsed;
        ApplyWorkspaceWidth();
    }

    internal Task ToggleTemporaryChatAsync() => Run(async () =>
    {
        if (current is not { CanToggleTemporaryChat: true } session) return;
        await workspace.ToggleTemporaryChatAsync(session);
        await RefreshCatalogAsync();
        Render();
    });

    internal Task ShowProjectActionsAsync(FrameworkElement anchor) => Run(async () =>
    {
        if (current is not { Record.WorkspaceKind: "project" } session) return;
        var path = session.Record.Cwd;
        if (!Directory.Exists(path)) throw new DirectoryNotFoundException("The project checkout is unavailable.");
        var configuration = await App.Projects.ConfigurationAsync(path);
        if (!ReferenceEquals(current, session) || !anchor.IsLoaded) return;

        var menu = new MenuFlyout();
        foreach (var action in configuration.Actions ?? [])
        {
            var item = new MenuFlyoutItem { Text = action.Name };
            item.Click += async (_, _) => await Run(async () =>
            {
                if (!ReferenceEquals(current, session) || session.Record.Cwd != path || !Directory.Exists(path))
                    throw new InvalidOperationException("Reopen Project actions in the active checkout.");
                await RunProjectActionAsync(session, action);
            });
            menu.Items.Add(item);
        }
        if (menu.Items.Count > 0) menu.Items.Add(new MenuFlyoutSeparator());
        var configure = new MenuFlyoutItem { Text = "Configure actions…" };
        configure.Click += async (_, _) => await Run(() => ShowSettingsAsync("Projects"));
        menu.Items.Add(configure);
        menu.ShowAt(anchor);
    });
}
