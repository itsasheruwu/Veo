using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Input;
using Windows.Foundation;
using Windows.UI.ViewManagement;
using Veo.Core;
using Veo.Protocol;
using Veo_Windows.Controls;

namespace Veo_Windows;

public sealed partial class MainPage
{
    readonly PathGeometry composerBolt = ModelPickerVisuals.BoltGeometry();
    readonly PathGeometry composerBoltPair = ModelPickerVisuals.BoltGeometry(pair: true);
    readonly SolidColorBrush modelTriggerFill = new();
    bool modelTriggerHovered;
    string composerAccess = "Workspace";
    string composerMode = "Agentic";
    Flyout? composerModelFlyout;
    (string ThreadId, long Generation)? composerGoalRead;

    bool UsesSliderPicker => workspace.Preferences.ModelPicker != "Native";

    void RenderComposerControls()
    {
        var catalogModel = App.Models.Find(modelCatalogId ?? model);
        var title = catalogModel?.DisplayName ?? ModelPickerCatalog.FormatName(
            workspace.Models.FirstOrDefault(candidate => candidate.Id == model)?.Name ?? model ?? "Select model");
        var modelKey = NativeModelDescriptor.Normalize(catalogModel?.Model ?? model ?? "");
        var slider = UsesSliderPicker;
        var direct = routingMode == "Direct";
        if (!direct) title = routingMode switch
        {
            "FirstPrompt" => "Auto", "Family56" => "5.6 Auto", "Family6" => "6 Auto", _ => routingMode
        };
        var effortTitle = direct && effort is { Length: > 0 } value ? new ModelReasoning(value, "").Title : "";
        var speed = direct ? catalogModel?.SpeedFor(tier) ?? ModelSpeed.Standard : ModelSpeed.Standard;
        var highContrast = new AccessibilitySettings().HighContrast;
        var dark = ActualTheme == ElementTheme.Dark;
        ModelLabel.Text = title;
        ModelEffortLabel.Text = effortTitle;
        ModelEffortLabel.FontWeight = slider ? Microsoft.UI.Text.FontWeights.Normal : Microsoft.UI.Text.FontWeights.Medium;
        var isPeak = direct && catalogModel is { Efforts.Length: > 1 } && catalogModel.Efforts[^1].Id == effort;
        ModelEffortLabel.Foreground = isPeak && slider && !highContrast
            ? new SolidColorBrush(ModelPickerVisuals.PeakText(dark, ModelPickerVisuals.UsesBluePalette(modelKey)))
            : ComposerKeyHints.Foreground;
        ModelSpeedMark.Visibility = speed == ModelSpeed.Standard ? Visibility.Collapsed : Visibility.Visible;
        ModelSpeedMark.Data = speed == ModelSpeed.Ultrafast ? composerBoltPair : composerBolt;
        ModelSpeedMark.Fill = highContrast ? ModelLabel.Foreground
            : new SolidColorBrush(speed == ModelSpeed.Ultrafast
                ? ModelPickerVisuals.PeakText(dark, blue: false) : ModelPickerVisuals.FastText(dark));
        ModelSpeedMark.Width = speed == ModelSpeed.Ultrafast ? 14 : 10;
        ModelTrigger.Width = slider ? ModelPickerVisuals.TriggerWidth : double.NaN;
        ModelTrigger.Height = ModelPickerVisuals.TriggerHeight;
        ModelTrigger.CornerRadius = new CornerRadius(slider ? ModelPickerVisuals.TriggerHeight / 2 : 7);
        ModelTriggerLabel.Spacing = slider ? 5 : 6;
        ModelTriggerLabel.HorizontalAlignment = slider ? HorizontalAlignment.Center : HorizontalAlignment.Left;
        ModelTriggerLabel.Margin = slider ? new Thickness(12, 0, 26, 0) : new Thickness(0);
        StudioChevron.Visibility = slider ? Visibility.Collapsed : Visibility.Visible;
        SliderChevron.Visibility = slider ? Visibility.Visible : Visibility.Collapsed;
        var mark = !direct ? "\uE1CE" : ModelPickerVisuals.ModelGlyph(modelKey);
        if (direct && mark.Length == 0 && catalogModel?.IsExternal != true)
            mark = ModelPickerVisuals.ModelGlyph(NativeModelDescriptor.Normalize(title));
        ModelMark.Glyph = mark;
        ModelMark.Visibility = mark.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ModelCube.Visibility = mark.Length == 0 && !slider ? Visibility.Visible : Visibility.Collapsed;
        ModelMarkHost.Visibility = mark.Length > 0 || !slider ? Visibility.Visible : Visibility.Collapsed;
        UpdateModelTriggerFill();
        UpdateComposerModelLayout();
        var speedTitle = speed switch { ModelSpeed.Fast => ", Fast Mode on", ModelSpeed.Ultrafast => ", Ultrafast on", _ => "" };
        AutomationProperties.SetName(ModelTrigger, $"Model settings, {title}" + (effortTitle.Length > 0 ? $", {effortTitle} reasoning" : "") + speedTitle);
        SendFace.Background = highContrast ? new SolidColorBrush(new UISettings().UIElementColor(UIElementType.Highlight)) : new SolidColorBrush(Colors.White);
        SendGlyph.Foreground = highContrast ? new SolidColorBrush(new UISettings().UIElementColor(UIElementType.HighlightText)) : new SolidColorBrush(Colors.Black);
        ToolTipService.SetToolTip(ModelTrigger, direct && catalogModel is { Description.Length: > 0 } ? catalogModel.Description : title);

        AccessLabel.Text = composerAccess;
        AccessLabel.Foreground = AccessChevron.Foreground = AccessIcon.Foreground = composerAccess == "Full access"
            && !new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast
            ? new SolidColorBrush(Windows.UI.Color.FromArgb(255, 231, 149, 57))
            : ComposerKeyHints.Foreground;
        AccessIcon.Glyph = AccessGlyph(composerAccess);
        AutomationProperties.SetName(AccessButton, $"Access mode, {composerAccess}");
        ToolTipService.SetToolTip(AccessButton, composerAccess switch
        {
            "Read only" => "Inspect files and changes without writing to the workspace.",
            "Full access" => "Allow the runtime to work outside this project's sandbox.",
            _ => "Allow writes within the current workspace. Other access requires approval."
        });
        if (current?.Record is { } record)
        {
            WelcomeProjectLabel.Text = record.WorkspaceKind switch
            {
                "scratch" => "Choose project", "temporary" => "Temporary workspace", _ => ProjectFolderName(record.Cwd)
            };
            ToolTipService.SetToolTip(WelcomeProjectButton, record.WorkspaceKind == "project" ? record.Cwd : "Choose the project for this chat");
        }
        RenderComposerGoalControls();
    }

