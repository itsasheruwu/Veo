using Veo_Windows.Services;
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
    string composerAccess = "Workspace";
    string composerMode = "Agentic";
    bool composerWild;
    Flyout? composerModelFlyout;
    (string ThreadId, long Generation)? composerGoalRead;

    bool UsesSliderPicker => workspace.Preferences.ModelPicker != "Native";

    void RenderComposerControls()
    {
        if (composerPillFlyout is not null) return;
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
        RenderComposerSpeedMark(speed);
        var mark = !direct ? "\uE1CE" : ModelPickerVisuals.ModelGlyph(modelKey);
        if (direct && mark.Length == 0 && catalogModel?.IsExternal != true)
            mark = ModelPickerVisuals.ModelGlyph(NativeModelDescriptor.Normalize(title));
        ModelMark.Glyph = mark;
        ModelMark.Visibility = mark.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ModelCube.Visibility = mark.Length == 0 && !slider ? Visibility.Visible : Visibility.Collapsed;
        ModelMarkHost.Visibility = mark.Length > 0 || !slider ? Visibility.Visible : Visibility.Collapsed;
        UpdateComposerModelLayout();
        var speedTitle = speed switch { ModelSpeed.Fast => ", Fast Mode on", ModelSpeed.Ultrafast => ", Ultrafast on", _ => "" };
        AutomationProperties.SetName(ModelTrigger, $"Model settings, {title}" + (effortTitle.Length > 0 ? $", {effortTitle} reasoning" : "") + speedTitle);
        SendFace.Background = highContrast ? new SolidColorBrush(new UISettings().UIElementColor(UIElementType.Highlight)) : new SolidColorBrush(Colors.White);
        SendGlyph.Foreground = highContrast ? new SolidColorBrush(new UISettings().UIElementColor(UIElementType.HighlightText)) : new SolidColorBrush(Colors.Black);
        ToolTipService.SetToolTip(ModelTrigger, direct && catalogModel is { Description.Length: > 0 } ? catalogModel.Description : title);

        var permission = ComposerPermission.Get(composerAccess);
        AccessLabel.Text = permission.Title;
        AccessLabel.Foreground = AccessChevron.Foreground = AccessIcon.Foreground = permission.Id == "Full access"
            && !new AccessibilitySettings().HighContrast
            ? new SolidColorBrush(Windows.UI.Color.FromArgb(255, 231, 149, 57))
            : ComposerKeyHints.Foreground;
        AccessIcon.Glyph = AccessGlyph(permission);
        AccessButton.IsEnabled = ActiveAgent is null;
        AutomationProperties.SetName(AccessButton, $"Permissions, {permission.Title}");
        ToolTipService.SetToolTip(AccessButton, ActiveAgent is null ? permission.Detail : "This provider manages its own permissions.");
        if (current?.Record is { } record)
        {
            WelcomeProjectLabel.Text = record.WorkspaceKind switch
            {
                "scratch" => "Choose project", "temporary" => "Temporary workspace", _ => ProjectFolderName(record.Cwd)
            };
            ToolTipService.SetToolTip(WelcomeProjectButton, record.WorkspaceKind == "project" ? record.Cwd : "Choose the project for this chat");
        }
        RenderProvider();
        RenderComposerGoalControls();
    }

    void RenderComposerSpeedMark(ModelSpeed speed)
    {
        var highContrast = new AccessibilitySettings().HighContrast;
        var dark = ActualTheme == ElementTheme.Dark;
        ModelSpeedMark.Visibility = speed == ModelSpeed.Standard ? Visibility.Collapsed : Visibility.Visible;
        ModelSpeedMark.Data = speed == ModelSpeed.Ultrafast ? composerBoltPair : composerBolt;
        ModelSpeedMark.Fill = highContrast ? ModelLabel.Foreground
            : new SolidColorBrush(speed == ModelSpeed.Ultrafast
                ? ModelPickerVisuals.PeakText(dark, blue: false) : ModelPickerVisuals.FastText(dark));
        ModelSpeedMark.Width = speed == ModelSpeed.Ultrafast ? 14 : 10;
    }

    void UpdateComposerModelLayout()
    {
        if (composerPillFlyout is not null) return;
        ModelEffortLabel.Visibility = ModelEffortLabel.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ModelLabel.MaxWidth = ComposerPanel.ActualWidth > 0
            ? Math.Clamp(ComposerPanel.ActualWidth - 255, 58, 185) : 185;
    }

    void InitializeComposerModePills()
    {
        static Windows.UI.Color Rgb(byte r, byte g, byte b) => Windows.UI.Color.FromArgb(255, r, g, b);

        ComposerModePill.Configure(ComposerPlanPill, "Plan", new FontIcon { Glyph = "\uE77F", FontSize = 11 },
            size: new(59, 23), dark: Rgb(255, 192, 58), light: Rgb(148, 79, 0));
        ComposerModePill.Configure(ComposerDebugPill, "Debug", new FontIcon { Glyph = "\uEBE8", FontSize = 11 },
            size: new(74, 24), dark: Rgb(255, 90, 255), light: Rgb(135, 36, 146));
        ComposerModePill.Configure(ComposerAskPill, "Ask", new FontIcon { Glyph = "\uE897", FontSize = 11 }, size: new(54, 23), dark: Rgb(89, 166, 239), light: Rgb(12, 90, 157));
        ComposerModePill.Configure(ComposerRobloxPill, "Roblox", ModelPickerVisuals.RobloxIcon(new SolidColorBrush(Microsoft.UI.Colors.IndianRed)), size: new(78, 23), dark: Rgb(231, 84, 100), light: Rgb(153, 21, 44));
        ComposerModePill.Configure(ComposerWildPill, "Wild", ModelPickerVisuals.WildIcon(new SolidColorBrush(Rgb(218, 100, 152))), size: new(56, 23), dark: Rgb(218, 100, 152), light: Rgb(143, 35, 89));
        ComposerModePill.Configure(ComposerGoalPill, "Goal", ModelPickerVisuals.GoalIcon(ComposerGoalPill.Foreground),
            size: new(62, 22), dark: Rgb(0, 255, 126), light: Rgb(6, 116, 58), opensSettings: true);
    }

    void RenderComposerGoalControls()
    {
        var session = current;
        var enabled = session is not null && App.ThreadSettings.ComposerGoalEnabled(session);
        if (composerGoalFlyout is { } flyout && (!enabled || !ReferenceEquals(composerGoalFlyoutSession, session))) flyout.Hide();
        ComposerPlanPill.Visibility = composerMode == "Plan" ? Visibility.Visible : Visibility.Collapsed;
        ComposerDebugPill.Visibility = composerMode == "Debug" ? Visibility.Visible : Visibility.Collapsed;
        ComposerGoalPill.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        ComposerAskPill.Visibility = composerMode == "Ask" ? Visibility.Visible : Visibility.Collapsed;
        ComposerRobloxPill.Visibility = composerMode == "Roblox" ? Visibility.Visible : Visibility.Collapsed;
        ComposerWildPill.Visibility = composerWild ? Visibility.Visible : Visibility.Collapsed;
        ComposerModePills.Visibility = enabled || composerWild || composerMode != "Agentic" ? Visibility.Visible : Visibility.Collapsed;
        var goal = session is null ? null : App.ThreadSettings.ActiveGoal(session);
        var mode = goal is not null ? ComposerGoalMode.ProviderManaged : session?.GoalMode ?? ComposerGoalMode.ProviderManaged;
        AutomationProperties.SetHelpText(ComposerGoalPill, ComposerGoals.Title(mode));
        ToolTipService.SetToolTip(ComposerGoalPill, goal is null ? "Goal settings · " + ComposerGoals.Title(mode) : "Goal settings · " + goal.Objective);
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

    void UpdateComposerKeyHints()
    {
        UpdateComposerModelLayout();
        UpdateComposerSendRow();
    }

    void UpdateComposerSendRow()
    {
        var width = ComposerPanel.ActualWidth - 26;
        if (width <= 0 || DictationActive || composerPillFlyout is not null) return;
        var unconstrained = new Size(double.PositiveInfinity, double.PositiveInfinity);
        ComposerKeyHints.Visibility = Visibility.Collapsed;
        ModelPickerSlot.Measure(unconstrained);
        ComposerSendControls.Measure(unconstrained);
        var gap = ComposerToolbar.ColumnSpacing;
        var modelGroup = ComposerOptionsButton.Width + ModelPickerSlot.DesiredSize.Width + gap;
        AccessButton.Measure(unconstrained);
        var permissions = AccessButton.DesiredSize.Width;
        var send = ComposerSendControls.DesiredSize.Width;
        var widthNeeded = modelGroup + permissions + send + 2 * gap;
        if (widthNeeded + 123 <= width && ComposerModePills.Visibility == Visibility.Collapsed &&
            current is { Timeline.IsRunning: false })
            ComposerKeyHints.Visibility = Visibility.Visible;

        var permissionsRow = modelGroup + permissions + gap <= width ? 0 : 1;
        var sendRow = widthNeeded <= width ? 0
            : permissionsRow == 0 || permissions + gap + send <= width ? 1 : 2;
        Grid.SetRow(AccessButton, permissionsRow);
        Grid.SetColumn(AccessButton, permissionsRow == 0 ? 2 : 0);
        Grid.SetColumnSpan(AccessButton, permissionsRow == 0 ? 1 : 2);
        Grid.SetRow(ComposerSendControls, sendRow);
        Grid.SetColumn(ComposerSendControls, sendRow == 0 ? 3 : 0);
        Grid.SetColumnSpan(ComposerSendControls, sendRow == 0 ? 1 : 4);
        ComposerToolbar.RowSpacing = sendRow == 0 ? 0 : gap;
    }

    void Model_Click(object sender, RoutedEventArgs e)
    {
        if (current is not { } session) return;
        if (composerModelFlyout is { } showing) { showing.Hide(); return; }
        var studioHeight = XamlRoot?.Content is UIElement root
            ? Math.Clamp(ModelTrigger.TransformToVisual(root).TransformPoint(new Point(0, 0)).Y
                - ModelPickerVisuals.PointerHeight - 12, 100, ModelPickerVisuals.StudioHeight)
            : ModelPickerVisuals.StudioHeight;
        var content = CreateModelPicker(session, UsesSliderPicker, studioHeight, ActiveAgent);
        var flyout = new Flyout
        {
            Content = content, Placement = FlyoutPlacementMode.Top,
            AreOpenCloseAnimationsEnabled = ModelPickerVisuals.MotionEnabled,
            FlyoutPresenterStyle = (Style)Resources["ModelPickerFlyoutPresenter"]
        };
        composerModelFlyout = flyout;
        flyout.Closed += (_, _) => { if (composerModelFlyout == flyout) composerModelFlyout = null; };
        ShowComposerPill(flyout, composerModelPill);
    }

    ModelPickerPanel CreateModelPicker(ThreadSession session, bool advanced, double studioHeight, string? agent = null) =>
        new ModelPickerPanel(App.Models, App.Routing, session, SettingsSnapshot, choice =>
        {
            if (!ReferenceEquals(current, session)) return;
            if (agent is not null)
            {
                if (ActiveAgent != agent) return;
                Agents.SetModelSelection(agent, choice.ModelId, choice.Tier == AgentConnection.GrokFastId, choice.Effort);
                Render();
                return;
            }
            ApplyModelChoice(choice);
            composerRevision++;
            _ = Run(SaveDraftNowAsync);
            Render();
        }, advanced, studioHeight, Resources,
        agent is null ? null : () => Agents.Connections.GetValueOrDefault(agent),
        agent is null ? null : () => Agents.Connections.TryGetValue(agent, out var connection) &&
            (connection.Models.Length == 0 || connection.Model.Length > 0 && connection.SelectedModel?.Efforts is null ||
                agent == "grok-build" && connection.Models.All(model => model.Efforts is null))
            ? Agents.RefreshModelCatalogAsync(agent) : Task.CompletedTask);

    Flyout ComposerFlyout(FrameworkElement content, FlyoutPlacementMode placement = FlyoutPlacementMode.TopEdgeAlignedLeft) => new()
    {
        Placement = placement, Content = content, AreOpenCloseAnimationsEnabled = false,
        FlyoutPresenterStyle = (Style)Resources["ComposerFlyoutPresenter"]
    };

    static string AccessGlyph(ComposerPermission permission) => permission.Id switch
    {
        "Read only" => "\uEA18", "Auto" => "\uE9D9", "Full access" => "\uE785", _ => "\uE70F"
    };

    Flyout? permissionsFlyout;

    void ComposerAccess_Click(object sender, RoutedEventArgs e) => ShowComposerAccess();

    void ShowComposerAccess()
    {
        if (current is not { } session || ActiveAgent is not null || DictationActive) return;
        if (permissionsFlyout is { } open) { open.Hide(); return; }
        var list = new StackPanel { Width = 260, Spacing = 4 };
        list.Children.Add(new TextBlock { Text = "Permissions", FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(7, 0, 7, 3) });
        var flyout = new Flyout { Content = list, Placement = FlyoutPlacementMode.TopEdgeAlignedLeft };
        foreach (var mode in ComposerPermission.Options)
        {
            var available = !mode.AutomaticReview || workspace.SupportsAutomaticReview;
            var description = available ? mode.Detail : "Automatic review requires a supported Codex runtime.";
            var label = new StackPanel { Spacing = 2, Children =
            {
                new TextBlock { Text = mode.Title, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium },
                new TextBlock { Text = description, FontSize = 11, TextWrapping = TextWrapping.Wrap,
                    Foreground = ComposerKeyHints.Foreground }
            } };
            var row = new Grid { ColumnSpacing = 9 };
            row.ColumnDefinitions.Add(new() { Width = new GridLength(18) });
            row.ColumnDefinitions.Add(new());
            row.ColumnDefinitions.Add(new() { Width = new GridLength(16) });
            row.Children.Add(new FontIcon { Glyph = AccessGlyph(mode), FontSize = 12, VerticalAlignment = VerticalAlignment.Top });
            Grid.SetColumn(label, 1);
            row.Children.Add(label);
            if (composerAccess == mode.Id)
            {
                var check = new FontIcon { Glyph = "\uE73E", FontSize = 11 };
                Grid.SetColumn(check, 2);
                row.Children.Add(check);
            }
            var option = new Button
            {
                Style = (Style)Application.Current.Resources["SubtleButtonStyle"], Content = row,
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(7, 6, 7, 6), IsEnabled = available
            };
            AutomationProperties.SetName(option, mode.Title + (composerAccess == mode.Id ? ", selected" : ""));
            AutomationProperties.SetHelpText(option, description);
            option.Click += async (_, _) =>
            {
                if (!ReferenceEquals(session, current) || composerAccess == mode.Id) { flyout.Hide(); return; }
                composerAccess = mode.Id;
                flyout.Hide();
                await Run(SaveComposerControlAsync);
            };
            list.Children.Add(option);
        }
        permissionsFlyout = flyout;
        flyout.Closed += (_, _) => { if (permissionsFlyout == flyout) permissionsFlyout = null; };
        ShowComposerPill(flyout, composerPermissionsPill);
    }

    async void ComposerWildPill_Click(object sender, RoutedEventArgs e) =>
        await Run(() => SetComposerWildAsync(false));

    async Task SetComposerWildAsync(bool enabled)
    {
        if (composerWild == enabled) return;
        composerWild = enabled;
        await SaveComposerControlAsync();
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
