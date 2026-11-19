using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Veo.Protocol;
using Veo_Windows.Services;

namespace Veo_Windows.Controls;

public sealed class ContinuationPanel : Grid, IDisposable
{
    private readonly WorkspaceCoordinator workspace;
    private readonly WorkspaceContinuationService continuation;
    private readonly StackPanel jobs = new() { Spacing = 16 };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly ToggleSwitch enabled = new() { Header = "Automatically continue future usage-limit interruptions" };
    private readonly WindowsQuietWakeCoordinator? quiet;
    private readonly ToggleSwitch quietEnabled = new() { Header = "Launch Veo quietly for an enabled interruption" };
    private readonly ToggleSwitch wakeComputer = new() { Header = "Allow Windows to wake this PC when its power policy permits" };
    private readonly TextBlock quietStatus = new() { TextWrapping = TextWrapping.Wrap };
    private bool synchronizingQuiet;
    private bool disposed;
    private int refreshScheduled;

    public ContinuationPanel(WorkspaceCoordinator workspace, WorkspaceContinuationService continuation, WindowsQuietWakeCoordinator? quiet = null)
    {
        this.workspace = workspace; this.continuation = continuation; this.quiet = quiet;
        MinWidth = 480; MinHeight = 360; MaxHeight = 680;
        var body = new StackPanel { Spacing = 16, Padding = new Thickness(4) };
        body.Children.Add(new TextBlock { Text = "Usage-limit continuation", Style = (Style)Application.Current.Resources["TitleTextBlockStyle"] });
        body.Children.Add(enabled);
        body.Children.Add(new TextBlock { Text = "Veo keeps the interrupted turn's access, model and mode. It waits for Codex's reported reset plus eight seconds, then rereads account, usage and history. Existing interruptions retain their own choice.", TextWrapping = TextWrapping.Wrap });
        body.Children.Add(status);
        if (quiet is not null)
        {
            body.Children.Add(quietEnabled); body.Children.Add(wakeComputer); body.Children.Add(quietStatus);
            var refreshHelper = new Button { Content = "Refresh installed helper status" };
            refreshHelper.Click += async (_, _) => { try { await quiet.RefreshAsync(); } catch (Exception error) { quietStatus.Text = DiagnosticRedactor.Redact(error.Message); } finally { SynchronizeQuiet(); } };
            body.Children.Add(refreshHelper); quiet.Changed += OnChanged;
            quietEnabled.Toggled += async (_, _) => { if (synchronizingQuiet) return; try { await quiet.SetEnabledAsync(quietEnabled.IsOn); } catch (Exception error) { quietStatus.Text = DiagnosticRedactor.Redact(error.Message); } finally { SynchronizeQuiet(); } };
            wakeComputer.Toggled += async (_, _) => { if (synchronizingQuiet) return; try { await quiet.SetWakeComputerAsync(wakeComputer.IsOn); } catch (Exception error) { quietStatus.Text = DiagnosticRedactor.Redact(error.Message); } finally { SynchronizeQuiet(); } };
        }
        body.Children.Add(new TextBlock { Text = "Saved interruptions", Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });
        body.Children.Add(jobs);
        Children.Add(new ScrollViewer { Content = body });
        continuation.Changed += OnChanged;
        Loaded += async (_, _) =>
        {
            try
            {
                await continuation.InitializeAsync(); enabled.IsOn = continuation.Preferences.EnabledByDefault;
                if (quiet is not null) { await quiet.InitializeAsync(); SynchronizeQuiet(); }
                enabled.Toggled += async (_, _) => await RunAsync(() => continuation.SetEnabledByDefaultAsync(enabled.IsOn));
                await RefreshAsync();
            }
            catch (Exception error) { status.Text = DiagnosticRedactor.Redact(error.Message); }
        };
        Unloaded += (_, _) => Dispose();
    }

