using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Controls;

/// <summary>Samples the same coordinates as the prism underneath the card. Video surfaces can
/// be rendered on an independent hardware plane, outside an in-app acrylic brush's backdrop.</summary>
public sealed class TourGlassPlate : Grid
{
    static readonly BitmapImage SoftPrism = new() {
        DecodePixelWidth = 52, UriSource = new Uri("ms-appx:///Assets/VeoPrism.jpg")
    };
    readonly Image scenery = new() { Source = SoftPrism, Stretch = Stretch.UniformToFill };
    readonly Border material = new();
    readonly Border rim = new();
    WorkspaceTour? tour;
    Rect bounds;
    bool light;

    public TourGlassPlate()
    {
        IsHitTestVisible = false;
        AutomationProperties.SetAccessibilityView(this, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        CornerRadius = new CornerRadius(15);
        Children.Add(new Canvas { Children = { scenery } });
        Children.Add(material);
        rim.BorderThickness = new Thickness(1);
        rim.CornerRadius = CornerRadius;
        Children.Add(rim);
        Loaded += (_, _) => {
            for (DependencyObject? owner = this; owner != null; owner = VisualTreeHelper.GetParent(owner))
                if (owner is WorkspaceTour parent) { tour = parent; break; }
            SetLight(light);
            LayoutUpdated += PositionBackdrop;
            PositionBackdrop(null, null!);
        };
        Unloaded += (_, _) => { LayoutUpdated -= PositionBackdrop; tour = null; bounds = default; };
    }

    internal void SetLight(bool value)
    {
        light = value;
        var opaque = new AccessibilitySettings().HighContrast || !new UISettings().AdvancedEffectsEnabled;
        scenery.Visibility = opaque ? Visibility.Collapsed : Visibility.Visible;
        material.Background = TourGlass.Panel(light);
        material.Opacity = opaque ? 1 : light ? .87 : .58;
        rim.Background = TourGlass.Sheen();
        rim.BorderBrush = TourGlass.Edge();
    }

    void PositionBackdrop(object? sender, object args)
    {
        if (tour == null || tour.ActualWidth == 0 || scenery.Visibility == Visibility.Collapsed) return;
        var origin = TransformToVisual(tour).TransformPoint(new Point());
        var current = new Rect(origin.X, origin.Y, tour.ActualWidth, tour.ActualHeight);
        if (current == bounds) return;
        bounds = current;
        scenery.Width = current.Width;
        scenery.Height = current.Height;
        Canvas.SetLeft(scenery, -current.X);
        Canvas.SetTop(scenery, -current.Y);
    }
}
