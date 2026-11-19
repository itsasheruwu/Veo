using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Veo.Platform.Windows.Audio;

public sealed record AudioDevice(string Id, string Name, bool IsInput);
public sealed record AudioFormat(int SampleRate = 24000, int BitsPerSample = 16, int Channels = 1)
{
    internal WaveFormat ToWaveFormat()
    {
        if (SampleRate is < 8000 or > 192000 || BitsPerSample is not (16 or 24 or 32) || Channels is < 1 or > 8) throw new ArgumentOutOfRangeException(nameof(SampleRate), "Unsupported PCM audio format.");
        return new WaveFormat(SampleRate, BitsPerSample, Channels);
    }
}
public sealed record CapturedAudio(ReadOnlyMemory<byte> Bytes, AudioFormat Format);

/// <summary>Explicitly started WASAPI capture/playback with a bounded, two-second output buffer.</summary>
public sealed class WasapiAudioService : IAsyncDisposable
{
    private readonly object gate = new();
    private WasapiCapture? capture;
    private WasapiOut? playback;
    private MMDevice? captureDevice, playbackDevice;
    private BufferedWaveProvider? playbackBuffer;
    private TaskCompletionSource? captureStopped;
    private long captureGeneration;
    private bool disposed;
    public event Action<CapturedAudio>? AudioCaptured;
    public event Action<Exception>? Faulted;
    public bool IsCapturing { get { lock (gate) return capture?.CaptureState == CaptureState.Capturing; } }

    public static IReadOnlyList<AudioDevice> EnumerateDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        var result = new List<AudioDevice>();
        foreach (var flow in new[] { DataFlow.Capture, DataFlow.Render })
            foreach (var device in enumerator.EnumerateAudioEndPoints(flow, DeviceState.Active))
                using (device) result.Add(new(device.ID, device.FriendlyName, flow == DataFlow.Capture));
        return result;
    }

    public void StartCapture(AudioFormat format, string? deviceId = null)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (capture is not null) throw new InvalidOperationException("Microphone capture is already active.");
            using var enumerator = new MMDeviceEnumerator();
            captureDevice = deviceId is null ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications) : enumerator.GetDevice(deviceId);
            WasapiCapture? candidate = null;
            try
            {
                candidate = new WasapiCapture(captureDevice, true, 50) { WaveFormat = format.ToWaveFormat() };
                var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                captureStopped = stopped;
                var generation = ++captureGeneration;
                candidate.DataAvailable += (_, e) =>
                {
                    if (e.BytesRecorded != 0 && Volatile.Read(ref captureGeneration) == generation) AudioCaptured?.Invoke(new(e.Buffer.AsMemory(0, e.BytesRecorded).ToArray(), format));
                };
                candidate.RecordingStopped += (_, e) =>
                {
                    stopped.TrySetResult();
                    if (e.Exception is not null) Faulted?.Invoke(e.Exception);
                };
                capture = candidate;
                candidate.StartRecording();
            }
            catch
            {
                candidate?.Dispose(); capture = null;
                captureDevice.Dispose(); captureDevice = null;
                captureStopped?.TrySetResult();
                throw;
            }
        }
    }

    public async Task StopCaptureAsync()
    {
        WasapiCapture? oldCapture;
        MMDevice? oldDevice;
        Task? stopped;
        lock (gate)
        {
            oldCapture = capture; capture = null;
            captureGeneration++;
            oldDevice = captureDevice; captureDevice = null;
            stopped = captureStopped?.Task;
            if (oldCapture is not null) oldCapture.StopRecording();
        }
        if (oldCapture is null) return;
        try { if (stopped is not null) await stopped.ConfigureAwait(false); }
        finally { oldCapture.Dispose(); oldDevice?.Dispose(); }
    }

    public void StartPlayback(AudioFormat format, string? deviceId = null)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (playback is not null) throw new InvalidOperationException("Audio playback is already active.");
            using var enumerator = new MMDeviceEnumerator();
            playbackDevice = deviceId is null ? enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Communications) : enumerator.GetDevice(deviceId);
            try
            {
                playbackBuffer = new BufferedWaveProvider(format.ToWaveFormat()) { BufferDuration = TimeSpan.FromSeconds(2), DiscardOnBufferOverflow = false, ReadFully = true };
                playback = new WasapiOut(playbackDevice, AudioClientShareMode.Shared, true, 50);
                playback.PlaybackStopped += (_, e) => { if (e.Exception is not null) Faulted?.Invoke(e.Exception); };
                playback.Init(playbackBuffer);
                playback.Play();
            }
            catch { playback?.Dispose(); playback = null; playbackBuffer = null; playbackDevice.Dispose(); playbackDevice = null; throw; }
        }
    }

    public bool TryAppendPlayback(ReadOnlySpan<byte> bytes)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (playbackBuffer is null) throw new InvalidOperationException("Audio playback has not started.");
            if (bytes.Length > playbackBuffer.BufferLength - playbackBuffer.BufferedBytes) return false;
            var copy = bytes.ToArray();
            playbackBuffer.AddSamples(copy, 0, copy.Length);
            return true;
        }
    }

    public void StopPlayback()
    {
        lock (gate)
        {
            playback?.Stop(); playback?.Dispose(); playback = null;
            playbackBuffer?.ClearBuffer(); playbackBuffer = null;
            playbackDevice?.Dispose(); playbackDevice = null;
        }
    }

    public async ValueTask DisposeAsync()
    {
        lock (gate) { if (disposed) return; disposed = true; }
        await StopCaptureAsync().ConfigureAwait(false);
        StopPlayback();
    }
}
