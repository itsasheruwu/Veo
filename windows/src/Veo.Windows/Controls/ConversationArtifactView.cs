using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Veo.Core;
using Veo.Protocol;
using Windows.Storage.Streams;

namespace Veo_Windows.Controls;

/// <summary>Inline/local artifacts use bounded native decoders. Remote content is opened only by an explicit user action.</summary>
public sealed class ConversationArtifactView : StackPanel
{
    readonly ThreadSession session;
    readonly ConversationArtifact artifact;
    readonly ConversationArtifactAccess access = new(App.Workspace.DataRoot);
    readonly StackPanel preview = new() { Spacing = 6 };
    readonly InfoBar notice = new() { IsClosable = true };
    readonly Expander expander = new() { HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    ArtifactReadResult? loaded;
    Microsoft.UI.Xaml.Controls.MediaPlayerElement? player;
    InMemoryRandomAccessStream? mediaStream;
    bool busy;
    bool allowOutside;
    public ConversationArtifactView(ThreadSession session, ConversationArtifact artifact, bool? expanded = null)
    {
        this.session = session; this.artifact = artifact; Spacing = 6;
        AutomationProperties.SetName(this, artifact.Name); expander.Header = artifact.Name; expander.Content = preview;
        expander.IsExpanded = expanded ?? App.Workspace.Preferences.ViewedImages == "Expanded";
        preview.Children.Add(new TextBlock { Text = artifact.Kind.StartsWith("inline", StringComparison.Ordinal) || artifact.Kind.StartsWith("data", StringComparison.Ordinal) ? artifact.MimeType ?? "Inline media" : artifact.Source, TextWrapping = TextWrapping.Wrap, FontSize = 11, IsTextSelectionEnabled = true });
        preview.Children.Add(notice); Children.Add(expander);
        if (artifact.UnavailableReason is not null || artifact.Kind is "unknown" or "storedFile") { notice.Message = artifact.UnavailableReason ?? "This artifact has no supported native representation. Its identity remains in local history."; notice.Severity = InfoBarSeverity.Warning; notice.IsOpen = true; return; }
        if (artifact.Kind is "remoteImage" or "remoteAudio" || artifact.Kind == "resource" && IntegrationCoordinator.SecureUri(artifact.Source) is not null)
        {
            preview.Children.Add(new TextBlock { Text = "Remote content is not fetched automatically.", TextWrapping = TextWrapping.Wrap });
            var open = new Button { Content = "Open in Veo's browser", IsEnabled = IntegrationCoordinator.SecureUri(artifact.Source) is not null }; open.Click += async (_, _) => await Run(async () => { if (App.Main is { } main) await main.NavigateBrowserAsync(IntegrationCoordinator.SecureUri(artifact.Source)!); }); preview.Children.Add(open); return;
        }
        if (artifact.Kind == "resource") { var source = new Button { Content = "Preview local source" }; source.Click += async (_, _) => await Run(async () => { await new ContentDialog { Title = artifact.Name, Content = new ConversationSourceView(session, new(artifact.Id, artifact.Name, artifact.Source)), CloseButtonText = "Done", XamlRoot = XamlRoot }.ShowAsync(); }); preview.Children.Add(source); return; }
        expander.Expanding += (_, _) => _ = LoadAsync(); Loaded += (_, _) => { if (expander.IsExpanded) _ = LoadAsync(); };
        Unloaded += (_, _) => { player?.MediaPlayer?.Pause(); };
    }
    async Task LoadAsync()
    {
        if (busy || loaded is not null) return; busy = true;
        try
        {
            loaded = await access.ReadAsync(session, artifact, allowOutside);
            if (loaded.MimeType.StartsWith("image/", StringComparison.OrdinalIgnoreCase))
            {
                using var stream = await Stream(loaded.Bytes); var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
                if ((ulong)decoder.PixelWidth * decoder.PixelHeight > 32_000_000) throw new InvalidDataException("This image exceeds the 32 megapixel native preview limit."); stream.Seek(0);
                var bitmap = new BitmapImage { DecodePixelWidth = 1000 }; await bitmap.SetSourceAsync(stream);
                var image = new Image { Source = bitmap, MaxHeight = 320, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform }; AutomationProperties.SetName(image, artifact.Name); preview.Children.Add(image);
                var view = new Button { Content = "View image" }; view.Click += async (_, _) => await Run(async () => { using var fullStream = await Stream(loaded.Bytes); var fullBitmap = new BitmapImage(); await fullBitmap.SetSourceAsync(fullStream); await new ContentDialog { Title = artifact.Name, Content = new ScrollViewer { Content = new Image { Source = fullBitmap, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform, MaxHeight = 700, MaxWidth = 1000 }, ZoomMode = ZoomMode.Enabled, MinZoomFactor = .25f, MaxZoomFactor = 5 }, CloseButtonText = "Done", XamlRoot = XamlRoot }.ShowAsync(); }); preview.Children.Add(view);
            }
            else if (loaded.MimeType.StartsWith("audio/", StringComparison.OrdinalIgnoreCase))
            {
                mediaStream = await Stream(loaded.Bytes); player = new MediaPlayerElement { AreTransportControlsEnabled = true, AutoPlay = false, Height = 80 }; player.Source = Windows.Media.Core.MediaSource.CreateFromStream(mediaStream, loaded.MimeType); preview.Children.Add(player);
            }
            else if (loaded.MimeType.StartsWith("text/", StringComparison.OrdinalIgnoreCase) || loaded.MimeType is "application/json" or "application/xml") preview.Children.Add(new TextBox { Text = new System.Text.UTF8Encoding(false, true).GetString(loaded.Bytes), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 300 });
            else preview.Children.Add(new TextBlock { Text = "This binary resource can be saved. No native preview is available for " + loaded.MimeType + ".", TextWrapping = TextWrapping.Wrap });
            var save = new Button { Content = "Save artifact…" }; save.Click += async (_, _) => await Run(SaveAsync); preview.Children.Add(save); notice.IsOpen = false;
        }
        catch (UnauthorizedAccessException error)
        {
            loaded = null; notice.Message = DiagnosticRedactor.Redact(error.Message); notice.Severity = InfoBarSeverity.Warning; notice.IsOpen = true;
            if (!allowOutside) { var allow = new Button { Content = "Allow this preview outside the workspace" }; allow.Click += async (_, _) => { allowOutside = true; allow.IsEnabled = false; await LoadAsync(); }; preview.Children.Add(allow); }
        }
        catch (Exception error) { loaded = null; notice.Message = DiagnosticRedactor.Redact(error.Message); notice.Severity = InfoBarSeverity.Warning; notice.IsOpen = true; }
        finally { busy = false; }
    }
    async Task SaveAsync()
    {
        if (loaded is null) return; var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = Path.GetFileNameWithoutExtension(artifact.Name) };
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Main!));
        picker.FileTypeChoices.Add("Artifact", new[] { loaded.MimeType switch { "image/png" => ".png", "image/jpeg" => ".jpg", "image/webp" => ".webp", "image/gif" => ".gif", "audio/wav" => ".wav", "audio/mpeg" => ".mp3", "text/plain" => ".txt", _ => ".bin" } });
        if (await picker.PickSaveFileAsync() is { } file) await Windows.Storage.FileIO.WriteBytesAsync(file, loaded.Bytes);
    }
    static async Task<InMemoryRandomAccessStream> Stream(byte[] bytes) { var stream = new InMemoryRandomAccessStream(); using var writer = new DataWriter(stream); writer.WriteBytes(bytes); await writer.StoreAsync(); writer.DetachStream(); stream.Seek(0); return stream; }
    async Task Run(Func<Task> action) { try { await action(); } catch (Exception error) { notice.Message = DiagnosticRedactor.Redact(error.Message); notice.Severity = InfoBarSeverity.Warning; notice.IsOpen = true; } }
}

