using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Veo.Core;
using Windows.UI;

namespace Veo_Windows;

public sealed partial class MainPage
{
    async Task ShowModelPickerUpgradeAsync()
    {
        var preferences = workspace.Preferences;
        if (!preferences.ModelPickerUpgradeNoticePending || XamlRoot is null) return;
        if (preferences.ModelPicker != VeoPreferences.SliderPicker)
        {
            preferences.ModelPickerUpgradeNoticePending = false;
            await workspace.SavePreferencesAsync();
            return;
        }

        var panel = new StackPanel { Spacing = 15 };
        panel.Children.Add(PickerUpgradePreview());
        var text = new TextBlock
        {
            Text = "Veo switched you to Slider / Advanced. Slide to change reasoning effort, or open Advanced for model, speed, and context controls.",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 14
        };
        panel.Children.Add(text);
        panel.Children.Add(new TextBlock
        {
            Text = "You can switch back anytime in Settings → Appearance.",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Opacity = .72
        });

        var dialog = new ContentDialog
        {
            Title = "Your model picker has a new look",
            Content = panel,
            XamlRoot = XamlRoot,
            PrimaryButtonText = "Keep Slider / Advanced",
            SecondaryButtonText = "Switch back to Native",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Secondary)
            preferences.ModelPicker = VeoPreferences.NativePicker;
        preferences.ModelPickerUpgradeNoticePending = false;
        await workspace.SavePreferencesAsync();
        RenderComposerControls();
    }

    FrameworkElement PickerUpgradePreview()
    {
        var color = ActualTheme == ElementTheme.Light
            ? Color.FromArgb(255, 22, 93, 170)
            : Color.FromArgb(255, 121, 191, 255);
        var accent = new SolidColorBrush(color);
        var heading = new Grid { ColumnSpacing = 7 };
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.Children.Add(new FontIcon { Glyph = "\uE9E9", Foreground = accent, FontSize = 14 });
        var effort = new TextBlock { Text = "Reasoning effort", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, FontSize = 12 };
        Grid.SetColumn(effort, 1);
        heading.Children.Add(effort);
        var advanced = new TextBlock { Text = "Advanced  ›", FontSize = 11, Opacity = .72 };
        Grid.SetColumn(advanced, 2);
        heading.Children.Add(advanced);

        var track = new Grid { Height = 14 };
        track.ColumnDefinitions.Add(new() { Width = new GridLength(7, GridUnitType.Star) });
        track.ColumnDefinitions.Add(new() { Width = new GridLength(3, GridUnitType.Star) });
        var background = new Border { Background = accent, Opacity = .20, Height = 4, CornerRadius = new(2), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumnSpan(background, 2);
        track.Children.Add(background);
        track.Children.Add(new Border { Background = accent, Height = 4, CornerRadius = new(2), VerticalAlignment = VerticalAlignment.Center });
        track.Children.Add(new Ellipse { Width = 12, Height = 12, Fill = accent, HorizontalAlignment = HorizontalAlignment.Right });

        var labels = new Grid();
        labels.Children.Add(new TextBlock { Text = "Light", FontSize = 11, Opacity = .72 });
        labels.Children.Add(new TextBlock { Text = "High", FontSize = 11, Foreground = accent, HorizontalAlignment = HorizontalAlignment.Right });
        var gradient = new LinearGradientBrush { StartPoint = new(0, 0), EndPoint = new(1, 1) };
        gradient.GradientStops.Add(new GradientStop { Color = Color.FromArgb(36, color.R, color.G, color.B), Offset = 0 });
        gradient.GradientStops.Add(new GradientStop { Color = Color.FromArgb(9, color.R, color.G, color.B), Offset = 1 });
        var preview = new Border
        {
            CornerRadius = new(12),
            Padding = new(15),
            Background = gradient,
            BorderBrush = new SolidColorBrush(Color.FromArgb(63, color.R, color.G, color.B)),
            BorderThickness = new(1),
            Child = new StackPanel { Spacing = 9, Children = { heading, track, labels } },
            IsHitTestVisible = false,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(preview, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return preview;
    }
}
