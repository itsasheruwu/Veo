using Microsoft.UI.Xaml;
using Microsoft.UI.Windowing;
using Veo.Core;
using Windows.Graphics;

namespace Veo_Windows.Services;

public sealed class WindowBoundsCoordinator(Window window, WorkspaceCoordinator workspace) : IAsyncDisposable
{
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer = window.DispatcherQueue.CreateTimer();
    bool attached;
    public void Restore()
    {
        var p = workspace.Preferences;
        var desired = new RectInt32(p.WindowX ?? 100, p.WindowY ?? 80, (int)p.WindowWidth, (int)p.WindowHeight);
        var work = DisplayArea.GetFromRect(desired, DisplayAreaFallback.Primary).WorkArea;
        desired.Width = Math.Clamp(desired.Width, 640, Math.Max(640, work.Width)); desired.Height = Math.Clamp(desired.Height, 480, Math.Max(480, work.Height));
        desired.X = Math.Clamp(desired.X, work.X, Math.Max(work.X, work.X + work.Width - desired.Width)); desired.Y = Math.Clamp(desired.Y, work.Y, Math.Max(work.Y, work.Y + work.Height - desired.Height));
        window.AppWindow.MoveAndResize(desired);
        if (p.WindowMaximized && window.AppWindow.Presenter is OverlappedPresenter presenter) presenter.Maximize();
        timer.Interval = TimeSpan.FromMilliseconds(350); timer.IsRepeating = false; timer.Tick += Save;
        window.AppWindow.Changed += Changed; attached = true;
    }
    void Changed(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (!args.DidPositionChange && !args.DidSizeChange && !args.DidPresenterChange) return;
        var p = workspace.Preferences;
        if (sender.Presenter is OverlappedPresenter presenter)
        {
            p.WindowMaximized = presenter.State == OverlappedPresenterState.Maximized;
            if (presenter.State != OverlappedPresenterState.Restored) { timer.Stop(); timer.Start(); return; }
        }
        p.WindowX = sender.Position.X; p.WindowY = sender.Position.Y; p.WindowWidth = sender.Size.Width; p.WindowHeight = sender.Size.Height;
        timer.Stop(); timer.Start();
    }
    async void Save(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        try { await workspace.SavePreferencesAsync(); }
        catch (Exception error) { System.Diagnostics.Debug.WriteLine("Veo bounds save: " + Veo.Protocol.DiagnosticRedactor.Redact(error.Message)); }
    }
    public async ValueTask DisposeAsync()
    {
        if (!attached) return; attached = false; window.AppWindow.Changed -= Changed; timer.Stop(); timer.Tick -= Save; await workspace.SavePreferencesAsync();
    }
}