    void ModelTrigger_PointerEntered(object sender, PointerRoutedEventArgs e)
    {
        modelTriggerHovered = true;
        UpdateModelTriggerFill();
    }

    void ModelTrigger_PointerExited(object sender, PointerRoutedEventArgs e)
    {
        modelTriggerHovered = false;
        UpdateModelTriggerFill();
    }

    void UpdateModelTriggerFill()
    {
        if (!ReferenceEquals(ModelTrigger.Background, modelTriggerFill)) ModelTrigger.Background = modelTriggerFill;
        if (!UsesSliderPicker) { modelTriggerFill.Color = Colors.Transparent; return; }
        var opacity = composerModelFlyout is not null || modelTriggerHovered ? (byte)22 : (byte)13;
        var value = ActualTheme == ElementTheme.Dark ? (byte)255 : (byte)0;
        modelTriggerFill.Color = Windows.UI.Color.FromArgb(opacity, value, value, value);
    }

    void UpdateComposerModelLayout()
    {
        var slider = UsesSliderPicker;
        var showsEffort = ModelEffortLabel.Text.Length > 0
            && (slider || ComposerPanel.ActualWidth <= 0 || ComposerPanel.ActualWidth >= 340);
        ModelEffortLabel.Visibility = showsEffort ? Visibility.Visible : Visibility.Collapsed;
        ModelSeparator.Visibility = !slider && showsEffort ? Visibility.Visible : Visibility.Collapsed;

        if (!slider)
        {
            ModelLabel.MaxWidth = ComposerPanel.ActualWidth > 0 ? Math.Clamp(ComposerPanel.ActualWidth - 230, 40, 130) : 130;
            return;
        }
        ModelEffortLabel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var effortWidth = showsEffort ? ModelEffortLabel.DesiredSize.Width + ModelTriggerLabel.Spacing : 0;
        var modelIcon = ModelMarkHost.Visibility == Visibility.Visible ? ModelMarkHost.Width + ModelTriggerLabel.Spacing : 0;
        var speedIcon = ModelSpeedMark.Visibility == Visibility.Visible ? ModelSpeedMark.Width + ModelTriggerLabel.Spacing : 0;
        ModelLabel.MaxWidth = Math.Max(32, ModelPickerVisuals.TriggerWidth - 38 - effortWidth - modelIcon - speedIcon);
    }

