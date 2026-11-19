using System.Diagnostics;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.System;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Controls;

sealed class ModelEffortSlider : UserControl
{
    public const double TrackHeight = ModelPickerVisuals.TrackHeight;
    public const double KnobDiameter = ModelPickerVisuals.KnobDiameter;
    const double DotDiameter = 3;
    readonly Canvas surface = new();
    readonly Border track = new() { Height = TrackHeight, CornerRadius = new(TrackHeight / 2) };
    readonly Border progress = new() { Height = TrackHeight, CornerRadius = new(TrackHeight / 2), IsHitTestVisible = false };
    readonly Canvas stars = new() { IsHitTestVisible = false };
    readonly Canvas ticks = new() { IsHitTestVisible = false };
    readonly Ellipse knob = new() { Width = KnobDiameter, Height = KnobDiameter, StrokeThickness = .5 };
    readonly Border outline = new() { Height = KnobDiameter, BorderThickness = new(1.5), CornerRadius = new(KnobDiameter / 2), IsHitTestVisible = false };
    const double SpringResponse = .26;
    const double Damping = .85;
    static readonly (double X, double Y, double Diameter, byte Opacity)[] StarPositions =
    [
        (.06, .34, 1.6, 140), (.11, .68, 1.1, 87), (.18, .24, 1.3, 107), (.24, .72, 2, 158), (.30, .44, 1.2, 77),
        (.37, .20, 1.7, 128), (.43, .66, 1.3, 97), (.49, .36, 2.1, 168), (.55, .76, 1.2, 82), (.61, .28, 1.5, 117),
        (.67, .58, 1.1, 77), (.73, .38, 1.9, 148), (.79, .70, 1.3, 92), (.86, .30, 1.5, 112), (.93, .60, 1.2, 82)
    ];
    readonly (Ellipse Dot, Line? Horizontal, Line? Vertical)[] starViews = new (Ellipse, Line?, Line?)[StarPositions.Length];
    readonly RectangleGeometry starClip = new();
    readonly DispatcherQueueTimer frames;
    double displayedIndex;
    double velocity;
    double starTravel;
    long lastFrame;
    bool hasFrame, highContrast;
    string[] options = [];
    int selected;
    int? preview;
    uint? pointer;
    bool hovered;
    bool blue;
    bool fast;
    bool keyboard;

    public event Action? PresentationChanged;
    public event Action<int>? SelectionCommitted;
    public bool IsEngaged => hovered || pointer is not null;
    public bool IsPeak => options.Length > 1 && (preview ?? selected) == options.Length - 1;
    public string CurrentTitle => options.ElementAtOrDefault(preview ?? selected) ?? "Default";
    int ActiveIndex => preview ?? selected;
    bool IsSettling => Math.Abs(displayedIndex - ActiveIndex) > .001 || Math.Abs(velocity) > .01;

    public ModelEffortSlider()
    {
        Height = KnobDiameter;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        AutomationProperties.SetName(this, "Reasoning effort");
        AutomationProperties.SetAutomationId(this, "ReasoningEffortSlider");
        ToolTipService.SetToolTip(this, "Drag left for faster answers, right for more reasoning.");
        foreach (var child in new UIElement[] { track, progress, stars, ticks, knob, outline }) surface.Children.Add(child);
        stars.Clip = starClip;
        var rays = new SolidColorBrush(Color.FromArgb(217, 255, 255, 255));
        for (var i = 0; i < StarPositions.Length; i++)
        {
            var star = StarPositions[i];
            var dot = new Ellipse { Width = star.Diameter, Height = star.Diameter,
                Fill = new SolidColorBrush(Color.FromArgb(star.Opacity, 255, 255, 255)) };
            stars.Children.Add(dot);
            Line? horizontal = null;
            Line? vertical = null;
            if (star.Diameter >= 1.9)
            {
                horizontal = new Line { X1 = -3.5, X2 = 3.5, Stroke = rays, StrokeThickness = .6 };
                vertical = new Line { Y1 = -4, Y2 = 4, Stroke = rays, StrokeThickness = .6 };
                stars.Children.Add(horizontal);
                stars.Children.Add(vertical);
            }
            starViews[i] = (dot, horizontal, vertical);
        }
        frames = DispatcherQueue.CreateTimer();
        frames.Interval = TimeSpan.FromMilliseconds(1000d / 60);
        frames.Tick += (_, _) => AdvanceFrame();
        Content = surface;
        Loaded += (_, _) => Draw();
        Unloaded += (_, _) =>
        {
            frames.Stop();
            hasFrame = hovered = false;
            pointer = null;
            preview = null;
            velocity = 0;
        };
        SizeChanged += (_, _) => Draw();
        ActualThemeChanged += (_, _) => Draw();
        GotFocus += (_, _) => { keyboard = keyboard || FocusState == FocusState.Keyboard; Draw(); };
        LostFocus += (_, _) => Draw();
        PointerEntered += (_, _) => { hovered = true; Redraw(); };
        PointerExited += (_, _) => { hovered = false; Redraw(); };
    }

