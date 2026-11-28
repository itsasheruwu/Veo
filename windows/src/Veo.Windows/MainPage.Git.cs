using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Infrastructure.Projects;
using Veo_Windows.Controls;

namespace Veo_Windows;

public sealed partial class MainPage
{
    bool gitDialogOpen;

    GitReviewPanel CreateReviewPanel() => new(workspace, AppendReviewCommentToDraftAsync)
    {
        OpenWorktreesAsync = ShowWorktreesAsync,
        OpenCheckpointsAsync = ShowCheckpointsAsync
    };

    public Task ShowWorktreesAsync() => Run(async () =>
    {
        var path = current?.Record.Cwd ?? throw new InvalidOperationException("Open a project chat first.");
        await ShowWorktreesAsync(path);
    });

    async Task ShowWorktreesAsync(string path, bool offerProjectFolder = false)
    {
        if (gitDialogOpen) return;
        gitDialogOpen = true;
        ThreadSession? created = null;
        ProjectAction? setup = null;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot, Title = "Project worktrees", CloseButtonText = "Cancel",
                SecondaryButtonText = offerProjectFolder ? "Open project folder" : ""
            };
            var panel = new WorktreesPanel(App.Worktrees, path, (session, action) =>
            {
                created = session;
                setup = action;
                dialog.Hide();
            });
            dialog.Content = new ScrollViewer { Content = panel, MaxHeight = 600 };
            dialog.Closing += (_, e) => e.Cancel = panel.IsBusy && created is null;
            if (await dialog.ShowAsync() == ContentDialogResult.Secondary)
                created = await workspace.CreateAsync(path);
        }
        finally { gitDialogOpen = false; }

        if (created is null) return;
        await SaveDraftNowAsync();
        await SelectAsync(created);
        await RefreshCatalogAsync();
        if (setup is not null) await RunProjectActionAsync(created, setup);
    }

    async Task CreateProjectChatAsync(string path)
    {
        if ((await App.Projects.ConfigurationAsync(path)).UsesWorktree)
        {
            await ShowWorktreesAsync(path, offerProjectFolder: true);
            return;
        }
        await SaveDraftNowAsync();
        await SelectAsync(await workspace.CreateAsync(path));
        await RefreshCatalogAsync();
    }

    async Task RunProjectActionAsync(ThreadSession session, ProjectAction action)
    {
        if (terminalPanel is null)
        {
            terminalPanel = new(workspace);
            terminalPanel.AddSelectionToChat += text => _ = Run(() => AddTerminalSelectionToComposerAsync(text));
            terminalPanel.SettingsRequested += () => _ = Run(() => ShowSettingsAsync("Terminal"));
            terminalPanel.ExpandedChanged += ApplyTerminalExpansion;
            terminalPanel.HideRequested += () => _ = Run(ToggleTerminalAsync);
        }
        TerminalHost.Content = terminalPanel;
        if (!terminalWorkspaceExpanded) SetDockHeight(workspace.Preferences.TerminalDockHeight);
        await terminalPanel.RunProjectActionAsync(session, action.Command);
    }

    public async Task RunProjectActionAsync(string path, ProjectAction action)
    {
        if (ShowWorkspace(restoreFocus: false)) await RefreshCatalogAsync();
        if (current is not { } session || !session.Record.Cwd.Equals(path, StringComparison.OrdinalIgnoreCase))
        {
            var record = (await workspace.CatalogAsync()).FirstOrDefault(thread =>
                thread.Cwd.Equals(path, StringComparison.OrdinalIgnoreCase));
            await SaveDraftNowAsync();
            session = record is null ? await workspace.CreateAsync(path) : await workspace.LoadAsync(record);
            await SelectAsync(session);
            await RefreshCatalogAsync();
        }
        App.Main?.Activate();
        await RunProjectActionAsync(session, action);
    }

    public Task ShowCheckpointsAsync() => Run(async () =>
    {
        if (gitDialogOpen) return;
        var session = current ?? throw new InvalidOperationException("Open a project chat first.");
        var panel = new CheckpointsPanel(App.Checkpoints, session);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "Workspace checkpoints", CloseButtonText = "Done",
            Content = new ScrollViewer { Content = panel, MaxHeight = 520 }
        };
        dialog.Closing += (_, e) => e.Cancel = panel.IsBusy;
        gitDialogOpen = true;
        try { await dialog.ShowAsync(); }
        finally { gitDialogOpen = false; }
        if (panel.FilesRestored && ReferenceEquals(current, session)) await ShowUtilityAsync();
    });
}
