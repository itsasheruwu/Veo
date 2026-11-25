using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Speech.Recognition;
using NAudio.Wave;
using Veo.Platform.Windows.Audio;

namespace Veo_Windows.Services;

internal sealed class ComposerDictation(bool whisper, bool live, string language, string executable, string model, bool openAI) : IAsyncDisposable
{
    readonly CancellationTokenSource lifetime = new();
    readonly object gate = new();
    readonly List<string> phrases = [];
    readonly TaskCompletionSource<string> recognized = new(TaskCreationOptions.RunContinuationsAsynchronously);
    SpeechRecognitionEngine? recognizer;
    WasapiAudioService? microphone;
    WaveFileWriter? recording;
    string? folder;
    double level;
    Exception? captureError;
    string? openAIKey;
    const int Rate = 16000;

    public bool IsBatch { get; } = whisper || !live;
    public double Level => Volatile.Read(ref level);
    public event Action<string>? Partial;
    public event Action<Exception>? Faulted;
    public event Action<string>? Ended;

    public void Start()
    {
        if (whisper || openAI)
        {
            if (openAI)
                openAIKey = OpenAIDictation.ReadKey() ?? throw new InvalidOperationException("Save an OpenAI API key in Voice settings to use OpenAI dictation.");
            if (whisper && (!Path.IsPathFullyQualified(executable) || !File.Exists(executable) ||
                !Path.IsPathFullyQualified(model) || !File.Exists(model)))
                throw new InvalidOperationException("Choose the whisper-cli executable and model file in Voice settings.");
            folder = Directory.CreateTempSubdirectory("VeoDictation-").FullName;
            recording = new WaveFileWriter(Path.Combine(folder, "speech.wav"), new WaveFormat(Rate, 16, 1));
            microphone = new WasapiAudioService();
            microphone.AudioCaptured += Capture;
            microphone.Faulted += CaptureFailed;
            microphone.StartCapture(new AudioFormat(Rate));
            return;
        }

        var installed = SpeechRecognitionEngine.InstalledRecognizers();
        var preferred = language.Length == 0 ? CultureInfo.CurrentUICulture : CultureInfo.GetCultureInfo(language);
        var selected = installed.FirstOrDefault(item => item.Culture.Name == preferred.Name);
        if (selected is null && (preferred.IsNeutralCulture || language.Length == 0))
            selected = installed.FirstOrDefault(item => item.Culture.TwoLetterISOLanguageName == preferred.TwoLetterISOLanguageName);
        if (selected is null && language.Length == 0) selected = installed.FirstOrDefault();
        if (selected is null)
            throw new InvalidOperationException("Windows has no desktop speech recognizer for this language. Install a Windows speech language pack or select Whisper in Voice settings.");

        var engine = recognizer = new SpeechRecognitionEngine(selected);
        engine.LoadGrammar(new DictationGrammar());
        engine.SetInputToDefaultAudioDevice();
        engine.InitialSilenceTimeout = TimeSpan.Zero;
        engine.AudioLevelUpdated += (_, e) => Volatile.Write(ref level, Math.Clamp(e.AudioLevel / 70.0, 0, 1));
        engine.SpeechHypothesized += (_, e) => PublishPartial(e.Result.Text);
        engine.SpeechRecognitionRejected += (_, _) => PublishPartial("");
        engine.SpeechRecognized += (_, e) =>
        {
            lock (gate) phrases.Add(e.Result.Text);
            PublishPartial("");
        };
        engine.RecognizeCompleted += (_, e) =>
        {
            if (e.Error is { } error)
            {
                recognized.TrySetException(error);
                Faulted?.Invoke(error);
            }
            else if (e.Cancelled) recognized.TrySetCanceled();
            else
            {
                string text;
                lock (gate) text = string.Join(" ", phrases);
                recognized.TrySetResult(text);
                Ended?.Invoke(text);
            }
        };
        engine.RecognizeAsync(RecognizeMode.Multiple);
    }

