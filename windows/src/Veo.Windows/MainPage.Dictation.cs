using System.Diagnostics;
using System.Globalization;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Veo_Windows.Controls;
using Veo_Windows.Services;
using Windows.Foundation;
using Windows.UI.ViewManagement;

namespace Veo_Windows;

public sealed partial class MainPage
{
    sealed record DictationDraft(string Thread, string Text, int Start, int Length)
    {
        public (string Prefix, string Suffix) AroundSelection()
        {
            var before = Text[..Start];
            var after = Text[(Start + Length)..];
            if (before.Length > 0 && !char.IsWhiteSpace(before[^1]) && !"([{".Contains(before[^1])) before += " ";
            if (after.Length > 0 && !char.IsWhiteSpace(after[0]) && !".,!?;:)]}".Contains(after[0])) after = " " + after;
            return (before, after);
        }
    }

    ComposerDictation? dictation;
    DictationDraft? dictationDraft;
    DictationParticles? dictationParticles;
    Task? dictationCleanup;
    Task<string>? finishingDictation;
    readonly UISettings dictationUi = new();
    readonly DispatcherTimer dictationTimer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    Run? dictationIncoming;
    SolidColorBrush? dictationIncomingBrush;
    string? pendingDictationText;
    readonly List<Point> dictationTargets = [];
    string dictationText = "";
    bool dictationFinishing;
    bool dictationAnimating;
    long lastDictationFrame;
    long dictationStarted;
    long dictationRevealStarted;
    long dictationCompleted;
    double dictationTargetWidth;
    bool DictationActive => dictation is not null;

    void InitializeDictation()
    {
        App.Voice.Changed += DictationRealtimeVoiceChanged;
        dictationTimer.Tick += (_, _) =>
        {
            if (dictation is null) return;
            if (pendingDictationText is { } pending)
            {
                pendingDictationText = null;
                SetDictationPreview(pending);
            }
            if (dictationFinishing) return;
            var elapsed = Stopwatch.GetElapsedTime(dictationStarted);
            DictationStatus.Text = $"{(int)elapsed.TotalMinutes}:{elapsed.Seconds:00}";
            AutomationProperties.SetName(DictationStatus, "Listening, " + (int)elapsed.TotalSeconds + " seconds");
            if (elapsed >= TimeSpan.FromMinutes(1)) _ = FinishDictationAsync();
        };
    }

