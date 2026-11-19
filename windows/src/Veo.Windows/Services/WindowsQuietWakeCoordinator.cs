using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Veo.Core;
using Veo.Platform.Windows.Activation;
using Veo.Protocol;

namespace Veo_Windows.Services;

public sealed record QuietWakePreferences(int Version = 1, bool Enabled = false, bool WakeComputer = false);

/// <summary>Owns only Veo's opt-in per-user task; closing Veo preserves an explicitly enabled future wake.</summary>
public sealed class WindowsQuietWakeCoordinator : IAsyncDisposable
{
    private readonly WorkspaceContinuationService continuation;
    private readonly QuietWakeTaskService task;
    private readonly string preferencesFile, helperAlias;
    private readonly string? aumid;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private Task? refreshWorker;
    private int requested, workerRunning;
    private bool initialized, disposed;
    public QuietWakePreferences Preferences { get; private set; } = new();
    public bool IsAvailable => aumid is not null && File.Exists(helperAlias);
    public bool IsRegistered { get; private set; }
    public DateTimeOffset? NextWake { get; private set; }
    public string TaskName => task.TaskName;
    public string Status { get; private set; } = "Quiet scheduled launch is off.";
    public event Action? Changed;

    public WindowsQuietWakeCoordinator(WorkspaceContinuationService continuation, string dataRoot)
    {
        this.continuation = continuation;
        var profile = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(dataRoot))))[..16];
        task = new(profile); preferencesFile = Path.Combine(dataRoot, "Continuation", "quiet-wake.json");
        helperAlias = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "veo-continuation.exe");
        try { aumid = Windows.ApplicationModel.Package.Current.Id.FamilyName + "!App"; }
        catch (InvalidOperationException) { aumid = null; }
        continuation.Jobs.Changed += OnJobsChanged;
    }

    public async Task InitializeAsync()
    {
        if (initialized) return;
        initialized = true;
        try
        {
            if (File.Exists(preferencesFile))
            {
                Preferences = JsonSerializer.Deserialize<QuietWakePreferences>(await File.ReadAllTextAsync(preferencesFile)) ?? throw new InvalidDataException("Quiet-launch preferences are empty.");
                if (Preferences.Version != 1) throw new InvalidDataException("Unsupported quiet-launch settings version; original settings were preserved.");
            }
            await RefreshAsync();
        }
        catch (Exception error) { SetStatus("Quiet launch needs attention: " + DiagnosticRedactor.Redact(error.Message)); }
    }

    public async Task SetEnabledAsync(bool enabled)
    {
        if (enabled && !IsAvailable) throw new InvalidOperationException("Install Veo's continuation helper and enable its Windows app execution alias before enabling quiet launch.");
        await gate.WaitAsync();
        try
        {
            if (!enabled) { await task.RemoveAsync(); IsRegistered = false; NextWake = null; }
            Preferences = Preferences with { Enabled = enabled }; await SaveAsync();
        }
        finally { gate.Release(); }
        await RefreshAsync();
    }

    public async Task SetWakeComputerAsync(bool enabled)
    {
        await gate.WaitAsync();
        try { Preferences = Preferences with { WakeComputer = enabled }; await SaveAsync(); NextWake = null; }
        finally { gate.Release(); }
        await RefreshAsync();
    }

    public async Task RefreshAsync()
    {
        await gate.WaitAsync(lifetime.Token);
        try
        {
            if (!Preferences.Enabled)
            {
                await task.RemoveAsync(lifetime.Token); IsRegistered = false; NextWake = null;
                SetStatus("Quiet scheduled launch is off. Pending work can resume next time Veo opens."); return;
            }
            if (!IsAvailable)
            {
                await task.RemoveAsync(lifetime.Token); IsRegistered = false; NextWake = null;
                SetStatus("Quiet launch is enabled but Veo's installed execution alias is unavailable. Pending work can resume next launch."); return;
            }
            var next = (await continuation.Jobs.ListAsync(lifetime.Token))
                .Where(x => x.IsEnabled && !x.RequiresSendReconciliation && x.Status == ContinuationStatus.Waiting && x.DispatchAt > DateTimeOffset.UtcNow)
                .Select(x => x.DispatchAt).Min();
            if (next is null)
            {
                await task.RemoveAsync(lifetime.Token); IsRegistered = false; NextWake = null;
                SetStatus("Quiet launch is enabled. No future eligible interruption needs a scheduled task."); return;
            }
            if (IsRegistered && NextWake == next) return;
            SetStatus("Registering the next per-user quiet launch…");
            await task.RegisterAsync(new(helperAlias, continuation.Jobs.JobsFile, aumid!, next.Value, Preferences.WakeComputer), explicitlyEnabled: true, lifetime.Token);
            IsRegistered = true; NextWake = next;
            SetStatus("Next quiet launch: " + next.Value.ToLocalTime().ToString("g") + ". Veo will recheck account, usage and history before any continuation.");
        }
        catch (Exception error) when (error is not OperationCanceledException)
        { IsRegistered = false; NextWake = null; SetStatus("Quiet launch needs attention: " + DiagnosticRedactor.Redact(error.Message)); throw; }
        finally { gate.Release(); }
    }

    private void OnJobsChanged()
    {
        if (disposed || !initialized) return;
        Interlocked.Exchange(ref requested, 1);
        if (Interlocked.CompareExchange(ref workerRunning, 1, 0) != 0) return;
        refreshWorker = Task.Run(async () =>
        {
            try
            {
                while (Interlocked.Exchange(ref requested, 0) != 0)
                {
                    await Task.Delay(150, lifetime.Token);
                    try { await RefreshAsync(); } catch (Exception error) when (error is not OperationCanceledException) { }
                }
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
            finally { Interlocked.Exchange(ref workerRunning, 0); if (Volatile.Read(ref requested) != 0 && !disposed) OnJobsChanged(); }
        });
    }

    private async Task SaveAsync()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(preferencesFile)!);
        var temporary = preferencesFile + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(Preferences));
            if (File.Exists(preferencesFile)) File.Replace(temporary, preferencesFile, null); else File.Move(temporary, preferencesFile);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private void SetStatus(string status) { Status = status; Changed?.Invoke(); }
    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        disposed = true; continuation.Jobs.Changed -= OnJobsChanged;
        if (initialized && Preferences.Enabled) { try { await RefreshAsync(); } catch { /* Status retains the registration failure; next-launch recovery remains available. */ } }
        lifetime.Cancel(); if (refreshWorker is not null) await refreshWorker; lifetime.Dispose();
    }
}
