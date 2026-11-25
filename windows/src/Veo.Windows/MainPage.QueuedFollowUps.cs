using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Media.Animation;
using System.Numerics;
using Veo_Windows.Controls;
using Veo.Core;
using Veo.Protocol;

namespace Veo_Windows;

public sealed partial class MainPage
{
    bool showEntireQueue;

    bool CanSteer(ThreadSession session) => session.Timeline.IsRunning
        && session.Record.CodexThreadId is not null && workspace.Runtime.Capabilities.Availability("turn/steer") != CapabilityAvailability.Unavailable;

    bool SendsSteer(ThreadSession session) => CanSteer(session) && workspace.Preferences.SteerFollowUps
        && !(session.ComposerGoalArmed && App.ThreadSettings.ActiveGoal(session) is null)
        && ComposerDefaults().Daybreak is null;

    Storyboard? queueDismissal;
    bool queueRenderedExpanded;

    void RenderQueue()
    {
        if (DictationActive)
        {
            QueueShelf.Visibility = Visibility.Collapsed;
            queueSignature = "";
            return;
        }
        if (current is not { } session) return;
        var queue = session.Queue;
        var signature = session.Record.VeoId + "|" + showEntireQueue + "|" + CanSteer(session) + "|" + session.Timeline.IsRunning
            + "|" + string.Join("|", queue.Select(item => item.ClientId + ":" + item.Text));
        if (signature == queueSignature) return;
        queueSignature = signature;

        if (queue.Count == 0)
        {
            showEntireQueue = false;
            CollapseQueueShelf();
            return;
        }

        var revealShelf = QueueShelf.Visibility == Visibility.Collapsed || queueDismissal is not null;
        var revealRows = queueRenderedExpanded != showEntireQueue;
        queueRenderedExpanded = showEntireQueue;
        queueDismissal?.Stop();
        queueDismissal = null;
        QueueShelf.Opacity = 1;
        QueueShelf.IsHitTestVisible = true;
        QueueShelf.Visibility = Visibility.Visible;
        QueuePanel.Children.Clear();
        QueuePanel.Children.Add(QueueHeading(queue.Count));

        var rows = new StackPanel { Spacing = 4 };
        foreach (var queued in showEntireQueue ? queue : queue.Take(1))
        {
            var row = new Grid { ColumnSpacing = 8, MinHeight = 25 };
            row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var summary = InlineChatContext.DisplayText(queued.Text);
            var preview = new TextBlock { Text = summary.Length == 0 ? "Attachments" : summary,
                MaxLines = 2, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center };
            row.Children.Add(preview);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, VerticalAlignment = VerticalAlignment.Center };

            void Add(string title, Func<Task> action, string? glyph = null)
            {
                var button = new Button { Height = 24, MinHeight = 0, FontSize = 11.5 };
                if (glyph is null)
                {
                    button.Content = title;
                    button.Padding = new(8, 0, 8, 0);
                }
                else
                {
                    button.Style = (Style)Resources["ComposerChromeButton"];
                    button.Content = new FontIcon { Glyph = glyph, FontSize = 11 };
                    button.Padding = new(0);
                    button.Width = 24;
                    button.CornerRadius = new(5);
                    ToolTipService.SetToolTip(button, title);
                }
                AutomationProperties.SetName(button, title);
                button.Click += async (_, _) => await Run(action);
                actions.Children.Add(button);
            }

            if (CanSteer(session) && !queued.StartGoal && queued.Daybreak is null)
                Add("Steer now", () => App.Queue.SteerAsync(session, queued));
            else if (!session.Timeline.IsRunning && queued.ClientId == queue[0].ClientId)
                Add("Send now", () => workspace.DispatchNextQueuedAsync(session));

            Add("Edit queued message", async () =>
            {
                var editor = new TextBox { Text = queued.Text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 180 };
                var dialog = new ContentDialog { Title = "Edit queued message", XamlRoot = XamlRoot, Content = editor,
                    PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
                if (await dialog.ShowAsync() == ContentDialogResult.Primary)
                    await App.Queue.EditAsync(session, queued.ClientId, editor.Text, queued.Attachments);
            }, "");
            Add("Remove queued message", () => App.Queue.RemoveAsync(session, queued.ClientId), "");

            Grid.SetColumn(actions, 1);
            row.Children.Add(actions);
            rows.Children.Add(row);
        }
        QueuePanel.Children.Add(showEntireQueue && queue.Count > 1
            ? new ScrollViewer { Content = rows, MaxHeight = 148, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }
            : rows);

        if (revealShelf || revealRows)
        {
            var target = revealShelf ? (FrameworkElement)QueueShelf : rows;
            var presentation = queueSignature;
            DispatcherQueue.TryEnqueue(() =>
            {
                if (target.IsLoaded && queueSignature == presentation)
                    ModelPickerVisuals.Reveal(target, new Vector3(0, 4, 0), 185);
            });
        }
    }

