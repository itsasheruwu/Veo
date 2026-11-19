using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;

namespace Veo_Windows.Services;

internal static class ProfilePaths
{
    internal static string Root()
    {
        if (Environment.GetEnvironmentVariable("VEO_PROFILE_ROOT") is { Length: > 0 } explicitRoot) return Path.GetFullPath(explicitRoot);
        string local;
        try { local = Path.Combine(Windows.Storage.ApplicationData.Current.LocalCacheFolder.Path, "Local"); }
        catch { local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData); }
#if DEBUG
        return Path.Combine(local, "Veo", "Development");
#else
        return Path.Combine(local, "Veo", "Production");
#endif
    }
}

/// <summary>Captures failures before App static services and XAML navigation exist; never suppresses an exception.</summary>
internal static class StartupDiagnostics
{
    static readonly object sync = new();
    static string? file;
    static int firstChanceCount;
    static bool firstChanceActive;
    [ThreadStatic] static bool writing;
    static Timer? startupDeadline;
    [ModuleInitializer]
    internal static void Initialize()
    {
        try
        {
            var logs = Path.Combine(ProfilePaths.Root(), "Logs"); Directory.CreateDirectory(logs); file = Path.Combine(logs, "last-startup.txt");
            File.WriteAllText(file, DateTimeOffset.Now.ToString("O") + " · process " + Environment.ProcessId + " · module initialized\n");
#if DEBUG
            firstChanceActive = true; AppDomain.CurrentDomain.FirstChanceException += FirstChance;
            startupDeadline = new Timer(_ => StopFirstChance(), null, TimeSpan.FromSeconds(30), Timeout.InfiniteTimeSpan);
#endif
            AppDomain.CurrentDomain.UnhandledException += (_, args) => Record("AppDomain unhandled", args.ExceptionObject as Exception);
            TaskScheduler.UnobservedTaskException += (_, args) => Record("Unobserved task", args.Exception);
        }
        catch { /* Diagnostics must not prevent the application from starting. */ }
    }
    static void FirstChance(object? sender, FirstChanceExceptionEventArgs args)
    {
        if (!firstChanceActive || writing || Interlocked.Increment(ref firstChanceCount) > 40) return;
        Record("First-chance " + args.Exception.GetType().Name, args.Exception);
    }
    internal static void Record(string stage, Exception? exception = null)
    {
        if (file is null || writing) return;
        writing = true;
        try
        {
            var text = DateTimeOffset.Now.ToString("O") + " · " + stage + (exception is null ? "" : "\n" + Veo.Protocol.DiagnosticRedactor.Redact(exception.ToString())) + "\n";
            lock (sync) { if (new FileInfo(file).Length < 192 * 1024) File.AppendAllText(file, text); }
        }
        catch { /* Logging failures must not replace the original exception. */ }
        finally { writing = false; }
    }
    internal static void StopFirstChance()
    {
        firstChanceActive = false; AppDomain.CurrentDomain.FirstChanceException -= FirstChance; startupDeadline?.Dispose(); startupDeadline = null;
    }
}
