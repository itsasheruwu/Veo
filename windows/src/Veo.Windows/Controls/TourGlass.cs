using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Controls;

/// <summary>In-app acrylic samples the tour artwork behind native panels and controls.</summary>
internal static class TourGlass
{
    static readonly Color Ink = Color.FromArgb(255, 17, 23, 35);
    static readonly Color Pearl = Color.FromArgb(255, 238, 244, 254);
    static readonly Color Blue = Color.FromArgb(255, 16, 107, 234);
    static bool HighContrast => new AccessibilitySettings().HighContrast;

    static AcrylicBrush Acrylic(Color tint, double opacity, double luminosity) =>
        new() { TintColor = tint, TintOpacity = opacity, TintLuminosityOpacity = luminosity, FallbackColor = tint };

    internal static Brush Panel(bool light = false) => HighContrast
        ? (Brush)Application.Current.Resources["SystemColorWindowColorBrush"]
        : Acrylic(light ? Pearl : Ink, light ? .58 : .45, light ? .87 : .24);

    internal static Brush Edge() => HighContrast
        ? (Brush)Application.Current.Resources["SystemColorWindowTextColorBrush"]
        : new LinearGradientBrush {
            StartPoint = new Point(0, 0), EndPoint = new Point(.45, 1),
            GradientStops = {
                new GradientStop { Offset = 0, Color = Color.FromArgb(154, 242, 249, 255) },
                new GradientStop { Offset = .44, Color = Color.FromArgb(57, 201, 224, 255) },
                new GradientStop { Offset = 1, Color = Color.FromArgb(82, 207, 224, 249) }
            }
        };

    internal static Brush Sheen(bool primary = false) => new LinearGradientBrush {
        StartPoint = new Point(.25, 0), EndPoint = new Point(.65, 1),
        GradientStops = {
            new GradientStop { Offset = 0, Color = Color.FromArgb(HighContrast ? (byte)0 : primary ? (byte)53 : (byte)24, 202, 230, 255) },
            new GradientStop { Offset = .52, Color = Microsoft.UI.Colors.Transparent },
            new GradientStop { Offset = 1, Color = Color.FromArgb(HighContrast ? (byte)0 : (byte)23, 0, 13, 42) }
        }
    };

    static Style Capsule(bool primary, bool light)
    {
        var tint = primary ? Blue : light ? Pearl : Ink;
        var style = new Style(typeof(Button));
        style.Setters.Add(new Setter(Control.BackgroundProperty, Acrylic(tint, primary ? .83 : .39, primary ? .53 : light ? .87 : .30)));
        style.Setters.Add(new Setter(Control.BorderBrushProperty, Edge()));
        style.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(1)));
        style.Setters.Add(new Setter(Control.CornerRadiusProperty, new CornerRadius(10)));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(13, 4, 13, 4)));
        if (primary) style.Setters.Add(new Setter(Control.ForegroundProperty, new SolidColorBrush(Microsoft.UI.Colors.White)));
        return style;
    }

    internal static void Navigation(Button button)
    {
        button.Style = (Style)Application.Current.Resources["SubtleButtonStyle"];
        button.CornerRadius = new CornerRadius(8);
        button.MinWidth = 0;
        button.Padding = new Thickness(9, 3, 9, 3);
    }

    internal static void Button(Button button, bool primary = false)
    {
        if (HighContrast) return;
        button.Style = Capsule(primary, false);
        var hover = primary ? Blue : Color.FromArgb(255, 61, 77, 105);
        button.Resources["ButtonBackgroundPointerOver"] = Acrylic(hover, .68, .43);
        button.Resources["ButtonBackgroundPressed"] = Acrylic(primary ? Blue : Ink, .82, .32);
        button.Resources["ButtonBorderBrushPointerOver"] = Edge();
    }

    internal static void Dialog(ContentDialog dialog, ElementTheme theme)
    {
        dialog.RequestedTheme = theme;
        if (HighContrast) return;
        bool light = theme == ElementTheme.Light;
        dialog.Background = Panel(light);
        dialog.BorderBrush = Edge();
        dialog.CornerRadius = new CornerRadius(20);
        dialog.Resources["ContentDialogTopOverlay"] = Sheen();
        dialog.PrimaryButtonStyle = Capsule(true, light);
        dialog.SecondaryButtonStyle = dialog.CloseButtonStyle = Capsule(false, light);
        // ContentDialog's default-action state replaces the primary Style with AccentButtonStyle.
        // Set its material on the realized control and preserve the native Return-key behavior.
        if (dialog.DefaultButton == ContentDialogButton.Primary)
            dialog.Opened += (_, _) => {
                if (FindPrimary(dialog) is { } button) {
                    button.CornerRadius = new CornerRadius(10);
                    button.Background = Acrylic(Blue, .83, .53);
                    button.Foreground = new SolidColorBrush(Microsoft.UI.Colors.White);
                    button.BorderBrush = Edge();
                }
            };
    }

    static Button? FindPrimary(DependencyObject parent)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is Button { Name: "PrimaryButton" } button) return button;
            if (FindPrimary(child) is { } descendant) return descendant;
        }
        return null;
    }
}
