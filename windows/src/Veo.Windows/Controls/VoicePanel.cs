using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Platform.Windows.Audio;

namespace Veo_Windows.Controls;

public sealed class WindowsVoiceAudio : IVoiceAudio
{
    readonly WasapiAudioService audio = new();
    readonly SemaphoreSlim operations = new(1, 1);
    CancellationTokenSource? sessionLifetime;
    string? outputDevice;
    (int Rate, int Channels)? playbackFormat;
    public event Action<ReadOnlyMemory<byte>>? Captured;
    public event Action<Exception>? Faulted;
    public WindowsVoiceAudio()
    {
        audio.AudioCaptured += chunk =>
        {
            if (chunk.Format is not { SampleRate: 24000, BitsPerSample: 16, Channels: 1 }) { Faulted?.Invoke(new InvalidDataException("The microphone did not supply negotiated PCM16 mono audio.")); return; }
            Captured?.Invoke(chunk.Bytes);
        };
        audio.Faulted += error => Faulted?.Invoke(error);
    }
    public async Task StartAsync(string? input, string? output, CancellationToken token)
    {
        await operations.WaitAsync(token);
        try
        {
            token.ThrowIfCancellationRequested(); outputDevice = output;
            sessionLifetime?.Dispose(); sessionLifetime = CancellationTokenSource.CreateLinkedTokenSource(token);
            // NAudio 2.2.1 shared-mode WASAPI enables AutoConvertPcm and
            // SrcDefaultQuality for capture and playback. The Windows audio
            // engine converts the device mix format to this explicit format.
            await Task.Run(() => { token.ThrowIfCancellationRequested(); audio.StartCapture(new(24000, 16, 1), input); }, token);
            token.ThrowIfCancellationRequested();
        }
        catch { await audio.StopCaptureAsync(); audio.StopPlayback(); throw; }
        finally { operations.Release(); }
    }
    public async Task PlayAsync(ReadOnlyMemory<byte> bytes, int sampleRate, int channels, CancellationToken token)
    {
        using var playbackLifetime = CancellationTokenSource.CreateLinkedTokenSource(token, sessionLifetime?.Token ?? token);
        token = playbackLifetime.Token;
        await operations.WaitAsync(token);
        try
        {
        if (playbackFormat != (sampleRate, channels))
        { audio.StopPlayback(); audio.StartPlayback(new(sampleRate, 16, channels), outputDevice); playbackFormat = (sampleRate, channels); }
        foreach (var chunk in Pcm16Packets.Split(bytes, channels))
        {
            token.ThrowIfCancellationRequested();
            var deadline = DateTimeOffset.UtcNow.AddSeconds(3);
            while (!audio.TryAppendPlayback(chunk.Span))
            { if (DateTimeOffset.UtcNow > deadline) throw new IOException("The selected speaker is not draining its playback buffer."); await Task.Delay(10, token); }
        }
        }
        finally { operations.Release(); }
    }
    public async Task StopAsync()
    {
        sessionLifetime?.Cancel();
        await operations.WaitAsync();
        try { try { await audio.StopCaptureAsync(); } finally { audio.StopPlayback(); playbackFormat = null; } }
        finally { operations.Release(); }
    }
    public async ValueTask DisposeAsync() { await StopAsync(); await audio.DisposeAsync(); sessionLifetime?.Dispose(); sessionLifetime = null; }
}

