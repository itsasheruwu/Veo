using System.Text.RegularExpressions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Veo_Windows.ViewModels;

namespace Veo_Windows;

public sealed partial class MainPage
{
    bool minimapDirty = true;
    readonly List<MessageRow> minimapTopics = [];
    Button? activeMarker;
    ScrollViewer? timelineScroller;

    void InitializeMinimap()
    {
        messages.CollectionChanged += (_, change) =>
        {
            if (change.Action == System.Collections.Specialized.NotifyCollectionChangedAction.Reset ||
                change.NewItems?.OfType<MessageRow>().Any(r => r.Item.Kind == "userMessage") == true ||
                change.OldItems?.OfType<MessageRow>().Any(r => r.Item.Kind == "userMessage") == true)
                minimapDirty = true;
        };
        Timeline.Loaded += (_, _) =>
        {
            timelineScroller = Controls.MarkdownView.Descendants(Timeline).OfType<ScrollViewer>().FirstOrDefault();
            if (timelineScroller is not null) timelineScroller.ViewChanged += MinimapViewChanged;
        };
        Timeline.Unloaded += (_, _) =>
        {
            if (timelineScroller is not null) timelineScroller.ViewChanged -= MinimapViewChanged;
            timelineScroller = null;
        };
    }

    static readonly string[] TopicShifts = ["new feature", "another feature", "different feature", "next feature", "switch to", "move on to", "instead work on", "start working on", "separate task", "different task", "new task", "now let's", "now lets"];
    static readonly string[] FollowUps = ["that", "this", "it", "same", "continue", "keep", "still", "also", "first thing", "actually", "instead", "make it", "change it", "fix it"];
    static readonly HashSet<string> CommonWords = new("the this that with for from and but can should please would could have make into your you are need will want just".Split());

    void UpdateMinimap()
    {
        if (!workspace.Preferences.ShowMinimap || terminalWorkspaceExpanded)
        {
            MinimapSurface.Visibility = Visibility.Collapsed;
            return;
        }
        if (minimapDirty)
        {
            minimapDirty = false;
            activeMarker = null;
            minimapTopics.Clear();
            MinimapMarkers.Children.Clear();
            var keywords = new HashSet<string>();
            foreach (var prompt in messages.Where(r => r.Item.Kind == "userMessage"))
            {
                var title = prompt.Text.Trim();
                if (title.Length == 0) continue;
                var lower = title.ToLowerInvariant();
                var words = Regex.Matches(lower, @"[\p{L}\p{N}]{3,}").Select(m => m.Value).Where(w => !CommonWords.Contains(w)).ToHashSet();
                var overlap = words.Count(keywords.Contains);
                var shift = TopicShifts.Any(lower.Contains) || title.Length >= 72 && words.Count >= 3 && !FollowUps.Any(lower.StartsWith);
                if (minimapTopics.Count > 0 && (!shift || overlap > 0))
                {
                    keywords.UnionWith(words);
                    continue;
                }
                keywords = words;
                minimapTopics.Add(prompt);
                var mark = new Border { Width = 11, Height = 3, CornerRadius = new(2), Background = (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"] };
                var button = new Button { Style = (Style)Application.Current.Resources["SubtleButtonStyle"], Width = 23, Height = 15, MinWidth = 0, MinHeight = 0, Padding = new(0), Opacity = .55, Content = mark };
                AutomationProperties.SetName(button, title);
                ToolTipService.SetToolTip(button, title.Length > 140 ? title[..140] + "…" : title);
                button.Click += (_, _) => Timeline.ScrollIntoView(prompt, ScrollIntoViewAlignment.Leading);
                MinimapMarkers.Children.Add(button);
            }
        }
        MinimapSurface.Visibility = minimapTopics.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        if (MinimapSurface.Visibility == Visibility.Visible) UpdateActiveMarker();
    }

    void MinimapViewChanged(object? sender, ScrollViewerViewChangedEventArgs args)
    {
        if (!args.IsIntermediate && MinimapSurface.Visibility == Visibility.Visible) UpdateActiveMarker();
    }

    void UpdateActiveMarker()
    {
        if (messages.Count == 0 || Timeline.ItemsPanelRoot is not ItemsStackPanel panel || minimapTopics.Count == 0) return;
        var first = Math.Clamp(panel.FirstVisibleIndex, 0, messages.Count - 1);
        var active = Math.Max(0, minimapTopics.FindLastIndex(row => row.Item.Order <= messages[first].Item.Order));
        var button = (Button)MinimapMarkers.Children[active];
        if (button == activeMarker) return;
        if (activeMarker is not null) { activeMarker.Opacity = .55; ((Border)activeMarker.Content).Width = 11; }
        button.Opacity = 1;
        ((Border)button.Content).Width = 18;
        activeMarker = button;
    }
}
