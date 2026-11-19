using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Veo.Protocol;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Controls;

public sealed partial class SettingsPanel
{
    Style StyleFor(string key) => (Style)Resources[key];

    TextBlock SettingText(string text, string style) => new() { Text = text, Style = StyleFor(style) };

    StackPanel Section(string title)
    {
        var section = new StackPanel { Spacing = 10 };
        var caption = SettingText(title, "SectionCaption");
        AutomationProperties.SetHeadingLevel(caption, AutomationHeadingLevel.Level2);
        section.Children.Add(caption);
        var rows = new StackPanel();
        section.Children.Add(new Border { Child = rows, Style = StyleFor("SettingCard") });
        Sections.Children.Add(section);
        return rows;
    }

    void AddRow(StackPanel rows, string title, string? detail, string glyph, FrameworkElement control, bool fullWidth = false)
    {
        if (rows.Children.Count > 0)
            rows.Children.Add(new Border { Style = StyleFor("SettingDivider"), IsHitTestVisible = false });
        var row = new Grid
        {
            MinHeight = 62,
            Padding = new Thickness(16, 11, 16, 11),
            ColumnSpacing = 14
        };
        row.RowDefinitions.Add(new() { Height = GridLength.Auto });
        row.RowDefinitions.Add(new() { Height = GridLength.Auto });
        row.ColumnDefinitions.Add(new() { Width = new GridLength(22) });
        row.ColumnDefinitions.Add(new());
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });

        var icon = new FontIcon { Glyph = glyph, Style = StyleFor("SettingIcon"), VerticalAlignment = VerticalAlignment.Center };
        var label = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        label.Children.Add(SettingText(title, "SettingHeading"));
        if (!string.IsNullOrEmpty(detail)) label.Children.Add(SettingText(detail, "SettingDetail"));

        Grid.SetColumn(label, 1);
        row.Children.Add(icon);
        row.Children.Add(label);
        row.Children.Add(control);
        Reflow(fullWidth);
        row.SizeChanged += (_, args) =>
        {
            var available = args.NewSize.Width;
            var preferred = double.IsNaN(control.Width) ? Math.Max(120, control.DesiredSize.Width) : control.Width;
            Reflow(fullWidth || available < 254 + preferred);
            if (!fullWidth && !double.IsNaN(control.Width))
                control.MaxWidth = Math.Max(64, available - 68);
        };
        rows.Children.Add(row);

        void Reflow(bool stacked)
        {
            Grid.SetRow(control, stacked ? 1 : 0);
            Grid.SetColumn(control, stacked ? 1 : 2);
            Grid.SetColumnSpan(label, stacked ? 2 : 1);
            Grid.SetColumnSpan(control, stacked ? 2 : 1);
            control.Margin = stacked ? new Thickness(0, 9, 0, 0) : new Thickness(0);
            control.HorizontalAlignment = fullWidth ? HorizontalAlignment.Stretch : HorizontalAlignment.Right;
            control.VerticalAlignment = VerticalAlignment.Center;
        }
    }

    void AddEmbedded(string title, FrameworkElement panel)
    {
        var rows = Section(title);
        rows.Children.Add(new Border
        {
            Padding = new Thickness(16, 12, 16, 12),
            Child = new ScrollViewer
            {
                Content = panel,
                HorizontalScrollMode = ScrollMode.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollMode = ScrollMode.Disabled,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                HorizontalContentAlignment = HorizontalAlignment.Stretch
            }
        });
    }

    FrameworkElement Choice(string label, string[] choices, string selected, Action<string> apply)
    {
        if (choices.Length > 3)
        {
            var combo = new ComboBox { ItemsSource = choices, SelectedItem = selected, Width = 172 };
            AutomationProperties.SetName(combo, label);
            AutomationProperties.SetAutomationId(combo, SettingId(label));
            combo.SelectionChanged += async (_, _) =>
            {
                if (combo.SelectedItem is string value) await SavePreferenceAsync(() => apply(value));
            };
            return combo;
        }

        var segments = new Grid { ColumnSpacing = 2, Padding = new Thickness(2) };
        AutomationProperties.SetName(segments, label);
        AutomationProperties.SetAutomationId(segments, SettingId(label));
        var buttons = new List<ToggleButton>();
        foreach (var value in choices)
        {
            var button = new ToggleButton
            {
                Style = StyleFor("SettingSegment"), Content = value, IsChecked = value == selected
            };
            AutomationProperties.SetName(button, value);
            AutomationProperties.SetHelpText(button, label);
            AutomationProperties.SetAutomationId(button, SettingId(label + value));
            button.Click += async (_, _) =>
            {
                foreach (var candidate in buttons) candidate.IsChecked = ReferenceEquals(candidate, button);
                if (selected == value) return;
                selected = value;
                await SavePreferenceAsync(() => apply(value));
            };
            Grid.SetColumn(button, buttons.Count);
            segments.ColumnDefinitions.Add(new());
            segments.Children.Add(button);
            buttons.Add(button);
        }

        return new Border
        {
            Child = segments, Width = choices.Length == 2 ? 214 : 280,
            Style = StyleFor("SettingCard"), CornerRadius = new CornerRadius(7)
        };
    }

    ToggleSwitch Toggle(string label, bool value, Action<bool> apply)
    {
        var toggle = new ToggleSwitch { IsOn = value, OffContent = "", OnContent = "", MinWidth = 0 };
        AutomationProperties.SetName(toggle, label);
        AutomationProperties.SetAutomationId(toggle, SettingId(label));
        toggle.Toggled += async (_, _) => await SavePreferenceAsync(() => apply(toggle.IsOn));
        return toggle;
    }

    Button ActionButton(string label, Func<Task> action)
    {
        var button = new Button { Content = label, FontSize = 12, Padding = new Thickness(10, 4, 10, 4) };
        button.Click += async (_, _) => await RunAsync(action);
        return button;
    }

    static string SettingId(string label) => "Preference_" + string.Concat(label.Where(char.IsLetterOrDigit));

    Task SavePreferenceAsync(Action apply) => RunAsync(async () =>
    {
        apply();
        await workspace.SavePreferencesAsync();
        App.Main?.RefreshAppearance();
    });

    async Task RunAsync(Func<Task> action)
    {
        try { await action(); }
        catch (Exception error) { ShowFeedback(DiagnosticRedactor.Redact(error.Message), InfoBarSeverity.Error); }
    }

    void ShowFeedback(string message, InfoBarSeverity severity)
    {
        Feedback.Severity = severity;
        Feedback.Message = message;
        Feedback.IsOpen = true;
    }

    static Color AccentColor(string hex)
    {
        if (new AccessibilitySettings().HighContrast) return new UISettings().UIElementColor(UIElementType.Highlight);
        if (hex.Length == 7 && hex[0] == '#' && uint.TryParse(hex.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var rgb))
            return Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
        return Color.FromArgb(255, 46, 140, 250);
    }

    void UpdateSelectionAppearance()
    {
        foreach (var (item, highlight, icon, label) in railItems)
        {
            var selected = ReferenceEquals(item, Categories.SelectedItem);
            highlight.Opacity = selected ? 0.18 : 0;
            if (selected) icon.Foreground = accentBrush;
            else icon.ClearValue(IconElement.ForegroundProperty);
            label.FontWeight = selected ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
        }
        foreach (var (value, button, preview, label) in themeChoices)
        {
            var selected = workspace.Preferences.Appearance == value;
            if (selected)
            {
                preview.BorderBrush = accentBrush;
                label.Foreground = accentBrush;
            }
            else
            {
                preview.ClearValue(Border.BorderBrushProperty);
                label.ClearValue(TextBlock.ForegroundProperty);
            }
            preview.BorderThickness = new Thickness(selected ? 2 : 1);
            label.FontWeight = selected ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
            AutomationProperties.SetItemStatus(button, selected ? "Selected" : "");
        }
    }
}
