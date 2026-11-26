using System.Numerics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Controls;

internal static class ComposerModePill
{
    const double IconSize = 11;
    const double CaptionSpacing = 8;
    static readonly TimeSpan HoverDuration = TimeSpan.FromMilliseconds(160);
    static readonly Vector3 SmallDismissMark = new(.65f, .65f, 1);

    internal static void Configure(Button button, string title, IconElement mark, Size size, Color dark, Color light, bool opensSettings = false)
    {
        var ui = new UISettings();
        var accessibility = new AccessibilitySettings();
        var tint = new SolidColorBrush();
        var radius = new CornerRadius(size.Height / 2);
        var fill = new Border { CornerRadius = radius, Background = tint };
        var edge = new Border { CornerRadius = radius, BorderBrush = tint, BorderThickness = new Thickness(1) };

        mark.Foreground = tint;
        var symbol = new Viewbox
        {
            Width = IconSize, Height = IconSize, Child = mark, VerticalAlignment = VerticalAlignment.Center
        };

        var caption = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CaptionSpacing,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                symbol,
                new TextBlock
                {
                    Text = title, FontSize = 10.5, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = tint, VerticalAlignment = VerticalAlignment.Center
                }
            }
        };
        var dismiss = new FontIcon
        {
            Glyph = opensSettings ? "\uE713" : "\uE711", FontSize = opensSettings ? 11 : 9, Foreground = tint, Opacity = 0, Scale = SmallDismissMark,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
        };
        dismiss.SizeChanged += (_, e) => dismiss.CenterPoint = new Vector3((float)e.NewSize.Width / 2, (float)e.NewSize.Height / 2, 0);

        var face = new Grid { IsHitTestVisible = false, Children = { fill, edge, caption, dismiss } };
        AutomationProperties.SetAccessibilityView(face, AccessibilityView.Raw);

        button.Height = size.Height;
        button.Width = size.Width;
        button.CornerRadius = radius;
        button.Content = face;
        button.Resources["SubtleFillColorSecondaryBrush"] = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));

        var fade = new ScalarTransition { Duration = HoverDuration };
        var scale = new Vector3Transition { Duration = HoverDuration };
        var hovered = false;
        var keyboardFocused = false;
        void ApplyAppearance(bool animate)
        {
            var highContrast = accessibility.HighContrast;
            tint.Color = highContrast ? ui.UIElementColor(UIElementType.WindowText)
                : button.ActualTheme == ElementTheme.Dark ? dark : light;

            var motion = animate && button.IsLoaded && ui.AnimationsEnabled;
            fill.OpacityTransition = edge.OpacityTransition = caption.OpacityTransition = dismiss.OpacityTransition = motion ? fade : null;
            dismiss.ScaleTransition = motion ? scale : null;
            var reveal = hovered || keyboardFocused;
            fill.Opacity = highContrast ? 0 : reveal ? .20 : .14;
            edge.Opacity = highContrast ? 1 : reveal ? .42 : .28;
            caption.Opacity = reveal ? .08 : 1;
            dismiss.Opacity = reveal ? 1 : 0;
            dismiss.Scale = reveal ? Vector3.One : SmallDismissMark;
        }

        void SetHover(bool value)
        {
            if (hovered == value) return;
            hovered = value;
            ApplyAppearance(animate: button.Visibility == Visibility.Visible);
        }

        button.Loaded += (_, _) => ApplyAppearance(animate: false);
        button.ActualThemeChanged += (_, _) => ApplyAppearance(animate: false);
        button.PointerEntered += (_, _) => SetHover(button.IsEnabled);
        button.PointerExited += (_, _) => SetHover(false);
        button.PointerCanceled += (_, _) => SetHover(false);
        button.Unloaded += (_, _) => SetHover(false);
        if (opensSettings)
        {
            button.GotFocus += (_, _) => { keyboardFocused = button.FocusState == FocusState.Keyboard; ApplyAppearance(animate: true); };
            button.LostFocus += (_, _) => { keyboardFocused = false; ApplyAppearance(animate: true); };
        }
        button.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) =>
        {
            if (button.Visibility != Visibility.Visible) SetHover(false);
        });
        ApplyAppearance(animate: false);
    }
}
