using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Protocol;

namespace Veo_Windows.Controls;

public sealed class ThreadSettingsPanel : StackPanel
{
    readonly ThreadSettingsCoordinator settings;
    readonly ThreadSession session;
    readonly Func<ComposerSnapshot> selection;
    readonly StackPanel status = new() { Spacing = 8 };
    readonly InfoBar notice = new() { IsClosable = true };
    readonly TextBox objective = new() { Header = "Goal objective", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 180 };
    readonly TextBox budget = new() { Header = "Token budget (optional)", PlaceholderText = "Blank preserves an existing goal's budget" };
    readonly ComboBox memory = new() { Header = "Thread memory", ItemsSource = new[] { "enabled", "disabled" }, PlaceholderText = "Select a memory mode" };
    bool busy;
    bool goalDraftLoaded;
    public ThreadSettingsPanel(ThreadSettingsCoordinator settings, ThreadSession session, Func<ComposerSnapshot> selection)
    {
        this.settings = settings; this.session = session; this.selection = selection; Spacing = 12;
        AutomationProperties.SetAutomationId(objective, "ThreadGoalObjective"); AutomationProperties.SetAutomationId(budget, "ThreadGoalBudget"); AutomationProperties.SetAutomationId(memory, "ThreadMemoryMode");
        Children.Add(status); Children.Add(notice); Children.Add(Text("Model, effort and speed selections are saved with the composer. Publishing live settings only affects later steps that capture them; already-started work and child sessions keep their captured settings. Context-window settings apply through session configuration."));
        Children.Add(Button("Apply composer selection to runtime", async () => await settings.ApplySelectionAsync(session, selection()), "ThreadApplySettings"));
        Children.Add(memory); var saveMemory = Button("Save memory mode", async () => { if (memory.SelectedItem is not string mode) throw new InvalidOperationException("Choose a memory mode."); await settings.SetMemoryModeAsync(session, mode); }, "ThreadSaveMemory"); saveMemory.IsEnabled = settings.Available("thread/memoryMode/set"); Children.Add(saveMemory);
        Children.Add(Text("A successful memory request records the runtime's acknowledgement. This CLI has no memory-mode readback method; Veo shows the last accepted value and does not silently reapply it on reconnect."));
        var goals = new StackPanel { Spacing = 8 }; goals.Children.Add(Text("Create a goal only when you want this chat to keep pursuing the written objective. Runtime goal state and measured usage are read back after changes.")); goals.Children.Add(objective); goals.Children.Add(budget);
        var saveGoal = Button("Set or update goal", async () =>
        {
            long? tokens = null; if (!string.IsNullOrWhiteSpace(budget.Text)) { if (!long.TryParse(budget.Text.Replace(",", ""), NumberStyles.None, CultureInfo.InvariantCulture, out var value) || value <= 0) throw new InvalidOperationException("Enter a positive whole token budget, or leave it blank."); tokens = value; }
            await settings.SetGoalAsync(session, objective.Text, tokens);
        }, "ThreadSetGoal"); saveGoal.IsEnabled = settings.Available("thread/goal/set"); goals.Children.Add(saveGoal);
        var commands = new CommandBar { DefaultLabelPosition = CommandBarDefaultLabelPosition.Right };
        foreach (var action in new[] { ("Pause", "paused"), ("Resume", "active"), ("Complete", "complete") })
        {
            var button = new AppBarButton { Label = action.Item1 }; button.Click += (_, _) => Run(async () => await settings.SetGoalStatusAsync(session, action.Item2)); commands.PrimaryCommands.Add(button);
        }
        var clear = new AppBarButton { Label = "Clear goal" }; clear.Click += (_, _) => Run(async () => { if (await new ContentDialog { Title = "Clear this goal?", Content = "This removes the runtime goal. It does not erase the conversation or cancel an already-running turn.", PrimaryButtonText = "Clear", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = XamlRoot }.ShowAsync() == ContentDialogResult.Primary) { await settings.ClearGoalAsync(session); objective.Text = ""; budget.Text = ""; } }); commands.SecondaryCommands.Add(clear); goals.Children.Add(commands); Children.Add(Section("Goal", goals));
        var personality = settings.PersonalitySupport(); var legacy = new StackPanel { Spacing = 6 }; legacy.Children.Add(Text(personality.Message));
        if (personality.Choices.Length > 0 && !personality.Deprecated)
        {
            var picker = new ComboBox { Header = "Personality", ItemsSource = personality.Choices, PlaceholderText = "Choose a runtime style" }; legacy.Children.Add(picker);
            legacy.Children.Add(Button("Apply personality for future turns", async () => { if (picker.SelectedItem is not string value) throw new InvalidOperationException("Choose a personality."); await settings.SetPersonalityAsync(session, value); }, "ThreadPersonality"));
        }
        Children.Add(Section("Personality", legacy)); Children.Add(Button("Refresh thread controls", RefreshAsync, "ThreadSettingsRefresh"));
        Loaded += (_, _) => { settings.Changed -= OnChanged; settings.Changed += OnChanged; Run(RefreshAsync); }; Unloaded += (_, _) => settings.Changed -= OnChanged;
    }
    async Task RefreshAsync() { await settings.LoadAsync(session); Render(); }
    void OnChanged() => DispatcherQueue.TryEnqueue(Render);
    void Render()
    {
        status.Children.Clear();
        if (session.Record.CodexThreadId is null) status.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Informational, Message = "This chat has no loaded runtime session. Submit its first message before using runtime goals or memory controls." });
        if (settings.Result(session) is { } result) status.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = result.Status == "failed" ? InfoBarSeverity.Error : result.LivePublished ? InfoBarSeverity.Success : InfoBarSeverity.Informational, Title = result.LivePublished ? "Live settings published" : "Thread settings", Message = result.Message });
        if (settings.MemoryMode(session) is { } receipt) { status.Children.Add(Text("Last accepted memory mode: " + receipt.Mode + "\n" + receipt.AcceptedAt.ToLocalTime().ToString("g"))); if (memory.SelectedItem is null) memory.SelectedItem = receipt.Mode; }
        if (settings.Goal(session) is { } goal)
        {
            status.Children.Add(Text("Goal: " + goal.Status + "\n" + goal.Objective + $"\n{goal.TokensUsed:N0} tokens used · {TimeSpan.FromSeconds(Math.Max(0, goal.TimeUsedSeconds)):g}" + (goal.TokenBudget is { } tokens ? $" · budget {tokens:N0}" : " · no token budget")));
            if (!goalDraftLoaded) { objective.Text = goal.Objective; budget.Text = goal.TokenBudget?.ToString(CultureInfo.InvariantCulture) ?? ""; goalDraftLoaded = true; }
        }
    }
    Button Button(string title, Func<Task> action, string id) { var button = new Button { Content = title }; AutomationProperties.SetAutomationId(button, id); button.Click += (_, _) => Run(action); return button; }
    async void Run(Func<Task> action) { if (busy) return; busy = true; try { notice.IsOpen = false; await action(); Render(); } catch (Exception ex) { notice.Message = DiagnosticRedactor.Redact(ex.Message); notice.Severity = InfoBarSeverity.Error; notice.IsOpen = true; } finally { busy = false; } }
    static TextBlock Text(string value) => new() { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    static Expander Section(string title, object content) => new() { Header = title, Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
}
