using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Veo_Windows.ViewModels;
using Windows.ApplicationModel.DataTransfer;

namespace Veo_Windows.Controls;

/// <summary>Native item presentation: plan documents keep their editor while ordinary messages remain selectable Markdown.</summary>
public sealed class TimelineMessageView : UserControl
{
    public static readonly DependencyProperty RowProperty = DependencyProperty.Register(nameof(Row), typeof(MessageRow), typeof(TimelineMessageView), new PropertyMetadata(null, RowChanged));
    public static readonly DependencyProperty PromptBackgroundProperty = DependencyProperty.Register(nameof(PromptBackground), typeof(Brush), typeof(TimelineMessageView), new PropertyMetadata(null));
    public static readonly DependencyProperty SecondaryForegroundProperty = DependencyProperty.Register(nameof(SecondaryForeground), typeof(Brush), typeof(TimelineMessageView), new PropertyMetadata(null));
    public MessageRow? Row { get => (MessageRow?)GetValue(RowProperty); set => SetValue(RowProperty, value); }
    public Brush? PromptBackground { get => (Brush?)GetValue(PromptBackgroundProperty); set => SetValue(PromptBackgroundProperty, value); }
    public Brush? SecondaryForeground { get => (Brush?)GetValue(SecondaryForegroundProperty); set => SetValue(SecondaryForegroundProperty, value); }

