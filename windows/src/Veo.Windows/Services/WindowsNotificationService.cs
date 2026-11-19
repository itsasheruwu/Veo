using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Veo.Core;
using System.Runtime.InteropServices;

namespace Veo_Windows.Services;

public sealed class WindowsNotificationService : INotificationPlatform, IDisposable
{
    bool registered;
    public string? LastError { get; private set; }
    public string Setting => registered ? AppNotificationManager.Default.Setting.ToString() : "Not registered";
    public event Action<string>? Activated;
    public void Register()
    {
        if (registered) return;
        try
        {
            AppNotificationManager.Default.NotificationInvoked += Invoked;
            AppNotificationManager.Default.Register(); registered = true;
        }
        catch (Exception error) { AppNotificationManager.Default.NotificationInvoked -= Invoked; LastError = Veo.Protocol.DiagnosticRedactor.Redact(error.Message); }
    }
    void Invoked(AppNotificationManager manager, AppNotificationActivatedEventArgs args)
    { if (ParseThread(args.Argument) is { } id) Activated?.Invoke(id); }
    public static string? ParseThread(string arguments)
    {
        var pairs = arguments.Split('&').Select(x => x.Split('=', 2)).Where(x => x.Length == 2).ToArray();
        var threads = pairs.Where(x => Uri.UnescapeDataString(x[0]) == "thread").ToArray();
        return threads.Length == 1 && Uri.UnescapeDataString(threads[0][1]) is { Length: > 0 and <= 128 } id ? id : null;
    }
    public bool Show(VeoNotification notification, bool soundEnabled, string? customSound)
    {
        if (!registered) return false;
        var builder = new AppNotificationBuilder().AddArgument("thread", notification.ThreadId).AddText(notification.Title).AddText(notification.Body);
        if (!soundEnabled || !string.IsNullOrEmpty(customSound)) builder.MuteAudio();
        var toast = builder.BuildNotification(); toast.Group = notification.ThreadId;
        toast.Tag = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(notification.Identity)))[..16];
        AppNotificationManager.Default.Show(toast);
        if (soundEnabled && customSound is { } path)
        {
            if (!File.Exists(path) || !PlaySoundW(path, 0, 0x00020000 | 0x0001 | 0x0002)) PlaySoundW("SystemNotification", 0, 0x00010000 | 0x0001);
        }
        return toast.Id != 0;
    }
    public void Dispose()
    {
        if (!registered) return; registered = false;
        AppNotificationManager.Default.NotificationInvoked -= Invoked;
        AppNotificationManager.Default.Unregister();
    }
    [DllImport("winmm.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool PlaySoundW(string sound, nint module, uint flags);
}
