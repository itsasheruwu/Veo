using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;

namespace Veo_Windows.Controls;

public sealed partial class SettingsPanel
{
    static readonly string[] Materials = ["Solid", "Mica", "Acrylic"];

    void ShowAppearance()
    {
        var p = workspace.Preferences;
        var theme = new StackPanel { Spacing = 10 };
        theme.Children.Add(SettingText("Theme", "SectionCaption"));
        theme.Children.Add(BuildThemeChoices());
        var themeRows = new StackPanel();
        theme.Children.Add(new Border { Child = themeRows, Style = StyleFor("SettingCard") });
        Sections.Children.Add(theme);
        AddRow(themeRows, "Theme material", "Background behind the conversation and settings.", "\uE737",
            Choice("Theme material", Materials, p.CanvasMaterial, v => p.CanvasMaterial = v));

        AddRow(Section("Accent"), "Accent color", "Used for selection, links, and controls.", "\uE790", AccentPicker());

        var sidebar = Section("Sidebar");
        Material(sidebar, "Left sidebar material", "\uE90C", p.SidebarMaterial, v => p.SidebarMaterial = v);
        Material(sidebar, "Right sidebar material", "\uE89F", p.UtilityMaterial, v => p.UtilityMaterial = v);
        Sections.Children.Add(SettingText("Windows transparency and High Contrast settings are used for material fallbacks.", "SettingDetail"));

        var composer = Section("Composer");
        AddRow(composer, "Model picker", "Choose the model selector used beside the composer.", "\uE81E",
            Choice("Model picker", ["Native", "Slider / Advanced"], p.ModelPicker, v => p.ModelPicker = v));
        Material(composer, "Composer material", "\uE70F", p.ComposerMaterial, v => p.ComposerMaterial = v);
        AddRow(composer, "Show turn status", "Display live task progress above the composer.", "\uE9D5",
            Toggle("Show turn status", p.ShowStatus, v => p.ShowStatus = v));
        var usage = Toggle("Show context window usage", p.ShowUsage, v => p.ShowUsage = v);
        AddRow(composer, "Show context window usage", "Display token usage beside Send.", "\uE9D9", usage);
        var usageOptions = new StackPanel { Visibility = p.ShowUsage ? Visibility.Visible : Visibility.Collapsed };
        AddRow(usageOptions, "Usage style", "Choose how context window use is drawn.", "\uE9D9",
            Choice("Usage style", ["Bar", "Circle"], p.ContextStyle, v => p.ContextStyle = v));
        AddRow(usageOptions, "Usage label", "Show remaining context as a percent or token count.", "\uE8EC",
            Choice("Usage label", ["Percent", "Tokens"], p.ContextLabel, v => p.ContextLabel = v));
        composer.Children.Add(usageOptions);
        usage.Toggled += (_, _) => usageOptions.Visibility = usage.IsOn ? Visibility.Visible : Visibility.Collapsed;

        Material(Section("Notifications"), "Notification material", "\uE7E7", p.NotificationMaterial, v => p.NotificationMaterial = v);

        var minimap = Section("Thread minimap");
        AddRow(minimap, "Show thread minimap", "Display topic changes beside longer conversations.", "\uE8A5",
            Toggle("Show thread minimap", p.ShowMinimap, v => p.ShowMinimap = v));
        Material(minimap, "Minimap material", "\uE8A5", p.MinimapMaterial, v => p.MinimapMaterial = v);

        var conversation = Section("Conversation");
        AddRow(conversation, "Response streaming", "Choose how quickly new response text appears.", "\uE8F2",
            Choice("Response streaming", ["None", "Paragraph", "Token"], p.Streaming, v => p.Streaming = v));
        AddRow(conversation, "Viewed images start", "Choose how image previews first appear in a conversation.", "\uEB9F",
            Choice("Viewed images start", ["Expanded", "Collapsed"], p.ViewedImages, v => p.ViewedImages = v));
        UpdateSelectionAppearance();
    }

    void Material(StackPanel card, string label, string icon, string value, Action<string> apply) =>
        AddRow(card, label, "Solid, Mica, or Acrylic.", icon, Choice(label, Materials, value, apply));

