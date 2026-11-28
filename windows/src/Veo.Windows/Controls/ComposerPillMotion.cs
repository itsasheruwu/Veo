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
    readonly Visual front;
    readonly SpriteVisual softLabel;
    readonly SpriteVisual softCapsule;
    readonly DropShadow labelBlur;
    readonly DropShadow capsuleBlur;
    readonly CompositionVisualSurface labelMask;
    readonly CompositionVisualSurface capsuleMask;
    readonly CompositionRoundedRectangleGeometry capsuleGeometry;
    readonly ShapeVisual capsule;
    readonly CompositionPropertySet progress;
    readonly UISettings accessibility = new();
    readonly AccessibilitySettings contrast = new();
    readonly Visual? chevron;
    double heldWidth;

    public ComposerPillMotion(Button button, Grid surface, FrameworkElement face)
    {
        Button = button;
        var frontHost = new Grid();
        surface.Children.Remove(face);
        frontHost.Children.Add(face);
        surface.Children.Add(frontHost);
        front = ElementCompositionPreview.GetElementVisual(frontHost);
        var compositor = front.Compositor;
        progress = compositor.CreatePropertySet();
        progress.InsertScalar("Flip", 0);
        labelMask = compositor.CreateVisualSurface();
        labelMask.SourceVisual = ElementCompositionPreview.GetElementVisual(face);
        labelBlur = compositor.CreateDropShadow();
        labelBlur.Mask = compositor.CreateSurfaceBrush(labelMask);
        softLabel = compositor.CreateSpriteVisual();
        softLabel.Shadow = labelBlur;

        capsuleGeometry = compositor.CreateRoundedRectangleGeometry();
        capsuleGeometry.CornerRadius = new Vector2(8);
        var silhouette = compositor.CreateSpriteShape(capsuleGeometry);
        silhouette.FillBrush = compositor.CreateColorBrush(Microsoft.UI.Colors.White);
        capsule = compositor.CreateShapeVisual();
        capsule.Shapes.Add(silhouette);
        capsuleMask = compositor.CreateVisualSurface();
        capsuleMask.SourceVisual = capsule;
        capsuleBlur = compositor.CreateDropShadow();
        capsuleBlur.Mask = compositor.CreateSurfaceBrush(capsuleMask);
        capsuleBlur.BlurRadius = 4;
        softCapsule = compositor.CreateSpriteVisual();
        softCapsule.Shadow = capsuleBlur;
        var effects = compositor.CreateContainerVisual();
        effects.Children.InsertAtTop(softLabel);
        effects.Children.InsertAtTop(softCapsule);
        var host = new Grid { IsHitTestVisible = false };
        AutomationProperties.SetAccessibilityView(host, AccessibilityView.Raw);
        surface.Children.Add(host);
        ElementCompositionPreview.SetElementChildVisual(host, effects);

        if (face is Panel panel && panel.Children.LastOrDefault() is FontIcon arrow)
        {
            chevron = ElementCompositionPreview.GetElementVisual(arrow);
            arrow.SizeChanged += (_, _) => chevron.CenterPoint = new Vector3(chevron.Size / 2, 0);
            Bind(chevron, "RotationAngleInDegrees", "track.Flip * 180");
        }
        Bind(front, "Scale.Y", "1 - 0.94 * Min(1,track.Flip*2)");
        Bind(front, "Opacity", "Max(0,1-track.Flip*2)");
        Bind(softLabel, "Opacity", "4 * Min(0.5,track.Flip) * Max(0,1-track.Flip*2)");
        Bind(softLabel, "Scale.Y", "1 - 0.94 * Min(1,track.Flip*2)");
        Bind(labelBlur, "BlurRadius", "7 * Min(1,track.Flip*2)");
        Bind(softCapsule, "Opacity", "0.40 * Max(0,track.Flip*2-1)");
        Bind(softCapsule, "Scale.Y", "0.06 + 0.94 * Max(0,track.Flip*2-1)");
        surface.SizeChanged += (_, change) =>
        {
            var size = new Vector2((float)change.NewSize.Width, (float)change.NewSize.Height);
            labelMask.SourceSize = softLabel.Size = size;
            capsuleMask.SourceSize = softCapsule.Size = capsule.Size = size;
            capsuleGeometry.Size = Vector2.Max(Vector2.One, size - new Vector2(2, 6));
            capsuleGeometry.Offset = new Vector2(1, 3);
            front.CenterPoint = softLabel.CenterPoint = softCapsule.CenterPoint = new Vector3(size / 2, 0);
        };
    }

    public Button Button { get; }
    bool Animates => accessibility.AnimationsEnabled && !contrast.HighContrast;

    public void Hold()
    {
        heldWidth = Button.ActualWidth;
        if (heldWidth > 0) Button.Width = heldWidth;
    }

    public void ReleaseWidth() => Button.Width = double.NaN;

    public async Task OpenAsync(CancellationToken token)
    {
        var color = (Button.Foreground as SolidColorBrush)?.Color ??
            (Button.ActualTheme == ElementTheme.Dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black);
        labelBlur.Color = capsuleBlur.Color = color;
        if (contrast.HighContrast) { SetFlip(0); return; }
        await FlipAsync(.5f, 105, token);
        await FlipAsync(1, 135, token);
    }

    public Task CloseFaceAsync(CancellationToken token) => contrast.HighContrast ? Task.CompletedTask : FlipAsync(.5f, 105, token);

    public async Task RevealAsync(CancellationToken token)
    {
        if (Animates) ResizeVisual();
        await FlipAsync(0, 180, token);
    }

    public void Reset()
    {
        SetFlip(0);
        var button = ElementCompositionPreview.GetElementVisual(Button);
        button.StopAnimation("Scale");
        button.Scale = Vector3.One;
    }

    void Bind(CompositionObject visual, string property, string expression)
    {
        using var animation = visual.Compositor.CreateExpressionAnimation(expression);
        animation.SetReferenceParameter("track", progress);
        visual.StartAnimation(property, animation);
    }

    async Task FlipAsync(float target, int duration, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        front.CenterPoint = new Vector3(front.Size / 2, 0);
        if (!Animates)
        {
            SetFlip(target);
            return;
        }

        var compositor = progress.Compositor;
        using var animation = compositor.CreateScalarKeyFrameAnimation();
        using var easing = compositor.CreateCubicBezierEasingFunction(target == .5f ? new Vector2(.42f, 0) : Vector2.Zero, target == .5f ? Vector2.One : new Vector2(.58f, 1));
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
