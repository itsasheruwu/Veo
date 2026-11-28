using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Services;

public enum WorkspaceSurface { Canvas, Sidebar, Utility, Composer, Notice, Minimap }

public static class WorkspaceAppearance
{
    public static void ApplyRegion(Grid host, string material, WorkspaceSurface surface)
    {
        var accessibility = new AccessibilitySettings(); var ui = new UISettings();
        var solid = SurfaceColor(surface, host.ActualTheme == ElementTheme.Dark);
        var backdrop = host.Children.FirstOrDefault() as SystemBackdropElement;
        if (accessibility.HighContrast || !ui.AdvancedEffectsEnabled || material is not ("Mica" or "Acrylic"))
        {
            if (backdrop is not null) { backdrop.SystemBackdrop = null; host.Children.Remove(backdrop); }
            var fallback = accessibility.HighContrast ? ui.UIElementColor(UIElementType.Background)
                : OpaqueMaterial(solid, material, host.ActualTheme == ElementTheme.Dark);
            if (host.Background is not SolidColorBrush current || current.Color != fallback)
                host.Background = new SolidColorBrush(fallback);
            return;
        }
        if (backdrop is null)
        {
            backdrop = new SystemBackdropElement { IsHitTestVisible = false, CornerRadius = host.CornerRadius };
            AutomationProperties.SetAccessibilityView(backdrop, AccessibilityView.Raw);
            Grid.SetColumnSpan(backdrop, Math.Max(1, host.ColumnDefinitions.Count));
            Grid.SetRowSpan(backdrop, Math.Max(1, host.RowDefinitions.Count));
            host.Children.Insert(0, backdrop);
        }
        host.Background = null;
        if (material == "Mica" && backdrop.SystemBackdrop is not MicaBackdrop)
            backdrop.SystemBackdrop = new MicaBackdrop();
        else if (material == "Acrylic" && backdrop.SystemBackdrop is not DesktopAcrylicBackdrop)
            backdrop.SystemBackdrop = new DesktopAcrylicBackdrop();
    }
    // Preserve the surface hierarchy when Windows disables backdrop effects.
    static Color OpaqueMaterial(Color solid, string material, bool dark)
    {
        var amount = material switch { "Mica" => .26, "Acrylic" => .45, _ => 0 };
        var tint = dark ? Color.FromArgb(255, 67, 72, 81) : Color.FromArgb(255, 201, 211, 224);
        byte Mix(byte channel, byte tintChannel) => (byte)Math.Round(channel + (tintChannel - channel) * amount);
        return Color.FromArgb(255, Mix(solid.R, tint.R), Mix(solid.G, tint.G), Mix(solid.B, tint.B));
    }

    static Color SurfaceColor(WorkspaceSurface surface, bool dark)
    {
        return (surface, dark) switch
        {
            (WorkspaceSurface.Canvas, true) => Color.FromArgb(255, 20, 20, 21),
            (WorkspaceSurface.Canvas, false) => Color.FromArgb(255, 246, 247, 248),
            (WorkspaceSurface.Sidebar or WorkspaceSurface.Utility, true) => Color.FromArgb(255, 25, 26, 27),
            (WorkspaceSurface.Sidebar or WorkspaceSurface.Utility, false) => Color.FromArgb(255, 236, 237, 239),
            (WorkspaceSurface.Composer, true) => Color.FromArgb(255, 47, 48, 49),
            (WorkspaceSurface.Composer, false) => Color.FromArgb(255, 255, 255, 255),
            (_, true) => Color.FromArgb(255, 33, 34, 36),
            _ => Color.FromArgb(255, 250, 250, 250)
        };
    }

    public static Brush FlyoutBrush(FrameworkElement element)
    {
        var ui = new UISettings();
        if (new AccessibilitySettings().HighContrast) return new SolidColorBrush(ui.UIElementColor(UIElementType.Background));
        var color = SurfaceColor(WorkspaceSurface.Composer, element.ActualTheme == ElementTheme.Dark);
        return ui.AdvancedEffectsEnabled ? new AcrylicBrush { TintColor = color, TintOpacity = .72, FallbackColor = color } : new SolidColorBrush(color);
    }

    public static void ApplyAccent(FrameworkElement element, string value)
    {
        if (new AccessibilitySettings().HighContrast) return;
        if (value.Length != 7 || value[0] != '#' || !uint.TryParse(value[1..], System.Globalization.NumberStyles.HexNumber, null, out var hex)) return;
        var color = Color.FromArgb(255, (byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);
        element.Resources["SystemAccentColor"] = color; element.Resources["AccentFillColorDefaultBrush"] = new SolidColorBrush(color);
        element.Resources["ListViewItemBackgroundSelected"] = new SolidColorBrush(Color.FromArgb(56, color.R, color.G, color.B));
        element.Resources["ListViewItemBackgroundSelectedPointerOver"] = new SolidColorBrush(Color.FromArgb(76, color.R, color.G, color.B));
    }
}