    MessageRow? subscribed;
    MarkdownView? markdown;
    PlanPanel? plan;
    StackPanel? artifacts;
    TextBox? commandOutput;
    TextBlock? activityTitle;
    FontIcon? activityMark;
    Action? updateActivityName;
    string? artifactSignature;
    string? presentationKey;
    bool renderPending;
    public TimelineMessageView()
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        Loaded += (_, _) => { Subscribe(Row); Render(); };
        Unloaded += (_, _) => Subscribe(null);
    }
    static void RowChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    { var view = (TimelineMessageView)sender; view.Subscribe(args.NewValue as MessageRow); view.Render(); }
    void Subscribe(MessageRow? row)
    {
        if (ReferenceEquals(subscribed, row)) return;
        if (subscribed is not null) subscribed.PropertyChanged -= Changed;
        subscribed = row;
        if (row is not null) row.PropertyChanged += Changed;
    }
    void Changed(object? sender, PropertyChangedEventArgs args)
    {
        if (renderPending) return; renderPending = true;
        DispatcherQueue.TryEnqueue(() => { renderPending = false; Render(); });
    }
    void Render()
    {
        if (Row is not { } row) { Content = null; presentationKey = null; return; }
        var key = row.Session.Record.VeoId + "|" + row.Id + "|" + row.Item.Kind;
        var shown = TimelinePresentation.Item(row.Item);
        if (presentationKey != key)
        {
            presentationKey = key; plan = null; markdown = null; artifacts = null; commandOutput = null; artifactSignature = null;
            activityTitle = null; activityMark = null; updateActivityName = null;
            if (row.Item.Kind == "plan")
            {
                plan = new PlanPanel(App.Plans, row.Session, row.Item, () => Snapshot(row.Session));
                plan.OpenThreadRequested += session => Navigate(session);
                plan.SourceRequested += _ => Navigate(row.Session);
                Content = plan;
            }
            else
            {
                var column = new StackPanel { Spacing = 7 };
                if (!shown.IsActivity && row.Item.Kind != "userMessage") column.Children.Add(Caption(shown.Title));
                if (row.Item.Kind == "commandExecution")
                {
                    commandOutput = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, FontFamily = new("Cascadia Mono"), FontSize = 12, MaxHeight = 350, BorderThickness = new(0) };
                    AutomationProperties.SetName(commandOutput, "Command output");
                    ScrollViewer.SetHorizontalScrollBarVisibility(commandOutput, ScrollBarVisibility.Auto);
                    column.Children.Add(commandOutput);
                }
                else
                {
                    var message = new MarkdownView { Session = row.Session };
                    markdown = message;
                    column.Children.Add(message);
                    message.Rendered += () => InstallSelectionMenu(message, row);
                }
                artifacts = new StackPanel { Spacing = 8, Visibility = Visibility.Collapsed };
                column.Children.Add(artifacts);
                Content = row.Item.Kind == "userMessage" ? PromptBubble(column) : shown.IsActivity ? ActivityDisclosure(column) : column;
            }
        }
        if (plan is not null) plan.Update(row.Item);
        if (commandOutput is not null) commandOutput.Text = shown.Body;
        if (markdown is not null)
        {
            markdown.IsStreaming = row.Session.Timeline.IsRunning && row.Item.Status is not ("completed" or "failed" or "interrupted");
            markdown.Markdown = row.Item.Kind is "agentMessage" or "userMessage" or "reasoning" ? ParagraphStreaming.Visible(row.Item, row.Session.Timeline.IsRunning, App.Workspace.Preferences.Streaming) : shown.Body;
            markdown.Visibility = markdown.Markdown.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        if (activityTitle is not null && activityMark is not null)
        {
            var running = row.Session.Timeline.IsRunning && row.Item.Status is ("inProgress" or "running" or "active");
            var failed = row.Item.Status is "failed" or "error";
            var interrupted = row.Item.Status is "interrupted" or "aborted" or "cancelled" or "canceled";
            activityTitle.Text = row.Item.Kind == "reasoning" && row.Item.Status == "completed" ? "Thought through the approach" : shown.Title.ReplaceLineEndings(" ");
            if (failed) activityTitle.Text += " · Failed";
            if (interrupted) activityTitle.Text += " · Interrupted";
            activityMark.Glyph = failed ? "\uE783" : running ? "\uE823" : interrupted ? "\uE71A" : "\uE73E";
            updateActivityName?.Invoke();
        }
        RenderArtifacts(row, shown);
    }

    Border PromptBubble(StackPanel content)
    {
        var bubble = new Border
        {
            Child = content,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new(64, 0, 0, 0),
            MaxWidth = 620,
            Padding = new(12, 6, 12, 6),
            CornerRadius = new(13)
        };
        bubble.SetBinding(Border.BackgroundProperty, new Binding { Source = this, Path = new(nameof(PromptBackground)) });
        return bubble;
    }

    TextBlock Caption(string title)
    {
        var label = new TextBlock
        {
            Text = title,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center
        };
        label.SetBinding(TextBlock.ForegroundProperty, new Binding { Source = this, Path = new(nameof(SecondaryForeground)) });
        return label;
    }

    StackPanel ActivityDisclosure(StackPanel details)
    {
        var title = activityTitle = Caption("");
        var mark = activityMark = new FontIcon { FontSize = 10, VerticalAlignment = VerticalAlignment.Center };
        var chevron = new FontIcon { FontSize = 8, Glyph = "\uE76C", VerticalAlignment = VerticalAlignment.Center };
        mark.SetBinding(IconElement.ForegroundProperty, new Binding { Source = this, Path = new(nameof(SecondaryForeground)) });
        chevron.SetBinding(IconElement.ForegroundProperty, new Binding { Source = this, Path = new(nameof(SecondaryForeground)) });
        var label = new Grid { ColumnSpacing = 8 };
        label.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        label.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        label.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        Grid.SetColumn(title, 1);
        Grid.SetColumn(chevron, 2);
        label.Children.Add(mark);
        label.Children.Add(title);
        label.Children.Add(chevron);
        var toggle = new Button
        {
            Content = label,
            Padding = new(3, 2, 6, 2),
            MinHeight = 24
        };
        if (Application.Current.Resources.TryGetValue("SubtleButtonStyle", out var style) && style is Style subtle)
            toggle.Style = subtle;
        details.Visibility = Visibility.Collapsed;
        details.Margin = new(20, 0, 0, 0);
        void UpdateName() => AutomationProperties.SetName(toggle, (details.Visibility == Visibility.Visible ? "Hide details for " : "Show details for ") + title.Text);
        updateActivityName = UpdateName;
        toggle.Click += (_, _) =>
        {
            var expanded = details.Visibility != Visibility.Visible;
            details.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
            chevron.Glyph = expanded ? "\uE70D" : "\uE76C";
            UpdateName();
        };
        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(toggle);
        panel.Children.Add(details);
        return panel;
    }
    static ComposerSnapshot Snapshot(ThreadSession session)
    {
        var fallback = App.Workspace.Models.FirstOrDefault();
        return ComposerDraft.Snapshot(session, includeInput: false, defaults: new(Guid.NewGuid().ToString("N"), "", fallback?.Id, fallback?.DefaultEffort, null, App.Workspace.Preferences.DefaultAccess, "Agentic", []));
    }
    void RenderArtifacts(MessageRow row, TimelineItemPresentation presentation)
    {
        if (artifacts is null) return;
        var signature = string.Join("|", presentation.Artifacts.Select(x => x.Id + x.Kind + x.Source.GetHashCode(StringComparison.Ordinal)));
        signature += string.Join("|", presentation.Sources.Select(x => x.Id + x.Target)) + string.Join("|", presentation.Agents.Select(x => x.ThreadId + x.Status + x.Message));
        if (signature == artifactSignature) return; artifactSignature = signature; artifacts.Children.Clear();
        artifacts.Visibility = signature.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        foreach (var artifact in presentation.Artifacts) artifacts.Children.Add(new ConversationArtifactView(row.Session, artifact));
        foreach (var source in presentation.Sources)
        {
            var button = new Button { Content = "Source · " + source.Label }; button.Click += async (_, _) => { try { if (IntegrationCoordinator.SecureUri(source.Target) is { } uri && App.Main is { } main) await main.NavigateBrowserAsync(uri); else await new ContentDialog { Title = source.Label, Content = new ConversationSourceView(row.Session, source), CloseButtonText = "Done", XamlRoot = XamlRoot }.ShowAsync(); } catch (Exception error) { artifacts.Children.Add(new TextBlock { Text = Veo.Protocol.DiagnosticRedactor.Redact(error.Message), TextWrapping = TextWrapping.Wrap }); } }; artifacts.Children.Add(button);
        }
        foreach (var agent in presentation.Agents)
        {
            var button = new Button { Content = agent.Name + " · " + agent.Status + (agent.Message is null ? "" : "\n" + agent.Message), HorizontalContentAlignment = HorizontalAlignment.Left };
            button.Click += async (_, _) => { try { await using var activity = new ConversationActivityCoordinator(App.Workspace, observeEvents: false); var child = await activity.OpenChildAsync(row.Session, agent.ThreadId); if (App.Main is { } main) await main.NavigateToThreadAsync(child); } catch (Exception error) { artifacts.Children.Add(new TextBlock { Text = Veo.Protocol.DiagnosticRedactor.Redact(error.Message), TextWrapping = TextWrapping.Wrap }); } }; artifacts.Children.Add(button);
        }
    }
    void InstallSelectionMenu(MarkdownView view, MessageRow row)
    {
        var menu = new MenuFlyout();
        var copy = new MenuFlyoutItem { Text = "Copy selection" };
        var copyMarkdown = new MenuFlyoutItem { Text = "Copy as Markdown" };
        var quote = new MenuFlyoutItem { Text = "Quote selection" };
        var selection = "";
        menu.Opening += (_, _) => { selection = SelectedText(view); copy.IsEnabled = quote.IsEnabled = selection.Length > 0; };
        copy.Click += (_, _) => Copy(selection);
        copyMarkdown.Click += (_, _) => Copy(ParagraphStreaming.Visible(row.Item, row.Session.Timeline.IsRunning, App.Workspace.Preferences.Streaming));
        quote.Click += async (_, _) =>
        {
            if (selection.Length == 0 || App.Main is not { } main) return;
            await main.QuoteIntoComposerAsync(new(row.Session.Record.VeoId, row.Id), selection);
        };
        menu.Items.Add(copy); menu.Items.Add(copyMarkdown); menu.Items.Add(new MenuFlyoutSeparator()); menu.Items.Add(quote);
        view.ContextFlyout = menu;
        foreach (var child in MarkdownView.Descendants(view).OfType<FrameworkElement>()) child.ContextFlyout = menu;
    }
    static string SelectedText(MarkdownView view) => view.SelectedText();
    static void Copy(string value) { var package = new DataPackage(); package.SetText(value); Clipboard.SetContent(package); }
    static async void Navigate(ThreadSession session) { if (App.Main is { } main) await main.NavigateToThreadAsync(session); }
}
