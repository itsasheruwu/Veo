using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media.Animation;
using Veo.Core;

namespace Veo_Windows.Controls;

public sealed class QueuePanel : UserControl
{
    readonly WorkspaceCoordinator workspace; readonly QueueCoordinator queue; readonly Func<ThreadSession?> selected;
    readonly StackPanel body = new() { Spacing = 10 }; readonly ObservableCollection<Row> items = [];
    readonly ListView list = new()
    {
        Height = 240, CanReorderItems = true, AllowDrop = true,
        ItemContainerTransitions = new() { new ReorderThemeTransition() }
    };
    readonly TextBox text = new() { Header = "Queued input", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 180 };
    readonly TextBox attachments = new() { Header = "Local image attachment paths, one per line", AcceptsReturn = true, MaxHeight = 100 };
    readonly TextBlock captured = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }; readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    readonly TextBox serverOnly = new() { Header = "Server-only input (settings unavailable; review in Codex)", IsReadOnly = true, AcceptsReturn = true, MaxHeight = 170 };
    ThreadSession? session; bool busy;
    public QueuePanel(WorkspaceCoordinator workspace, QueueCoordinator queue, Func<ThreadSession?> selected)
    {
        this.workspace = workspace; this.queue = queue; this.selected = selected;
        list.ItemsSource = items; list.ItemTemplate = (DataTemplate)XamlReader.Load("""<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><StackPanel><TextBlock Text="{Binding Text}" TextWrapping="Wrap" MaxLines="3"/><TextBlock Text="{Binding Detail}" Foreground="{ThemeResource TextFillColorSecondaryBrush}" FontSize="12"/></StackPanel></DataTemplate>""");
        AutomationProperties.SetName(list, "Queued frozen prompts"); body.Children.Add(list); Add("Refresh queue identities", async () => await LoadAsync(Current()));
        Add("Start next queued prompt", async () => { await workspace.DispatchNextQueuedAsync(Current()); await LoadAsync(Current()); });
        Add("Move selected earlier", () => MoveAsync(-1)); Add("Move selected later", () => MoveAsync(1));
        body.Children.Add(captured); body.Children.Add(text); body.Children.Add(attachments);
        Add("Save queued input edits", async () => { var row = Selected(); await queue.EditAsync(Current(), row.Payload.ClientId, text.Text, Paths()); await LoadAsync(Current()); });
        Add("Remove selected queued prompt", async () => { await queue.RemoveAsync(Current(), Selected().Payload.ClientId); await LoadAsync(Current()); });
        Add("Steer active turn with selected input", async () => { var row = Selected(); await queue.EditAsync(Current(), row.Payload.ClientId, text.Text, Paths()); var payload = Current().Queue.First(x => x.ClientId == row.Payload.ClientId); await queue.SteerAsync(Current(), payload); await LoadAsync(Current()); });
        body.Children.Add(serverOnly); body.Children.Add(status); Content = body;
        list.SelectionChanged += (_, _) => { if (list.SelectedItem is Row row) { text.Text = row.Payload.Text; attachments.Text = string.Join(Environment.NewLine, row.Payload.Attachments); captured.Text = row.Detail + "\nClient identity: " + row.Payload.ClientId; } };
        list.DragItemsCompleted += async (_, _) => await RunAsync(async () => { await queue.ReorderAsync(Current(), items.Select(x => x.Payload.ClientId).ToArray()); await LoadAsync(Current()); });
        Loaded += async (_, _) => { if (selected() is { } active) await RunAsync(() => LoadAsync(active)); };
    }
    public async Task LoadAsync(ThreadSession active)
    {
        session = active; var view = await queue.LoadAsync(active); items.Clear();
        foreach (var payload in view.Local) items.Add(new(payload, payload.Text, $"{payload.Model ?? "runtime default"} · {payload.Effort ?? "default effort"} · {payload.Access} · {payload.Mode} · {payload.ContextTokens?.ToString() ?? "default"} context · {view.Bindings.FirstOrDefault(x => x.ClientId == payload.ClientId)?.State ?? "local"}"));
        serverOnly.Text = string.Join("\n\n", view.ServerOnly.Select(x => x.GetRawText())); status.Text = view.Warning ?? (items.Count == 0 ? "No queued prompts." : "Settings were captured when each prompt was queued.");
    }
    ThreadSession Current() => session ?? selected() ?? throw new InvalidOperationException("Select a chat first.");
    Row Selected() => list.SelectedItem as Row ?? throw new InvalidOperationException("Select a queued prompt.");
    string[] Paths() => attachments.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    async Task MoveAsync(int delta)
    {
        var row = Selected(); var at = items.IndexOf(row); var target = at + delta; if (target < 0 || target >= items.Count) return;
        items.Move(at, target); await queue.ReorderAsync(Current(), items.Select(x => x.Payload.ClientId).ToArray()); await LoadAsync(Current());
    }
    void Add(string label, Func<Task> action) { var button = new Button { Content = label }; button.Click += async (_, _) => await RunAsync(action); body.Children.Add(button); }
    async Task RunAsync(Func<Task> action)
    {
        if (busy) return; busy = true; IsEnabled = false;
        try { await action(); } catch (Exception error) { status.Text = error.Message; }
        finally { IsEnabled = true; busy = false; }
    }
    public sealed record Row(ComposerSnapshot Payload, string Text, string Detail);
}
