using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Veo.Infrastructure.Files;
using Veo.Infrastructure.Git;

namespace Veo_Windows.Controls;

/// <summary>Review commands always use the snapshot the user actually reviewed.</summary>
public sealed class GitReviewPanel : UserControl
{
    private readonly WorkspaceCoordinator coordinator;
    private readonly LocalGitService git;
    private readonly Func<ThreadSession, string, Task> appendToDraft;
    private readonly ListView changes = new() { SelectionMode = ListViewSelectionMode.Multiple, IsMultiSelectCheckBoxEnabled = true, IsItemClickEnabled = true, ItemContainerTransitions = new() };
    private readonly NativeDiffView diff = new() { PlaceholderText = "Select a changed file to inspect its diff" };
    private readonly ComboBox side = new() { ItemsSource = new[] { "Unstaged", "Staged" }, SelectedIndex = 0, MinWidth = 120 };
    private readonly ComboBox layout = new() { ItemsSource = new[] { "Unified", "Split" }, SelectedIndex = 0, MinWidth = 100 };
    private readonly ComboBox hunks = new() { PlaceholderText = "Choose hunk", MinWidth = 100, MaxWidth = 250 };
    private readonly AppBarToggleButton whitespace = new() { Label = "Ignore whitespace", IsChecked = false };
    private readonly Button applyHunk = new() { Content = "Stage hunk", IsEnabled = false };
    private readonly Button commentOnLines = new() { Content = "Comment on lines", IsEnabled = false };
    private readonly TextBlock summary = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly InfoBar notice = new() { IsOpen = false, IsClosable = true };
    private readonly TextBox commitMessage = new() { PlaceholderText = "Commit message", AcceptsReturn = true, MaxHeight = 90, TextWrapping = TextWrapping.Wrap };
    private readonly Button commit = new() { Content = "Commit selected staged files", HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = false };
    private readonly AppBarButton recover = new() { Label = "Recover last discard", Icon = new SymbolIcon(Symbol.Undo), IsEnabled = false };
    private readonly List<AppBarButton> mutations = [];
    private readonly Dictionary<string, GitRecoveryReceipt> recoveries = [];
    private ThreadSession? session;
    private GitRepositorySnapshot? snapshot;
    public Func<Task>? OpenWorktreesAsync { get; init; }
    public Func<Task>? OpenCheckpointsAsync { get; init; }
    private readonly SemaphoreSlim viewGate = new(1, 1);
    private int diffRequest;
    private bool hunkActionsAllowed;
    private DisplayedDiff? displayedDiff;
    private sealed record DisplayedDiff(ThreadSession Session, string Path, bool Staged, bool IgnoreWhitespace);
    private sealed record CommentRow(DiffLine Line)
    { public override string ToString() => GitReviewComment.LineLabel(Line); }
    private sealed record ChangeRow(GitFileChange File)
    { public override string ToString() => $"{File.IndexStatus}{File.WorktreeStatus}  {File.Path}"; }