    void InitializeComposerModePills()
    {
        static Windows.UI.Color Rgb(byte r, byte g, byte b) => Windows.UI.Color.FromArgb(255, r, g, b);

        ComposerModePill.Configure(ComposerPlanPill, "Plan", new FontIcon { Glyph = "\uE77F", FontSize = 11 },
            size: new(59, 23), dark: Rgb(255, 192, 58), light: Rgb(148, 79, 0));
        ComposerModePill.Configure(ComposerDebugPill, "Debug", new FontIcon { Glyph = "\uEBE8", FontSize = 11 },
            size: new(74, 24), dark: Rgb(255, 90, 255), light: Rgb(135, 36, 146));
        ComposerModePill.Configure(ComposerGoalPill, "Goal", ModelPickerVisuals.GoalIcon(ComposerGoalPill.Foreground),
            size: new(62, 22), dark: Rgb(0, 255, 126), light: Rgb(6, 116, 58));
    }

    void RenderComposerGoalControls()
    {
        var session = current;
        var enabled = session is not null && App.ThreadSettings.ComposerGoalEnabled(session);
        ComposerPlanPill.Visibility = composerMode == "Plan" ? Visibility.Visible : Visibility.Collapsed;
        ComposerDebugPill.Visibility = composerMode == "Debug" ? Visibility.Visible : Visibility.Collapsed;
        ComposerGoalPill.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        ComposerModePills.Visibility = enabled || composerMode is "Plan" or "Debug" ? Visibility.Visible : Visibility.Collapsed;
        var goal = session is null ? null : App.ThreadSettings.ActiveGoal(session);
        ToolTipService.SetToolTip(ComposerGoalPill, goal is null ? "Turn off Goal" : "Turn off Goal · " + goal.Objective);
        UpdateComposerKeyHints();
        if (session?.Record.CodexThreadId is { } threadId && workspace.Runtime.RuntimeState == CodexRuntimeState.Ready)
        {
            var key = (threadId, workspace.Runtime.Generation);
            if (composerGoalRead != key && App.ThreadSettings.Available("thread/goal/get"))
            {
                composerGoalRead = key;
                _ = ReadComposerGoalAsync(session);
            }
        }
        else composerGoalRead = null;
    }

    async Task ReadComposerGoalAsync(ThreadSession session)
    {
        try { await App.ThreadSettings.RefreshGoalAsync(session); }
        catch (Exception e) when (e is NotSupportedException or CodexRpcException { Code: -32601 }) { }
        catch (Exception e) { if (ReferenceEquals(current, session)) ShowError(e); }
    }

    async void ComposerModePill_Click(object sender, RoutedEventArgs e) =>
        await Run(() => SetComposerModeAsync("Agentic"));

    async void ComposerGoalPill_Click(object sender, RoutedEventArgs e)
    {
        if (current is not { } session) return;
        await Run(() => App.ThreadSettings.SetComposerGoalModeAsync(session, false));
        RenderComposerGoalControls();
    }