    public void Configure(string[] titles, int index, bool useBluePalette, bool fastMode)
    {
        var old = selected;
        options = titles;
        selected = Math.Clamp(index, 0, Math.Max(0, titles.Length - 1));
        blue = useBluePalette;
        fast = fastMode;
        RefreshAutomation(old);
        Redraw();
    }

    protected override void OnPointerPressed(PointerRoutedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (!IsEnabled || pointer is not null || !e.GetCurrentPoint(this).Properties.IsLeftButtonPressed || !CapturePointer(e.Pointer)) return;
        keyboard = false;
        Focus(FocusState.Pointer);
        pointer = e.Pointer.PointerId;
        PreviewAt(e.GetCurrentPoint(this).Position.X);
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerRoutedEventArgs e)
    {
        base.OnPointerMoved(e);
        if (pointer != e.Pointer.PointerId) return;
        PreviewAt(e.GetCurrentPoint(this).Position.X);
        e.Handled = true;
    }

    protected override void OnPointerReleased(PointerRoutedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (pointer != e.Pointer.PointerId) return;
        pointer = null;
        preview = null;
        ReleasePointerCapture(e.Pointer);
        Commit(StopAt(e.GetCurrentPoint(this).Position.X));
        e.Handled = true;
    }

    protected override void OnPointerCaptureLost(PointerRoutedEventArgs e) { base.OnPointerCaptureLost(e); Cancel(e); }
    protected override void OnPointerCanceled(PointerRoutedEventArgs e) { base.OnPointerCanceled(e); Cancel(e); }

