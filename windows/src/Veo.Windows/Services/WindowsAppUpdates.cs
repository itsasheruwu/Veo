using System.Reflection;
using Velopack;
using Velopack.Sources;
using Veo.Core;

namespace Veo_Windows.Services;

internal sealed class WindowsAppUpdates
{
    const string Repository = "https://github.com/itsasheruwu/Veo";
    internal static Uri Releases { get; } = new(Repository + "/releases");
    readonly UpdateManager manager = new(new GithubSource(Repository, accessToken: null, prerelease: true));
    readonly CancellationTokenSource lifetime = new();
    UpdateInfo? available;
    bool current;
    string? error;

    public event Action? Changed;
    public bool IsInstalled => manager.IsInstalled;
    public bool Busy { get; private set; }
    public bool HasUpdate => available is not null;
    public bool ReadyToRestart => IsInstalled && manager.UpdatePendingRestart is not null;
    public string Version => manager.CurrentVersion?.ToString()
        ?? typeof(WindowsAppUpdates).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? "Unknown";
    public string Status => error ?? (Busy ? "Checking for or downloading updates…"
        : ReadyToRestart ? $"Veo {manager.UpdatePendingRestart?.Version} is ready to install."
        : available is { } update ? $"Veo {update.TargetFullRelease.Version} is available."
        : current ? "Veo is up to date." : "Get the latest Windows beta from GitHub Releases.");

    public async Task MonitorAsync(VeoPreferences preferences)
    {
        if (!IsInstalled) return;
        using var timer = new PeriodicTimer(TimeSpan.FromHours(6));
        try
        {
            do
            {
                if (preferences.CheckForAppUpdates) await CheckAsync(() => preferences.CheckForAppUpdates && preferences.InstallAppUpdatesAutomatically);
            } while (await timer.WaitForNextTickAsync(lifetime.Token));
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }

    public Task CheckAsync(Func<bool>? installAutomatically = null) => RunAsync(async () =>
    {
        available = await manager.CheckForUpdatesAsync();
        current = available is null;
        if (available is not null && !ReadyToRestart && !lifetime.IsCancellationRequested && installAutomatically?.Invoke() == true)
            await DownloadCoreAsync(available);
    });

    public Task DownloadAsync() => available is { } update ? RunAsync(() => DownloadCoreAsync(update)) : Task.CompletedTask;

    async Task DownloadCoreAsync(UpdateInfo update)
    {
        await manager.DownloadUpdatesAsync(update, cancelToken: lifetime.Token);
        available = null;
    }

    async Task RunAsync(Func<Task> operation)
    {
        if (!IsInstalled || Busy || lifetime.IsCancellationRequested) return;
        Busy = true;
        error = null;
        Changed?.Invoke();
        try { await operation(); }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception exception)
        {
            StartupDiagnostics.Record("Windows app update failed", exception);
            error = "Couldn’t complete the update. Check your connection and try again.";
        }
        finally
        {
            Busy = false;
            if (!lifetime.IsCancellationRequested) Changed?.Invoke();
        }
    }

    public void Stop() => lifetime.Cancel();

    public void ApplyOnExit(bool restart)
    {
        if (IsInstalled && manager.UpdatePendingRestart is { } pending)
            manager.WaitExitThenApplyUpdates(pending, silent: true, restart: restart);
    }
}