    public GitReviewPanel(WorkspaceCoordinator coordinator, Func<ThreadSession, string, Task> appendToDraft)
    {
        this.coordinator = coordinator; git = new(Path.Combine(coordinator.DataRoot, "Recovery"));
        this.appendToDraft = appendToDraft;
        AutomationProperties.SetName(changes, "Changed files"); AutomationProperties.SetName(diff, "Git diff");
        AutomationProperties.SetName(commitMessage, "Commit message"); AutomationProperties.SetName(side, "Diff side");
        AutomationProperties.SetName(layout, "Diff layout"); AutomationProperties.SetName(hunks, "Diff hunk");
        var bar = new CommandBar
        {
            Content = new Grid { Height = 34, Children = { summary } },
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            DefaultLabelPosition = CommandBarDefaultLabelPosition.Collapsed
        };
        var refresh = Button("Refresh review", Symbol.Refresh, RefreshAsync); refresh.Width = 36; bar.PrimaryCommands.Add(refresh);
        var stage = Button("Stage selected files", Symbol.Add, () => MutateAsync((s, p) => git.StageAsync(s, p))); stage.Width = 36; bar.SecondaryCommands.Add(stage); mutations.Add(stage);
        var unstage = Button("Unstage selected files", Symbol.Remove, () => MutateAsync((s, p) => git.UnstageAsync(s, p))); unstage.Width = 36; bar.SecondaryCommands.Add(unstage); mutations.Add(unstage);
        var discard = Button("Discard selected unstaged changes", Symbol.Delete, DiscardAsync); bar.SecondaryCommands.Add(discard); mutations.Add(discard);
        recover.Click += async (_, _) => await GuardAsync(RecoverAsync); bar.SecondaryCommands.Add(recover);
        bar.SecondaryCommands.Add(whitespace);
        var branch = Button("Create branch", Symbol.Add, CreateBranchAsync); bar.SecondaryCommands.Add(branch); mutations.Add(branch);
        var worktrees = new AppBarButton { Label = "Project worktrees", Icon = new SymbolIcon(Symbol.OpenLocal) };
        worktrees.Click += async (_, _) => { if (OpenWorktreesAsync is { } open) await open(); };
        bar.SecondaryCommands.Add(worktrees);
        var checkpoints = new AppBarButton { Label = "Workspace checkpoints", Icon = new SymbolIcon(Symbol.Save) };
        checkpoints.Click += async (_, _) => { if (OpenCheckpointsAsync is { } open) await open(); };
        bar.SecondaryCommands.Add(checkpoints);
        foreach (var button in mutations) button.IsEnabled = false;
        commit.Click += async (_, _) => await GuardAsync(CommitAsync);
        side.SelectionChanged += async (_, _) => await RequestDiffAsync();
        layout.SelectionChanged += (_, _) => diff.IsSplit = layout.SelectedIndex == 1;
        whitespace.Checked += async (_, _) => await RequestDiffAsync();
        whitespace.Unchecked += async (_, _) => await RequestDiffAsync();
        hunks.SelectionChanged += (_, _) => UpdateHunkActions();
        applyHunk.Click += async (_, _) => await GuardAsync(ApplyHunkAsync);
        commentOnLines.Click += async (_, _) => await GuardAsync(CommentOnLinesAsync);
        changes.SelectionChanged += async (_, args) =>
        {
            if (args.AddedItems.FirstOrDefault() is not ChangeRow selected) return;
            inspectedFile = selected.File.Path;
            await RequestDiffAsync();
        };
        var diffOptions = new Grid { ColumnSpacing = 6 };
        diffOptions.ColumnDefinitions.Add(new()); diffOptions.ColumnDefinitions.Add(new());
        diffOptions.Children.Add(side); Grid.SetColumn(layout, 1); diffOptions.Children.Add(layout);
        hunkOptions.ColumnSpacing = 6;
        hunkOptions.ColumnDefinitions.Add(new()); hunkOptions.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        hunkOptions.Children.Add(hunks); Grid.SetColumn(applyHunk, 1); hunkOptions.Children.Add(applyHunk);
        var grid = new Grid { Padding = new Thickness(8, 0, 8, 8), RowSpacing = 4 };
        grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new());
        grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
        Add(grid, bar, 0);
        Add(grid, notice, 1);
        Add(grid, body, 2);
        body.ColumnDefinitions.Add(new());
        body.ColumnDefinitions.Add(new());
        fileList.RowDefinitions.Add(new() { Height = GridLength.Auto });
        fileList.RowDefinitions.Add(new());
        Add(fileList, changeHeading, 0);
        Add(fileList, changes, 1);
        body.Children.Add(fileList);
        body.Children.Add(detail);
        for (int row = 0; row < 4; row++) detail.RowDefinitions.Add(new() { Height = GridLength.Auto });
        detail.RowDefinitions.Add(new());
        back.Style = (Style)Application.Current.Resources["SubtleButtonStyle"];
        back.Click += (_, _) =>
        {
            showsCompactDiff = false;
            LayoutReview();
            changes.Focus(FocusState.Programmatic);
        };
        changes.ItemClick += (_, args) =>
        {
            if (args.ClickedItem is not ChangeRow row) return;
            showsCompactDiff = true;
            inspectedFile = row.File.Path;
            LayoutReview();
            _ = RequestDiffAsync();
        };
        Add(detail, back, 0);
        Add(detail, diffOptions, 1);
        Add(detail, hunkOptions, 2);
        Add(detail, commentOnLines, 3);
        Add(detail, diff, 4);
        commitToggle.Style = (Style)Application.Current.Resources["SubtleButtonStyle"];
        commitToggle.Click += (_, _) =>
        {
            commitOpen = !commitOpen;
            LayoutReview();
            if (commitOpen) commitMessage.Focus(FocusState.Keyboard);
        };
        var commitArea = new StackPanel { Spacing = 4 };
        commitArea.Children.Add(commitToggle);
        commitArea.Children.Add(commitMessage);
        commitArea.Children.Add(commit);
        Add(grid, commitArea, 3);
        Add(grid, empty, 2);
        SizeChanged += (_, _) => LayoutReview();
        UpdateReviewSurface(false, false);
        Content = grid;
    }

    readonly InspectorEmptyState empty = new("\uE8A5", "Git unavailable", "Open a project with a Git repository.");
    readonly Grid body = new() { ColumnSpacing = 6 }, fileList = new(), detail = new() { RowSpacing = 4 }, hunkOptions = new();
    readonly TextBlock changeHeading = new() { Text = "Changed files", FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(4, 6, 4, 6) };
    readonly Button back = new() { Content = "‹  Back to Changes", HorizontalAlignment = HorizontalAlignment.Left };
    readonly Button commitToggle = new() { Content = "Commit…", FontSize = 12, HorizontalAlignment = HorizontalAlignment.Left };
    string? inspectedFile;
    bool commitOpen, hasChanges, showsCompactDiff;

    void LayoutReview()
    {
        var compact = ActualWidth < 620;
        body.ColumnDefinitions[0].Width = compact ? new GridLength(1, GridUnitType.Star) : new GridLength(210);
        body.ColumnDefinitions[1].Width = compact ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        Grid.SetColumn(detail, compact ? 0 : 1);
        body.Visibility = hasChanges ? Visibility.Visible : Visibility.Collapsed;
        fileList.Visibility = !compact || !showsCompactDiff ? Visibility.Visible : Visibility.Collapsed;
        detail.Visibility = !compact || showsCompactDiff ? Visibility.Visible : Visibility.Collapsed;
        back.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        layout.Visibility = ActualWidth >= 880 ? Visibility.Visible : Visibility.Collapsed;
        diff.IsSplit = ActualWidth >= 880 && layout.SelectedIndex == 1;
        commitToggle.Visibility = hasChanges ? Visibility.Visible : Visibility.Collapsed;
        commit.Visibility = commitMessage.Visibility = hasChanges && commitOpen ? Visibility.Visible : Visibility.Collapsed;
    }

    void UpdateReviewSurface(bool available, bool changed)
    {
        hasChanges = changed;
        empty.Visibility = changed ? Visibility.Collapsed : Visibility.Visible;
        empty.SetText(available ? "No changes" : "Git unavailable", available ? "Your working tree is clean." : "Open a project with a Git repository.");
        if (!changed) { commitOpen = showsCompactDiff = false; inspectedFile = null; }
        LayoutReview();
    }

    public async Task LoadAsync(ThreadSession value)
    {
        await viewGate.WaitAsync();
        try
        {
            if (session?.Record.VeoId != value.Record.VeoId)
            {
                session = value; snapshot = null; inspectedFile = null; showsCompactDiff = false; ResetDiff(); commitMessage.Text = "";
                var recovery = await coordinator.Threads.ReadStateAsync(value.Record.VeoId, "lastGitRecovery");
                if (recovery is not null && JsonSerializer.Deserialize<GitRecoveryReceipt>(recovery) is { } receipt)
                    recoveries[value.Record.VeoId] = receipt;
                recover.IsEnabled = recoveries.ContainsKey(value.Record.VeoId);
            }
            await RefreshAsync();
        }
        catch (Exception error) { await PreserveFailureRecoveryAsync(error); ShowError(error); }
        finally { viewGate.Release(); }
    }
    private async Task RefreshAsync()
    {
        if (session is null) return;
        snapshot = null; commit.IsEnabled = false; ResetDiff();
        foreach (var button in mutations) button.IsEnabled = false;
        GitRepositorySnapshot result;
        try { result = await git.SnapshotAsync(session.Record.Cwd); }
        catch (NotGitRepositoryException)
        {
            UpdateReviewSurface(false, false); summary.Text = "Review"; changes.ItemsSource = Array.Empty<ChangeRow>(); diff.Text = "";
            diff.PlaceholderText = "This workspace has no Git repository."; notice.IsOpen = false; recover.IsEnabled = false;
            return;
        }
        UpdateReviewSurface(true, result.Files.Any(file => file.IsInWorkspace));
        snapshot = result; summary.Text = result.Branch ?? "Detached HEAD";
        diff.PlaceholderText = "Select a changed file to inspect its diff"; commit.IsEnabled = result.CanMutate;
        var files = result.Files.Where(f => f.IsInWorkspace).Select(f => new ChangeRow(f)).ToArray();
        changes.ItemsSource = files;
        inspectedFile = files.FirstOrDefault(row => row.File.Path == inspectedFile)?.File.Path ?? files.FirstOrDefault()?.File.Path;
        if (inspectedFile is not null) _ = RequestDiffAsync();
        foreach (var button in mutations) button.IsEnabled = result.CanMutate;
    }
    private string[] Selection() => changes.SelectedItems.Cast<ChangeRow>().Select(row => row.File.Path).ToArray();
    private void ResetDiff()
    {
        diffRequest++;
        displayedDiff = null;
        hunkActionsAllowed = false;
        hunks.ItemsSource = null;
        diff.Text = "";
        UpdateHunkActions();
    }
    private void UpdateHunkActions()
    {
        var hasHunk = displayedDiff is not null && hunks.SelectedItem is DiffHunk;
        hunkOptions.Visibility = commentOnLines.Visibility = hasHunk ? Visibility.Visible : Visibility.Collapsed;
        commentOnLines.IsEnabled = hasHunk;
        applyHunk.IsEnabled = hasHunk && hunkActionsAllowed
            && displayedDiff?.IgnoreWhitespace == false && snapshot?.CanMutate == true;
    }
    private async Task RequestDiffAsync()
    {
        ResetDiff();
        var request = diffRequest;
        await viewGate.WaitAsync();
        try
        {
            if (request != diffRequest || snapshot is not { } expected || session is not { } target
                || changes.Items.OfType<ChangeRow>().FirstOrDefault(file => file.File.Path == inspectedFile) is not { } row) return;
            var requested = new DisplayedDiff(target, row.File.Path, side.SelectedIndex == 1, whitespace.IsChecked == true);
            notice.IsOpen = false;
            var text = await git.DiffAsync(expected, requested.Path, requested.Staged, requested.IgnoreWhitespace);
            if (text.Length == 0 && row.File.IsUntracked && !requested.Staged)
            {
                var preview = await new WorkspaceFileService(expected.RootPath).ReadTextAsync(requested.Path);
                if (request == diffRequest) diff.ShowRawText(preview.Text);
                return;
            }
            if (request != diffRequest) return;
            var document = UnifiedDiff.Parse(text);
            diff.Text = text;
            displayedDiff = requested;
            hunkActionsAllowed = !document.IsNewFile && !document.IsDeletedFile && !document.IsRename && !document.IsBinary;
            hunks.ItemsSource = document.Hunks;
            hunks.SelectedIndex = document.Hunks.Count > 0 ? 0 : -1;
            applyHunk.Content = requested.Staged ? "Unstage hunk" : "Stage hunk";
            UpdateHunkActions();
        }
        catch (Exception error) { if (request == diffRequest) ShowError(error); }
        finally { viewGate.Release(); }
    }
    private async Task CommentOnLinesAsync()
    {
        if (displayedDiff is not { } shown || hunks.SelectedItem is not DiffHunk hunk) return;
        var context = new GitReviewComment(shown.Path, shown.Staged, shown.IgnoreWhitespace, hunk);
        var lines = new ListView
        {
            Header = hunk.Header,
            ItemsSource = context.Lines.Select(line => new CommentRow(line)).ToArray(),
            SelectionMode = ListViewSelectionMode.Multiple,
            IsMultiSelectCheckBoxEnabled = true,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            MaxHeight = 220,
            ItemContainerTransitions = new()
        };
        AutomationProperties.SetName(lines, "Select patch lines");
        ScrollViewer.SetHorizontalScrollBarVisibility(lines, ScrollBarVisibility.Auto);
        ScrollViewer.SetHorizontalScrollMode(lines, ScrollMode.Enabled);
        var comment = new TextBox
        {
            Header = "What should Codex change?",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 68,
            MaxHeight = 120
        };
        var content = new StackPanel { Spacing = 10 };
        content.Children.Add(new TextBlock { Text = context.Location, TextWrapping = TextWrapping.Wrap });
        content.Children.Add(lines);
        content.Children.Add(comment);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "Comment on lines", Content = content,
            PrimaryButtonText = "Add to draft", CloseButtonText = "Cancel", IsPrimaryButtonEnabled = false
        };
        void UpdateAddButton() => dialog.IsPrimaryButtonEnabled = lines.SelectedItems.Count > 0
            && !string.IsNullOrWhiteSpace(comment.Text);
        lines.SelectionChanged += (_, _) => UpdateAddButton();
        comment.TextChanged += (_, _) => UpdateAddButton();
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        await appendToDraft(shown.Session, context.FormatDraft(lines.SelectedItems.Cast<CommentRow>().Select(row => row.Line), comment.Text));
    }
    private async Task ApplyHunkAsync()
    {
        if (snapshot is null || displayedDiff is not { } shown || hunks.SelectedItem is not DiffHunk hunk) return;
        if (shown.IgnoreWhitespace) throw new InvalidOperationException("Show all whitespace before applying a hunk.");
        var result = await git.ApplyHunkAsync(snapshot, shown.Path, hunk.Index, hunk.Sha256, shown.Staged);
        snapshot = result.Snapshot; await RefreshAsync();
    }
    private async Task MutateAsync(Func<GitRepositorySnapshot, string[], Task<GitMutationResult>> mutation)
    {
        if (snapshot is null) return;
        var result = await mutation(snapshot, Selection()); snapshot = result.Snapshot; await RefreshAsync();
    }
    private async Task DiscardAsync()
    {
        if (snapshot is null || session is null) return;
        var paths = Selection(); if (paths.Length == 0) throw new InvalidOperationException("Select the files to discard.");
        if (!await ConfirmAsync("Discard unstaged changes?", $"Discard unstaged edits in {paths.Length} selected file(s)? Veo saves a local recovery bundle first. Staged changes are retained.", "Discard")) return;
        var result = await git.DiscardAsync(snapshot, paths);
        if (result.Recovery is { } receipt)
        {
            recoveries[session.Record.VeoId] = receipt; recover.IsEnabled = true;
            await coordinator.Threads.SaveStateAsync(session.Record.VeoId, "lastGitRecovery", JsonSerializer.Serialize(receipt));
        }
        snapshot = result.Snapshot; await RefreshAsync();
    }
    private async Task RecoverAsync()
    {
        if (session is null) return;
        if (!recoveries.TryGetValue(session.Record.VeoId, out var receipt))
        {
            var raw = await coordinator.Threads.ReadStateAsync(session.Record.VeoId, "lastGitRecovery");
            receipt = raw is null ? null : JsonSerializer.Deserialize<GitRecoveryReceipt>(raw);
        }
        if (receipt is null) throw new InvalidOperationException("This chat has no saved discard recovery.");
        if (!await ConfirmAsync("Restore discarded changes?", "Restore the saved file bytes and staging state? Veo refuses if the repository changed after the discard.", "Restore")) return;
        var result = await git.RestoreRecoveryAsync(receipt); snapshot = result.Snapshot;
        recoveries.Remove(session.Record.VeoId); recover.IsEnabled = false;
        await coordinator.Threads.SaveStateAsync(session.Record.VeoId, "lastGitRecovery", "null"); await RefreshAsync();
    }
    private async Task CommitAsync()
    {
        if (snapshot is null) return;
        if (string.IsNullOrWhiteSpace(commitMessage.Text)) throw new InvalidOperationException("Enter a commit message.");
        var selected = Selection(); if (selected.Length == 0) throw new InvalidOperationException("Select fully staged files to commit.");
        if (!await ConfirmAsync("Commit selected files?", $"Commit {selected.Length} selected fully staged file(s) on {snapshot.Branch}? Unrelated staged files remain staged.", "Commit")) return;
        var result = await git.CommitSelectedAsync(snapshot, selected, commitMessage.Text);
        snapshot = result.Snapshot; commitMessage.Text = ""; await RefreshAsync();
    }
    private async Task CreateBranchAsync()
    {
        if (snapshot is null) return;
        var name = await PromptAsync("Create branch", "New branch name"); if (name is null) return;
        snapshot = await git.CreateBranchAsync(snapshot, name); await RefreshAsync();
    }
    private AppBarButton Button(string label, Symbol symbol, Func<Task> action)
    { var button = new AppBarButton { Label = label, Icon = new SymbolIcon(symbol) }; button.Click += async (_, _) => await GuardAsync(action); return button; }
    private async Task GuardAsync(Func<Task> action)
    {
        if (!await viewGate.WaitAsync(0)) return; notice.IsOpen = false;
        try { await action(); }
        catch (Exception error) { await PreserveFailureRecoveryAsync(error); ShowError(error); }
        finally { viewGate.Release(); }
    }
    private void ShowError(Exception error) { notice.Severity = InfoBarSeverity.Error; notice.Title = "Git action failed"; notice.Message = error.Message; notice.IsOpen = true; }
    private async Task PreserveFailureRecoveryAsync(Exception error)
    {
        if (error is GitRecoveryOperationException failure && session is not null)
        {
            recoveries[session.Record.VeoId] = failure.Recovery; recover.IsEnabled = true;
            try { await coordinator.Threads.SaveStateAsync(session.Record.VeoId, "lastGitRecovery", JsonSerializer.Serialize(failure.Recovery)); }
            catch (Exception) { /* The error still displays the durable recovery bundle path. */ }
        }
    }
    private async Task<bool> ConfirmAsync(string title, string message, string primary)
    { var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = title, Content = message, PrimaryButtonText = primary, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }; return await dialog.ShowAsync() == ContentDialogResult.Primary; }
    private async Task<string?> PromptAsync(string title, string placeholder, string value = "")
    {
        var field = new TextBox { Text = value, PlaceholderText = placeholder, MinWidth = 280 };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = title, Content = field, PrimaryButtonText = "Continue", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        return await dialog.ShowAsync() == ContentDialogResult.Primary ? field.Text : null;
    }
    private static void Add(Grid grid, FrameworkElement child, int row) { Grid.SetRow(child, row); grid.Children.Add(child); }
}
