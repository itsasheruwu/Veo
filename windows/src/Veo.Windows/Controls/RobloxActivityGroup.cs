using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Veo_Windows.ViewModels;

namespace Veo_Windows.Controls;

internal sealed class RobloxActivityGroup : StackPanel
{
    readonly Brush? secondaryForeground;
    readonly Button toggle = new() { MinHeight = 24, Padding = new(3, 2, 6, 2), HorizontalAlignment = HorizontalAlignment.Left };
    readonly FontIcon chevron = new() { FontSize = 8, Glyph = "\uE76C", VerticalAlignment = VerticalAlignment.Center };
    readonly StackPanel steps = new() { Spacing = 8 };
    readonly Border trace;
    readonly LiveActivityView heading;
    string title = "";
    bool expanded;

    public RobloxActivityGroup(Brush? secondaryForeground)
    {
        this.secondaryForeground = secondaryForeground;
        Spacing = 4;
        if (Application.Current.Resources.TryGetValue("SubtleButtonStyle", out var style) && style is Style subtle)
            toggle.Style = subtle;
        chevron.Foreground = secondaryForeground;
        AutomationProperties.SetAccessibilityView(chevron, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        heading = new(ModelPickerVisuals.RobloxIcon(new SolidColorBrush(Microsoft.UI.Colors.IndianRed)));
        var label = new Grid { ColumnSpacing = 6 };
        label.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        label.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        label.Children.Add(heading);
        Grid.SetColumn(chevron, 1);
        label.Children.Add(chevron);
        toggle.Content = label;
        AutomationProperties.SetAutomationId(toggle, "RobloxActivityToggle");
        Application.Current.Resources.TryGetValue("DividerStrokeColorDefaultBrush", out var divider);
        trace = new Border
        {
            Child = steps, Visibility = Visibility.Collapsed, Margin = new(8, 2, 0, 0), Padding = new(10, 2, 0, 3),
            BorderThickness = new(1, 0, 0, 0), BorderBrush = divider as Brush ?? secondaryForeground
        };
        toggle.Click += (_, _) =>
        {
            expanded = !expanded;
            trace.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
            chevron.Glyph = expanded ? "\uE70D" : "\uE76C";
            UpdateAccessibleName();
        };
        Children.Add(toggle);
        Children.Add(trace);
    }

    public void Update(MessageRow row)
    {
        var item = row.Item;
        var calls = item.Raw.Deserialize<TimelineItem[]>() ?? [];
        var timeline = row.Session.Timeline;
        var live = timeline.IsRunning && (timeline.ActiveTurnId is null || timeline.ActiveTurnId == item.TurnId)
            ? calls.LastOrDefault(TimelinePresentation.IsInProgress) : null;
        heading.Update(item with { Status = live?.Id ?? "" }, turnStartedAt: null, working: live is not null);
        if (title != item.Text)
        {
            title = item.Text;
            UpdateAccessibleName();
        }

        while (steps.Children.Count > calls.Length) steps.Children.RemoveAt(steps.Children.Count - 1);
        for (var index = 0; index < calls.Length; index++)
        {
            var call = calls[index];
            if (index < steps.Children.Count && steps.Children[index] is TimelineMessageView { Row: { } existing } && existing.Id == call.Id)
            {
                if (!existing.Item.HasSameContent(call)) existing.Update(call);
                continue;
            }
            var step = new TimelineMessageView { InlineRobloxTool = true, SecondaryForeground = secondaryForeground, Row = new MessageRow(row.Session, call) };
            if (index < steps.Children.Count) steps.Children[index] = step;
            else steps.Children.Add(step);
        }
    }

    void UpdateAccessibleName() => AutomationProperties.SetName(toggle, (expanded ? "Hide work details: " : "Show work details: ") + title);
}
