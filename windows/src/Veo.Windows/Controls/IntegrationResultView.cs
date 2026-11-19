using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Veo.Core;
using Veo.Protocol;
using Windows.Storage.Streams;

namespace Veo_Windows.Controls;

/// <summary>Result artifacts stay local; unrecognized content is visible and can be exported explicitly.</summary>
public sealed class IntegrationResultView : StackPanel
{
    readonly InfoBar notice = new() { IsClosable = true, Severity = InfoBarSeverity.Error };
    public IntegrationResultView(IntegrationToolResult result)
    {
        Spacing = 8;
        if (result.IsError) Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Title = "The integration reported an error" });
        foreach (var content in result.Content) AddContent(content);
        if (result.Structured is { } structured)
        {
            var tree = new TreeView { SelectionMode = TreeViewSelectionMode.None, MaxHeight = 360 }; var remaining = 1000; tree.RootNodes.Add(Node("Result", structured, 0, ref remaining));
            Children.Add(new Expander { Header = "Structured result", Content = tree, HorizontalAlignment = HorizontalAlignment.Stretch });
        }
        if (result.Content.Length == 0 && result.Structured is null) Children.Add(Text("The integration returned no displayable content.")); Children.Add(notice);
    }
    public IntegrationResultView(IntegrationResourceContent content)
    {
        Spacing = 8; Children.Add(Text(content.Uri));
        if (content.Text is not null) Children.Add(Text(content.Text));
        if (content.Data is { } data) AddBytes(data, content.MimeType, "Resource");
        Children.Add(notice);
    }
    void AddContent(JsonElement content)
    {
        switch (content.Str("type"))
        {
            case "text": Children.Add(Text(content.Str("text") ?? "")); break;
            case "image": case "audio":
                if (content.Str("data") is { } encoded) { try { AddBytes(Convert.FromBase64String(encoded), content.Str("mimeType"), content.Str("type") == "image" ? "Image" : "Audio"); } catch (FormatException) { Children.Add(Text("The integration returned invalid encoded media.")); } }
                break;
            case "resource":
                if (content.TryObjectProperty("resource", out var resource))
                {
                    Children.Add(Text(resource.Str("uri") ?? "Embedded resource")); if (resource.Str("text") is { } text) Children.Add(Text(text));
                    if (resource.Str("blob") is { } blob) { try { AddBytes(Convert.FromBase64String(blob), resource.Str("mimeType"), "Resource"); } catch (FormatException) { Children.Add(Text("The resource contains invalid encoded data.")); } }
                }
                break;
            case "resource_link": Children.Add(Text((content.Str("title") ?? content.Str("name") ?? "Resource") + "\n" + content.Str("uri") + "\n" + content.Str("description"))); break;
            default: Children.Add(Text("This integration returned content that has no native renderer (" + (content.Str("type") ?? "unknown") + ").")); break;
        }
    }
    void AddBytes(byte[] data, string? mime, string name)
    {
        Children.Add(Text($"{name} · {mime ?? "application/octet-stream"} · {data.Length:N0} bytes"));
        if (mime is "image/png" or "image/jpeg" or "image/gif" or "image/webp")
        {
            var image = new Image { MaxHeight = 320, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform }; Children.Add(image);
            image.Loaded += (_, _) => Run(async () => { using var stream = new InMemoryRandomAccessStream(); using (var writer = new DataWriter(stream)) { writer.WriteBytes(data); await writer.StoreAsync(); writer.DetachStream(); } stream.Seek(0); var bitmap = new BitmapImage(); await bitmap.SetSourceAsync(stream); image.Source = bitmap; });
        }
        var export = new Button { Content = "Save " + name.ToLowerInvariant() + "…" }; export.Click += (_, _) => Run(async () =>
        {
            var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = name };
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Main!));
            var extension = mime switch { "image/png" => ".png", "image/jpeg" => ".jpg", "image/gif" => ".gif", "image/webp" => ".webp", "audio/wav" => ".wav", "audio/mpeg" => ".mp3", "application/pdf" => ".pdf", _ => ".bin" };
            picker.FileTypeChoices.Add(name, new[] { extension }); if (await picker.PickSaveFileAsync() is { } file) await Windows.Storage.FileIO.WriteBytesAsync(file, data);
        }); Children.Add(export);
    }
    static TreeViewNode Node(string label, JsonElement value, int depth, ref int remaining)
    {
        if (--remaining < 0 || depth > 12) return new() { Content = label + ": … (display limit)" };
        if (value.ValueKind == JsonValueKind.Object)
        {
            var node = new TreeViewNode { Content = label }; foreach (var property in value.EnumerateObject()) { if (remaining <= 0) { node.Children.Add(new() { Content = "More values omitted from display" }); break; } node.Children.Add(Node(property.Name, property.Value, depth + 1, ref remaining)); } return node;
        }
        if (value.ValueKind == JsonValueKind.Array)
        {
            var node = new TreeViewNode { Content = label + $" ({value.GetArrayLength()})" }; var index = 0; foreach (var item in value.EnumerateArray()) { if (remaining <= 0) { node.Children.Add(new() { Content = "More values omitted from display" }); break; } node.Children.Add(Node((index++).ToString(), item, depth + 1, ref remaining)); } return node;
        }
        var text = value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : value.ToString(); return new() { Content = label + ": " + (text.Length > 8000 ? text[..8000] + "…" : text) };
    }
    static TextBlock Text(string value) => new() { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, MaxHeight = 500 };
    async void Run(Func<Task> action) { try { await action(); } catch (Exception exception) { notice.Message = DiagnosticRedactor.Redact(exception.Message); notice.IsOpen = true; } }
}
