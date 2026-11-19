using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Services;

public enum WorkspaceSurface { Canvas, Sidebar, Utility, Composer, Notice }

public static class WorkspaceAppearance
{
    public static Brush Region(FrameworkElement element, string material, WorkspaceSurface surface)
    {
        var accessibility = new AccessibilitySettings(); var ui = new UISettings();
        if (accessibility.HighContrast) return new SolidColorBrush(ui.UIElementColor(UIElementType.Background));
        var dark = element.ActualTheme == ElementTheme.Dark;
        var solid = (surface, dark) switch
        {
            (WorkspaceSurface.Canvas, true) => Color.FromArgb(255, 20, 20, 21),
            (WorkspaceSurface.Canvas, false) => Color.FromArgb(255, 246, 247, 248),
            (WorkspaceSurface.Sidebar or WorkspaceSurface.Utility, true) => Color.FromArgb(255, 25, 26, 27),
            (WorkspaceSurface.Sidebar or WorkspaceSurface.Utility, false) => Color.FromArgb(255, 236, 237, 239),
            (WorkspaceSurface.Composer, true) => Color.FromArgb(255, 40, 40, 41),
            (WorkspaceSurface.Composer, false) => Color.FromArgb(255, 255, 255, 255),
            (_, true) => Color.FromArgb(255, 33, 34, 36),
            _ => Color.FromArgb(255, 250, 250, 250)
        };
        if (!ui.AdvancedEffectsEnabled || material == "Solid") return new SolidColorBrush(solid);
        // Mica is shared at window level; transparent regions reveal that backdrop.
        if (material == "Mica") return new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
        return new AcrylicBrush { TintColor = solid, TintOpacity = .72, FallbackColor = solid };
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
