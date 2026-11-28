using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Windows.ApplicationModel.DataTransfer;

namespace Veo_Windows.Controls;

/// <summary>A native durable plan document. The visible controls own their real pointer targets.</summary>
public sealed class PlanPanel : UserControl
{
    readonly PlanCoordinator plans;
    readonly ThreadSession session;
    readonly PlanReference reference;
    readonly Func<ComposerSnapshot> settings;
    readonly Expander expander = new() { IsExpanded = true, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    readonly StackPanel body = new() { Spacing = 10 };
    readonly MarkdownView markdown = new();
    readonly TextBox editor = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 180, MaxHeight = 500 };
    readonly TextBlock state = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap };
    readonly InfoBar error = new() { Severity = InfoBarSeverity.Error, IsClosable = true };
    readonly CommandBar commands = new() { DefaultLabelPosition = CommandBarDefaultLabelPosition.Right, IsOpen = false };
    readonly AppBarButton edit = new() { Label = "Edit", Icon = new SymbolIcon(Symbol.Edit) };
    readonly AppBarButton save = new() { Label = "Save", Icon = new SymbolIcon(Symbol.Save) };
    readonly AppBarButton cancel = new() { Label = "Cancel", Icon = new SymbolIcon(Symbol.Cancel) };
    readonly AppBarButton implement = new() { Label = "Implement", Icon = new SymbolIcon(Symbol.Play) };
    TimelineItem item;
    bool updating;
    public event Action<ThreadSession>? OpenThreadRequested;
    public event Action<PlanReference>? SourceRequested;
    public PlanPanel(PlanCoordinator plans, ThreadSession session, TimelineItem item, Func<ComposerSnapshot> settings, bool inInspector = false)
    {
        this.plans = plans; this.session = session; this.item = item; this.settings = settings;
        reference = new(session.Record.VeoId, item.Id);
        AutomationProperties.SetName(this, "Proposed plan"); AutomationProperties.SetName(editor, "Plan Markdown");
        var header = new StackPanel { Spacing = 3 }; header.Children.Add(new TextBlock { Text = "Proposed plan", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }); header.Children.Add(state);
        expander.Header = header; body.Children.Add(markdown); body.Children.Add(editor); body.Children.Add(error); body.Children.Add(commands); expander.Content = body; Content = expander;
        var copy = new AppBarButton { Label = "Copy Markdown", Icon = new SymbolIcon(Symbol.Copy) };
        var export = new AppBarButton { Label = "Export Markdown…", Icon = new SymbolIcon(Symbol.Download) };
        var revert = new AppBarButton { Label = "Revert to Codex plan", Icon = new SymbolIcon(Symbol.Undo) };
        var newTask = new AppBarButton { Label = "Implement in new chat" };
        var source = new AppBarButton { Label = "Go to plan source" };
        commands.PrimaryCommands.Add(edit); commands.PrimaryCommands.Add(save); commands.PrimaryCommands.Add(cancel); commands.PrimaryCommands.Add(implement);
        if (!inInspector)
        {
            var open = new AppBarButton { Label = "Open plan in sidebar", Icon = new SymbolIcon(Symbol.OpenPane) };
            open.Click += (_, _) => Run(() => App.Main?.OpenPlanTabAsync(session, item) ?? Task.CompletedTask);
            commands.PrimaryCommands.Insert(0, open);
        }
        commands.SecondaryCommands.Add(copy); commands.SecondaryCommands.Add(export); commands.SecondaryCommands.Add(revert); commands.SecondaryCommands.Add(newTask); commands.SecondaryCommands.Add(source);
        edit.Click += (_, _) => Run(() => { plans.BeginEditing(reference); Refresh(); return Task.CompletedTask; });
        editor.TextChanged += (_, _) => { if (!updating) plans.UpdateDraft(reference, editor.Text); };
        save.Click += (_, _) => Run(async () => { plans.UpdateDraft(reference, editor.Text); await plans.SaveEditingAsync(reference); Refresh(); });
        cancel.Click += (_, _) => { plans.CancelEditing(reference); Refresh(); };
        revert.Click += (_, _) => Run(async () => { await plans.RevertAsync(reference); Refresh(); });
        copy.Click += (_, _) => { var package = new DataPackage(); package.SetText(plans.Markdown(reference, this.item.Text)); Clipboard.SetContent(package); };
        implement.Click += (_, _) => Run(async () => OpenThreadRequested?.Invoke(await plans.ImplementAsync(reference, session, settings())));
        newTask.Click += (_, _) => Run(async () => OpenThreadRequested?.Invoke(await plans.ImplementAsync(reference, session, settings(), true)));
        source.Click += (_, _) => SourceRequested?.Invoke(reference);
        export.Click += (_, _) => Run(async () =>
        {
            var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = "Veo plan" };
            picker.FileTypeChoices.Add("Markdown", new List<string> { ".md" });
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Main!));
            if (await picker.PickSaveFileAsync() is { } file) await File.WriteAllTextAsync(file.Path, plans.Markdown(reference, this.item.Text));
        });
        plans.Changed += PlansChanged;
        Loaded += (_, _) => Run(async () => { plans.Changed -= PlansChanged; plans.Changed += PlansChanged; await plans.ObserveAsync(session); Refresh(); });
        Unloaded += (_, _) => plans.Changed -= PlansChanged;
        Refresh();
    }
    public void Update(TimelineItem latest) { item = latest; Refresh(); }
    void PlansChanged() => DispatcherQueue.TryEnqueue(Refresh);
    void Refresh()
    {
        var plan = plans.Get(reference); var draft = plans.EditingDraft(reference);
        var streaming = item.Status is "pending" or "inProgress";
        state.Text = streaming ? "Writing plan…" : plan?.Lifecycle switch { "superseded" => "A newer plan is ready", "implementing" => "Implementing", "implemented" => "Implemented", _ => plan?.EditedMarkdown is null ? "Ready" : "Edited · ready" };
        markdown.Markdown = plans.Markdown(reference, item.Text);
        markdown.Visibility = draft is null ? Visibility.Visible : Visibility.Collapsed;
        editor.Visibility = draft is null ? Visibility.Collapsed : Visibility.Visible;
        if (draft is not null && editor.Text != draft) { updating = true; editor.Text = draft; updating = false; }
        edit.Visibility = draft is null ? Visibility.Visible : Visibility.Collapsed;
        save.Visibility = cancel.Visibility = draft is null ? Visibility.Collapsed : Visibility.Visible;
        edit.IsEnabled = plan?.Lifecycle == "ready" && !streaming;
        implement.IsEnabled = plan?.Lifecycle == "ready" && !streaming && draft is null && !session.Timeline.IsRunning;
        if (plans.Error(reference) is { } failure) { error.Message = failure; error.IsOpen = true; }
    }
    async void Run(Func<Task> action)
    {
        try { await action(); error.IsOpen = false; }
        catch (Exception exception) { error.Message = Veo.Protocol.DiagnosticRedactor.Redact(exception.Message); error.IsOpen = true; }
    }
}