    void Cancel(PointerRoutedEventArgs e)
    {
        if (pointer != e.Pointer.PointerId) return;
        pointer = null;
        preview = null;
        Redraw();
    }

    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        var next = e.Key switch
        {
            VirtualKey.Left or VirtualKey.Down => selected - 1,
            VirtualKey.Right or VirtualKey.Up => selected + 1,
            VirtualKey.Home => 0,
            VirtualKey.End => options.Length - 1,
            _ => int.MinValue
        };
        if (next == int.MinValue) { base.OnKeyDown(e); return; }
        keyboard = true;
        Commit(next);
        e.Handled = true;
    }

    int StopAt(double x) => Math.Clamp((int)Math.Round((x - KnobDiameter / 2) * Math.Max(1, options.Length - 1)
        / Math.Max(1, ActualWidth - KnobDiameter), MidpointRounding.AwayFromZero), 0, Math.Max(0, options.Length - 1));

    void PreviewAt(double x)
    {
        var next = StopAt(x);
        if (preview == next) return;
        preview = next;
        Redraw();
    }

    void Commit(int index)
    {
        if (!IsEnabled || options.Length < 2) return;
        var old = selected;
        selected = Math.Clamp(index, 0, options.Length - 1);
        RefreshAutomation(old);
        Redraw();
        if (selected != old) SelectionCommitted?.Invoke(selected);
    }

    void RefreshAutomation(int old)
    {
        AutomationProperties.SetHelpText(this, CurrentTitle);
        if (old != selected && FrameworkElementAutomationPeer.FromElement(this) is { } peer)
            peer.RaisePropertyChangedEvent(RangeValuePatternIdentifiers.ValueProperty, (double)old, (double)selected);
    }

    void Redraw() { Draw(); PresentationChanged?.Invoke(); }

    void Draw()
    {
        var width = ActualWidth;
        if (width <= KnobDiameter) return;
        var active = ActiveIndex;
        var center = KnobDiameter / 2;
        var spacing = (width - KnobDiameter) / Math.Max(1, options.Length - 1);
        highContrast = new AccessibilitySettings().HighContrast;
        var ui = new UISettings();
        var foreground = highContrast ? ui.GetColorValue(UIColorType.Foreground)
            : ActualTheme == ElementTheme.Dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
        track.Width = outline.Width = width;
        track.Background = new SolidColorBrush(Alpha(foreground, highContrast ? (byte)255 : (byte)23));
        Canvas.SetTop(track, (KnobDiameter - TrackHeight) / 2);
        progress.Background = highContrast ? new SolidColorBrush(ui.UIElementColor(UIElementType.Highlight)) : Fill(width);
        Canvas.SetTop(progress, (KnobDiameter - TrackHeight) / 2);
        knob.Fill = new SolidColorBrush(highContrast ? ui.UIElementColor(UIElementType.Background) : Microsoft.UI.Colors.White);
        knob.Stroke = new SolidColorBrush(highContrast ? foreground : Color.FromArgb(18, 0, 0, 0));
        outline.BorderBrush = new SolidColorBrush(Alpha(foreground, highContrast ? (byte)255 : (byte)82));
        outline.Visibility = keyboard && FocusState != FocusState.Unfocused ? Visibility.Visible : Visibility.Collapsed;

        ticks.Children.Clear();
        for (var i = 0; i < options.Length; i++)
        {
            if (i == active || i < active && !IsEngaged) continue;
            var tick = new Ellipse { Width = DotDiameter, Height = DotDiameter,
                Fill = new SolidColorBrush(highContrast ? ui.UIElementColor(UIElementType.HighlightText)
                    : i < active ? Color.FromArgb(97, 255, 255, 255) : Alpha(foreground, 71)) };
            Canvas.SetLeft(tick, center + spacing * i - DotDiameter / 2);
            Canvas.SetTop(tick, center - DotDiameter / 2);
            ticks.Children.Add(tick);
        }

        if (!hasFrame || !CanAnimate(ui))
        {
            displayedIndex = active;
            velocity = 0;
        }
        hasFrame = true;
        RenderFrame();
        if (!CanAnimate(ui) || !IsSettling && (!IsPeak || highContrast)) frames.Stop();
        else if (!frames.IsRunning)
        {
            lastFrame = Stopwatch.GetTimestamp();
            frames.Start();
        }
    }

    bool CanAnimate(UISettings ui) => ui.AnimationsEnabled && IsLoaded && IsEnabled && Visibility == Visibility.Visible;

    void AdvanceFrame()
    {
        if (!CanAnimate(new UISettings()))
        {
            displayedIndex = ActiveIndex;
            velocity = 0;
            RenderFrame();
            frames.Stop();
            return;
        }
        var now = Stopwatch.GetTimestamp();
        var elapsed = Math.Min(Stopwatch.GetElapsedTime(lastFrame, now).TotalSeconds, .05);
        lastFrame = now;

        if (IsSettling)
        {
            // Use the same damped spring as the Mac picker and keep its velocity
            // when the pointer crosses another stop before it has settled.
            var target = ActiveIndex;
            var offset = displayedIndex - target;
            var angular = 2 * Math.PI / SpringResponse;
            var decay = Damping * angular;
            var frequency = angular * Math.Sqrt(1 - Damping * Damping);
            var sineOffset = (velocity + decay * offset) / frequency;
            var sine = Math.Sin(frequency * elapsed);
            var cosine = Math.Cos(frequency * elapsed);
            var envelope = Math.Exp(-decay * elapsed);
            var wave = offset * cosine + sineOffset * sine;
            displayedIndex = target + envelope * wave;
            velocity = envelope * (frequency * (sineOffset * cosine - offset * sine) - decay * wave);
        }
        if (!IsSettling)
        {
            displayedIndex = ActiveIndex;
            velocity = 0;
        }
        if (IsPeak && !highContrast)
            starTravel = (starTravel + elapsed * (fast ? 12 : 4)) % (ActualWidth + 8);
        else if (!IsSettling) frames.Stop();
        RenderFrame();
    }

    void RenderFrame()
    {
        var width = ActualWidth;
        if (width <= KnobDiameter) return;
        var center = KnobDiameter / 2;
        var spacing = (width - KnobDiameter) / Math.Max(1, options.Length - 1);
        var x = center + spacing * Math.Clamp(displayedIndex, 0, Math.Max(0, options.Length - 1));
        progress.Width = x;
        Canvas.SetLeft(knob, x - center);
        stars.Visibility = IsPeak && !highContrast ? Visibility.Visible : Visibility.Collapsed;
        if (stars.Visibility != Visibility.Visible) return;

        starClip.Rect = new Rect(0, (KnobDiameter - TrackHeight) / 2, x, TrackHeight);
        var period = width + 8;
        for (var i = 0; i < starViews.Length; i++)
        {
            var star = StarPositions[i];
            var (dot, horizontal, vertical) = starViews[i];
            var left = (star.X * period + starTravel) % period - 4;
            var top = (KnobDiameter - TrackHeight) / 2 + star.Y * TrackHeight;
            Canvas.SetLeft(dot, left - star.Diameter / 2);
            Canvas.SetTop(dot, top - star.Diameter / 2);
            if (horizontal is not null && vertical is not null)
            {
                Canvas.SetLeft(horizontal, left);
                Canvas.SetTop(horizontal, top);
                Canvas.SetLeft(vertical, left);
                Canvas.SetTop(vertical, top);
            }
        }
    }

    Brush Fill(double width)
    {
        var ramp = new LinearGradientBrush { MappingMode = BrushMappingMode.Absolute,
            StartPoint = new Point(0, 0), EndPoint = new Point(width, 0) };
        var colors = (blue, IsPeak) switch
        {
            (true, true) => new[] { (4, 18, 61), (6, 46, 117), (20, 92, 173) },
            (false, true) => new[] { (74, 89, 232), (140, 77, 250), (194, 79, 240) },
            (true, false) => new[] { (18, 87, 196), (31, 89, 214), (46, 133, 224) },
            _ => new[] { (18, 87, 196), (31, 89, 214), (92, 79, 237) }
        };
        var offsets = new[] { 0, IsPeak ? .55 : .62, 1 };
        for (var i = 0; i < colors.Length; i++)
        {
            var (r, g, b) = colors[i];
            ramp.GradientStops.Add(new GradientStop { Color = Color.FromArgb(255, (byte)r, (byte)g, (byte)b), Offset = offsets[i] });
        }
        return ramp;
    }

    static Color Alpha(Color color, byte value) => Color.FromArgb(value, color.R, color.G, color.B);

    protected override AutomationPeer OnCreateAutomationPeer() => new EffortAutomationPeer(this);

    sealed class EffortAutomationPeer(ModelEffortSlider owner) : FrameworkElementAutomationPeer(owner), IRangeValueProvider
    {
        protected override string GetClassNameCore() => "Slider";
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Slider;
        protected override object GetPatternCore(PatternInterface patternInterface) => patternInterface == PatternInterface.RangeValue ? this : base.GetPatternCore(patternInterface);
        public bool IsReadOnly => !owner.IsEnabled;
        public double LargeChange => 1;
        public double Maximum => Math.Max(0, owner.options.Length - 1);
        public double Minimum => 0;
        public double SmallChange => 1;
        public double Value => owner.selected;
        public void SetValue(double value)
        {
            if (IsReadOnly) throw new InvalidOperationException("Reasoning effort is unavailable.");
            if (!double.IsFinite(value) || value < Minimum || value > Maximum) throw new ArgumentOutOfRangeException(nameof(value));
            owner.Commit((int)Math.Round(value));
        }
    }
}
