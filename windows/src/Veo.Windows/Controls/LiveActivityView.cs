using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Windows.Foundation;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Controls;

internal sealed class LiveActivityView : UserControl
{
    readonly UISettings motion = new();
    readonly AccessibilitySettings accessibility = new();
    readonly FontIcon icon = new() { Width = 14, FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock label = new() { FontSize = 12, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    readonly Grid labelHost = new();
    readonly FrameworkElement activityIcon;
    readonly DispatcherTimer statusTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    const double SweepPeriod = 1.8;
    const double RevealDuration = .24;
    readonly RectangleGeometry revealClip = new();
    LinearGradientBrush? shimmer;
    bool rendering;
    bool highContrast;
    double revealStartedAt = double.NegativeInfinity;
    double lastFrame;
    TimelineItem? step;
    DateTimeOffset? startedAt;
    bool isWorking = true;

    public LiveActivityView(FrameworkElement? leadingIcon = null)
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        activityIcon = leadingIcon ?? icon;
        AutomationProperties.SetAccessibilityView(activityIcon, AccessibilityView.Raw);
        var row = new Grid { ColumnSpacing = 8, MinHeight = 16 };
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new());
        row.Children.Add(activityIcon);
        Grid.SetColumn(labelHost, 1);
        labelHost.Children.Add(label);
        row.Children.Add(labelHost);
        Content = row;

        statusTimer.Tick += (_, _) =>
        {
            if (step?.Text.Length == 0) UpdateLabel();
            if (CanAnimate != rendering || accessibility.HighContrast != highContrast) RefreshMotion();
        };
        Loaded += (_, _) =>
        {
            RefreshMotion();
            if (isWorking) statusTimer.Start();
        };
        Unloaded += (_, _) =>
        {
            statusTimer.Stop();
            StopMotion();
        };
        ActualThemeChanged += (_, _) => RefreshMotion();
    }

    public void Update(TimelineItem item, DateTimeOffset? turnStartedAt, bool working = true)
    {
        var switched = step is not null && (step.Order != item.Order || step.Status != item.Status);
        var motionChanged = isWorking != working || step?.Status == "waitingForInput" || item.Status == "waitingForInput";
        isWorking = working;
        step = item;
        startedAt = turnStartedAt;
        icon.Glyph = item.Status switch
        {
            "commandExecution" => "\uE756",
            "fileChange" => "\uE70F",
            "webSearch" => "\uE721",
            "planUpdate" => "\uE9D5",
            "waitingForInput" => "\uE897",
            "mcpToolCall" or "dynamicToolCall" or "collabAgentToolCall" => "\uE713",
            _ => "\uE712"
        };
        UpdateLabel();
        if (!IsLoaded) return;

        if (motionChanged)
        {
            if (isWorking) statusTimer.Start();
            else statusTimer.Stop();
            RefreshMotion();
        }
        if (switched && rendering)
        {
            revealStartedAt = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
            labelHost.Clip = revealClip;
            DrawFrame(revealStartedAt);
        }
    }

    void UpdateLabel()
    {
        var elapsed = TimelineMessageView.Elapsed(startedAt, DateTimeOffset.UtcNow);
        var text = step?.Text is { Length: > 0 } title ? title : elapsed is null ? "Working…" : "Working for " + elapsed;
        if (label.Text != text) label.Text = text;
    }

    bool CanAnimate => isWorking && motion.AnimationsEnabled && !accessibility.HighContrast && step?.Status != "waitingForInput";

    void RefreshMotion()
    {
        if (!IsLoaded) return;
        StopMotion();
        highContrast = accessibility.HighContrast;
        label.Opacity = highContrast ? 1 : .82;
        if (!CanAnimate) return;
        var bright = label.Foreground is SolidColorBrush foreground ? foreground.Color :
            ActualTheme == ElementTheme.Dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
        var baseColor = bright;
        baseColor.A = (byte)(bright.A * .65);
        shimmer = new LinearGradientBrush
        {
            GradientStops =
            {
                new GradientStop { Offset = 0, Color = baseColor },
                new GradientStop { Offset = .5, Color = bright },
                new GradientStop { Offset = 1, Color = baseColor }
            }
        };
        label.Foreground = shimmer;
        label.Opacity = 1;
        rendering = true;
        CompositionTarget.Rendering += Animate;
        DrawFrame(Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency);
    }

    void Animate(object? sender, object args)
    {
        var time = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
        if (time - lastFrame >= 1.0 / 35) DrawFrame(time);
    }

    void DrawFrame(double time)
    {
        lastFrame = time;
        if (shimmer is null) return;
        var center = time % SweepPeriod / SweepPeriod * 1.5 - .25;
        shimmer.StartPoint = new Point(center - .22, .5);
        shimmer.EndPoint = new Point(center + .22, .5);
        icon.Opacity = .65 + .35 * (.5 + .5 * Math.Cos(time * Math.Tau / 1.25));

        if (labelHost.Clip is null) return;
        var progress = Math.Clamp((time - revealStartedAt) / RevealDuration, 0, 1);
        if (progress >= 1)
        {
            labelHost.Clip = null;
            return;
        }
        var visible = 1 - Math.Pow(1 - progress, 3);
        revealClip.Rect = new Rect(0, 0, labelHost.ActualWidth * visible, labelHost.ActualHeight);
    }

    void StopMotion()
    {
        if (rendering) CompositionTarget.Rendering -= Animate;
        rendering = false;
        shimmer = null;
        icon.Opacity = 1;
        labelHost.Clip = null;
        label.ClearValue(TextBlock.ForegroundProperty);
    }
}
