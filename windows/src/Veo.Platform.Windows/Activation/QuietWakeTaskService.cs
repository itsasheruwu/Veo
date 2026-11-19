using System.Diagnostics;
using System.Globalization;
using System.Security.Principal;
using System.Text;
using System.Xml.Linq;
using System.Runtime.InteropServices;

namespace Veo.Platform.Windows.Activation;

public sealed record QuietWakeTaskOptions(string HelperExecutable, string JobsFile, string MainApplicationAumid, DateTimeOffset RunAt, bool WakeComputer = false);

/// <summary>Explicit per-user registration. Construction/XML generation never registers anything.</summary>
public sealed class QuietWakeTaskService
{
    private readonly string taskName;
    public QuietWakeTaskService(string profile)
    {
        if (string.IsNullOrWhiteSpace(profile) || profile.Length > 80 || profile.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('-' or '_'))) throw new ArgumentException("A simple Veo profile identity is required.", nameof(profile));
        taskName = "Veo-" + profile + "-QuietContinuation";
    }
    public string TaskName => taskName;

    public static string BuildTaskXml(QuietWakeTaskOptions options, string currentUserSid)
    {
        Validate(options);
        if (!currentUserSid.StartsWith("S-1-", StringComparison.Ordinal)) throw new ArgumentException("The current user's SID is required.", nameof(currentUserSid));
        XNamespace ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";
        XElement E(string name, object content) => new(ns + name, content);
        var arguments = "--jobs " + PackagedApplicationActivator.QuoteArgument(Path.GetFullPath(options.JobsFile)) + " --aumid " + PackagedApplicationActivator.QuoteArgument(options.MainApplicationAumid);
        var task = new XElement(ns + "Task", new XAttribute("version", "1.3"),
            E("RegistrationInfo", E("Description", "Explicitly enabled Veo usage-limit continuation. Runs only while this user is signed in.")),
            E("Triggers", E("TimeTrigger", new object[] { E("Enabled", "true"), E("StartBoundary", options.RunAt.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture)) })),
            E("Principals", new XElement(ns + "Principal", new XAttribute("id", "CurrentUser"), E("UserId", currentUserSid), E("LogonType", "InteractiveToken"), E("RunLevel", "LeastPrivilege"))),
            E("Settings", new object[] { E("MultipleInstancesPolicy", "IgnoreNew"), E("DisallowStartIfOnBatteries", "false"), E("StopIfGoingOnBatteries", "false"), E("StartWhenAvailable", "true"), E("AllowStartOnDemand", "true"), E("Enabled", "true"), E("Hidden", "true"), E("WakeToRun", options.WakeComputer ? "true" : "false"), E("ExecutionTimeLimit", "PT1M") }),
            new XElement(ns + "Actions", new XAttribute("Context", "CurrentUser"), E("Exec", new object[] { E("Command", Path.GetFullPath(options.HelperExecutable)), E("Arguments", arguments), E("WorkingDirectory", Path.GetDirectoryName(Path.GetFullPath(options.HelperExecutable))!) })));
        return new XDocument(new XDeclaration("1.0", "utf-16", null), task).ToString();
    }

    public async Task RegisterAsync(QuietWakeTaskOptions options, bool explicitlyEnabled, CancellationToken cancellationToken = default)
    {
        if (!explicitlyEnabled) throw new InvalidOperationException("Quiet continuation must be explicitly enabled before registering a scheduled task.");
        Validate(options);
        if (!File.Exists(options.HelperExecutable)) throw new FileNotFoundException("Install Veo's stable continuation execution alias before enabling quiet wake.", options.HelperExecutable);
        var sid = WindowsIdentity.GetCurrent().User?.Value ?? throw new InvalidOperationException("The signed-in user has no available SID.");
        var temporary = Path.Combine(Path.GetTempPath(), "veo-task-" + Guid.NewGuid().ToString("N") + ".xml");
        try
        {
            await File.WriteAllTextAsync(temporary, BuildTaskXml(options, sid), Encoding.Unicode, cancellationToken);
            await RunSchtasksAsync(["/Create", "/TN", taskName, "/XML", temporary, "/F"], cancellationToken);
            var readback = await ReadXmlAsync(cancellationToken) ?? throw new IOException("The registered continuation task could not be reread.");
            XNamespace ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";
            var actual = XDocument.Parse(readback);
            if (!string.Equals(actual.Descendants(ns + "Command").Single().Value, Path.GetFullPath(options.HelperExecutable), StringComparison.OrdinalIgnoreCase)) throw new IOException("The registered task points to a different executable.");
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public async Task RemoveAsync(CancellationToken cancellationToken = default)
    {
        if (await ReadXmlAsync(cancellationToken) is null) return;
        await RunSchtasksAsync(["/Delete", "/TN", taskName, "/F"], cancellationToken);
        if (await ReadXmlAsync(cancellationToken) is not null) throw new IOException("The continuation task remained registered after removal.");
    }
    public async Task RunNowAsync(CancellationToken cancellationToken = default)
    {
        if (await ReadXmlAsync(cancellationToken) is null) throw new InvalidOperationException("No Veo continuation task is registered.");
        await RunSchtasksAsync(["/Run", "/TN", taskName], cancellationToken);
    }

    public Task<string?> ReadXmlAsync(CancellationToken cancellationToken = default) => Task.Run(() =>
    {
        cancellationToken.ThrowIfCancellationRequested();
        object? scheduler = null, folder = null, registered = null;
        try
        {
            var type = Type.GetTypeFromProgID("Schedule.Service", throwOnError: true)!;
            scheduler = Activator.CreateInstance(type)!; ((dynamic)scheduler).Connect();
            folder = ((dynamic)scheduler).GetFolder("\\");
            registered = ((dynamic)folder).GetTask(taskName);
            return (string?)((dynamic)registered).Xml;
        }
        // The COM dynamic binder maps HRESULT_FILE_NOT_FOUND to FileNotFoundException
        // on current .NET, while some interop paths retain COMException.
        catch (Exception error) when (error is COMException or FileNotFoundException && (uint)error.HResult == 0x80070002) { return null; }
        finally
        {
            if (registered is not null) Marshal.FinalReleaseComObject(registered);
            if (folder is not null) Marshal.FinalReleaseComObject(folder);
            if (scheduler is not null) Marshal.FinalReleaseComObject(scheduler);
        }
    }, cancellationToken);

    private static void Validate(QuietWakeTaskOptions options)
    {
        PackagedApplicationActivator.ValidateAumid(options.MainApplicationAumid);
        if (!Path.IsPathFullyQualified(options.HelperExecutable) || !Path.IsPathFullyQualified(options.JobsFile)) throw new ArgumentException("Continuation task paths must be absolute.");
        var aliases = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps");
        if (!string.Equals(Path.GetDirectoryName(Path.GetFullPath(options.HelperExecutable)), aliases, StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Quiet wake requires a stable installed execution alias, not a versioned MSIX or development output path.");
        if (!Path.GetFileName(options.HelperExecutable).Equals("veo-continuation.exe", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Select Veo's continuation execution alias.");
    }

    private static async Task RunSchtasksAsync(IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "schtasks.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        using var process = Process.Start(info) ?? throw new IOException("Task Scheduler did not start.");
        var stdout = process.StandardOutput.ReadToEndAsync(cancellationToken); var stderr = process.StandardError.ReadToEndAsync(cancellationToken);
        try { await process.WaitForExitAsync(cancellationToken); }
        catch { if (!process.HasExited) process.Kill(entireProcessTree: true); throw; }
        await stdout; var error = await stderr;
        if (process.ExitCode != 0) throw new IOException("Task Scheduler rejected the per-user registration: " + error.Trim());
    }
}