public sealed class VoicePanel : Grid, IDisposable, IAsyncDisposable
{
    readonly RealtimeVoiceCoordinator voice;
    readonly Func<ThreadSession?> session;
    readonly Func<ComposerSnapshot> settings;
    readonly Func<ThreadSession, Task>? beforeStart;
    readonly TextBlock state = new() { TextWrapping = TextWrapping.Wrap };
    readonly TextBox transcript = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 120, MaxHeight = 260 };
    readonly ComboBox protocols = new() { Header = "Voice history", ItemsSource = new[] { "Automatic", "Timeline v3", "Legacy v2" }, HorizontalAlignment = HorizontalAlignment.Stretch };
    readonly ComboBox voices = new() { Header = "Voice", HorizontalAlignment = HorizontalAlignment.Stretch };
    readonly ComboBox modality = new() { Header = "Output", ItemsSource = new[] { "audio", "text" }, HorizontalAlignment = HorizontalAlignment.Stretch };
    readonly ComboBox inputs = new() { Header = "Microphone", DisplayMemberPath = "Name", HorizontalAlignment = HorizontalAlignment.Stretch };
    readonly ComboBox outputs = new() { Header = "Speaker / headphones", DisplayMemberPath = "Name", HorizontalAlignment = HorizontalAlignment.Stretch };
    bool disposed;
    public VoicePanel(RealtimeVoiceCoordinator voice, Func<ThreadSession?> session, Func<ComposerSnapshot> settings, Func<ThreadSession, Task>? beforeStart = null)
    {
        this.voice = voice; this.session = session; this.settings = settings; this.beforeStart = beforeStart;
        var body = new StackPanel { Spacing = 12 }; Children.Add(body); MinWidth = 440;
        body.Children.Add(new TextBlock { Text = "Microphone capture starts only when you press Start. Voice uses the selected chat's local Codex runtime.", TextWrapping = TextWrapping.Wrap });
        inputs.PlaceholderText = "System default"; outputs.PlaceholderText = "System default";
        foreach (var control in new FrameworkElement[] { protocols, voices, modality, inputs, outputs }) body.Children.Add(control);
        var devices = WasapiAudioService.EnumerateDevices();
        inputs.ItemsSource = devices.Where(x => x.IsInput).ToArray(); outputs.ItemsSource = devices.Where(x => !x.IsInput).ToArray();
        inputs.SelectedItem = devices.FirstOrDefault(x => x.Id == voice.Preferences.InputDevice); outputs.SelectedItem = devices.FirstOrDefault(x => x.Id == voice.Preferences.OutputDevice);
        protocols.SelectedItem = voice.Preferences.Protocol; modality.SelectedItem = voice.Preferences.Output;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var start = new Button { Content = "Start voice" }; start.Click += async (_, _) => await Run(async () =>
        {
            var selected = session() ?? throw new InvalidOperationException("Select a chat first.");
            if (this.beforeStart is not null) await this.beforeStart(selected);
            await SaveAsync(); await voice.StartAsync(selected, settings());
        });
        var stop = new Button { Content = "Stop voice" }; stop.Click += async (_, _) => await Run(voice.StopAsync);
        buttons.Children.Add(start); buttons.Children.Add(stop); body.Children.Add(buttons); body.Children.Add(state); body.Children.Add(transcript);
        protocols.SelectionChanged += async (_, _) => await Run(RefreshVoicesAsync);
        voice.Changed += VoiceChanged;
        Unloaded += (_, _) => Dispose();
        Loaded += async (_, _) => await Run(RefreshVoicesAsync);
        Refresh();
    }
    async Task RefreshVoicesAsync()
    {
        var previous = voices.SelectedItem as string ?? voice.Preferences.Voice;
        await SaveAsync(); var options = await voice.VoicesAsync(); voices.ItemsSource = options;
        voices.SelectedItem = options.Contains(previous) ? previous : options.FirstOrDefault();
    }
    Task SaveAsync() => voice.SavePreferencesAsync(new(protocols.SelectedItem as string ?? "Automatic", modality.SelectedItem as string ?? "audio", voices.SelectedItem as string ?? voice.Preferences.Voice, (inputs.SelectedItem as AudioDevice)?.Id, (outputs.SelectedItem as AudioDevice)?.Id));
    void VoiceChanged() => DispatcherQueue.TryEnqueue(Refresh);
    void Refresh() { state.Text = voice.Error is { } error ? voice.State + " · " + error : voice.State; transcript.Text = voice.Transcript; }
    async Task Run(Func<Task> action) { try { await action(); } catch (Exception e) { state.Text = Veo.Protocol.DiagnosticRedactor.Redact(e.Message); } }
    public void Dispose() { if (disposed) return; disposed = true; voice.Changed -= VoiceChanged; _ = StopOnCloseAsync(); }
    async Task StopOnCloseAsync() { try { await voice.StopAsync(); } catch (Exception error) { DispatcherQueue.TryEnqueue(() => state.Text = Veo.Protocol.DiagnosticRedactor.Redact(error.Message)); } }
    public async ValueTask DisposeAsync() { disposed = true; voice.Changed -= VoiceChanged; await voice.StopAsync(); }
}
