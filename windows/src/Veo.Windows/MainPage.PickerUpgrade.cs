using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Veo.Core;

namespace Veo_Windows;

public sealed partial class MainPage
{
    async Task ShowModelPickerUpgradeAsync()
    {
        var preferences = workspace.Preferences;
        if (ActiveAgent != null || !preferences.ModelPickerUpgradeNoticePending || XamlRoot is null) return;
        if (preferences.ModelPicker != VeoPreferences.SliderPicker)
        {
            preferences.ModelPickerUpgradeNoticePending = false;
            await workspace.SavePreferencesAsync();
            return;
        }

        var panel = new StackPanel { Spacing = 12 };
        var stage = new Grid { MinHeight = 160, CornerRadius = new(12) };
        stage.Children.Add(new Controls.PrismBackdrop { MaxHeight=180 });
        if (current is { } session)
        {
            var picker = CreateModelPicker(session, true, 320);
            picker.HorizontalAlignment = HorizontalAlignment.Center;
            picker.VerticalAlignment = VerticalAlignment.Center;
            picker.Margin = new Thickness(12);
            stage.Children.Add(picker);
        }
        panel.Children.Add(stage);
        panel.Children.Add(new TextBlock
        {
            Text = "Try the slider to change reasoning effort. Open Advanced to choose a model or adjust its settings.",
            TextWrapping = TextWrapping.Wrap, FontSize = 14
        });
        panel.Children.Add(new TextBlock
        {
            Text = "Change picker styles anytime in Settings → Appearance.",
            TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = .72
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
        Controls.TourGlass.Dialog(dialog, ActualTheme);
        if (await dialog.ShowAsync() == ContentDialogResult.Secondary)
            preferences.ModelPicker = VeoPreferences.NativePicker;
        preferences.ModelPickerUpgradeNoticePending = false;
        await workspace.SavePreferencesAsync();
        RenderComposerControls();
    }

}
