using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Protocol;

namespace Veo_Windows.Controls;

public sealed class RuntimeManagementPanel : StackPanel
{
    readonly RuntimeManagementCoordinator runtime;
    readonly ThreadSession? session;
    readonly IntegrationContext context;
    readonly StackPanel body = new() { Spacing = 10 };
    readonly InfoBar notice = new() { IsClosable = true };
    readonly ProgressBar progress = new() { IsIndeterminate = true, Visibility = Visibility.Collapsed };
    public RuntimeManagementPanel(RuntimeManagementCoordinator runtime, ThreadSession? session)
    {
        this.runtime = runtime; this.session = session; context = IntegrationContext.For(session); Spacing = 12;
        var refresh = new Button { Content = "Refresh runtime configuration" }; AutomationProperties.SetAutomationId(refresh, "RuntimeManagementRefresh"); refresh.Click += (_, _) => Run(RefreshAsync);
        Children.Add(refresh); Children.Add(progress); Children.Add(notice); Children.Add(body);
        Loaded += (_, _) => Run(RefreshAsync);
    }
    async Task RefreshAsync()
    {
        progress.Visibility = Visibility.Visible;
        try
        {
            var state = await runtime.RefreshAsync(context); if (session is not null) await runtime.LoadApprovalReviewsAsync(session); Render(state);
        }
        finally { progress.Visibility = Visibility.Collapsed; }
    }
    void Render(RuntimeConfigSnapshot state)
    {
        body.Children.Clear();
        body.Children.Add(Text("These settings belong to the local Codex CLI and can affect other local clients. Saved values apply to new turns or sessions; active work keeps its current settings."));
        foreach (var issue in state.Issues) body.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Title = issue.Unavailable ? "Runtime feature unavailable" : "Runtime request failed", Message = issue.Method + ": " + issue.Message });
        var sandbox = new StackPanel { Spacing = 8 }; sandbox.Children.Add(Text("Windows sandbox: " + runtime.WindowsSandboxStatus));
        if (runtime.WindowsSandboxError is { } sandboxError) sandbox.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Message = sandboxError });
        var readiness = new Button { Content = "Check sandbox readiness" }; readiness.Click += (_, _) => Run(async () => { await runtime.RefreshWindowsSandboxAsync(); await RefreshAsync(); }); sandbox.Children.Add(readiness);
        foreach (var mode in new[] { ("Repair without elevation", "unelevated"), ("Repair with Windows administrator approval", "elevated") })
        {
            var button = new Button { Content = mode.Item1, IsEnabled = context.Cwd is not null }; AutomationProperties.SetAutomationId(button, "WindowsSandboxRepair_" + mode.Item2);
            button.Click += (_, _) => Run(async () => { await runtime.RepairWindowsSandboxAsync(context, mode.Item2); notice.Message = "Sandbox setup started. Access remains unchanged; check readiness after setup completes."; notice.Severity = InfoBarSeverity.Informational; notice.IsOpen = true; }); sandbox.Children.Add(button);
        }
        body.Children.Add(Section("Windows sandbox", sandbox));
        var requirements = new StackPanel { Spacing = 6 };
        foreach (var property in state.Requirements.EnumerateObject())
            if (property.Value.ValueKind is JsonValueKind.String or JsonValueKind.True or JsonValueKind.False || property.Value.ValueKind == JsonValueKind.Array)
                requirements.Children.Add(Text(property.Name + ": " + (property.Value.ValueKind == JsonValueKind.Array ? string.Join(", ", property.Value.EnumerateArray().Select(x => x.ValueKind == JsonValueKind.String ? x.GetString() : "Custom policy")) : property.Value.ToString())));
        foreach (var profile in state.Profiles) requirements.Children.Add(Text(profile.Id + (profile.Allowed ? " · allowed" : " · managed restriction") + (profile.Description is null ? "" : "\n" + profile.Description)));
        if (requirements.Children.Count == 0) requirements.Children.Add(Text(state.Issues.Any(x => x.Method == "configRequirements/read") ? "Managed restrictions could not be read. Codex still enforces its active policy." : "The runtime reported no managed restrictions.")); body.Children.Add(Section("Managed requirements and access profiles", requirements));
        var config = new StackPanel { Spacing = 10 };
        foreach (var field in state.Fields)
        {
            var row = new StackPanel { Spacing = 5 }; var initial = field.Value.ValueKind == JsonValueKind.String ? field.Value.GetString() ?? "" : field.Value.ValueKind == JsonValueKind.Null ? "" : field.Value.ToString(); Func<string> value;
            FrameworkElement editor;
            if (field.Choices.Length > 0) { var choice = new ComboBox { Header = field.Title, ItemsSource = field.Choices, SelectedItem = initial, HorizontalAlignment = HorizontalAlignment.Stretch }; editor = choice; value = () => choice.SelectedItem as string ?? ""; }
            else if (field.Kind == "boolean") { var toggle = new ToggleSwitch { Header = field.Title, IsOn = initial == "true" }; editor = toggle; value = () => toggle.IsOn ? "true" : "false"; }
            else { var text = new TextBox { Header = field.Title, Text = initial, AcceptsReturn = initial.Contains('\n'), TextWrapping = TextWrapping.Wrap, MaxHeight = 150, IsReadOnly = field.Managed || field.Kind == "unknown" }; editor = text; value = () => text.Text; }
            AutomationProperties.SetAutomationId(editor, "RuntimeConfig_" + field.Key); row.Children.Add(editor);
            var save = new Button { Content = field.Managed ? "Managed by policy" : field.Kind == "unknown" ? "No native editor for this field" : "Save", IsEnabled = !field.Managed && field.Kind != "unknown" };
            save.Click += (_, _) => Run(async () => { var result = await runtime.WriteScalarAsync(context, field.Key, value()); notice.Message = result.Message; notice.Severity = result.Applied ? InfoBarSeverity.Success : InfoBarSeverity.Warning; notice.IsOpen = true; if (runtime.Snapshot(context) is { } updated) Render(updated); }); row.Children.Add(save); config.Children.Add(row);
        }
        body.Children.Add(Section("Configuration", config));
        var features = new StackPanel { Spacing = 8 };
        foreach (var feature in state.Features)
        {
            var toggle = new ToggleSwitch { Header = feature.Title + (feature.Required is null ? "" : " · managed"), IsOn = feature.Enabled, IsEnabled = feature.Required is null };
            AutomationProperties.SetAutomationId(toggle, "RuntimeFeature_" + feature.Name);
            var resetting = false;
            toggle.Toggled += (_, _) => { if (!resetting) Run(async () => { toggle.IsEnabled = false; try { await runtime.SetFeatureAsync(context, feature, toggle.IsOn); } catch { resetting = true; toggle.IsOn = feature.Enabled; resetting = false; throw; } finally { toggle.IsEnabled = feature.Required is null; } }); }; features.Children.Add(toggle); if (feature.Description.Length > 0) features.Children.Add(Text(feature.Description));
        }
        body.Children.Add(Section("Experimental features", features));
        var hooks = new StackPanel { Spacing = 8 };
        foreach (var hook in state.Hooks)
        {
            var row = new StackPanel { Spacing = 4 }; row.Children.Add(Text(hook.Event + " · " + hook.Handler + (hook.Enabled ? " · enabled" : " · disabled") + (hook.Managed ? " · managed" : ""))); row.Children.Add(Text(hook.Trust + " · " + hook.Source + "\n" + hook.Path));
            var reveal = new Button { Content = "Reveal hook source", IsEnabled = File.Exists(hook.Path) }; reveal.Click += (_, _) => Process.Start(new ProcessStartInfo("explorer.exe") { UseShellExecute = true, ArgumentList = { "/select,", hook.Path } }); row.Children.Add(reveal); hooks.Children.Add(row);
        }
        body.Children.Add(Section("Hooks", hooks));
        var subscriptions = new StackPanel { Spacing = 6 };
        foreach (var id in state.LoadedThreads)
        {
            var row = new StackPanel { Spacing = 3 }; row.Children.Add(Text(id + (id == context.RuntimeThreadId ? " · selected chat" : ""))); var unload = new Button { Content = "Unload inactive subscription", IsEnabled = id != context.RuntimeThreadId }; unload.Click += (_, _) => Run(async () => { await runtime.UnsubscribeAsync(context, id); await RefreshAsync(); }); row.Children.Add(unload); subscriptions.Children.Add(row);
        }
        body.Children.Add(Section("Loaded runtime subscriptions", subscriptions));
        var reviewPanel = new ApprovalReviewsPanel(runtime, session); body.Children.Add(reviewPanel);
    }
    static TextBlock Text(string value) => new() { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    static Expander Section(string title, object content) => new() { Header = title, Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    async void Run(Func<Task> action) { try { await action(); } catch (Exception exception) { notice.Message = DiagnosticRedactor.Redact(exception.Message); notice.Severity = InfoBarSeverity.Error; notice.IsOpen = true; } }
}

public sealed class ApprovalReviewsPanel : StackPanel
{
    readonly RuntimeManagementCoordinator runtime;
    readonly ThreadSession? session;
    public ApprovalReviewsPanel(RuntimeManagementCoordinator runtime, ThreadSession? session)
    {
        this.runtime = runtime; this.session = session; Spacing = 8; AutomationProperties.SetAutomationId(this, "ApprovalReviewStatus");
        Loaded += (_, _) => { runtime.Changed -= OnChanged; runtime.Changed += OnChanged; Render(); }; Unloaded += (_, _) => runtime.Changed -= OnChanged;
    }
    void OnChanged() => DispatcherQueue.TryEnqueue(Render);
    void Render()
    {
        Children.Clear(); foreach (var review in runtime.ApprovalReviews(session).Take(12))
        {
            var info = new InfoBar { IsOpen = true, IsClosable = !review.NeedsAttention, Severity = review.NeedsAttention ? InfoBarSeverity.Error : review.Status == "approved" ? InfoBarSeverity.Success : InfoBarSeverity.Informational, Title = review.Status == "denied" ? "Automatic approval denied this action" : review.Status == "strictReviewRequired" ? "Manual approval review required" : "Automatic approval: " + review.Status, Message = review.Action + "\n" + review.Rationale + (review.Risk is null ? "" : "\nRisk: " + review.Risk) };
            Children.Add(info);
            if (review.Status == "denied") Children.Add(new TextBlock { Text = "This runtime did not provide an executable denied-assessment event. Veo cannot safely replay an override from this notification.", TextWrapping = TextWrapping.Wrap, FontSize = 12 });
        }
    }
}