    void Dictate_Click(object sender, RoutedEventArgs e) => ToggleDictation();
    void CancelDictation_Click(object sender, RoutedEventArgs e) => CancelDictation(restoreFocus: true);
    void DictateShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs e)
    {
        if (!CanDictate()) return;
        e.Handled = true;
        ToggleDictation();
    }
    void CancelDictationShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs e)
    {
        if (!DictationActive) return;
        e.Handled = true;
        CancelDictation(restoreFocus: true);
    }

    void DictationRealtimeVoiceChanged() => DispatcherQueue.TryEnqueue(() =>
    {
        if (DictationActive && !CanDictate()) CancelDictation();
        UpdateDictationControl();
    });

    bool CanDictate() => initialized && !loading && !IsShowingSettings && current is { IsSubmitting: false }
        && App.Voice.State is not ("Starting" or "Listening")
        && ComposerPanel.Visibility == Visibility.Visible && Shell.Visibility == Visibility.Visible;

    void ToggleDictation()
    {
        if (dictation is not null)
        {
            if (!dictationFinishing) _ = FinishDictationAsync();
            return;
        }
        if (current is not { } session || !CanDictate() || imeComposing || dictationCleanup is { IsCompleted: false }) return;
        var prefs = workspace.Preferences;
        var whisper = prefs.DictationModel == "Whisper (local)";
        var openAI = prefs.DictationModel == OpenAIDictation.ModelName;
        var active = new ComposerDictation(whisper, openAI ? prefs.DictationOpenAIStream : prefs.DictationLive,
            whisper ? prefs.DictationWhisperLanguage : prefs.DictationLanguage,
            prefs.DictationWhisperExecutable, prefs.DictationWhisperModel, openAI);
        var text = Composer.Text;
        var start = Math.Clamp(Composer.SelectionStart, 0, text.Length);
        var length = Math.Clamp(Composer.SelectionLength, 0, text.Length - start);
        dictation = active;
        dictationDraft = new(session.Record.VeoId, text, start, length);
        dictationText = "";
        dictationFinishing = false;
        dictationCompleted = 0;
        DictationError.IsOpen = false;
        active.Partial += partial => DispatcherQueue.TryEnqueue(() =>
        {
            if (dictation == active && dictationCompleted == 0) pendingDictationText = partial;
        });
        active.Faulted += error => DispatcherQueue.TryEnqueue(() =>
        {
            if (dictation == active) DictationFailed(error);
        });
        active.Ended += result => DispatcherQueue.TryEnqueue(() =>
        {
            if (dictation == active && !dictationFinishing) _ = FinishDictationAsync(result);
        });
        try
        {
            active.Start();
            dictationStarted = Stopwatch.GetTimestamp();
            CloseCompletions();
            Composer.IsReadOnly = true;
            Composer.Visibility = Visibility.Collapsed;
            ComposerToolbar.Visibility = Visibility.Collapsed;
            WelcomeProjectRow.Visibility = Visibility.Collapsed;
            QueueShelf.Visibility = Visibility.Collapsed;
            ComposerInputs.Visibility = Visibility.Collapsed;
            CloseComposerPill();
            DictationEditor.Visibility = Visibility.Visible;
            DictationTranscript.FontSize = Composer.FontSize;
            DictationEditor.MaxHeight = Composer.MaxHeight + 29;
            DictationStatus.Text = "0:00";
            DictationStatus.Visibility = Visibility.Visible;
            DictationIndicator.Visibility = Visibility.Visible;
            SetDictationPreview("", force: true);
            dictationTimer.Start();
            if (dictationUi.AnimationsEnabled)
            {
                dictationParticles = new(ComposerDictationEffects);
                lastDictationFrame = 0;
                ComposerDictationEffects.Visibility = Visibility.Visible;
                CompositionTarget.Rendering += RenderDictation;
                dictationAnimating = true;
            }
            UpdateDictationControl();
            FinishDictationButton.Focus(FocusState.Programmatic);
        }
        catch (Exception error) { DictationFailed(error); }
    }

    async Task FinishDictationAsync(string? completed = null)
    {
        if (dictation is not { } active || dictationFinishing) return;
        dictationFinishing = true;
        DictationStatus.Text = "thinking";
        AutomationProperties.SetName(DictationStatus, "Transcribing");
        UpdateDictationControl();

        try
        {
            finishingDictation = completed is null ? active.FinishAsync() : Task.FromResult(completed);
            var spoken = (await finishingDictation).Trim();
            if (dictation != active) return;
            if (spoken.Length == 0) { DictationFailed(new InvalidOperationException("No speech was transcribed.")); return; }
            dictationTimer.Stop();
            pendingDictationText = null;
            SetDictationPreview(spoken);
            dictationCompleted = Stopwatch.GetTimestamp();
            DictationStatus.Visibility = Visibility.Collapsed;
            DictationIndicator.Visibility = Visibility.Collapsed;
            if (dictationAnimating && dictationUi.AnimationsEnabled)
            {
                var remaining = RevealDuration(active) - Stopwatch.GetElapsedTime(dictationRevealStarted).TotalSeconds;
                await Task.Delay(TimeSpan.FromSeconds(Math.Max(0.24, remaining)));
            }
            if (dictation != active) return;
            var snapshot = dictationDraft;
            CancelDictation(restoreFocus: true);
            if (snapshot is null || current?.Record.VeoId != snapshot.Thread || Composer.Text != snapshot.Text) return;
            var (before, after) = snapshot.AroundSelection();
            Composer.Text = before + spoken + after;
            Composer.SelectionStart = before.Length + spoken.Length;
            await SaveDraftNowAsync();
        }
        catch (Exception error) { if (dictation == active) DictationFailed(error); }
    }

    void CancelDictation(bool restoreFocus = false)
    {
        if (dictation is not { } active) return;
        dictation = null;
        var finish = finishingDictation;
        finishingDictation = null;
        active.Cancel();
        dictationCleanup = DisposeDictationAsync(active, finish);
        dictationTimer.Stop();
        if (dictationAnimating) CompositionTarget.Rendering -= RenderDictation;
        dictationAnimating = false;
        dictationParticles?.Dispose();
        dictationParticles = null;
        pendingDictationText = null;
        ComposerDictationEffects.Visibility = Visibility.Collapsed;
        DictationEditor.Visibility = Visibility.Collapsed;
        dictationDraft = null;
        dictationFinishing = false;
        Composer.IsReadOnly = false;
        Composer.Visibility = Visibility.Visible;
        ComposerToolbar.Visibility = Visibility.Visible;
        UpdateComposerInputStrip();
        RenderQueue();
        UpdateConversationChrome();
        UpdateDictationControl();
        if (restoreFocus && !IsShowingSettings) Composer.Focus(FocusState.Programmatic);
    }

    async Task DisposeDictationAsync(ComposerDictation active, Task<string>? finish)
    {
        try { if (finish is not null) await finish; } catch (Exception) { }
        try { await active.DisposeAsync(); } catch (Exception) { }
    }

    void DictationFailed(Exception error)
    {
        CancelDictation(restoreFocus: true);
        DictationError.Message = error is UnauthorizedAccessException
            ? "Allow desktop apps to use the microphone in Windows microphone privacy settings."
            : error.Message;
        DictationError.IsOpen = true;
    }

    void UpdateDictationControl()
    {
        DictateButton.IsEnabled = CanDictate() && !dictationFinishing;
        FinishDictationButton.IsEnabled = DictationActive && !dictationFinishing;
        FinishDictationGlyph.Glyph = dictationFinishing ? "\uE712" : "\uE71A";
        var title = dictationFinishing ? "Transcribing" : DictationActive ? "Finish dictation" : "Dictate";
        AutomationProperties.SetName(DictateButton, title);
        ToolTipService.SetToolTip(DictateButton, "Dictate (Ctrl+Shift+D)");
        AutomationProperties.SetName(FinishDictationButton, title);
        ToolTipService.SetToolTip(FinishDictationButton, title + " (Ctrl+Shift+D)");
        UpdateSendAvailability();
    }

    void SetDictationPreview(string updated, bool force = false)
    {
        if (!force && updated == dictationText) return;
        if (dictationDraft is not { } draft || dictation is not { } active) return;
        var unchanged = 0;
        if (!active.IsBatch)
        {
            var prior = StringInfo.GetTextElementEnumerator(dictationText);
            var next = StringInfo.GetTextElementEnumerator(updated);
            while (prior.MoveNext() && next.MoveNext() && prior.GetTextElement() == next.GetTextElement())
                unchanged += prior.GetTextElement().Length;
        }
        dictationText = updated;
        dictationRevealStarted = Stopwatch.GetTimestamp();
        dictationTargetWidth = 0;
        dictationTargets.Clear();
        dictationIncoming = null;
        dictationIncomingBrush = null;
        DictationTranscript.Inlines.Clear();
        var textColor = (DictationTranscript.Foreground as SolidColorBrush)?.Color
            ?? (ActualTheme == ElementTheme.Dark ? Colors.White : Colors.Black);
        if (updated.Length == 0)
        {
            var text = PreviewText(draft.Text);
            var run = new Run { Text = text.Length > 0 ? text : "Listening…" };
            if (text.Length == 0)
                run.Foreground = new SolidColorBrush(textColor) { Opacity = 0.48 };
            DictationTranscript.Inlines.Add(run);
            return;
        }

        var (prefix, suffix) = draft.AroundSelection();
        DictationTranscript.Inlines.Add(new Run { Text = PreviewText(prefix) + updated[..unchanged] });
        var incoming = updated[unchanged..];
        if (incoming.Length > 0)
        {
            dictationIncomingBrush = new SolidColorBrush(textColor) { Opacity = dictationAnimating ? 0 : 1 };
            dictationIncoming = new Run { Text = incoming, Foreground = dictationIncomingBrush };
            DictationTranscript.Inlines.Add(dictationIncoming);
        }
        DictationTranscript.Inlines.Add(new Run { Text = PreviewText(suffix) });
        DictationScroll.ChangeView(null, double.MaxValue, null, disableAnimation: true);
    }

    static string PreviewText(string text)
    {
        foreach (var context in InlineChatContext.Scan(text).Reverse())
            text = text.Remove(context.Start, context.Length).Insert(context.Start, "[" + context.Label + "]");
        return text;
    }

    void RenderDictation(object? sender, object e)
    {
        if (dictation is not { } active) return;
        var now = Stopwatch.GetTimestamp();
        if (lastDictationFrame != 0 && Stopwatch.GetElapsedTime(lastDictationFrame, now).TotalMilliseconds < 12) return;
        lastDictationFrame = now;
        var time = Stopwatch.GetElapsedTime(dictationStarted, now).TotalSeconds;
        var progress = Math.Clamp(Stopwatch.GetElapsedTime(dictationRevealStarted, now).TotalSeconds / RevealDuration(active), 0, 1);
        var animated = dictationUi.AnimationsEnabled;
        if (dictationIncomingBrush is { } brush)
        {
            var phase = active.IsBatch ? progress : Math.Clamp((progress - 0.25) / 0.54, 0, 1);
            var opacity = animated ? 1 - Math.Pow(1 - phase, 2) : 1;
            if (brush.Opacity != opacity) brush.Opacity = opacity;
        }
        if (!animated || ComposerDictationEffects.ActualWidth <= 0)
        {
            ComposerDictationEffects.Opacity = 0;
            return;
        }
        ComposerDictationEffects.Opacity = 1;
        if (progress < 1 && !active.IsBatch && dictationTargetWidth != DictationTranscript.ActualWidth)
            MeasureDictationTargets();
        var decay = dictationCompleted == 0 ? 1 : Math.Max(0, 1 - Stopwatch.GetElapsedTime(dictationCompleted).TotalSeconds / 0.28);
        var volume = dictationFinishing ? 0.11 + 0.045 * Math.Sin(time * 3) : active.Level;
        var color = (DictationTranscript.Foreground as SolidColorBrush)?.Color
            ?? (ActualTheme == ElementTheme.Dark ? Colors.White : Colors.Black);
        dictationParticles?.Draw(ComposerDictationEffects.ActualWidth, ComposerDictationEffects.ActualHeight,
            time, volume, decay, progress, progress < 1 && !active.IsBatch ? dictationTargets : [], color);
    }

    static double RevealDuration(ComposerDictation active) => active.IsBatch ? 0.29 : 0.54;

    void MeasureDictationTargets()
    {
        if (DictationTranscript.ActualWidth <= 0 || DictationTranscript.ActualHeight <= 0) return;
        dictationTargetWidth = DictationTranscript.ActualWidth;
        dictationTargets.Clear();
        var transform = DictationTranscript.TransformToVisual(ComposerDictationEffects);
        if (dictationIncoming is not { } run) return;
        var elements = StringInfo.GetTextElementEnumerator(run.Text);
        while (elements.MoveNext())
        {
            if (string.IsNullOrWhiteSpace(elements.GetTextElement())) continue;
            var pointer = run.ContentStart.GetPositionAtOffset(elements.ElementIndex, LogicalDirection.Forward);
            if (pointer is null) continue;
            var rect = pointer.GetCharacterRect(LogicalDirection.Forward);
            var point = transform.TransformPoint(new Point(rect.X, rect.Y + rect.Height * 0.54));
            if (!double.IsFinite(point.X) || !double.IsFinite(point.Y) || point.Y < 2) continue;
            for (var index = 0; index < 3; index++)
                dictationTargets.Add(new Point(point.X + index * 1.65, point.Y + Math.Cos(dictationTargets.Count * 2.4) * 4));
        }
        if (dictationTargets.Count <= 105) return;
        var stride = (int)Math.Ceiling(dictationTargets.Count / 105.0);
        var sample = dictationTargets.Where((_, index) => index % stride == 0).ToArray();
        dictationTargets.Clear();
        dictationTargets.AddRange(sample);
    }
}
