using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Protocol;

namespace Veo_Windows.Controls;

public sealed class CheckpointsPanel : UserControl
{
    readonly CheckpointCoordinator checkpoints;
    readonly ThreadSession session;
    readonly ListView rows = new() { MaxHeight = 280, ItemContainerTransitions = new() };
    readonly CheckBox confirm = new() { Content = "Restore the selected checkpoint’s files and staging" };
    readonly Button restore = new() { Content = "Restore files" };
    readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };

    public bool IsBusy { get; private set; }
    public bool FilesRestored { get; private set; }

    public CheckpointsPanel(CheckpointCoordinator checkpoints, ThreadSession session)
    {
        this.checkpoints = checkpoints;
        this.session = session;
        AutomationProperties.SetName(rows, "Saved workspace checkpoints");
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
        var capture = new Button { Content = "Save checkpoint" };
        capture.Click += async (_, _) => await RunAsync(async () =>
        {
            await checkpoints.CaptureManualAsync(session);
            await RefreshAsync();
            status.Text = "Checkpoint saved.";
        });
        restore.Click += async (_, _) => await RunAsync(RestoreAsync);
        rows.SelectionChanged += (_, _) => { confirm.IsChecked = false; ApplyEligibility(); };
        confirm.Checked += (_, _) => ApplyEligibility();
        confirm.Unchecked += (_, _) => ApplyEligibility();
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(capture);
        actions.Children.Add(restore);
        Content = new StackPanel
        {
            Spacing = 12,
            Children =
            {
                new TextBlock { Text = session.Record.Cwd, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
                new TextBlock
                {
                    Text = "Files and staging return to the selected checkpoint. Veo saves a recovery checkpoint first. Ignored files and conversation history stay in place.",
                    TextWrapping = TextWrapping.Wrap
                },
                rows, confirm, actions, status
            }
        };
        Loaded += async (_, _) => await RunAsync(RefreshAsync);
        ApplyEligibility();
    }

    async Task RefreshAsync()
    {
        var saved = await checkpoints.WorkspaceEntriesAsync(session);
        rows.ItemsSource = saved.Select(checkpoint => new Row(checkpoint)).ToArray();
        rows.Visibility = saved.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        confirm.Visibility = restore.Visibility = rows.Visibility;
        status.Text = checkpoints.Warning(session) ?? (saved.Count == 0 ? "No checkpoints saved for this workspace." : "");
        ApplyEligibility();
    }

    async Task RestoreAsync()
    {
        if (confirm.IsChecked != true || rows.SelectedItem is not Row row) return;
        confirm.IsChecked = false;
        try
        {
            await checkpoints.RestoreFilesAsync(session, row.Entry.Checkpoint);
            FilesRestored = true;
        }
        finally { await RefreshAsync(); }
        status.Text = "Files and staging restored. The previous state is listed as a recovery checkpoint.";
    }

    void ApplyEligibility()
    {
        confirm.IsEnabled = rows.SelectedItem is Row;
        restore.IsEnabled = confirm.IsEnabled && confirm.IsChecked == true;
    }

    async Task RunAsync(Func<Task> action)
    {
        if (IsBusy) return;
        IsBusy = true;
        IsEnabled = false;
        try { await action(); }
        catch (Exception error) { status.Text = DiagnosticRedactor.Redact(error.Message); }
        finally { IsBusy = false; IsEnabled = true; }
    }

    sealed record Row(TurnCheckpoint Entry)
    {
        public override string ToString() =>
            $"{(Entry.State switch { "recovery" => "Recovery checkpoint", "manual" => "Manual checkpoint", _ => "Before turn" })} · {Entry.Checkpoint.CreatedAt.ToLocalTime():g} · {Entry.Checkpoint.Branch ?? "Detached HEAD"}";
    }
}
