using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Veo.Infrastructure.Projects;

namespace Veo_Windows.Controls;

public sealed class ProjectsPanel : UserControl
{
    readonly WorkspaceCoordinator workspace; readonly ProjectPreferencesService preferences; readonly Func<ThreadSession?> selected;
    readonly Func<string, ProjectAction, Task>? runAction; readonly StackPanel body = new() { Spacing = 18 };
    readonly StackPanel projectContent = new() { Spacing = 18, Visibility = Visibility.Collapsed };
    readonly TextBlock emptyProjects = SettingsGroup.Note("Open a project to configure its actions and defaults.");
    readonly ComboBox projects = new() { MinWidth = 180, MaxWidth = 280, HorizontalAlignment = HorizontalAlignment.Left };
    readonly ComboBox models = new() { Width = 176 };
    readonly ComboBox effort = new() { Width = 176 };
    readonly ToggleSwitch worktree = new() { OnContent = null, OffContent = null, MinWidth = 0 };
    readonly CheckBox checkpoints = new() { IsThreeState = true, MinWidth = 0 };
    readonly ListView actions = new() { MaxHeight = 200, ItemContainerTransitions = new() };
    readonly TextBox name = new() { Header = "Action name" };
    readonly TextBox command = new()
    {
        Header = "PowerShell command", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
        MinHeight = 88, MaxHeight = 160, FontFamily = new FontFamily("Cascadia Mono")
    };
    readonly CheckBox setup = new() { Content = "Offer this action when creating a worktree" }; readonly CheckBox consent = new() { Content = "Run this saved command in a new terminal in the selected checkout" };
    readonly TextBlock context = SettingsGroup.Note("");
    readonly TextBlock noActions = SettingsGroup.Note("No saved actions for this checkout.");
    readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    readonly FrameworkElement actionEditor;
    ProjectConfiguration config = new(); string? actionId; bool loading; bool busy;
    public ProjectsPanel(WorkspaceCoordinator workspace, ProjectPreferencesService preferences, Func<ThreadSession?> selected, Func<string, ProjectAction, Task>? runAction = null)
    {
        this.workspace = workspace; this.preferences = preferences; this.selected = selected; this.runAction = runAction;
        AutomationProperties.SetName(projects, "Project checkout");
        AutomationProperties.SetAutomationId(projects, "ProjectSettingsCheckout");
        AutomationProperties.SetName(models, "New chat model");
        AutomationProperties.SetName(effort, "New chat reasoning effort");
        AutomationProperties.SetName(worktree, "Offer a new worktree for new chats");
        AutomationProperties.SetName(checkpoints, "Save workspace checkpoints before turns");
        AutomationProperties.SetHelpText(checkpoints, "Indeterminate uses the default, enabled.");
        AutomationProperties.SetName(actions, "Saved project actions");
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
        projects.DisplayMemberPath = nameof(ProjectRow.Name);
        context.IsTextSelectionEnabled = true;
        context.FontFamily = new FontFamily("Cascadia Mono");
        actions.ItemTemplate = (DataTemplate)XamlReader.Load("""
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
              <StackPanel Spacing="3" Padding="0,6">
                <TextBlock Text="{Binding Name}" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                <TextBlock Text="{Binding Command}" FontSize="11.5" FontFamily="Cascadia Mono" Foreground="{ThemeResource TextFillColorSecondaryBrush}" TextWrapping="Wrap" TextTrimming="CharacterEllipsis" MaxLines="2"/>
              </StackPanel>
            </DataTemplate>
            """);

        var checkout = new StackPanel { Spacing = 6, Children = { projects, context } };
        var defaults = new StackPanel();
        defaults.Children.Add(DefaultRow("Model", "Choose the model for new project chats.", models));
        defaults.Children.Add(SettingsGroup.Divider(16));
        defaults.Children.Add(DefaultRow("Reasoning", "Use the selected model’s default or choose an effort.", effort));
        defaults.Children.Add(SettingsGroup.Divider(16));
        defaults.Children.Add(DefaultRow("New worktree", "Offer a worktree when starting a project chat.", worktree));
        defaults.Children.Add(SettingsGroup.Divider(16));
        defaults.Children.Add(DefaultRow("Workspace checkpoints", "Save tracked and nonignored files before turns. The default is enabled.", checkpoints));
        defaults.Children.Add(SettingsGroup.Divider(16));
        defaults.Children.Add(new StackPanel
        {
            Margin = new Thickness(16, 10, 16, 12), Spacing = 8,
            Children =
            {
                SettingsGroup.Note("Defaults apply to new chats. Existing chats keep their selections and access."),
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 8,
                    Children =
                    {
                        CreateButton("Save defaults", SaveDefaultsAsync),
                        CreateButton("Reset defaults", async () => { await preferences.ResetDefaultsAsync(Path()); await LoadProjectAsync(); })
                    }
                }
            }
        });

