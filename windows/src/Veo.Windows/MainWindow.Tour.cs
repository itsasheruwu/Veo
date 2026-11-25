using System.Diagnostics;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics;

namespace Veo_Windows;

public sealed partial class MainWindow
{
    RectInt32 workspaceFrame;
    bool wasMaximized, closed;
    bool InTour => TourHost.Visibility == Visibility.Visible;

    internal void EnterTour()
    {
        if (InTour) return;
        if (bounds is not null) bounds.Suspended = true;
        var presenter = AppWindow.Presenter as OverlappedPresenter;
        wasMaximized = presenter?.State == OverlappedPresenterState.Maximized;
        if (wasMaximized) presenter!.Restore();
        workspaceFrame = new(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
        WorkspaceChrome.Opacity = 0;
        WorkspaceChrome.IsHitTestVisible = false;
        RootFrame.IsEnabled = false;
        TourHost.Visibility = Visibility.Visible;
        SetTitleBar(TourTitleBar);
        ApplyCaptionTheme();
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96d;
        var width = Math.Min((int)Math.Round(568 * scale), work.Width);
        var height = Math.Min((int)Math.Round(552 * scale), work.Height);
        AppWindow.MoveAndResize(new(
            Math.Clamp(workspaceFrame.X + (workspaceFrame.Width - width) / 2, work.X, work.X + work.Width - width),
            Math.Clamp(workspaceFrame.Y + (workspaceFrame.Height - height) / 2, work.Y, work.Y + work.Height - height),
            width, height));
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern uint GetDpiForWindow(IntPtr hwnd);

    internal void ShowTourControl(UserControl tour)
    {
        WorkspaceChrome.Visibility = Visibility.Collapsed;
        TourContent.Child = tour;
    }

    // Render the real XAML surfaces at reduced resolution. Filtering before
    // enlargement keeps text and controls soft even when system acrylic is off.
    static async Task<WriteableBitmap?> SoftSnapshotAsync(FrameworkElement content)
    {
        int width = Math.Max(2, (int)Math.Ceiling(content.ActualWidth / 6));
        int height = Math.Max(2, (int)Math.Ceiling(content.ActualHeight / 6));
        var snapshot = new RenderTargetBitmap();
        try
        {
            await snapshot.RenderAsync(content, width, height);
            width = snapshot.PixelWidth;
            height = snapshot.PixelHeight;
            if (width == 0 || height == 0) return null;
            var pixels = (await snapshot.GetPixelsAsync()).ToArray();
            var filtered = new byte[pixels.Length];
            int[] kernel = [1, 4, 6, 4, 1];
            for (int pass = 0; pass < 2; pass++)
            {
                for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++)
                for (int c = 0; c < 4; c++)
                {
                    int sum = 0;
                    for (int k = -2; k <= 2; k++)
                    {
                        int sx = pass == 0 ? Math.Clamp(x + k, 0, width - 1) : x;
                        int sy = pass == 1 ? Math.Clamp(y + k, 0, height - 1) : y;
                        sum += pixels[(sy * width + sx) * 4 + c] * kernel[k + 2];
                    }
                    filtered[(y * width + x) * 4 + c] = (byte)(sum / 16);
                }
                (filtered, pixels) = (pixels, filtered);
            }
            var result = new WriteableBitmap(width, height);
            using var stream = result.PixelBuffer.AsStream();
            stream.Write(pixels);
            result.Invalidate();
            return result;
        }
        catch (System.Runtime.InteropServices.COMException) { return null; }
    }

    internal async Task RevealWorkspaceAsync()
    {
        var start = new RectInt32(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
        var target = wasMaximized ? DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea : workspaceFrame;
        TourHost.IsHitTestVisible = false;
        WorkspaceChrome.Visibility = Visibility.Visible;
        SetTitleBar(AppTitleBar);
        WorkspaceChrome.Opacity = 1;
        if (new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
        {
            double scale = WorkspaceChrome.XamlRoot.RasterizationScale;
            WorkspaceChrome.Width = target.Width / scale;
            WorkspaceChrome.Height = target.Height / scale;
            WorkspaceChrome.UpdateLayout();
            var surfaces = await Task.WhenAll(SoftSnapshotAsync(TourContent), SoftSnapshotAsync(WorkspaceChrome));
            if (closed) return;
            TourSoft.Source = surfaces[0];
            WorkspaceSoft.Source = surfaces[1];
            TourSoft.Opacity = 0;
            WorkspaceSoft.Opacity = 1;
            WorkspaceSoft.Visibility = TourSoft.Visibility = Visibility.Visible;
            var clock = Stopwatch.StartNew();
            while (!closed)
            {
                double t = Math.Min(1, clock.Elapsed.TotalMilliseconds / 720);
                double eased = t * t * (3 - 2 * t);
                int Blend(int a, int b) => (int)Math.Round(a + (b - a) * eased);
                AppWindow.MoveAndResize(new(Blend(start.X, target.X), Blend(start.Y, target.Y),
                    Blend(start.Width, target.Width), Blend(start.Height, target.Height)));
                TourSoft.Opacity = Math.Clamp(t / .35, 0, 1);
                TourHost.Opacity = 1 - Math.Clamp((t - .18) / .52, 0, 1);
                WorkspaceSoft.Opacity = 1 - Math.Clamp((t - .48) / .52, 0, 1);
                if (t >= 1) break;
                await Task.Delay(15);
            }
        }
        if (closed) return;
        AppWindow.MoveAndResize(workspaceFrame);
        if (wasMaximized && AppWindow.Presenter is OverlappedPresenter presenter) presenter.Maximize();
        TourHost.Visibility = TourSoft.Visibility = WorkspaceSoft.Visibility = Visibility.Collapsed;
        WorkspaceChrome.ClearValue(FrameworkElement.WidthProperty);
        WorkspaceChrome.ClearValue(FrameworkElement.HeightProperty);
        TourSoft.Source = WorkspaceSoft.Source = null;
        TourContent.Child = null;
        ApplyCaptionTheme();
        TourHost.Opacity = 1;
        TourHost.IsHitTestVisible = WorkspaceChrome.IsHitTestVisible = RootFrame.IsEnabled = true;
        if (bounds is not null) bounds.Suspended = false;
    }
}
