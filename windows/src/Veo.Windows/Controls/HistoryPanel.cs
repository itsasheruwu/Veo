using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Veo.Core;
using Veo.Infrastructure.Git;

namespace Veo_Windows.Controls;

public sealed class HistoryPanel : UserControl
{
    readonly WorkspaceCoordinator workspace; readonly HistoryCoordinator history; readonly ThreadCatalogCoordinator catalog;
    readonly Func<ThreadSession?> selected; readonly Func<ThreadSession, Task>? openFork; readonly Action<string>? focusItem;
    readonly Func<ThreadSession, string, Task<WorkspaceCheckpoint?>>? checkpoint;
    readonly StackPanel body = new() { Spacing = 10 }; readonly ListView rows = new() { Height = 340, ItemContainerTransitions = new() };
    readonly ComboBox mode = new() { Header = "History source", ItemsSource = Enum.GetValues<HistoryMode>(), SelectedItem = HistoryMode.Automatic };
    readonly CheckBox confirmation = new() { Content = "Remove the selected turn and all later turns from this runtime chat" };
    readonly CheckBox restoreFiles = new() { Content = "Restore this chat's checkpoint files and index too" };
    readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap }; readonly TextBlock context = new() { TextWrapping = TextWrapping.Wrap };
    ThreadSession? session; bool busy;
    public HistoryPanel(WorkspaceCoordinator workspace, HistoryCoordinator history, ThreadCatalogCoordinator catalog, Func<ThreadSession?> selected,
        Func<ThreadSession, Task>? openFork = null, Action<string>? focusItem = null, Func<ThreadSession, string, Task<WorkspaceCheckpoint?>>? checkpoint = null)
    {
        this.workspace = workspace; this.history = history; this.catalog = catalog; this.selected = selected; this.openFork = openFork; this.focusItem = focusItem; this.checkpoint = checkpoint;
        rows.ItemTemplate = (DataTemplate)XamlReader.Load("""<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><StackPanel Spacing="2"><TextBlock Text="{Binding Label}" FontWeight="SemiBold"/><TextBlock Text="{Binding Preview}" TextWrapping="Wrap" MaxLines="4"/></StackPanel></DataTemplate>""");
        AutomationProperties.SetName(rows, "Messages and turn boundaries"); body.Children.Add(context); body.Children.Add(mode);
        Add("Refresh history", async () => { var active = Current(); await history.LoadAsync(active, preferred: (HistoryMode)(mode.SelectedItem ?? HistoryMode.Automatic)); Render(active); });
        Add("Load more history", async () => { var active = Current(); var page = await history.LoadAsync(active, true); status.Text = page.NextCursor is null ? "All pages from this history source are loaded." : "More history is available."; Render(active); });
        Add("Reconcile uncertain history change", async () => { var active = Current(); await history.ReconcilePendingRevertAsync(active); Render(active); status.Text = "Runtime history confirms the prior change. Draft and file restoration were not repeated; inspect them before continuing."; });
        body.Children.Add(rows); Add("Go to selected message", () => { if (rows.SelectedItem is Row row) focusItem?.Invoke(row.Item.Id); return Task.CompletedTask; });
        Add("Fork including selected turn", () => ForkAsync(false)); Add("Fork before selected turn", () => ForkAsync(true));
        body.Children.Add(confirmation); body.Children.Add(restoreFiles); restoreFiles.IsEnabled = checkpoint is not null;
        Add("Revert before selected turn", () => RevertAsync(false)); Add("Edit user message from here", () => RevertAsync(true));
        body.Children.Add(status); Content = body; Loaded += async (_, _) => { if (selected() is { } active) await LoadAsync(active); };
    }
    public Task LoadAsync(ThreadSession active) { session = active; confirmation.IsChecked = false; restoreFiles.IsChecked = false; Render(active); return Task.CompletedTask; }
    ThreadSession Current() => session ?? selected() ?? throw new InvalidOperationException("Select a chat first.");
    void Render(ThreadSession active)
    {
        session = active; context.Text = active.Record.Title + "\n" + active.Record.Cwd;
        rows.ItemsSource = active.Timeline.Items.Select(item => new Row(item, item.Kind + " · " + (item.TurnId ?? "no turn boundary"), item.Text)).ToArray();
    }
    async Task ForkAsync(bool before)
    {
        var active = Current(); var row = rows.SelectedItem as Row ?? throw new InvalidOperationException("Select a message with a turn boundary.");
        var turn = row.Item.TurnId ?? throw new InvalidOperationException("This item has no fork boundary.");
        var fork = await catalog.ForkAsync(active, before ? null : turn, before ? turn : null); if (openFork is not null) await openFork(fork); status.Text = "Created a local fork with its own runtime identity.";
    }
    async Task RevertAsync(bool edit)
    {
        if (confirmation.IsChecked != true) throw new InvalidOperationException("Select the history removal confirmation first.");
        var active = Current(); var row = rows.SelectedItem as Row ?? throw new InvalidOperationException("Select a message first.");
        var turn = row.Item.TurnId ?? throw new InvalidOperationException("This message has no history boundary.");
        if (edit && row.Item.Kind != "userMessage") throw new InvalidOperationException("Select the user message to edit.");
        WorkspaceCheckpoint? restore = null;
        if (restoreFiles.IsChecked == true) restore = checkpoint is null ? throw new InvalidOperationException("No checkpoint resolver is available.") : await checkpoint(active, turn) ?? throw new InvalidOperationException("No checkpoint is available at this turn boundary.");
        confirmation.IsChecked = false; var result = await history.RevertAsync(active, turn, edit, restore);
        status.Text = result.Warning ?? (edit ? "History reverted; the original input is appended to this chat's draft." : "History reverted before the selected turn."); Render(active); workspace.NotifyChanged();
    }
    void Add(string label, Func<Task> action)
    {
        var button = new Button { Content = label }; button.Click += async (_, _) =>
        {
            if (busy) return; busy = true; IsEnabled = false;
            try { await action(); } catch (Exception error) { status.Text = error.Message; }
            finally { IsEnabled = true; busy = false; }
        }; body.Children.Add(button);
    }
    public sealed record Row(TimelineItem Item, string Label, string Preview);
}
