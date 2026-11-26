using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Controls;

internal static class ModelPickerVisuals
{
    // Logical points from the macOS picker on a 2× display. WinUI uses the same
    // values in DIPs so text, the anchor, and the flyout scale together.
    internal const double StudioWidth = 332;
    internal const double StudioHeight = 430;
    internal const double StudioInset = 11;
    internal const double StudioTitle = 12.5;
    internal const double StudioDetail = 10.5;
    internal const double SliderWidth = 224;
    internal const double TriggerWidth = 178;
    internal const double TriggerHeight = 26;
    internal const double SliderInset = 12;
    internal const double TrackHeight = 24;
    internal const double KnobDiameter = 28;
    internal const double HeaderHeight = 26;
    internal const double RowHeight = 28;
    internal const double RowInset = 8;
    internal const double AdvancedInset = 4;
    internal const double Label = 13;
    internal const double ReasoningCaption = 11;
    internal const double CompactSpacing = 11;
    internal const double CornerRadius = 20;
    internal const double PointerHeight = 10;

    internal static bool MotionEnabled => new UISettings().AnimationsEnabled;

    internal static bool UsesBluePalette(string? modelName) =>
        modelName is "gpt-6-astra" or "gpt-6-sol" or "gpt-6.1-sol";

    internal static string ModelGlyph(string model)
    {
        var parts = (model.StartsWith("gpt-", StringComparison.Ordinal) ? model[4..] : model).Split('-', 3);
        if (parts.Length < 2 || parts[0] is not ("5.6" or "6" or "6.1" or "6.2")) return "";
        return parts[1] switch
        {
            "astra" => "\uE735",
            "sol" => "\uE706",
            "terra" => "\uE774",
            "luna" => "\uE708",
            _ => ""
        };
    }

    internal static Color PeakText(bool dark, bool blue) => (dark, blue) switch
    {
        (true, true) => Color.FromArgb(255, 145, 207, 255),
        (false, true) => Color.FromArgb(255, 18, 82, 166),
        (true, false) => Color.FromArgb(255, 184, 143, 255),
        _ => Color.FromArgb(255, 102, 33, 214)
    };

    internal static Color FastText(bool dark) => dark
        ? Color.FromArgb(255, 255, 214, 10)
        : Color.FromArgb(255, 154, 108, 0);

    internal static void Reveal(FrameworkElement element, Vector3 translation, int milliseconds)
    {
        if (!MotionEnabled) return;
        var compositor = ElementCompositionPreview.GetElementVisual(element).Compositor;
        var ease = compositor.CreateCubicBezierEasingFunction(new Vector2(.42f, 0), new Vector2(.58f, 1));
        var opacity = compositor.CreateScalarKeyFrameAnimation();
        opacity.Target = "Opacity";
        opacity.Duration = TimeSpan.FromMilliseconds(milliseconds);
        opacity.InsertKeyFrame(0, 0);
        opacity.InsertKeyFrame(1, 1, ease);
        element.StartAnimation(opacity);
        var move = compositor.CreateVector3KeyFrameAnimation();
        move.Target = "Translation";
        move.Duration = opacity.Duration;
        move.InsertKeyFrame(0, translation);
        move.InsertKeyFrame(1, Vector3.Zero, ease);
        element.StartAnimation(move);
    }

    internal static void FadeTo(FrameworkElement element, double target)
    {
        var previous = element.Opacity;
        element.Opacity = target;
        if (!MotionEnabled || previous == target) return;
        var compositor = ElementCompositionPreview.GetElementVisual(element).Compositor;
        var animation = compositor.CreateScalarKeyFrameAnimation();
        animation.Target = "Opacity";
        animation.Duration = TimeSpan.FromMilliseconds(140);
        animation.InsertKeyFrame(0, (float)previous);
        animation.InsertKeyFrame(1, (float)target, compositor.CreateCubicBezierEasingFunction(new(.42f, 0), new(.58f, 1)));
        element.StartAnimation(animation);
    }