    void UpdateComposerKeyHints()
    {
        UpdateComposerModelLayout();
        ComposerKeyHints.Visibility = ComposerPanel.ActualWidth >= 415
            && ComposerModePills.Visibility == Visibility.Collapsed
            && current is { Timeline.IsRunning: false }
            ? Visibility.Visible : Visibility.Collapsed;
        UpdateComposerSendRow();
    }

    void UpdateComposerSendRow()
    {
        var compact = false;
        if (ComposerModePills.Visibility == Visibility.Visible && ComposerToolbar.ActualWidth > 0)
        {
            var unconstrained = new Size(double.PositiveInfinity, double.PositiveInfinity);
            ModelTrigger.Measure(unconstrained);
            AccessButton.Measure(unconstrained);
            ComposerSendControls.Measure(unconstrained);
            var requiredWidth = ComposerOptionsButton.Width + ModelTrigger.DesiredSize.Width
                + AccessButton.DesiredSize.Width + ComposerSendControls.DesiredSize.Width
                + 3 * ComposerToolbar.ColumnSpacing;
            compact = requiredWidth > ComposerToolbar.ActualWidth;
        }

        var row = compact ? 1 : 0;
        if (Grid.GetRow(ComposerSendControls) == row) return;
        Grid.SetRow(ComposerSendControls, row);
        Grid.SetColumn(ComposerSendControls, compact ? 0 : 3);
        Grid.SetColumnSpan(ComposerSendControls, compact ? 4 : 1);
        ComposerToolbar.RowSpacing = compact ? ComposerToolbar.ColumnSpacing : 0;
    }

    void Model_Click(object sender, RoutedEventArgs e)
    {
        if (current is not { } session) return;
        if (composerModelFlyout is { } showing) { showing.Hide(); return; }
        var studioHeight = XamlRoot?.Content is UIElement root
            ? Math.Clamp(ModelTrigger.TransformToVisual(root).TransformPoint(new Point(0, 0)).Y
                - ModelPickerVisuals.PointerHeight - 12, 100, ModelPickerVisuals.StudioHeight)
            : ModelPickerVisuals.StudioHeight;
        var content = new ModelPickerPanel(App.Models, App.Routing, session, SettingsSnapshot, choice =>
        {
            if (!ReferenceEquals(current, session)) return;
            ApplyModelChoice(choice);
            composerRevision++;
            _ = Run(SaveDraftNowAsync);
            Render();
        }, UsesSliderPicker, studioHeight, Resources);
        var flyout = new Flyout
        {
            Content = content, Placement = FlyoutPlacementMode.Top,
            AreOpenCloseAnimationsEnabled = ModelPickerVisuals.MotionEnabled,
            FlyoutPresenterStyle = (Style)Resources["ModelPickerFlyoutPresenter"]
        };
        composerModelFlyout = flyout;
        flyout.Closed += (_, _) => { composerModelFlyout = null; UpdateModelTriggerFill(); };
        UpdateModelTriggerFill();
        flyout.ShowAt(ModelTrigger);
    }

    Flyout ComposerFlyout(FrameworkElement content, FlyoutPlacementMode placement = FlyoutPlacementMode.TopEdgeAlignedLeft) => new()
    {
        Placement = placement, Content = content, AreOpenCloseAnimationsEnabled = false,
        FlyoutPresenterStyle = (Style)Resources["ComposerFlyoutPresenter"]
    };

    static string AccessGlyph(string access) => access switch
    {
        "Read only" => "\uE890", "Full access" => "\uE785", _ => "\uE8B7"
    };

    void ComposerAccess_Click(object sender, RoutedEventArgs e) => ShowComposerAccess();