    void PublishPartial(string hypothesis)
    {
        if (IsBatch) return;
        string text;
        lock (gate) text = string.Join(" ", phrases.Append(hypothesis).Where(value => value.Length > 0));
        Partial?.Invoke(text);
    }

    public async Task<string> FinishAsync()
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(whisper || openAI ? 120 : 12));
        try
        {
            if (recognizer is { } engine)
            {
                if (!recognized.Task.IsCompleted) engine.RecognizeAsyncStop();
                return await recognized.Task.WaitAsync(timeout.Token);
            }

            if (microphone is null || folder is null) throw new InvalidOperationException("Microphone recording has ended.");
            await microphone.StopCaptureAsync();
            lock (gate)
            {
                if (captureError is { } error) throw error;
                if (recording is null || recording.Length < Rate / 5)
                    throw new InvalidOperationException("No usable microphone audio was recorded.");
                CloseRecording();
            }

            var audioPath = Path.Combine(folder, "speech.wav");
            if (openAIKey is { } key)
            {
                openAIKey = null;
                return await OpenAIDictation.TranscribeAsync(audioPath, key, !IsBatch,
                    partial => Partial?.Invoke(partial), timeout.Token);
            }

            var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true };
            var code = language.Length == 0 ? "auto" : language.Split('-', '_')[0].ToLowerInvariant();
            var output = Path.Combine(folder, "transcript");
            foreach (var arg in new[] { "-m", model, "-l", code, "-f", audioPath, "-otxt", "-of", output, "-np" })
                start.ArgumentList.Add(arg);
            timeout.Token.ThrowIfCancellationRequested();
            using var process = Process.Start(start) ?? throw new InvalidOperationException("Whisper couldn’t start.");
            var outputDrain = process.StandardOutput.BaseStream.CopyToAsync(Stream.Null);
            var errorDrain = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
            try { await process.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException)
            {
                if (!process.HasExited)
                    try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                await process.WaitForExitAsync();
                throw;
            }
            finally { await Task.WhenAll(outputDrain, errorDrain); }
            if (process.ExitCode != 0 || !File.Exists(output + ".txt"))
                throw new InvalidOperationException("Whisper couldn’t transcribe the recording. Check the executable, model and language in Voice settings.");
            return await File.ReadAllTextAsync(output + ".txt", timeout.Token);
        }
        catch (OperationCanceledException) when (!lifetime.IsCancellationRequested)
        {
            throw new TimeoutException("Dictation timed out.");
        }
    }

    void Capture(CapturedAudio audio)
    {
        try
        {
            lock (gate)
            {
                if (captureError is not null || recording is null) return;
                var bytes = audio.Bytes.Span;
                recording.Write(bytes);
                var samples = MemoryMarshal.Cast<byte, short>(bytes);
                if (samples.IsEmpty) return;
                var sum = 0.0;
                foreach (var sample in samples) sum += (double)sample * sample;
                var rms = Math.Sqrt(sum / samples.Length) / 32768;
                var normalized = Math.Clamp((20 * Math.Log10(Math.Max(0.00001, rms)) + 52) / 36, 0, 1);
                Volatile.Write(ref level, level * 0.62 + normalized * 0.38);
            }
        }
        catch (Exception error) { CaptureFailed(error); }
    }

    void CaptureFailed(Exception error)
    {
        lock (gate) captureError = error;
        Faulted?.Invoke(error);
    }

    public void Cancel() => lifetime.Cancel();

    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        openAIKey = null;
        try
        {
            if (recognizer is { } engine)
            {
                try { if (!recognized.Task.IsCompleted) engine.RecognizeAsyncCancel(); }
                catch (InvalidOperationException) { }
                finally { engine.Dispose(); }
            }
            if (microphone is { } input) await input.DisposeAsync();
        }
        finally
        {
            lock (gate) CloseRecording();
            if (folder is { } directory)
                try { Directory.Delete(directory, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            lifetime.Dispose();
        }
    }

    void CloseRecording()
    {
        recording?.Dispose();
        recording = null;
    }
}