    Grid BuildThemeChoices()
    {
        var choices = new Grid { ColumnSpacing = 12 };
        var p = workspace.Preferences;
        foreach (var (value, title) in new[] { ("System", "Sync"), ("Light", "Light"), ("Dark", "Dark") })
        {
            var preview = new Border
            {
                Height = 78, Child = PreviewWindow(value),
                Style = StyleFor("SettingCard"), CornerRadius = new CornerRadius(10)
            };
            var label = new TextBlock { Text = title, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center };
            var content = new StackPanel { Spacing = 8 };
            content.Children.Add(preview);
            content.Children.Add(label);
            var button = new Button
            {
                Style = (Style)Application.Current.Resources["SubtleButtonStyle"], Content = content,
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(0), MinWidth = 0
            };
            AutomationProperties.SetName(button, title);
            AutomationProperties.SetAutomationId(button, "SettingsTheme" + value);
            if (value == "System") AutomationProperties.SetHelpText(button, "Follow Windows appearance");
            button.Click += async (_, _) => await SavePreferenceAsync(() => p.Appearance = value);
            Grid.SetColumn(button, choices.ColumnDefinitions.Count);
            choices.ColumnDefinitions.Add(new());
            choices.Children.Add(button);
            themeChoices.Add((value, button, preview, label));
        }
        return choices;
    }

    static Grid PreviewWindow(string value)
    {
        var darkCanvas = Color.FromArgb(255, 20, 20, 21);
        var lightCanvas = Color.FromArgb(255, 246, 247, 248);
        var darkRail = Color.FromArgb(255, 38, 40, 42);
        var lightRail = Color.FromArgb(255, 216, 220, 225);
        var ruleDark = Color.FromArgb(255, 76, 76, 81);
        var ruleLight = Color.FromArgb(255, 200, 205, 211);
        var background = new Grid
        {
            Background = new SolidColorBrush(value == "Dark" ? darkCanvas : lightCanvas),
            CornerRadius = new CornerRadius(9),
            IsHitTestVisible = false
        };
        background.ColumnDefinitions.Add(new() { Width = new GridLength(28) });
        background.ColumnDefinitions.Add(new());
        background.Children.Add(new Border { Background = new SolidColorBrush(value == "Dark" ? darkRail : lightRail) });
        if (value == "System")
        {
            var darkHalf = new Polygon
            {
                Points = new PointCollection { new(1, 0), new(1, 1), new(0, 1) },
                Stretch = Stretch.Fill,
                Fill = new SolidColorBrush(darkCanvas),
                IsHitTestVisible = false
            };
            Grid.SetColumnSpan(darkHalf, 2);
            background.Children.Add(darkHalf);
        }
        var lines = new StackPanel
        {
            Spacing = 5, Margin = new Thickness(10, 14, 4, 0),
            VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Left
        };
        var rule = new SolidColorBrush(value == "Dark" ? ruleDark : ruleLight);
        lines.Children.Add(new Border { Width = 35, Height = 5, CornerRadius = new CornerRadius(2), Background = rule });
        lines.Children.Add(new Border { Width = 23, Height = 4, CornerRadius = new CornerRadius(2), Background = rule, Opacity = 0.7 });
        Grid.SetColumn(lines, 1);
        background.Children.Add(lines);
        AutomationProperties.SetAccessibilityView(background, AccessibilityView.Raw);
        return background;
    }

    Button AccentPicker()
    {
        var prefs = workspace.Preferences;
        var swatch = new Border { Width = 26, Height = 26, Background = accentBrush, CornerRadius = new CornerRadius(6) };
        var button = new Button { Content = swatch, Padding = new Thickness(2), Width = 32, Height = 32, MinWidth = 0 };
        AutomationProperties.SetName(button, "Choose accent color");
        AutomationProperties.SetAutomationId(button, "SettingsAccent");
        var picker = new ColorPicker
        {
            IsAlphaEnabled = false, IsColorSliderVisible = true,
            IsHexInputVisible = true, IsColorChannelTextInputVisible = false
        };
        var flyout = new Flyout();
        var pickerContent = new StackPanel { Spacing = 10 };
        pickerContent.Children.Add(picker);
        pickerContent.Children.Add(ActionButton("Apply accent", async () =>
        {
            var selected = picker.Color;
            await SavePreferenceAsync(() => prefs.Accent = $"#{selected.R:X2}{selected.G:X2}{selected.B:X2}");
            flyout.Hide();
        }));
        flyout.Content = pickerContent;
        flyout.Opening += (_, _) => picker.Color = AccentColor(prefs.Accent);
        button.Flyout = flyout;
        return button;
    }
}
