using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Veo.Core;
using Veo.Infrastructure.PromptLibrary;
using Veo.Protocol;
using Veo_Windows.Controls;
using Veo_Windows.Services;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Veo_Windows;

public sealed partial class MainPage
{
    static class ComposerOptionsMetrics
    {
        internal const double Width = 326;
        internal const double Inset = 12;
        internal const double RowHeight = 30;
        internal const double RowSpacing = 10;
        internal const double ModeSpacing = 8;
        internal const double IconWidth = 16;
        internal const double IconHeight = 18;
        internal const double LabelGap = 9;
        internal const double Title = 12.5;
        internal const double Detail = 10.5;
    }

    Flyout? composerOptionsFlyout;

    static double ComposerMenuHeight(FrameworkElement anchor, double maximum)
    {
        if (anchor.XamlRoot?.Content is not UIElement root) return maximum;
        var top = anchor.TransformToVisual(root).TransformPoint(new(0, 0)).Y;
        return Math.Clamp(top - ModelPickerVisuals.PointerHeight - 12, 84, maximum);
    }

    void ComposerOptions_Click(object sender, RoutedEventArgs e)
    {
        if (composerOptionsFlyout is { } open) { open.Hide(); return; }

        var session = current;
        var pageHost = new ContentControl
        {
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Top
        };
        var scroll = new ScrollViewer
        {
            Width = ComposerOptionsMetrics.Width, MaxHeight = ComposerMenuHeight(ComposerOptionsButton, 520), Content = pageHost,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalContentAlignment = HorizontalAlignment.Stretch
        };
        AutomationProperties.SetName(scroll, "Composer options");
        AutomationProperties.SetAutomationId(scroll, "ComposerOptionsMenu");

        var surface = WorkspaceAppearance.Region(this, "Acrylic", WorkspaceSurface.Composer);
        var flyout = new Flyout
        {
            Content = new StackPanel { Children =
            {
                new Border { CornerRadius = new(ModelPickerVisuals.CornerRadius), Background = surface, Child = scroll },
                ModelPickerVisuals.PickerPointer(surface)
            } },
            Placement = FlyoutPlacementMode.Top,
            ShouldConstrainToRootBounds = true,
            AreOpenCloseAnimationsEnabled = ModelPickerVisuals.MotionEnabled,
            FlyoutPresenterStyle = (Style)Resources["ModelPickerFlyoutPresenter"]
        };
        var dark = ActualTheme == ElementTheme.Dark;
        var contrast = new AccessibilitySettings().HighContrast;
        var ui = new UISettings();
        Brush ColorPair(uint light, uint darkColor)
        {
            var value = dark ? darkColor : light;
            return contrast ? ComposerKeyHints.Foreground
                : new SolidColorBrush(Color.FromArgb(255, (byte)(value >> 16), (byte)(value >> 8), (byte)value));
        }
        var neutral = ComposerKeyHints.Foreground;
        var accent = contrast ? neutral : new SolidColorBrush(ui.GetColorValue(UIColorType.Accent));
        var customAccent = workspace.Preferences.Accent;
        if (!contrast && customAccent is { Length: 7 } && customAccent[0] == '#'
            && uint.TryParse(customAccent[1..], System.Globalization.NumberStyles.HexNumber, null, out var hex))
            accent = ColorPair(hex, hex);
        var orange = ColorPair(0x965000, 0xFF9E33);
        var purple = ColorPair(0x852492, 0xE746FC);
        var green = ColorPair(0x06743A, 0x3BDB63);
        var blue = ColorPair(0x1767AE, 0x0B99FF);
        var teal = ColorPair(0x007984, 0x2CD7E0);
        var disabledMark = new SolidColorBrush(contrast ? ui.GetColorValue(UIColorType.Foreground)
            : Color.FromArgb(120, dark ? (byte)255 : (byte)0, dark ? (byte)255 : (byte)0, dark ? (byte)255 : (byte)0));
        var library = new PromptLibraryService(workspace.DataRoot);

        StackPanel Page() => new() { Padding = new(ComposerOptionsMetrics.Inset), Spacing = ComposerOptionsMetrics.RowSpacing };
        var options = Page();
        void Navigate(StackPanel next, string name)
        {
            pageHost.Content = next;
            AutomationProperties.SetName(scroll, name);
            scroll.ChangeView(null, 0, null, true);
            if (ReferenceEquals(composerOptionsFlyout, flyout))
                ModelPickerVisuals.Reveal(next, System.Numerics.Vector3.Zero, 180);
        }
        void ShowOptions() => Navigate(options, "Composer options");
        Button Row(string title, string detail, FrameworkElement icon, string id, string? name = null) =>
            ComposerOptionsButtonFor(ComposerOptionsRow(title, detail, icon), name ?? title, id, detail);

        if (session is null)
        {
            var project = Row("Open Project…", "Choose a project folder.", ComposerOptionsIcon("\uE8DA", accent),
                "ComposerOpenProject", "Open project");
            project.Click += async (_, _) => { flyout.Hide(); await Run(OpenProjectAsync); };
            options.Children.Add(project);
        }
        else
        {
            var attach = Row("Attach Image or Audio…", "Add media to your message.", ComposerOptionsIcon("\uE723", blue),
                "ComposerAttachMedia");
            attach.Click += async (_, _) => await Run(PickComposerAttachmentsAsync);
            options.Children.Add(attach);
            var mention = Row("Mention Project File…", "Reference a project file.", ComposerOutlineIcon(
                "M8,14 H3 Q2,14 2,13 V2 Q2,1 3,1 H11 Q12,1 12,2 V6 M4.5,4 H9.5 M4.5,7 H8 "
                + "M14,10.5 A2.5,2.5 0 1 1 9,10.5 A2.5,2.5 0 1 1 14,10.5 Z M13.25,12.25 L15,14", teal),
                "ComposerMentionFile");
            mention.Click += async (_, _) => await Run(ChooseFileMentionAsync);
            options.Children.Add(mention);
        }
        options.Children.Add(ComposerOptionsDivider());

        var plugins = Row("Plugins", "Mention an enabled plugin.", ComposerOptionsIcon("\uE74C", accent), "ComposerPlugins");
        plugins.IsEnabled = session is not null && workspace.Runtime.RuntimeState == CodexRuntimeState.Ready;
        plugins.Click += async (_, _) => await Run(async () =>
        {
            if (session is null || !ReferenceEquals(current, session)) return;
            var available = await App.Integrations.RefreshMentionablePluginsAsync(IntegrationContext.For(session));
            if (!ReferenceEquals(current, session)) return;
            var list = new StackPanel { Spacing = 6 };
            var back = new Button { Content = "Back to options" };
            back.Click += (_, _) => ShowOptions();
            list.Children.Add(back);
            foreach (var suggestion in ComposerSuggestionService.PluginSuggestions(available))
            {
                var item = Row(suggestion.Title, suggestion.Description, ComposerPluginIcon(suggestion, accent), "ComposerPlugin");
                item.Click += async (_, _) => await Run(async () =>
                {
                    if (!ReferenceEquals(current, session)) return;
                    flyout.Hide();
                    await InsertPluginMentionAsync(suggestion);
                });
                list.Children.Add(item);
            }
            if (list.Children.Count == 1) list.Children.Add(ComposerOptionDetail("No enabled plugins."));
            flyout.Content = new ScrollViewer { Content = list, MaxHeight = 320 };
        });
        options.Children.Add(plugins);

        var save = Row("Save draft for later", "Keep this draft and attachments.", ComposerTrayIcon(neutral, "\uE74B"), "ComposerSaveDraft");
        bool HasDraft() => session is not null && ReferenceEquals(current, session)
            && (!string.IsNullOrWhiteSpace(Composer.Text) || typedComposerAttachments.Count > 0);
        save.IsEnabled = HasDraft();
        save.Click += async (_, _) =>
        {
            if (session is null || !HasDraft()) return;
            save.IsEnabled = false;
            await Run(() => PromptLibraryPanel.SaveCompleteDraftAsync(library, session, CaptureComposerDraft, ApplyCompleteLibraryDraftAsync));
            save.IsEnabled = HasDraft();
        };
        options.Children.Add(save);

        var prompts = Row("Saved prompts", "Restore a saved prompt.", ComposerTrayIcon(neutral), "ComposerSavedPrompts");
        prompts.Click += async (_, _) => await ShowSavedPromptsAsync();
        options.Children.Add(prompts);
        options.Children.Add(ComposerOptionsDivider());
        var rose = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 218, 100, 152));
        var wildRow = ComposerOptionsRow("Wild", "Find code and design references.", ModelPickerVisuals.WildIcon(rose));
        var wildSwitch = new ToggleSwitch { IsOn = composerWild, OnContent = "", OffContent = "" };
        AutomationProperties.SetName(wildSwitch, "Wild");
        wildSwitch.Toggled += async (_, _) => { if (ReferenceEquals(current, session)) await Run(() => SetComposerWildAsync(wildSwitch.IsOn)); };
        AddComposerOptionsTrailing(wildRow, wildSwitch, 52);
        options.Children.Add(wildRow);
        options.Children.Add(new TextBlock
        {
            Text = "Mode", FontSize = ComposerOptionsMetrics.Detail, Height = 13, LineHeight = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = neutral
        });

        var modes = new StackPanel { Spacing = ComposerOptionsMetrics.ModeSpacing };
        options.Children.Add(modes);
        var refreshModeMarks = new List<Action>();
        Button Mode(string name, string detail, FrameworkElement icon, Brush color)
        {
            var row = ComposerOptionsRow(name, detail, icon);
            var check = ComposerOptionsIcon("\uE73E", surface is AcrylicBrush acrylic ? new SolidColorBrush(acrylic.FallbackColor) : surface, 8);
            var circle = new Grid
            {
                Width = 13, Height = 13, Margin = new(0, 1, 0, 0),
                VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Center,
                IsHitTestVisible = false,
                Children = { new Ellipse { StrokeThickness = 1.5 }, check }
            };
            AddComposerOptionsTrailing(row, circle, 16);
            var button = ComposerOptionsButtonFor(row, name, "ComposerMode_" + name, detail);
            void RefreshMark()
            {
                var selected = composerMode == name;
                var ring = (Ellipse)circle.Children[0];
                ring.Stroke = selected ? color : disabledMark;
                ring.Fill = selected ? color : null;
                check.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
                AutomationProperties.SetName(button, selected ? name + ", selected" : name);
                AutomationProperties.SetItemStatus(button, selected ? "Selected" : "Not selected");
            }
            refreshModeMarks.Add(RefreshMark);
            RefreshMark();
            button.Click += async (_, _) =>
            {
                if (!ReferenceEquals(current, session)) return;
                await Run(() => SetComposerModeAsync(name));
                refreshModeMarks.ForEach(refresh => refresh());
            };
            modes.Children.Add(button);
            return button;
        }
        Mode("Agentic", "Work through the request.", ModelPickerVisuals.SparklesIcon(accent), accent);
        var plan = Mode("Plan", "Plan before making changes.", ComposerOutlineIcon(
            "M5,3 H3 Q2,3 2,4 V14 Q2,15 3,15 H12 Q13,15 13,14 V4 Q13,3 12,3 H10 "
            + "M5,2.5 H6 Q6,1 7.5,1 Q9,1 9,2.5 H10 V5 H5 Z "
            + "M4.5,8 H5.2 M7.2,8 H10.5 M4.5,10.5 H5.2 M7.2,10.5 H10.5 M4.5,13 H5.2 M7.2,13 H10.5", orange), orange);
        var debug = Mode("Debug", "Diagnose and fix issues.", ComposerOptionsIcon("\uEBE8", purple), purple);
        var ready = session is not null && ActiveAgent is null && workspace.Runtime.RuntimeState == CodexRuntimeState.Ready;
        var canAsk = ready && workspace.CanUseReadOnlyTurns && routingMode == "Direct";
        var ask = Mode("Ask", canAsk ? "Investigate with read-only access."
            : "Choose a direct Codex model.",
            ComposerOptionsIcon("\uE897", accent), accent);
        ask.IsEnabled = canAsk;
        var roblox = Mode("Roblox", ready ? "Work with Roblox and Luau."
            : "Connect Codex for Roblox.", ModelPickerVisuals.RobloxIcon(rose), rose);
        roblox.IsEnabled = ready;
        plan.IsEnabled = false;
        debug.IsEnabled = session is not null && workspace.Runtime.RuntimeState == CodexRuntimeState.Ready
            && workspace.Runtime.Capabilities.Availability("collaborationMode/list") != CapabilityAvailability.Unavailable;
        options.Children.Add(ComposerOptionsDivider());
        options.Children.Add(ComposerGoalOption(session, green));
        ShowOptions();

        flyout.Closed += (_, _) => { if (ReferenceEquals(composerOptionsFlyout, flyout)) composerOptionsFlyout = null; };
        composerOptionsFlyout = flyout;
        flyout.ShowAt(ComposerOptionsButton);
        if (debug.IsEnabled) _ = ReadPlanAvailabilityAsync();

        async Task ReadPlanAvailabilityAsync()
        {
            try
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                var reply = await workspace.Runtime.RequestAsync("collaborationMode/list", new { }, deadline.Token);
                if (!ReferenceEquals(composerOptionsFlyout, flyout)) return;
                plan.IsEnabled = reply.TryGetProperty("data", out var values) && values.ValueKind == System.Text.Json.JsonValueKind.Array
                    && values.EnumerateArray().Any(value => value.Str("mode") == "plan");
            }
            catch (Exception ex) when (ex is CodexRpcException or IOException or InvalidOperationException or NotSupportedException or OperationCanceledException)
            {
                if (ReferenceEquals(composerOptionsFlyout, flyout)) debug.IsEnabled = false;
            }
            finally
            {
                if (!plan.IsEnabled) ToolTipService.SetToolTip(plan, "Plan mode is unavailable in this Codex runtime");
                if (!debug.IsEnabled) ToolTipService.SetToolTip(debug, "Debug mode requires collaboration-mode support in the Codex runtime");
            }
        }

        async Task ShowSavedPromptsAsync()
        {
            var page = Page();
            var back = ComposerOptionsButtonFor(ComposerOptionsRow("Saved prompts", "", ComposerOptionsIcon("\uE76B", neutral, 11)),
                "Back to composer options", "ComposerPromptsBack", "");
            back.Height = double.NaN;
            back.Click += (_, _) => { save.IsEnabled = HasDraft(); ShowOptions(); };
            page.Children.Add(back);
            page.Children.Add(ComposerOptionsDivider());
            Navigate(page, "Saved prompts");

            await Run(async () =>
            {
                var saved = await library.ListAsync();
                if (!ReferenceEquals(composerOptionsFlyout, flyout) || !ReferenceEquals(pageHost.Content, page)) return;
                if (saved.Count == 0)
                {
                    var empty = ComposerOptionsRow("No saved prompts", "Save a draft to reuse it here.", ComposerTrayIcon(neutral));
                    empty.Margin = new(0, 8, 0, 8);
                    page.Children.Add(empty);
                    return;
                }

                var list = new StackPanel { Spacing = 10 };
                var items = new ScrollViewer
                {
                    MaxHeight = Math.Min(saved.Count * 62, 280), Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalContentAlignment = HorizontalAlignment.Stretch
                };
                page.Children.Add(items);
                page.Children.Add(ComposerOptionsDivider());
                page.Children.Add(ComposerOptionDetail("Choose a prompt to add."));
                foreach (var item in saved)
                {
                    var detail = ProjectFolderName(item.WorkspacePath);
                    if (item.Attachments.Count > 0) detail += $" · {item.Attachments.Count} attachments";
                    var row = ComposerOptionsRow(item.Title, detail, ComposerTrayIcon(neutral, "\uE74A"), titleLines: 2);
                    var restore = ComposerOptionsButtonFor(row, "Add to draft: " + item.Title, "ComposerRestorePrompt_" + item.Id, detail);
                    restore.Height = double.NaN;
                    restore.IsEnabled = session is not null;
                    restore.Click += async (_, _) =>
                    {
                        if (session is null || !ReferenceEquals(current, session) || !list.IsHitTestVisible) return;
                        list.IsHitTestVisible = false;
                        back.IsEnabled = false;
                        try
                        {
                            await PromptLibraryPanel.RestoreCompleteDraftAsync(library, item, session, CaptureComposerDraft, ApplyCompleteLibraryDraftAsync);
                            save.IsEnabled = HasDraft();
                            if (ReferenceEquals(composerOptionsFlyout, flyout)) ShowOptions();
                        }
                        catch (Exception ex) { ShowError(ex); }
                        finally { list.IsHitTestVisible = true; back.IsEnabled = true; }
                    };
                    var remove = ComposerOptionsButtonFor(ComposerOptionsIcon("\uE74D", neutral, 11), "Delete saved prompt: " + item.Title,
                        "ComposerDeletePrompt_" + item.Id, "");
                    remove.Width = 22;
                    remove.Height = 22;
                    remove.HorizontalAlignment = HorizontalAlignment.Right;
                    remove.VerticalAlignment = VerticalAlignment.Top;
                    row.Margin = new(0, 0, 24, 0);
                    remove.Click += async (_, _) => await Run(async () =>
                    {
                        var dialog = new ContentDialog
                        {
                            XamlRoot = XamlRoot, Title = "Delete saved prompt?",
                            Content = $"“{item.Title}” and its saved attachments will be deleted. Copies already added to a draft are kept.",
                            PrimaryButtonText = "Delete", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
                        };
                        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
                        await library.RemoveAsync(item.Id);
                        if (ReferenceEquals(composerOptionsFlyout, flyout)) await ShowSavedPromptsAsync();
                    });
                    list.Children.Add(new Grid { Children = { restore, remove } });
                }
            });
        }
    }

    Grid ComposerGoalOption(ThreadSession? session, Brush color)
    {
        var active = session is not null && App.ThreadSettings.HasActiveComposerGoal(session);
        var row = ComposerOptionsRow("Goal", active ? "Keep working on this goal." : "Use the next message as a goal.",
            ModelPickerVisuals.GoalIcon(color));
        var toggle = new ToggleSwitch
        {
            IsOn = session is not null && App.ThreadSettings.ComposerGoalEnabled(session),
            IsEnabled = session is not null && (ActiveAgent is null || App.ThreadSettings.ComposerGoalEnabled(session)),
            MinWidth = 0, Width = 44, Height = 30, Padding = new(0),
            OnContent = "", OffContent = "", VerticalAlignment = VerticalAlignment.Center
        };
        AutomationProperties.SetName(toggle, "Goal");
        AutomationProperties.SetHelpText(toggle, "Keep working toward a persistent goal");
        AutomationProperties.SetAutomationId(toggle, "ComposerGoalToggle");
        ToolTipService.SetToolTip(toggle, "Keep working toward a persistent goal");
        var syncing = false;
        toggle.Toggled += async (_, _) =>
        {
            if (session is null || syncing || !ReferenceEquals(current, session)) return;
            var enabled = toggle.IsOn;
            syncing = true;
            try
            {
                await Run(() => App.ThreadSettings.SetComposerGoalModeAsync(session, enabled));
                toggle.IsOn = App.ThreadSettings.ComposerGoalEnabled(session);
                RenderComposerGoalControls();
            }
            finally { syncing = false; }
        };
        AddComposerOptionsTrailing(row, toggle, 44);
        return row;
    }

    TextBlock ComposerOptionDetail(string text)
    {
        var label = new TextBlock
        {
            Text = text.ReplaceLineEndings(" "), FontSize = ComposerOptionsMetrics.Detail, LineHeight = 13,
            Foreground = ComposerKeyHints.Foreground, TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1, TextWrapping = TextWrapping.NoWrap
        };
        label.IsTextTrimmedChanged += (_, _) => ToolTipService.SetToolTip(label, label.IsTextTrimmed ? text : null);
        return label;
    }

    Grid ComposerOptionsRow(string title, string detail, FrameworkElement icon, int titleLines = 1)
    {
        var row = new Grid { ColumnSpacing = ComposerOptionsMetrics.LabelGap };
        row.ColumnDefinitions.Add(new() { Width = new(ComposerOptionsMetrics.IconWidth) });
        row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        var mark = new Viewbox
        {
            Width = 13, Height = 14, Child = icon, Margin = new(0, 2, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false
        };
        AutomationProperties.SetAccessibilityView(mark, AccessibilityView.Raw);
        row.Children.Add(mark);
        var labels = new StackPanel { Spacing = 2 };
        labels.Children.Add(new TextBlock
        {
            Text = title, FontSize = ComposerOptionsMetrics.Title, LineHeight = 15,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = titleLines, TextWrapping = titleLines > 1 ? TextWrapping.Wrap : TextWrapping.NoWrap
        });
        if (detail.Length > 0) labels.Children.Add(ComposerOptionDetail(detail));
        Grid.SetColumn(labels, 1);
        row.Children.Add(labels);
        return row;
    }

    static void AddComposerOptionsTrailing(Grid row, FrameworkElement control, double width)
    {
        row.ColumnDefinitions.Add(new() { Width = new(width) });
        Grid.SetColumn(control, 2);
        row.Children.Add(control);
    }

    Button ComposerOptionsButtonFor(object content, string name, string id, string detail)
    {
        var button = new Button
        {
            Style = (Style)Resources["ComposerChromeButton"], Content = content, Height = ComposerOptionsMetrics.RowHeight,
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch
        };
        AutomationProperties.SetName(button, name);
        AutomationProperties.SetAutomationId(button, id);
        if (detail.Length > 0) AutomationProperties.SetHelpText(button, detail);
        return button;
    }

    Border ComposerOptionsDivider() => new() { Height = 1, Background = ComposerPanel.BorderBrush };

    static FontIcon ComposerPluginIcon(ComposerSuggestion suggestion, Brush fallback)
    {
        var chrome = suggestion.Source.StartsWith("chrome@", StringComparison.OrdinalIgnoreCase);
        var color = suggestion.BrandColor ?? (chrome ? "#4285F4" : null);
        var brush = color is { Length: 7 } && color[0] == '#' && uint.TryParse(color.AsSpan(1),
            System.Globalization.NumberStyles.HexNumber, System.Globalization.CultureInfo.InvariantCulture, out var rgb)
            && !new AccessibilitySettings().HighContrast
            ? new SolidColorBrush(Color.FromArgb(222, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb))
            : fallback;
        var icon = ComposerOptionsIcon(chrome ? "\uE774" : "\uE74C", brush, 13);
        icon.IsHitTestVisible = false;
        return icon;
    }

    static FontIcon ComposerOptionsIcon(string glyph, Brush foreground, double size = 13) => new()
    {
        Glyph = glyph, FontSize = size, Foreground = foreground, VerticalAlignment = VerticalAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center
    };

    static Microsoft.UI.Xaml.Shapes.Path ComposerOutlineIcon(string geometry, Brush brush)
    {
        var icon = (Microsoft.UI.Xaml.Shapes.Path)Microsoft.UI.Xaml.Markup.XamlReader.Load($"""
            <Path xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Data="{geometry}"
                  Width="16" Height="16" Stretch="Uniform" StrokeThickness="1.2"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
            """);
        icon.Stroke = brush;
        return icon;
    }

    static Grid ComposerTrayIcon(Brush brush, string? arrow = null)
    {
        var tray = new PathFigure { StartPoint = new(1, 7), IsClosed = true };
        foreach (var point in new Windows.Foundation.Point[] { new(4, 4), new(12, 4), new(15, 7), new(15, 13), new(1, 13) })
            tray.Segments.Add(new LineSegment { Point = point });
        var lip = new PathFigure { StartPoint = new(1, 8) };
        foreach (var point in new Windows.Foundation.Point[] { new(5.5, 8), new(7, 10), new(9, 10), new(10.5, 8), new(15, 8) })
            lip.Segments.Add(new LineSegment { Point = point });
        var icon = new Grid { Width = 16, Height = ComposerOptionsMetrics.IconHeight };
        icon.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = new PathGeometry { Figures = { tray, lip } }, Stroke = brush, StrokeThickness = 1.2,
            VerticalAlignment = VerticalAlignment.Bottom
        });
        if (arrow is not null)
        {
            var mark = ComposerOptionsIcon(arrow, brush, 8);
            mark.VerticalAlignment = VerticalAlignment.Top;
            icon.Children.Add(mark);
        }
        return icon;
    }
}