    FrameworkElement QueueHeading(int count)
    {
        var heading = new Grid { ColumnSpacing = 8 };
        heading.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 6, Opacity = .78, VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                new FontIcon { Glyph = "", FontSize = 11 },
                new TextBlock { Text = "Queued", FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    VerticalAlignment = VerticalAlignment.Center }
            }
        });
        if (count > 1)
        {
            var toggle = new Button
            {
                Style = (Style)Resources["ComposerChromeButton"],
                Content = showEntireQueue ? "Show next  ⌃" : $"Show all {count}  ⌄",
                Height = 21, MinHeight = 0, Padding = new(4, 0, 4, 0), FontSize = 11
            };
            AutomationProperties.SetName(toggle, showEntireQueue ? "Show only the next queued message" : $"Show all {count} queued messages");
            toggle.Click += (_, _) => { showEntireQueue = !showEntireQueue; RenderQueue(); };
            Grid.SetColumn(toggle, 1);
            heading.Children.Add(toggle);
        }
        return heading;
    }

    void CollapseQueueShelf()
    {
        if (QueueShelf.Visibility == Visibility.Collapsed || queueDismissal is not null) return;
        QueueShelf.IsHitTestVisible = false;
        foreach (var button in MarkdownView.Descendants(QueueShelf).OfType<Button>())
            button.IsEnabled = false;
        void Collapse()
        {
            QueuePanel.Children.Clear();
            QueueShelf.Visibility = Visibility.Collapsed;
            QueueShelf.Opacity = 1;
        }
        if (!ModelPickerVisuals.MotionEnabled || !QueueShelf.IsLoaded)
        {
            Collapse();
            return;
        }
        var fade = new DoubleAnimation { To = 0, Duration = TimeSpan.FromMilliseconds(120) };
        Storyboard.SetTarget(fade, QueueShelf);
        Storyboard.SetTargetProperty(fade, "Opacity");
        var animation = new Storyboard();
        animation.Children.Add(fade);
        queueDismissal = animation;
        animation.Completed += (_, _) =>
        {
            if (queueDismissal != animation) return;
            queueDismissal = null;
            Collapse();
            animation.Stop();
        };
        animation.Begin();
    }

    void RenderFollowUpSend(ThreadSession session)
    {
        var active = session.Timeline.IsRunning;
        var steer = SendsSteer(session);
        var label = !active ? "Send" : steer ? "Steer current turn" : "Queue next message";
        SendGlyph.Glyph = !active ? "\uE74A" : steer ? "\uE7AD" : "\uE8FD";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(SendButton, label);
        ToolTipService.SetToolTip(SendButton, label);
        if (active && SendButton.ContextFlyout is null)
        {
            var menu = new MenuFlyout();
            void Add(string text, bool value)
            {
                var item = new ToggleMenuFlyoutItem { Text = text };
                item.Click += async (_, _) => await Run(async () =>
                {
                    workspace.Preferences.SteerFollowUps = value;
                    await workspace.SavePreferencesAsync();
                    Render();
                });
                menu.Opening += (_, _) =>
                {
                    item.IsEnabled = !value || current is { } selected && CanSteer(selected);
                    item.IsChecked = workspace.Preferences.SteerFollowUps == value;
                };
                menu.Items.Add(item);
            }
            Add("Queue next message", false);
            Add("Steer current turn", true);
            SendButton.ContextFlyout = menu;
        }
        else if (!active) SendButton.ContextFlyout = null;
    }
}
