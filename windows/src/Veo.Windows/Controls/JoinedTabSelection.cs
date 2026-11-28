using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Foundation;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Controls;

// One moving silhouette under the native tab headers. Scrolling, dragging, focus,
// selection, close buttons and keyboard shortcuts remain owned by TabView.
internal sealed class JoinedTabSelection
{
    readonly TabView tabs;
    readonly Canvas underlay = new() { IsHitTestVisible = false };
    readonly CompositeTransform position = new();
    readonly Microsoft.UI.Xaml.Shapes.Path shape;
    readonly RectangleGeometry clip = new();
    readonly AccessibilitySettings contrast = new();
    ScrollViewer? scroll;
    TabViewItem? previous;
    Rect last;
    Storyboard? movement;

    public JoinedTabSelection(TabView tabs, Grid bar)
    {
        this.tabs = tabs;
        tabs.Resources.ThemeDictionaries["Default"] = new ResourceDictionary { ["TabViewItemHeaderBackgroundSelected"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        tabs.Resources.ThemeDictionaries["HighContrast"] = new ResourceDictionary();
        shape = (Microsoft.UI.Xaml.Shapes.Path)Microsoft.UI.Xaml.Markup.XamlReader.Load("""
            <Path xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Data="M0,32 Q5,32 5,27 L5,9 Q5,0 14,0 L96,0 Q105,0 105,9 L105,27 Q105,32 110,32 Z" Fill="{ThemeResource ControlFillColorSecondaryBrush}" />
            """);
        shape.RenderTransform = position;
        underlay.Clip = clip;
        AutomationProperties.SetAccessibilityView(underlay, AccessibilityView.Raw);
        underlay.Children.Add(shape);
        bar.Children.Insert(0, underlay);
        tabs.Loaded += (_, _) => { tabs.LayoutUpdated += Align; Align(null, null); };
        tabs.Unloaded += (_, _) => { tabs.LayoutUpdated -= Align; previous = null; scroll = null; movement?.Stop(); };
    }

    void Align(object? sender, object? args)
    {
        if (tabs.SelectedItem is not TabViewItem { IsLoaded: true, ActualWidth: > 0 } item || underlay.ActualHeight == 0 || contrast.HighContrast)
        {
            shape.Visibility = Visibility.Collapsed;
            previous = null;
            return;
        }
        scroll ??= AncestorScroll(item);
        var local = item.TransformToVisual(underlay).TransformPoint(new Point());
        var width = item.ActualWidth + 10;
        var rect = new Rect(local.X - 5, underlay.ActualHeight - 32, width, 32);
        var viewport = scroll is { IsLoaded: true } ? scroll.TransformToVisual(underlay).TransformBounds(new Rect(0, 0, scroll.ActualWidth, scroll.ActualHeight)) : new Rect(0, 0, tabs.ActualWidth, tabs.ActualHeight);
        if (clip.Rect != viewport) clip.Rect = viewport;
        if (previous == item && last == rect && shape.Visibility == Visibility.Visible) return;
        shape.Visibility = Visibility.Visible;
        var animate = previous != null && previous != item && ModelPickerVisuals.MotionEnabled;
        var startX = position.TranslateX;
        var startScale = position.ScaleX;
        movement?.Stop();
        position.TranslateX = rect.X;
        position.TranslateY = rect.Y;
        position.ScaleX = rect.Width / 110;
        if (animate)
        {
            movement = new Storyboard();
            AddMotion("TranslateX", startX, position.TranslateX);
            AddMotion("ScaleX", startScale, position.ScaleX);
            movement.Begin();
        }
        previous = item;
        last = rect;
    }

    static ScrollViewer? AncestorScroll(DependencyObject item)
    {
        for (var node = VisualTreeHelper.GetParent(item); node != null; node = VisualTreeHelper.GetParent(node))
            if (node is ScrollViewer viewer) return viewer;
        return null;
    }

    void AddMotion(string property, double from, double to)
    {
        var animation = new DoubleAnimation { From = from, To = to, Duration = TimeSpan.FromMilliseconds(190), EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } };
        Storyboard.SetTarget(animation, position);
        Storyboard.SetTargetProperty(animation, property);
        movement!.Children.Add(animation);
    }
}