public sealed class ConversationSourceView : StackPanel
{
    readonly ThreadSession session;
    readonly ConversationSource source;
    readonly InfoBar notice = new() { IsClosable = true };
    readonly TextBox content = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 520, MinWidth = 360, FontFamily = new("Cascadia Mono"), FontSize = 12 };
    public ConversationSourceView(ThreadSession session, ConversationSource source)
    {
        this.session = session; this.source = source; Spacing = 8;
        Children.Add(new TextBlock { Text = source.Target + (source.StartLine is { } start ? $" · line {start}" : "") + (source.Note is null ? "" : "\n" + source.Note), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }); Children.Add(notice); Children.Add(content);
        var load = new Button { Content = "Read source" }; load.Click += async (_, _) => await ReadAsync(false); Children.Add(load);
        var outside = new Button { Content = "Read this source outside the workspace" }; outside.Click += async (_, _) => await ReadAsync(true); Children.Add(outside);
        Loaded += async (_, _) => await ReadAsync(false);
    }
    async Task ReadAsync(bool outside)
    {
        try
        {
            var result = await new ConversationArtifactAccess(App.Workspace.DataRoot).ReadAsync(session, new(source.Id, "localText", source.Target, source.Label, "text/plain"), outside); content.Text = new System.Text.UTF8Encoding(false, true).GetString(result.Bytes);
            if (source.StartLine is { } start) { var lines = content.Text.Split('\n'); var offset = lines.Take(Math.Clamp(start - 1, 0, lines.Length)).Sum(x => x.Length + 1); content.Select(Math.Min(offset, content.Text.Length), 0); }
            notice.IsOpen = false;
        }
        catch (Exception error) { notice.Message = DiagnosticRedactor.Redact(error.Message); notice.Severity = InfoBarSeverity.Warning; notice.IsOpen = true; }
    }
}