        var actionList = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                actions, noActions,
                CreateButton("Add action…", () =>
                {
                    actions.SelectedItem = null;
                    EditAction(null);
                    DispatcherQueue.TryEnqueue(() =>
                    {
                        name.StartBringIntoView();
                        name.Focus(FocusState.Programmatic);
                    });
                    return Task.CompletedTask;
                }),
                SettingsGroup.Note("Actions run in a new terminal in this checkout. Setup actions are offered when creating a worktree.")
            }
        };
        var editor = new StackPanel
        {
            Spacing = 10,
            Children =
            {
                name, command, setup,
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 8,
                    Children =
                    {
                        CreateButton("Save action", SaveActionAsync),
                        CreateButton("Delete action", async () =>
                        {
                            if (actionId is null) return;
                            config = config with { Actions = (config.Actions ?? []).Where(x => x.Id != actionId).ToArray() };
                            await preferences.SetAsync(Path(), config); await LoadProjectAsync();
                        })
                    }
                },
                SettingsGroup.Divider(0), consent
            }
        };
        editor.Children.Add(CreateButton("Run saved action", async () =>
        {
            if (runAction is null) throw new InvalidOperationException("This window has no project terminal action handler.");
            if (consent.IsChecked != true) throw new InvalidOperationException("Confirm the explicit terminal action first.");
            var action = (config.Actions ?? []).FirstOrDefault(x => x.Id == actionId) ?? throw new InvalidOperationException("Select a saved action first.");
            consent.IsChecked = false; await runAction(Path(), action); status.Text = "Opened a dedicated project terminal. Agent CLI input follows Terminal consent settings.";
        }));
        projectContent.Children.Add(checkout);
        projectContent.Children.Add(SettingsGroup.Section("New chat defaults", defaults, new Thickness(0)));
        projectContent.Children.Add(SettingsGroup.Section("Actions", actionList, new Thickness(16)));
        actionEditor = SettingsGroup.Section("Action editor", editor, new Thickness(16));
        actionEditor.Visibility = Visibility.Collapsed;
        projectContent.Children.Add(actionEditor);
        body.Children.Add(projectContent);
        body.Children.Add(emptyProjects);
        body.Children.Add(status);
        Content = body;
        projects.SelectionChanged += async (_, _) => { if (!loading) await RunAsync(LoadProjectAsync); };
        models.SelectionChanged += (_, _) => { if (!loading) FillEfforts(null); };
        actions.SelectionChanged += (_, _) => { if (actions.SelectedItem is ProjectAction action) EditAction(action); };
        command.TextChanged += (_, _) => consent.IsChecked = false; name.TextChanged += (_, _) => consent.IsChecked = false;
        Loaded += async (_, _) => await RunAsync(RefreshAsync);
    }
    public async Task RefreshAsync()
    {
        loading = true;
        try
        {
            var records = (await workspace.Threads.ListThreadsAsync(false, limit: 100000)).Concat(await workspace.Threads.ListThreadsAsync(true, limit: 100000));
            var paths = records.Where(x => x.WorkspaceKind == "project").Select(x => x.Cwd).Concat(await preferences.ConfiguredPathsAsync()).Where(Directory.Exists).Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToArray();
            var rows = paths.Select(path => new ProjectRow(path, System.IO.Path.GetFileName(System.IO.Path.TrimEndingDirectorySeparator(path)) is { Length: > 0 } projectName ? projectName : path)).ToArray();
            var activePath = selected()?.Record.Cwd;
            projects.ItemsSource = rows;
            projects.SelectedItem = rows.FirstOrDefault(row => row.Path.Equals(activePath, StringComparison.OrdinalIgnoreCase)) ?? rows.FirstOrDefault();
            projectContent.Visibility = rows.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            emptyProjects.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        finally { loading = false; }
        if (projects.SelectedItem is not null) await LoadProjectAsync();
    }
    async Task LoadProjectAsync()
    {
        loading = true;
        try
        {
            var path = Path(); config = await preferences.ConfigurationAsync(path);
            var projectPath = await preferences.ProjectPathAsync(path);
            context.Text = path.Equals(projectPath, StringComparison.OrdinalIgnoreCase) ? path : path + "\nSettings project: " + projectPath;
            var available = new List<ModelRow> { new(null, "Use global default") };
            available.AddRange(workspace.Models
                .Where(model => !ModelPickerCatalog.IsStandaloneDaybreakAlias(model.Id)
                    && !ModelPickerCatalog.IsStandaloneDaybreakAlias(model.Name))
                .Select(model => new ModelRow(model.Id, ModelPickerCatalog.FormatName(model.Name))));
            if (config.ModelId is { } missing && available.All(model => model.Id != missing)
                && !ModelPickerCatalog.IsStandaloneDaybreakAlias(missing))
                available.Add(new(missing, ModelPickerCatalog.FormatName(missing) + " (currently unavailable)"));
            models.ItemsSource = available; models.DisplayMemberPath = "Name"; models.SelectedItem = available.FirstOrDefault(x => x.Id == config.ModelId); FillEfforts(config.ReasoningEffort);
            worktree.IsOn = config.UsesWorktree; checkpoints.IsChecked = config.CheckpointsEnabled;
            var savedActions = config.Actions ?? [];
            actions.ItemsSource = savedActions;
            actions.Visibility = savedActions.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            noActions.Visibility = savedActions.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            actionId = null; consent.IsChecked = false; actionEditor.Visibility = Visibility.Collapsed;
        }
        finally { loading = false; }
    }
    void FillEfforts(string? saved)
    {
        var modelId = (models.SelectedItem as ModelRow)?.Id; var values = new[] { "Use model default" }.Concat(workspace.Models.FirstOrDefault(x => x.Id == modelId)?.Efforts ?? []).ToList();
        if (saved is not null && !values.Contains(saved)) values.Add(saved); effort.ItemsSource = values; effort.SelectedItem = saved ?? values[0]; effort.IsEnabled = modelId is not null;
    }
    void EditAction(ProjectAction? action)
    {
        actionId = action?.Id;
        name.Text = action?.Name ?? "";
        command.Text = action?.Command ?? "";
        setup.IsChecked = action?.OfferOnWorktreeCreate ?? false;
        consent.IsChecked = false;
        actionEditor.Visibility = Visibility.Visible;
    }
    async Task SaveDefaultsAsync()
    {
        config = config with { ModelId = models.SelectedItem is ModelRow model ? model.Id : config.ModelId, ReasoningEffort = effort.SelectedItem is string value && value != "Use model default" ? value : null, UsesWorktree = worktree.IsOn, CheckpointsEnabled = checkpoints.IsChecked };
        await preferences.SetAsync(Path(), config); status.Text = "Project defaults saved. Existing chat selections were kept.";
    }
    async Task SaveActionAsync()
    {
        var action = new ProjectAction(actionId ?? Guid.NewGuid().ToString("N"), name.Text.Trim(), command.Text, setup.IsChecked == true);
        var actions = (config.Actions ?? []).ToList(); var at = actions.FindIndex(x => x.Id == action.Id); if (at < 0) actions.Add(action); else actions[at] = action;
        config = config with { Actions = actions.ToArray() }; await preferences.SetAsync(Path(), config); await LoadProjectAsync(); status.Text = "Project action saved.";
    }
    string Path() => (projects.SelectedItem as ProjectRow)?.Path ?? throw new InvalidOperationException("Select an available project checkout first.");
    Button CreateButton(string title, Func<Task> action)
    {
        var button = new Button { Content = title };
        button.Click += async (_, _) => await RunAsync(action);
        return button;
    }
    static Grid DefaultRow(string title, string detail, Control trailing)
    {
        var row = new Grid { Padding = new Thickness(16, 10, 16, 10), MinHeight = 62, ColumnSpacing = 14 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(new StackPanel
        {
            Spacing = 3, VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                new TextBlock { Text = title, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap },
                SettingsGroup.Note(detail)
            }
        });
        trailing.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(trailing, 1);
        row.Children.Add(trailing);
        return row;
    }
    async Task RunAsync(Func<Task> action) { if (busy) return; busy = true; IsEnabled = false; try { await action(); } catch (Exception error) { status.Text = Veo.Protocol.DiagnosticRedactor.Redact(error.Message); } finally { busy = false; IsEnabled = true; } }
    public sealed record ProjectRow(string Path, string Name);
    public sealed record ModelRow(string? Id, string Name);
}

internal static class SettingsGroup
{
    public static StackPanel Section(string title, UIElement content, Thickness padding)
    {
        var heading = Note(title);
        heading.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        heading.Margin = new Thickness(2, 0, 0, 0);
        AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level2);
        var card = (Border)XamlReader.Load("""
            <Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Background="{ThemeResource SubtleFillColorSecondaryBrush}" BorderBrush="{ThemeResource DividerStrokeColorDefaultBrush}" BorderThickness="1" CornerRadius="12"/>
            """);
        card.Padding = padding;
        card.Child = content;
        return new StackPanel { Spacing = 8, Children = { heading, card } };
    }

    public static TextBlock Note(string text)
    {
        var note = (TextBlock)XamlReader.Load("""
            <TextBlock xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" FontSize="11.5" Foreground="{ThemeResource TextFillColorSecondaryBrush}" TextWrapping="Wrap"/>
            """);
        note.Text = text;
        return note;
    }

    public static Border Divider(double inset)
    {
        var divider = (Border)XamlReader.Load("""
            <Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Height="1" Background="{ThemeResource DividerStrokeColorDefaultBrush}" IsHitTestVisible="False"/>
            """);
        divider.Margin = new Thickness(inset, 0, inset, 0);
        return divider;
    }
}
