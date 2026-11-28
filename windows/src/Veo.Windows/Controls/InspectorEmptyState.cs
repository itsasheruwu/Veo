using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Veo_Windows.Controls;

internal sealed class InspectorEmptyState : StackPanel
{
    readonly TextBlock heading;
    readonly TextBlock detail;
    public InspectorEmptyState(string glyph, string title, string description)
    {
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Center;
        MaxWidth = 300;
        Padding = new Thickness(18);
        Spacing = 7;
        Children.Add(new FontIcon { Glyph = glyph, FontSize = 25, Opacity = .55, Margin = new Thickness(0, 0, 0, 4) });
        heading = new TextBlock { FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextAlignment = TextAlignment.Center };
        detail = new TextBlock { FontSize = 12, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap };
        Children.Add(heading);
        Children.Add(detail);
        SetText(title, description);
    }
    public void SetText(string title, string description)
    {
        heading.Text = title;
        detail.Text = description;
    }
}
