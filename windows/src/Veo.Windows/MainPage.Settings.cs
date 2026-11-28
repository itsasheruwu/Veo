using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Veo.Core;
using Veo_Windows.Controls;

namespace Veo_Windows;

public sealed partial class MainPage
{
    SettingsPanel? settingsPanel;
    Control? workspaceFocusBeforeSettings;
    readonly CommandDispatcher shortcutCommands = new();
    CommandAcceleratorBinder? shortcutBindings;
    internal bool IsShowingSettings => settingsPanel is not null;

    async Task ShowSettingsAsync(string? category = null)
    {
        await ready.Task;
        if (settingsPanel is null)
        {
            CancelDictation();
            workspaceFocusBeforeSettings = FocusManager.GetFocusedElement(XamlRoot) as Control;
            CloseCompletions();
            settingsPanel = new SettingsPanel(workspace, shortcutCommands.IsAvailable, SetIncludeGPT56ModelsAsync, GetSettingsProvider);
            settingsPanel.BackRequested += BackFromSettings;
            SettingsHost.Content = settingsPanel;
            SettingsHost.Visibility = Visibility.Visible;
            Shell.Visibility = Visibility.Collapsed;
            settingsPanel.SetWorkspaceWidth(UtilityWindowWidth(), PreferredSidebarWidth());
            ToolbarContextChanged?.Invoke();
        }
        settingsPanel.Select(category);
        settingsPanel.FocusCategory();
        App.Main?.Activate();
    }

    (string Name, string? Executable)? GetSettingsProvider()
    {
        if (ActiveAgent is { } id && Agents.Connections.TryGetValue(id, out var connection))
            return (Services.AgentConnections.Catalog.First(a => a.Id == id).Name, connection.Executable);
        var selection = App.Models.Find(modelCatalogId ?? model);
        return selection?.IsExternal == true ? (selection.Id.Split('/')[0], null) : null;
    }

    async Task SetIncludeGPT56ModelsAsync(bool enabled)
    {
        await App.Models.SetIncludeGPT56ModelsAsync(enabled);
        if (current is { } session && await ReconcileGPT56OptInAsync(session))
        {
            await SaveDraftNowAsync();
            Render();
        }
    }

    async Task<bool> ReconcileGPT56OptInAsync(ThreadSession session)
    {
        if (App.Routing.LockedRoute(session) is not null || !App.Models.RequiresGPT56OptIn(modelCatalogId ?? model, routingMode))
            return false;
        var fallback = await App.Models.ResolveAsync(session);
        if (current != session) return false;
        ApplyModelChoice(fallback);
        return true;
    }

    async void BackFromSettings()
    {
        if (ShowWorkspace()) await Run(RefreshCatalogAsync);
    }

    bool ShowWorkspace(bool restoreFocus = true)
    {
        if (settingsPanel is not { } panel) return false;
        panel.BackRequested -= BackFromSettings;
        settingsPanel = null;
        var previous = workspaceFocusBeforeSettings;
        workspaceFocusBeforeSettings = null;
        SettingsHost.Visibility = Visibility.Collapsed;
        SettingsHost.Content = null;
        Shell.Visibility = Visibility.Visible;
        UpdateDictationControl();
        ToolbarContextChanged?.Invoke();
        if (restoreFocus && previous is not null)
            DispatcherQueue.TryEnqueue(() =>
            {
                if (!IsShowingSettings && previous.IsLoaded) previous.Focus(FocusState.Programmatic);
            });
        return true;
    }

    public Task OpenSettingsAsync() => ShowSettingsAsync();

    async Task InitializeShortcutsAsync()
    {
        foreach (var command in CommandRegistry.Definitions.Where(x => x.SlashName is not null && x.Id is not ("init" or "goal")))
        {
            shortcutCommands.Register(command.Id, async (_, _) =>
            {
                await ExecuteCommandAsync("/" + command.SlashName);
            });
        }
        shortcutCommands.Register("settings", (_, _) => ShowSettingsAsync());
        shortcutCommands.Register("openProject", (_, _) => OpenProjectAsync());
        shortcutCommands.Register("stash", (_, _) => ShowPromptLibraryAsync());
        shortcutCommands.Register("worktrees", (_, _) => ShowWorktreesAsync());
        try { await App.Commands.InitializeAsync(); }
        finally
        {
            shortcutBindings = new CommandAcceleratorBinder(this, App.Commands, shortcutCommands, ShowError,
                command => !IsShowingSettings || command.Id == "settings" && settingsPanel?.IsCapturingShortcut != true);
        }
    }
}
