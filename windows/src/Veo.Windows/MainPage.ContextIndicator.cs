using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;

namespace Veo_Windows;

public sealed partial class MainPage
{
    void RenderContextIndicator(ThreadSession session)
    {
        ComposerContextIndicator.Visibility = !workspace.Preferences.ShowUsage || session.ContextUsage is null ? Visibility.Collapsed : Visibility.Visible;
        if (session.ContextUsage is not { } usage) return;
        var percent = $"{usage.Percent}%";
        var p = workspace.Preferences;
        ContextBar.Visibility = p.ContextStyle == "Bar" ? Visibility.Visible : Visibility.Collapsed;
        ContextRing.Visibility = p.ContextStyle == "Circle" ? Visibility.Visible : Visibility.Collapsed;
        ContextBar.Value = ContextRing.Value = usage.Percent;
        ComposerContextPercent.Text = p.ContextLabel == "Tokens" && p.ContextStyle != "Percent" ? $"{usage.Used:N0}" : percent;
        var label = session.IsCompactingContext ? $"Compacting context, {percent} used" : $"Context window: {percent} used";
        AutomationProperties.SetName(ComposerContextIndicator, label);
        ToolTipService.SetToolTip(ComposerContextIndicator, label);
        var compacting = session.IsCompactingContext;
        var key = compacting ? "AccentTextFillColorPrimaryBrush"
            : usage.Percent >= 90 ? "SystemFillColorCriticalBrush"
            : usage.Percent >= 75 ? "SystemFillColorCautionBrush" : "TextFillColorSecondaryBrush";
        if (Application.Current.Resources.TryGetValue(key, out var resource) && resource is Microsoft.UI.Xaml.Media.Brush brush)
            ComposerContextPercent.Foreground = brush;
    }

    void ContextIndicator_Click(object sender, RoutedEventArgs e)
    {
        if (current?.ContextUsage is not { } usage) return;
        var column = new StackPanel { Spacing = 8, MinWidth = 175 };
        column.Children.Add(new TextBlock
        {
            Text = "Context window",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        column.Children.Add(new ProgressBar { Maximum = 100, Value = usage.Percent });
        column.Children.Add(new TextBlock { Text = $"{usage.Used:N0} of {usage.Window:N0} tokens used", FontSize = 12 });
        if (current.IsCompactingContext) column.Children.Add(new TextBlock { Text = "Compacting context…", FontSize = 12 });
        new Flyout { Content = column, Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Top }.ShowAt(ComposerContextIndicator);
    }
}
