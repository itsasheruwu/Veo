using Microsoft.UI.Xaml.Controls.Primitives;
using Veo_Windows.Controls;

namespace Veo_Windows;

public sealed partial class MainPage
{
    ComposerPillMotion composerProviderPill = null!;
    ComposerPillMotion composerModelPill = null!;
    ComposerPillMotion composerPermissionsPill = null!;
    ComposerPillMotion[] composerPills = [];
    FlyoutBase? composerPillFlyout;
    CancellationTokenSource? composerPillTransition;
    Task? pendingComposerProviderSelection;

    void InitializeComposerPills()
    {
        composerProviderPill = new(ProviderTrigger, ProviderPillSurface, ProviderPillFace);
        composerModelPill = new(ModelTrigger, ModelPillSurface, ModelTriggerLabel);
        composerPermissionsPill = new(AccessButton, AccessPillSurface, AccessPillFace);
        composerPills = [composerProviderPill, composerModelPill, composerPermissionsPill];
    }

    void ShowComposerPill(FlyoutBase flyout, ComposerPillMotion selected)
    {
        CloseComposerPill();
        composerPillFlyout = flyout;
        foreach (var pill in composerPills) pill.Hold();
        flyout.Closed += (_, _) =>
        {
            if (composerPillFlyout == flyout)
                _ = ReleaseComposerPillAsync(flyout, selected, RenewComposerPillTransition());
        };
        try
        {
            flyout.ShowAt(selected.Button);
            if (composerPillFlyout == flyout)
                _ = OpenComposerPillAsync(selected, RenewComposerPillTransition());
        }
        catch { CloseComposerPill(); throw; }
    }

    async Task OpenComposerPillAsync(ComposerPillMotion selected, CancellationToken token)
    {
        try { await selected.OpenAsync(token); }
        catch (OperationCanceledException) { }
    }

    async Task ReleaseComposerPillAsync(FlyoutBase flyout, ComposerPillMotion selected, CancellationToken token)
    {
        try
        {
            await selected.CloseFaceAsync(token);
            await Task.Yield();
            if (selected == composerProviderPill && pendingComposerProviderSelection is { } selection)
                await selection.WaitAsync(token);
            if (composerPillFlyout != flyout) return;
            composerPillFlyout = null;
            foreach (var pill in composerPills) pill.ReleaseWidth();
            // Measure against the new text while the selected face is still edge-on.
            RenderComposerControls();
            ComposerToolbar.UpdateLayout();
            await selected.RevealAsync(token);
        }
        catch (OperationCanceledException) { }
    }

    void CloseComposerPill()
    {
        composerPillTransition?.Cancel();
        composerPillTransition?.Dispose();
        composerPillTransition = null;
        pendingComposerProviderSelection = null;
        var flyout = composerPillFlyout;
        composerPillFlyout = null;
        flyout?.Hide();
        foreach (var pill in composerPills)
        {
            pill.Reset();
            pill.ReleaseWidth();
        }
    }

    CancellationToken RenewComposerPillTransition()
    {
        composerPillTransition?.Cancel();
        composerPillTransition?.Dispose();
        composerPillTransition = new CancellationTokenSource();
        return composerPillTransition.Token;
    }
}