    private void OnChanged()
    {
        if (disposed || Interlocked.Exchange(ref refreshScheduled, 1) != 0) return;
        DispatcherQueue.TryEnqueue(async () => { Interlocked.Exchange(ref refreshScheduled, 0); if (!disposed) await RefreshAsync(); });
    }

    private async Task RefreshAsync()
    {
        try
        {
            status.Text = continuation.Status;
            SynchronizeQuiet();
            var records = (await workspace.Threads.ListThreadsAsync(limit: 1000)).Concat(await workspace.Threads.ListThreadsAsync(archived: true, limit: 1000)).ToDictionary(x => x.VeoId);
            var saved = await continuation.Jobs.ListAsync();
            jobs.Children.Clear();
            if (saved.Count == 0)
            {
                jobs.Children.Add(new TextBlock { Text = "No usage-limit interruption has been saved. A job is created only after a real usage-limit error with a reported reset time.", TextWrapping = TextWrapping.Wrap });
                return;
            }
            foreach (var job in saved.OrderByDescending(x => x.CreatedAt))
            {
                var row = new StackPanel { Spacing = 6 };
                row.Children.Add(new TextBlock { Text = records.TryGetValue(job.VeoThreadId, out var thread) ? thread.Title : "Saved chat", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
                row.Children.Add(new TextBlock { Text = $"{job.Status} · {job.Access} · {job.Model ?? "Runtime default"}", TextWrapping = TextWrapping.Wrap });
                if (job.DispatchAt is DateTimeOffset due) row.Children.Add(new TextBlock { Text = "Eligible after " + due.ToLocalTime().ToString("g"), TextWrapping = TextWrapping.Wrap });
                if (job.Detail is { Length: > 0 }) row.Children.Add(new TextBlock { Text = job.Detail, TextWrapping = TextWrapping.Wrap });
                if (job.Status is not (ContinuationStatus.Completed or ContinuationStatus.Cancelled))
                {
                    var choice = new ToggleSwitch { Header = "Continue this interruption", IsOn = job.IsEnabled };
                    choice.Toggled += async (_, _) => await RunAsync(async () => { await continuation.Jobs.SetEnabledAsync(job.Id, choice.IsOn); await continuation.ProcessDueAsync(); });
                    row.Children.Add(choice);
                    var commands = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                    var recheck = new Button { Content = "Recheck account and history" };
                    recheck.Click += async (_, _) => await RunAsync(async () => { await continuation.RecheckAsync(job.Id); });
                    var cancel = new Button { Content = "Cancel continuation" };
                    cancel.Click += async (_, _) => await RunAsync(() => continuation.Jobs.CancelThreadAsync(job.VeoThreadId, "Cancelled explicitly."));
                    if (job.IsEnabled) commands.Children.Add(recheck);
                    commands.Children.Add(cancel); row.Children.Add(commands);
                }
                jobs.Children.Add(row);
            }
        }
        catch (Exception error) { status.Text = DiagnosticRedactor.Redact(error.Message); }
    }

    private async Task RunAsync(Func<Task> action)
    { try { await action(); await RefreshAsync(); } catch (Exception error) { status.Text = DiagnosticRedactor.Redact(error.Message); } }
    public void Dispose()
    { if (disposed) return; disposed = true; continuation.Changed -= OnChanged; if (quiet is not null) quiet.Changed -= OnChanged; }
    private void SynchronizeQuiet()
    {
        if (quiet is null) return;
        synchronizingQuiet = true;
        try
        {
            quietEnabled.IsOn = quiet.Preferences.Enabled; quietEnabled.IsEnabled = quiet.IsAvailable || quiet.Preferences.Enabled;
            wakeComputer.IsOn = quiet.Preferences.WakeComputer; wakeComputer.IsEnabled = quiet.Preferences.Enabled;
            quietStatus.Text = quiet.IsAvailable ? quiet.Status : "Veo's installed continuation execution alias is unavailable. Pending work can resume next time Veo opens.";
        }
        finally { synchronizingQuiet = false; }
    }
}
