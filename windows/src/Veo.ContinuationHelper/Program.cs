using System.Text.Json;
using Veo.Platform.Windows.Activation;

[assembly: System.Runtime.Versioning.SupportedOSPlatform("windows10.0.26100")]

namespace Veo.ContinuationHelper;

internal static class Program
{
    [STAThread]
    private static int Main(string[] arguments)
    {
        // No Codex transport, account secrets, microphone, scheduling or elevation.
        // The app instance revalidates account/history/access before deciding to send.
        try
        {
            if (arguments.Length != 4 || arguments[0] != "--jobs" || arguments[2] != "--aumid") return 2;
            var file = Path.GetFullPath(arguments[1]);
            if (!File.Exists(file) || new FileInfo(file).Length > 1024 * 1024) return 0;
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var document = JsonDocument.Parse(stream);
            if (document.RootElement.GetProperty("Version").GetInt32() != 1) return 2;
            var now = DateTimeOffset.UtcNow;
            foreach (var job in document.RootElement.GetProperty("Jobs").EnumerateArray())
            {
                if (!job.GetProperty("IsEnabled").GetBoolean() || job.GetProperty("Status").GetString() != "Waiting" || job.TryGetProperty("RequiresSendReconciliation", out var uncertain) && uncertain.GetBoolean()) continue;
                if (!job.TryGetProperty("ResetAt", out var reset) || reset.ValueKind != JsonValueKind.String || !reset.TryGetDateTimeOffset(out var at) || at.AddSeconds(8) > now) continue;
                var id = job.GetProperty("Id").GetString();
                if (!Guid.TryParse(id, out _)) continue;
                PackagedApplicationActivator.ActivateContinuation(arguments[3], id!);
                return 0; // One app activation is enough to reconcile every due job.
            }
            return 0;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException or InvalidOperationException or ArgumentException or System.Runtime.InteropServices.COMException)
        { return 1; }
    }
}
