using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Controls;

sealed class GeneratedImageSweep : StackPanel
{
    readonly Grid dotPanel = new() { CornerRadius = new(8), Background = new SolidColorBrush(Color.FromArgb(255, 8, 13, 20)) };
    readonly GeometryGroup dots = new();
    static readonly Color DotColor = Color.FromArgb(255, 24, 65, 98);
    readonly RadialGradientBrush light = new() { RadiusX = .47, RadiusY = .38 };
    readonly GradientStop bright = new() { Offset = 0 };
    readonly GradientStop shoulder = new() { Offset = .38 };
    readonly UISettings motionSettings = new();
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(32) };

    public GeneratedImageSweep()
    {
        Spacing = 8;
        MaxWidth = 360;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        Padding = new(12);
        Background = new SolidColorBrush(Color.FromArgb(19, 103, 137, 166));
        CornerRadius = new(12);
        Children.Add(new TextBlock { Text = "Creating image", FontSize = 13 });
        light.GradientStops.Add(bright);
        light.GradientStops.Add(shoulder);
        light.GradientStops.Add(new GradientStop { Color = DotColor, Offset = 1 });
        bright.Color = HighlightColor(.72);
        shoulder.Color = HighlightColor(.52);
        dotPanel.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = dots, Fill = light });
        Children.Add(dotPanel);
        SizeChanged += (_, args) =>
        {
            var width = Math.Max(1, args.NewSize.Width - 24);
            var height = width * .75;
            dotPanel.Width = width;
            dotPanel.Height = height;
            dots.Children.Clear();
            for (double x = 4; x < width; x += 8)
                for (double y = 4; y < height; y += 8)
                    dots.Children.Add(new EllipseGeometry { Center = new(x, y), RadiusX = .85, RadiusY = .85 });
        };
        Loaded += (_, _) => timer.Start();
        Unloaded += (_, _) => timer.Stop();
        timer.Tick += (_, _) =>
        {
            var visible = IsVisibleInViewport(this);
            var animate = visible && App.Main?.IsActive == true && motionSettings.AnimationsEnabled;
            timer.Interval = TimeSpan.FromMilliseconds(animate ? 32 : 200);
            var fraction = animate ? (1 - Math.Cos(Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency * Math.PI / 4)) / 2 : .5;
            light.Center = light.GradientOrigin = new(.5 + (-24 + 56 * fraction) / Math.Max(dotPanel.ActualWidth, 1),
                .5 + (24 - 48 * fraction) / Math.Max(dotPanel.ActualHeight, 1));
            var amount = .45 + fraction * .55;
            bright.Color = HighlightColor(amount);
            shoulder.Color = HighlightColor(amount * .72);
        };
    }

    static Color HighlightColor(double strength) => Color.FromArgb(255,
        (byte)(DotColor.R + (67 - DotColor.R) * strength),
        (byte)(DotColor.G + (221 - DotColor.G) * strength),
        (byte)(DotColor.B + (255 - DotColor.B) * strength));

    internal static void Shimmer(FrameworkElement element)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(60) };
        element.Loaded += (_, _) => timer.Start();
        element.Unloaded += (_, _) => timer.Stop();
        timer.Tick += (_, _) =>
        {
            var animate = App.Main?.IsActive == true && IsVisibleInViewport(element) && new UISettings().AnimationsEnabled;
            if (animate && element is Panel { Children.Count: > 1 } panel && panel.Children[1] is TextBlock label)
            {
                var color = label.Foreground is SolidColorBrush solid ? solid.Color :
                    label.ActualTheme == ElementTheme.Dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
                var muted = color; muted.A = 150;
                var brush = new LinearGradientBrush();
                var offset = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency % 1.8 / 1.8 * 1.5 - .25;
                brush.StartPoint = new(offset - .22, .5); brush.EndPoint = new(offset + .22, .5);
                brush.GradientStops.Add(new GradientStop { Color = muted, Offset = 0 });
                brush.GradientStops.Add(new GradientStop { Color = color, Offset = .5 });
                brush.GradientStops.Add(new GradientStop { Color = muted, Offset = 1 });
                label.Foreground = brush;
            }
            else if (element is Panel { Children.Count: > 1 } inactive && inactive.Children[1] is TextBlock text)
                text.ClearValue(TextBlock.ForegroundProperty);
        };
    }

    static bool IsVisibleInViewport(FrameworkElement view)
    {
        if (!view.IsLoaded || view.ActualHeight <= 0) return false;
        for (var parent = VisualTreeHelper.GetParent(view); parent is not null; parent = VisualTreeHelper.GetParent(parent))
        {
            if (parent is not ScrollViewer viewport) continue;
            var bounds = view.TransformToVisual(viewport).TransformBounds(new Rect(0, 0, view.ActualWidth, view.ActualHeight));
            return bounds.Bottom > 0 && bounds.Top < viewport.ActualHeight;
        }
        return true;
    }
}
