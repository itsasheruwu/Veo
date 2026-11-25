using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.UI;

namespace Veo_Windows.Controls;

// Keep frame updates out of XAML measure and arrange. Size changes are the only
// point where the raster surface and its backing buffer need to be replaced.
internal sealed class DictationParticles(Canvas host) : IDisposable
{
    readonly Image image = new() { Stretch = Stretch.Fill, IsHitTestVisible = false };
    WriteableBitmap? bitmap;
    Stream? stream;
    byte[] pixels = [];
    double scale;
    Color ink;

    public void Draw(double width, double height, double time, double level, double decay,
        double progress, IReadOnlyList<Point> targets, Color color)
    {
        if (width < 8 || height < 8) return;
        Resize(width, height);
        Array.Clear(pixels);
        ink = color;
        var center = width * 0.51;
        var span = width * 0.80;
        var bottom = height - 4;
        const double pitch = 4.8;
        var columns = Math.Clamp((int)(span / pitch), 2, 240);
        for (var column = 0; column < columns; column++)
        {
            var fraction = (double)column / (columns - 1);
            var x = center + (fraction - 0.5) * span;
            var envelope = Math.Exp(-Math.Pow((fraction - 0.5 - Math.Sin(time * 4) * 0.036) / 0.19, 2));
            var ripple = 0.72 + 0.18 * Math.Sin(fraction * 37 - time * 9) + 0.11 * Math.Cos(fraction * 91 + time * 11);
            var amplitude = (2.5 + (4 + 58 * level) * envelope * ripple) * decay;
            for (var row = 0; row < Math.Ceiling(amplitude / pitch); row++)
            {
                var seed = column * 31 + row * 79;
                var sparkle = 0.5 + Math.Sin(seed * 1.773 + time * 3.4) * 0.5;
                var coverage = Math.Clamp((amplitude - row * pitch) / pitch, 0, 1);
                var radius = (0.46 + 1.48 * Math.Pow(sparkle, 4)) * Math.Sqrt(coverage);
                var y = bottom - row * pitch;
                if (Math.Sin(seed * 6.71) > 0.28)
                {
                    Dot(x, y, radius * 2.10, 0.09 * decay);
                    Dot(x, y, radius, 0.86 * decay);
                }
                else Dot(x, y, radius * 0.68, 0.30 * decay);
            }
        }

        for (var index = 0; index < targets.Count; index++)
        {
            var delay = (double)index / targets.Count * 0.26;
            var phase = (progress - delay) / 0.54;
            if (phase is < 0 or >= 1.23) continue;
            var end = targets[index];
            var start = new Point(center + Math.Sin(index * 2.12) * span * 0.11,
                bottom - 13 - level * 33 - Math.Cos(index) * 8);
            var point = Flight(start, end, Math.Min(1, phase), index);
            if (phase < 1.05)
            {
                for (var step = 1; step < 5; step++)
                {
                    var trail = Flight(start, end, Math.Clamp(phase - step * 0.029, 0, 1), index);
                    Dot(trail.X, trail.Y, 0.53, 0.24 - step * 0.039);
                }
            }
            var radius = 0.66 + 0.45 * (Math.Sin(index * 3.7) * 0.5 + 0.5);
            Dot(point.X, point.Y, radius * 2, 0.12);
            Dot(point.X, point.Y, radius, 0.87);
        }
        stream!.Position = 0;
        stream.Write(pixels);
        bitmap!.Invalidate();
    }

    static Point Flight(Point start, Point end, double p, int seed)
    {
        var q = 1 - p;
        var first = new Point(start.X + Math.Sin(seed) * 13, start.Y + (end.Y - start.Y) * 0.72);
        var second = new Point(end.X + (start.X - end.X) * 0.30, end.Y - 4 + Math.Cos(seed) * 6);
        return new Point(q * q * q * start.X + 3 * q * q * p * first.X + 3 * q * p * p * second.X + p * p * p * end.X,
            q * q * q * start.Y + 3 * q * q * p * first.Y + 3 * q * p * p * second.Y + p * p * p * end.Y);
    }

    void Resize(double width, double height)
    {
        image.Width = width;
        image.Height = height;
        scale = Math.Clamp(host.XamlRoot?.RasterizationScale ?? 1, 1, 1.5);
        var w = (int)Math.Ceiling(width * scale);
        var h = (int)Math.Ceiling(height * scale);
        if (bitmap?.PixelWidth == w && bitmap?.PixelHeight == h) return;
        stream?.Dispose();
        bitmap = new WriteableBitmap(w, h);
        pixels = new byte[w * h * 4];
        stream = bitmap.PixelBuffer.AsStream();
        image.Source = bitmap;
        if (host.Children.Count == 0) host.Children.Add(image);
    }

    void Dot(double x, double y, double radius, double opacity)
    {
        if (radius <= 0 || opacity <= 0 || bitmap is null) return;
        x *= scale;
        y *= scale;
        radius *= scale;
        var minX = Math.Max(0, (int)Math.Floor(x - radius - 0.7));
        var maxX = Math.Min(bitmap.PixelWidth - 1, (int)Math.Ceiling(x + radius + 0.7));
        var minY = Math.Max(0, (int)Math.Floor(y - radius - 0.7));
        var maxY = Math.Min(bitmap.PixelHeight - 1, (int)Math.Ceiling(y + radius + 0.7));
        for (var py = minY; py <= maxY; py++)
        for (var px = minX; px <= maxX; px++)
        {
            var dx = px + 0.5 - x;
            var dy = py + 0.5 - y;
            var coverage = Math.Clamp(radius + 0.6 - Math.Sqrt(dx * dx + dy * dy), 0, 1);
            var alpha = (int)(ink.A * opacity * coverage);
            if (alpha == 0) continue;
            var offset = (py * bitmap.PixelWidth + px) * 4;
            var remainder = 255 - alpha;
            pixels[offset] = (byte)((ink.B * alpha + pixels[offset] * remainder) / 255);
            pixels[offset + 1] = (byte)((ink.G * alpha + pixels[offset + 1] * remainder) / 255);
            pixels[offset + 2] = (byte)((ink.R * alpha + pixels[offset + 2] * remainder) / 255);
            pixels[offset + 3] = (byte)(alpha + pixels[offset + 3] * remainder / 255);
        }
    }

    public void Dispose()
    {
        stream?.Dispose();
        stream = null;
        host.Children.Remove(image);
        image.Source = null;
        bitmap = null;
        pixels = [];
    }
}
