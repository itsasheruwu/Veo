using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Veo.Core;
using Veo.Infrastructure.Git;
using Veo.Infrastructure.Projects;

namespace Veo_Windows.Controls;

public sealed class WorktreesPanel : UserControl
{
    readonly WorktreeCoordinator worktrees; readonly string projectPath; readonly Action<ThreadSession, ProjectAction?> open;
    readonly StackPanel body = new() { Spacing = 10 }; readonly ListView existing = new() { MaxHeight = 180, ItemContainerTransitions = new() };
    readonly TextBox branch = new() { Header = "New branch", PlaceholderText = "codex/task-1" }; readonly TextBox destination = new() { Header = "New absolute worktree directory" };
    readonly ComboBox basis = new() { Header = "Start from commit or branch", HorizontalAlignment = HorizontalAlignment.Stretch };
    readonly CheckBox setup = new() { Content = "Run the listed saved project setup actions in a new terminal" }; readonly TextBlock setupNames = new() { TextWrapping = TextWrapping.Wrap };
    readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap }; WorktreeContext? context; bool destinationEdited; bool refreshing;
    public bool IsBusy { get; private set; }
    public WorktreesPanel(WorktreeCoordinator worktrees, string projectPath, Action<ThreadSession, ProjectAction?> open)
    {
        this.worktrees = worktrees; this.projectPath = projectPath; this.open = open;
        existing.ItemTemplate = (DataTemplate)XamlReader.Load("""<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><StackPanel><TextBlock Text="{Binding Branch}" FontWeight="SemiBold"/><TextBlock Text="{Binding Path}" TextWrapping="Wrap" FontSize="12"/></StackPanel></DataTemplate>""");
        AutomationProperties.SetName(existing, "Existing worktrees");
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
        body.Children.Add(new TextBlock { Text = projectPath, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        Button("Refresh worktrees", RefreshAsync); body.Children.Add(existing); Button("Open selected worktree in a new chat", ReuseAsync);
        body.Children.Add(branch); body.Children.Add(basis); body.Children.Add(destination); Button("Use suggested directory", () => { destinationEdited = false; SuggestDestination(); return Task.CompletedTask; });
        body.Children.Add(setup); body.Children.Add(setupNames); Button("Create worktree and open new chat", CreateAsync); body.Children.Add(status); Content = body;
        branch.TextChanged += (_, _) => { if (!destinationEdited) SuggestDestination(); };
        destination.TextChanged += (_, _) => { if (!refreshing) destinationEdited = true; }; Loaded += async (_, _) => await RunAsync(RefreshAsync);
    }
    async Task RefreshAsync()
    {
        context = null;
        existing.ItemsSource = null;
        context = await worktrees.InspectAsync(projectPath);
        existing.ItemsSource = context.Worktrees.Where(x => !x.IsBare && Directory.Exists(x.Path)).ToArray();
        existing.SelectedItem = existing.Items.OfType<GitWorktree>().FirstOrDefault(x => x.Path.Equals(context.Snapshot.RootPath, StringComparison.OrdinalIgnoreCase));
        basis.ItemsSource = new[] { "HEAD" }.Concat(context.Bases).Distinct(StringComparer.Ordinal).ToArray(); basis.SelectedItem = "HEAD"; branch.Text = WorktreeCoordinator.SuggestedBranch(context); destinationEdited = false; SuggestDestination();
        var names = (context.Configuration.Actions ?? []).Where(x => x.OfferOnWorktreeCreate).Select(x => x.Name).ToArray();
        setupNames.Text = string.Join(", ", names);
        setup.Visibility = setupNames.Visibility = names.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        setup.IsChecked = false;
        status.Text = "";
    }
    void SuggestDestination()
    {
        if (context is null) return; refreshing = true;
        try { destination.Text = WorktreeCoordinator.SuggestedDestination(context.Snapshot.RootPath, branch.Text); } catch (ArgumentException error) { status.Text = error.Message; }
        finally { refreshing = false; }
    }
    async Task ReuseAsync()
    {
        if (context is null || existing.SelectedItem is not GitWorktree tree) throw new InvalidOperationException("Choose a repository worktree first.");
        open(await worktrees.ReuseAsync(context.Snapshot, tree.Path), null);
    }
    async Task CreateAsync()
    {
        if (context is null) throw new InvalidOperationException("Refresh the repository first.");
        var setupAction = setup.IsChecked == true ? WorktreeCoordinator.SetupAction(context.Configuration) : null;
        var created = await worktrees.CreateAsync(context.Snapshot, branch.Text.Trim(), destination.Text.Trim(), basis.SelectedItem as string ?? "HEAD");
        open(created, setupAction);
    }
    void Button(string title, Func<Task> action) { var button = new Button { Content = title }; button.Click += async (_, _) => await RunAsync(action); body.Children.Add(button); }
    async Task RunAsync(Func<Task> action) { if (IsBusy) return; IsBusy = true; IsEnabled = false; try { await action(); } catch (Exception error) { status.Text = Veo.Protocol.DiagnosticRedactor.Redact(error.Message); } finally { IsEnabled = true; IsBusy = false; } }
}