    internal static Microsoft.UI.Xaml.Shapes.Path PickerPointer(Brush fill)
    {
        var figure = new PathFigure { StartPoint = new(0, 0), IsClosed = true };
        figure.Segments.Add(new QuadraticBezierSegment { Point1 = new(6, 0), Point2 = new(11, 6) });
        figure.Segments.Add(new QuadraticBezierSegment { Point1 = new(16, 13), Point2 = new(21, 6) });
        figure.Segments.Add(new QuadraticBezierSegment { Point1 = new(26, 0), Point2 = new(32, 0) });
        return new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = new PathGeometry { Figures = { figure } }, Fill = fill, Height = PointerHeight,
            Width = 32, HorizontalAlignment = HorizontalAlignment.Center, Stretch = Stretch.Fill,
            Margin = new(0, -1, 0, 0), IsHitTestVisible = false
        };
    }

    internal static Canvas InfoMark(Brush brush)
    {
        var mark = new Canvas { Width = 12, Height = 12, VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center, IsHitTestVisible = false };
        mark.Children.Add(new Ellipse { Width = 11, Height = 11, Stroke = brush, StrokeThickness = 1,
            RenderTransform = new TranslateTransform { X = .5, Y = .5 } });
        var dot = new Ellipse { Width = 1.25, Height = 1.25, Fill = brush };
        Canvas.SetLeft(dot, 5.45);
        Canvas.SetTop(dot, 2.8);
        mark.Children.Add(dot);
        var stem = new PathFigure { StartPoint = new(5, 5.2) };
        stem.Segments.Add(new LineSegment { Point = new(6.3, 5.2) });
        stem.Segments.Add(new LineSegment { Point = new(6.3, 8.5) });
        var foot = new PathFigure { StartPoint = new(5, 8.5) };
        foot.Segments.Add(new LineSegment { Point = new(7.4, 8.5) });
        mark.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = new PathGeometry { Figures = { stem, foot } }, Stroke = brush, StrokeThickness = .9
        });
        return mark;
    }

    internal static PathIcon SparklesIcon(Brush brush) => Mark(
        "M6,1 L7.4,5.4 12,7 7.4,8.5 6,13 4.5,8.5 0,7 4.5,5.4 Z M12,0 L12.8,2.2 15,3 12.8,3.8 12,6 11.2,3.8 9,3 11.2,2.2 Z",
        brush);

    internal static PathIcon GoalIcon(Brush brush) => Mark(
        "F0 M7,0 A7,7 0 1 1 7,14 A7,7 0 1 1 7,0 Z M7,1.4 A5.6,5.6 0 1 1 7,12.6 A5.6,5.6 0 1 1 7,1.4 Z M7,3.5 A3.5,3.5 0 1 1 7,10.5 A3.5,3.5 0 1 1 7,3.5 Z M7,5 A2,2 0 1 1 7,9 A2,2 0 1 1 7,5 Z",
        brush);

    internal static PathIcon RobloxIcon(Brush brush) => Mark(
        "F0 M3,0 L15,3 12,15 0,12 Z M6.4,5.5 L9.5,6.4 8.6,9.5 5.5,8.6 Z", brush);

    internal static PathIcon WildIcon(Brush brush) => Mark(
        "M2,7 L4.6,6.2 5.6,1.5 7.5,2.7 9.5,1.5 10.5,6.2 13,7 15,8.3 13,9.1 2,9.1 0,8.3 Z M0.8,10.5 L6.4,10.5 7.5,11.2 8.5,10.5 14.2,10.5 13.3,13.8 10,14.2 8.6,12.9 6.4,12.9 5,14.2 1.7,13.8 Z", brush);

    static PathIcon Mark(string path, Brush brush)
    {
        var icon = (PathIcon)Microsoft.UI.Xaml.Markup.XamlReader.Load($"""
            <PathIcon xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="15" Height="14" Data="{path}"/>
            """);
        icon.Foreground = brush;
        return icon;
    }

    internal static Microsoft.UI.Xaml.Shapes.Path SpeedBolt(bool ultrafast, Brush fill) => new()
    {
        Data = BoltGeometry(pair: ultrafast),
        Fill = fill,
        Stretch = Stretch.Uniform,
        Width = ultrafast ? 14 : 10,
        Height = 13,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        IsHitTestVisible = false
    };

    internal static PathGeometry BoltGeometry(bool outline = false, bool pair = false)
    {
        var geometry = new PathGeometry { FillRule = pair ? FillRule.Nonzero : FillRule.EvenOdd };
        Point[] points = [new(8, .5), new(1, 8.5), new(5.8, 8.5), new(4.6, 15), new(12.5, 5.6), new(7.5, 5.6)];
        AddPolygon(points);
        if (pair) AddPolygon(points.Select(point => new Point(point.X + 6, point.Y)).ToArray());
        if (outline) AddPolygon([new(6.7, 3.4), new(3.2, 7.4), new(7, 7.4), new(6.4, 11.2), new(10.1, 6.7), new(6.4, 6.7)]);
        return geometry;

        void AddPolygon(Point[] shape)
        {
            var figure = new PathFigure { StartPoint = shape[0], IsClosed = true };
            foreach (var point in shape.Skip(1)) figure.Segments.Add(new LineSegment { Point = point });
            geometry.Figures.Add(figure);
        }
    }
}
