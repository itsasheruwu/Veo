using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace Veo_Windows.Controls;

internal static class ProviderMark
{
    internal static Border Create(string? id, double size)
    {
        var file = $"AgentMark-{id}.png";
        bool hasImage = id != null && File.Exists(Path.Combine(AppContext.BaseDirectory, "Assets", file));
        var tile = new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.24),
            Background = hasImage ? new SolidColorBrush(Color.FromArgb(255, 240, 240, 240))
                : (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
            Child = hasImage
                ? new Image { Source = new BitmapImage(new Uri("ms-appx:///Assets/" + file)),
                    Margin = new Thickness(size * 0.18), Stretch = Stretch.Uniform }
                : id == "fx" ? new TextBlock { Text = "ƒx", FontFamily = new FontFamily("Georgia"),
                    FontSize = size * 0.49, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }
                : new FontIcon { Glyph = "\uE774", FontSize = size * 0.46 }
        };
        AutomationProperties.SetAccessibilityView(tile, AccessibilityView.Raw);
        return tile;
    }
}
