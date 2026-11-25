using Microsoft.UI.Xaml;
using Veo.Core;
using Microsoft.Windows.AppLifecycle;
using Microsoft.UI.Dispatching;
namespace Veo_Windows;
public partial class App : Application
{
    public static WorkspaceCoordinator Workspace { get; } = new(ProfileRoot());
    public static PlanCoordinator Plans { get; } = new(Workspace);
    public static QuestionCoordinator Questions { get; } = new(Workspace);
    public static WorkspaceContinuationService Continuation { get; } = new(Workspace);
    public static RealtimeVoiceCoordinator Voice { get; } = new(Workspace, new Controls.WindowsVoiceAudio());
    public static Veo.Infrastructure.Projects.ProjectPreferencesService Projects { get; } = new(Workspace.Threads);
    public static ModelSelectionService Models { get; } = new(Workspace, projectPreferences: Projects);
    static Veo.Platform.Windows.Security.CredentialManager Credentials { get; } = new(Workspace.DataRoot);
    static JevFirstPromptRouter Jev { get; } = new(_ => Task.FromResult(Credentials.Read("Router/Jev", "api-key")?.Secret));
    public static AutoRoutingCoordinator Routing { get; } = new(Workspace, Models, Jev);
    public static IntegrationCoordinator Integrations { get; } = new(Workspace);
    public static RuntimeManagementCoordinator RuntimeManagement { get; } = new(Workspace);
    public static AccountCoordinator Accounts { get; } = new(Workspace);
    public static ThreadSettingsCoordinator ThreadSettings { get; } = new(Workspace);
    public static WorktreeCoordinator Worktrees { get; } = new(Workspace, Projects);
    public static CheckpointCoordinator Checkpoints { get; } = new(Workspace, Projects);
    public static CommandRegistry Commands { get; } = new(Workspace.Threads);
    public static ThreadCatalogCoordinator Catalog { get; } = new(Workspace);
    public static HistoryCoordinator History { get; } = new(Workspace, checkpoints: Checkpoints);
    public static QueueCoordinator Queue { get; } = new(Workspace);
    public static Services.WindowsNotificationService NotificationPlatform { get; } = new();
    public static NotificationCoordinator Notifications { get; } = new(Workspace, NotificationPlatform, thread => Main?.IsActive == true && Main.SelectedThread?.Record.VeoId == thread);
    public static string? PendingNotificationThread { get; private set; }
    public static MainWindow? Main { get; private set; }
    static Veo.Platform.Windows.Shell.NotificationAreaIcon? tray;
    Task? shutdown;
    bool allowingClose;
    public static Services.WindowsQuietWakeCoordinator QuietWake { get; } = new(Continuation, Workspace.DataRoot);
    public App()
    {
        Services.StartupDiagnostics.Record("App constructor entered");
        UnhandledException += (_, e) => Services.StartupDiagnostics.Record("XAML unhandled", e.Exception);
        InitializeComponent();
        Services.StartupDiagnostics.Record("App XAML initialized");
        var previousDispatch = Workspace.BeforeDispatchAsync;
        Workspace.BeforeDispatchAsync = async (session, payload, continuation) =>
        {
            await RuntimeManagement.ValidateAccessAsync(session, payload);
            if (previousDispatch is not null) await previousDispatch(session, payload, continuation);
        };
        Workspace.PrepareComposerGoalAsync = ThreadSettings.PrepareComposerGoalAsync;
        Workspace.CaptureTurnCheckpointAsync = Checkpoints.BeforeDispatchAsync;
        Workspace.BindTurnCheckpointAsync = Checkpoints.AfterDispatchAsync;
        UnhandledException += (_, e) =>
        {
            var directory = Path.Combine(Workspace.DataRoot, "Logs"); Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory, "last-error.txt"), Veo.Protocol.DiagnosticRedactor.Redact(e.Exception.ToString()));
        };
    }
    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
        Services.StartupDiagnostics.Record("OnLaunched entered");
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        NotificationPlatform.Activated += id =>
        {
            PendingNotificationThread = id;
            dispatcher.TryEnqueue(async () => { if (Main is { } main) await main.NavigateThreadIdAsync(id); });
        };
        NotificationPlatform.Register();
        Services.StartupDiagnostics.Record("Notification registration completed");
        var profileIdentity = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(Workspace.DataRoot).ToUpperInvariant())))[..24];
        var owner = AppInstance.FindOrRegisterForKey("Veo." + profileIdentity);
        Services.StartupDiagnostics.Record("App instance selected");
        if (!owner.IsCurrent)
        {
            await owner.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs());
            Exit(); return;
        }
        owner.Activated += (_, activation) => dispatcher.TryEnqueue(async () =>
        {
            Main?.Activate();
            if (activation.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch && Main is { } main)
                await main.HandleActivationAsync(launch.Arguments);
            if (activation.Data is Microsoft.Windows.AppNotifications.AppNotificationActivatedEventArgs notification
                && Services.WindowsNotificationService.ParseThread(notification.Argument) is { } threadId && Main is { } target)
                await target.NavigateThreadIdAsync(threadId);
        });
        Services.StartupDiagnostics.Record("Constructing MainWindow");
        await Workspace.LoadPreferencesAsync();
        Main = new MainWindow(); Services.StartupDiagnostics.Record("MainWindow constructed"); Main.Activate();
        Services.StartupDiagnostics.Record("MainWindow activated");
        Main.PendingActivation = args.Arguments;
        Main.AppWindow.Closing += (sender, closing) =>
        {
            if (allowingClose) return;
            closing.Cancel = true;
            if (Workspace.Preferences.KeepRunningWhenClosed && tray is not null) { Main.AppWindow.Hide(); return; }
            _ = ShutdownAsync();
        };
        }
        catch (Exception exception) { Services.StartupDiagnostics.Record("OnLaunched failed", exception); throw; }
    }
    public static void ApplyTrayPreference()
    {
        if (!Workspace.Preferences.ShowTrayIcon) { tray?.Dispose(); tray = null; return; }
        if (tray is not null || Main is not { } window) return;
        tray = new(WinRT.Interop.WindowNative.GetWindowHandle(window), Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        tray.Invoked += command => window.DispatcherQueue.TryEnqueue(async () =>
        {
            if (command == Veo.Platform.Windows.Shell.TrayCommand.Quit) { await ShutdownAsync(); return; }
            window.AppWindow.Show(); window.Activate();
            if (command == Veo.Platform.Windows.Shell.TrayCommand.NewChat) await window.CreateChatAsync();
            else if (command == Veo.Platform.Windows.Shell.TrayCommand.Settings) await window.ShowSettingsAsync();
        });
    }
    public static Task ShutdownAsync()
    {
        var app = (App)Current; return app.shutdown ??= app.ShutdownCoreAsync();
    }
    async Task ShutdownCoreAsync()
    {
        async Task Release(Func<Task> action)
        {
            try { await action(); }
            catch (Exception error)
            {
                try
                {
                    var logs = Path.Combine(Workspace.DataRoot, "Logs"); Directory.CreateDirectory(logs);
                    await File.WriteAllTextAsync(Path.Combine(logs, "last-shutdown-error.txt"), Veo.Protocol.DiagnosticRedactor.Redact(error.ToString()));
                }
                catch { /* A logging failure must not skip disposal of owned processes. */ }
            }
        }
        await Release(() => Main?.DisposeSurfacesAsync() ?? Task.CompletedTask);
        tray?.Dispose(); tray = null;
        await Release(async () => await Notifications.DisposeAsync()); NotificationPlatform.Dispose();
        await Release(async () => await Routing.DisposeAsync()); Jev.Dispose();
        await Release(async () => await Integrations.DisposeAsync());
        await Release(async () => await RuntimeManagement.DisposeAsync());
        await Release(async () => await Accounts.DisposeAsync());
        await Release(async () => await ThreadSettings.DisposeAsync());
        await Release(async () => await Voice.DisposeAsync());
        await Release(async () => await QuietWake.DisposeAsync());
        await Release(async () => await Continuation.DisposeAsync());
        await Release(async () => await Questions.DisposeAsync());
        await Release(async () => await Plans.DisposeAsync());
        Queue.Dispose();
        await Release(async () => await Workspace.DisposeAsync());
        allowingClose = true; Main?.Close(); Exit();
    }
    static string ProfileRoot()
    {
        return Services.ProfilePaths.Root();
    }
}
