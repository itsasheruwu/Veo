using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Veo_Windows.Controls;
using Veo_Windows.Services;
using Windows.UI.ViewManagement;

namespace Veo_Windows;

public sealed partial class MainPage
{
    Flyout? composerGoalFlyout;
    ThreadSession? composerGoalFlyoutSession;

    void ComposerGoalPill_Click(object sender, RoutedEventArgs e)
    {
        if (current is not { } session || DictationActive) return;
        if (composerGoalFlyout is { } open) { open.Hide(); return; }

        var anchor = sender as FrameworkElement ?? ComposerGoalPill;
        var nativeGoal = App.ThreadSettings.ActiveGoal(session);
        var selected = nativeGoal is not null ? ComposerGoalMode.ProviderManaged : session.GoalMode;
        var active = App.ThreadSettings.HasActiveComposerGoal(session);
        var foreground = ComposerKeyHints.Foreground;
        var contrast = new AccessibilitySettings().HighContrast;
        var tint = contrast ? foreground : new SolidColorBrush(ActualTheme == ElementTheme.Dark
            ? Windows.UI.Color.FromArgb(255, 0, 255, 126) : Windows.UI.Color.FromArgb(255, 6, 116, 58));
        var list = new StackPanel { Padding = new(9), Spacing = 4 };
        list.Children.Add(new TextBlock
        {
            Text = "Goal mode", FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = tint, Margin = new(7, 2, 7, 3)
        });
        var scroll = new ScrollViewer
        {
            Width = 255, MaxHeight = ComposerMenuHeight(anchor, 260), Content = list,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalContentAlignment = HorizontalAlignment.Stretch
        };
        AutomationProperties.SetName(scroll, "Goal settings");
        AutomationProperties.SetAutomationId(scroll, "ComposerGoalMenu");
        var surface = WorkspaceAppearance.FlyoutBrush(this);
        var flyout = new Flyout
        {
            Content = new StackPanel { Children =
            {
                new Border { CornerRadius = new(ModelPickerVisuals.CornerRadius), Background = surface, Child = scroll },
                ModelPickerVisuals.PickerPointer(surface)
            } },
            Placement = FlyoutPlacementMode.Top, ShouldConstrainToRootBounds = true,
            AreOpenCloseAnimationsEnabled = ModelPickerVisuals.MotionEnabled,
            FlyoutPresenterStyle = (Style)Resources["ModelPickerFlyoutPresenter"]
        };
        foreach (var mode in Enum.GetValues<ComposerGoalMode>())
        {
            var available = mode != ComposerGoalMode.ProviderManaged || App.ThreadSettings.Available("thread/goal/set");
            var title = ComposerGoals.Title(mode);
            var detail = available ? ComposerGoals.Description(mode) : "Built-in goals unavailable.";
            FrameworkElement icon = mode switch
            {
                ComposerGoalMode.Loop => ComposerOptionsIcon("\uE72C", tint),
                ComposerGoalMode.Gauntlet => ComposerOptionsIcon("\uE9D9", tint),
                _ => ModelPickerVisuals.GoalIcon(tint)
            };
            var row = ComposerOptionsRow(title, detail, icon);
            if (selected == mode) AddComposerOptionsTrailing(row, ComposerOptionsIcon("\uE73E", tint), 16);
            var option = ComposerOptionsButtonFor(row, title + (mode == selected ? ", selected" : ""), "ComposerGoalMode" + mode, detail);
            option.Height = double.NaN;
            option.MinHeight = 34;
            option.Padding = new(6, 4, 6, 4);
            option.IsEnabled = !active && available && ActiveAgent is null;
            AutomationProperties.SetItemStatus(option, mode == selected ? "Selected" : "Not selected");
            option.Click += async (_, _) =>
            {
                if (!ReferenceEquals(current, session)) return;
                await Run(() => App.ThreadSettings.SelectComposerGoalModeAsync(session, mode));
                flyout.Hide();
                RenderComposerGoalControls();
            };
            list.Children.Add(option);
        }

        if (session.ManagedGoalStatus is { } status)
        {
            var label = ComposerOptionDetail(status);
            label.Margin = new(7, 3, 7, 2);
            list.Children.Add(label);
        }
        list.Children.Add(ComposerOptionsDivider());
        var stopTitle = active ? "Stop Goal" : "Turn off Goal";
        var stopDetail = session.HasManagedGoal ? "Cancel future passes." : "";
        var stopRow = ComposerOptionsRow(stopTitle, stopDetail, ComposerOptionsIcon("\uE711", foreground));
        var stop = ComposerOptionsButtonFor(stopRow, stopTitle, "ComposerGoalStop", stopDetail);
        stop.Click += async (_, _) =>
        {
            flyout.Hide();
            if (!ReferenceEquals(current, session)) return;
            await Run(() => App.ThreadSettings.SetComposerGoalModeAsync(session, false));
            RenderComposerGoalControls();
        };
        list.Children.Add(stop);
        composerGoalFlyout = flyout;
        composerGoalFlyoutSession = session;
        flyout.Closed += (_, _) =>
        {
            if (!ReferenceEquals(composerGoalFlyout, flyout)) return;
            composerGoalFlyout = null;
            composerGoalFlyoutSession = null;
        };
        flyout.ShowAt(anchor);
    }
}
