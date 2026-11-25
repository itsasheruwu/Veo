using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Controls;

internal sealed class ComposerPillMotion
{
    readonly Border obscured = new() { Height = 18, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    readonly Visual front;
    readonly Visual back;
    readonly CompositionPropertySet progress;
    readonly UISettings accessibility = new();
    readonly AccessibilitySettings contrast = new();
    double heldWidth;

    public ComposerPillMotion(Button button, Grid surface, FrameworkElement face)
    {
        Button = button;
        AutomationProperties.SetAccessibilityView(obscured, AccessibilityView.Raw);
        surface.Children.Add(obscured);
        front = ElementCompositionPreview.GetElementVisual(face);
        back = ElementCompositionPreview.GetElementVisual(obscured);
        obscured.SizeChanged += (_, _) => back.CenterPoint = new Vector3(back.Size / 2, 0);
        progress = front.Compositor.CreatePropertySet();
        progress.InsertScalar("Flip", 0);
        front.RotationAxis = back.RotationAxis = Vector3.UnitX;
        Bind(front, "RotationAngleInDegrees", "track.Flip * 180.0f");
        Bind(back, "RotationAngleInDegrees", "(track.Flip - 1.0f) * 180.0f");
        Bind(front, "Opacity", "Max(0.0f, 1.0f - track.Flip * 2.5f)");
        Bind(back, "Opacity", "Max(0.0f, (track.Flip - 0.5f) * 2.0f)");
    }

    public Button Button { get; }
    bool Animates => accessibility.AnimationsEnabled && !contrast.HighContrast;

    public void Hold()
    {
        heldWidth = Button.ActualWidth;
        if (heldWidth > 0) Button.Width = heldWidth;
    }

    public void ReleaseWidth() => Button.Width = double.NaN;

    public Task OpenAsync(CancellationToken token)
    {
        var color = (Button.Foreground as SolidColorBrush)?.Color ??
            (Button.ActualTheme == ElementTheme.Dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black);
        var gradient = new RadialGradientBrush();
        var edge = color;
        color.A = contrast.HighContrast ? (byte)210 : (byte)134;
        edge.A = 0;
        gradient.GradientStops.Add(new() { Offset = 0.35, Color = color });
        gradient.GradientStops.Add(new() { Offset = 1, Color = edge });
        obscured.Background = gradient;
        obscured.Visibility = Visibility.Visible;
        return FlipAsync(1, 240, token);
    }

    public Task CloseFaceAsync(CancellationToken token) => FlipAsync(0.5f, 105, token);

    public async Task RevealAsync(CancellationToken token)
    {
        obscured.Visibility = Visibility.Collapsed;
        if (Animates) ResizeVisual();
        await FlipAsync(0, 180, token);
    }

    public void Reset()
    {
        SetFlip(0);
        obscured.Visibility = Visibility.Collapsed;
        var button = ElementCompositionPreview.GetElementVisual(Button);
        button.StopAnimation("Scale");
        button.Scale = Vector3.One;
    }

    void Bind(Visual visual, string property, string expression)
    {
        using var animation = visual.Compositor.CreateExpressionAnimation(expression);
        animation.SetReferenceParameter("track", progress);
        visual.StartAnimation(property, animation);
    }

    async Task FlipAsync(float target, int duration, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        front.CenterPoint = new Vector3(front.Size / 2, 0);
        back.CenterPoint = new Vector3(back.Size / 2, 0);
        if (!Animates)
        {
            SetFlip(target);
            return;
        }

        var compositor = progress.Compositor;
        using var animation = compositor.CreateScalarKeyFrameAnimation();
        using var easing = compositor.CreateCubicBezierEasingFunction(new Vector2(0.33f, 0), new Vector2(0.33f, 1));
        animation.InsertExpressionKeyFrame(0, "this.StartingValue");
        animation.InsertKeyFrame(1, target, easing);
        animation.Duration = TimeSpan.FromMilliseconds(duration);

        using var batch = compositor.CreateScopedBatch(CompositionBatchTypes.Animation);
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        batch.Completed += (_, _) => completed.TrySetResult();
        progress.StartAnimation("Flip", animation);
        batch.End();
        await completed.Task.WaitAsync(token);
        token.ThrowIfCancellationRequested();
        SetFlip(target);
    }

    void SetFlip(float target)
    {
        progress.StopAnimation("Flip");
        progress.InsertScalar("Flip", target);
    }

    void ResizeVisual()
    {
        if (Button.ActualWidth <= 0 || heldWidth <= 0 || Math.Abs(heldWidth - Button.ActualWidth) < 0.5) return;
        var visual = ElementCompositionPreview.GetElementVisual(Button);
        visual.CenterPoint = Vector3.Zero;
        visual.Scale = new Vector3((float)(heldWidth / Button.ActualWidth), 1, 1);
        using var animation = visual.Compositor.CreateVector3KeyFrameAnimation();
        animation.InsertKeyFrame(1, Vector3.One);
        animation.Duration = TimeSpan.FromMilliseconds(180);
        visual.StartAnimation("Scale", animation);
    }
}