    void ShowComposerAccess()
    {
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.TopEdgeAlignedLeft, AreOpenCloseAnimationsEnabled = false };
        foreach (var access in new[] { "Read only", "Workspace", "Full access" })
        {
            var item = new RadioMenuFlyoutItem
            {
                Text = access, GroupName = "ComposerAccess", IsChecked = composerAccess == access,
                Icon = new FontIcon { Glyph = AccessGlyph(access), FontSize = 12 }
            };
            item.Click += async (_, _) =>
            {
                if (composerAccess == access) return;
                composerAccess = access;
                await SaveComposerControlAsync();
            };
            menu.Items.Add(item);
        }
        menu.ShowAt(AccessButton);
    }

    async Task SetComposerModeAsync(string mode)
    {
        if (composerMode == mode) return;
        composerMode = mode;
        await SaveComposerControlAsync();
    }

    async Task SaveComposerControlAsync()
    {
        RenderComposerControls();
        if (!initialized || loading) return;
        composerRevision++;
        await Run(SaveDraftNowAsync);
    }

    async void ComposerProject_Click(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        var session = current;
        var catalog = await workspace.CatalogAsync();
        if (!ReferenceEquals(current, session) || WelcomeProjectRow.Visibility != Visibility.Visible) return;
        var panel = new StackPanel { Width = 310, Padding = new Thickness(12), Spacing = 6 };
        panel.Children.Add(new TextBlock { Text = "Choose project", FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var projects = new StackPanel { Spacing = 2 };
        var flyout = ComposerFlyout(panel, FlyoutPlacementMode.Top);
        foreach (var path in catalog.Where(thread => thread.WorkspaceKind == "project" && Directory.Exists(thread.Cwd))
            .Select(thread => thread.Cwd).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var button = ComposerOptionRow(ProjectFolderName(path), path, "\uE8B7", string.Equals(session?.Record.Cwd, path, StringComparison.OrdinalIgnoreCase));
            button.Click += async (_, _) => { flyout.Hide(); await Run(() => CreateProjectChatAsync(path)); };
            projects.Children.Add(button);
        }
        if (projects.Children.Count > 0) panel.Children.Add(new ScrollViewer { Content = projects, MaxHeight = 220 });
        panel.Children.Add(ComposerFlyoutDivider());
        var add = ComposerOptionRow("Add project…", "", "\uE838");
        add.Click += async (_, _) => { flyout.Hide(); await Run(OpenProjectAsync); };
        panel.Children.Add(add);
        flyout.ShowAt(WelcomeProjectButton);
    });

    Button ComposerOptionRow(string title, string detail, string glyph, bool selected = false, IconElement? icon = null)
    {
        var mark = icon ?? new FontIcon { Glyph = glyph, FontSize = 13, Foreground = ComposerKeyHints.Foreground };
        var row = ComposerOptionContent(title, detail, mark);
        if (selected)
        {
            var check = new FontIcon { Glyph = "\uE73E", FontSize = 11 };
            Grid.SetColumn(check, 2);
            row.Children.Add(check);
        }
        var button = new Button
        {
            Style = (Style)Resources["ComposerChromeButton"], Content = row, Padding = new Thickness(6, 4, 6, 4),
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch
        };
        AutomationProperties.SetName(button, selected ? title + ", selected" : title);
        if (detail.Length > 0) AutomationProperties.SetHelpText(button, detail);
        return button;
    }

    Grid ComposerOptionContent(string title, string detail, IconElement mark)
    {
        var label = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        label.Children.Add(new TextBlock { Text = title, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium });
        if (detail.Length > 0) label.Children.Add(new TextBlock { Text = detail, FontSize = 10.5, Foreground = ComposerKeyHints.Foreground, TextTrimming = TextTrimming.CharacterEllipsis });
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        mark.VerticalAlignment = VerticalAlignment.Center;
        mark.IsHitTestVisible = false;
        AutomationProperties.SetAccessibilityView(mark, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        row.Children.Add(mark);
        Grid.SetColumn(label, 1);
        row.Children.Add(label);
        return row;
    }

    Border ComposerFlyoutDivider() => new() { Height = 1, Margin = new Thickness(4, 3, 4, 3), Background = ComposerPanel.BorderBrush };

    static string ProjectFolderName(string path) => Path.GetFileName(Path.TrimEndingDirectorySeparator(path)) is { Length: > 0 } name ? name : path;
}
