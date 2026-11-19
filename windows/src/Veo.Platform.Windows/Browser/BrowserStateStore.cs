using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Veo.Platform.Windows.Browser;
public sealed record NativeBrowserTab(string Id, string Url = "", string Title = "New tab");
public sealed record NativeBrowserWorkspace(NativeBrowserTab[] Tabs, string? SelectedId, string Viewport = "Responsive");
public sealed record NativeBrowserPreferences
{
    public int Version { get; init; } = 1;
    public bool DesktopSite { get; set; } = true;
    public Dictionary<string, NativeBrowserWorkspace> Workspaces { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

/// <summary>Separate browser state; restored on a new process only when the caller opted in.</summary>
public sealed class BrowserStateStore(string dataRoot)
{
    readonly string path = Path.Combine(dataRoot, "Browser", "state.json");
    readonly SemaphoreSlim writer = new(1, 1);
    public NativeBrowserPreferences Value { get; private set; } = new();

    public async Task LoadAsync()
    {
        if (!File.Exists(path))
            return;
        if (new FileInfo(path).Length > 2 * 1024 * 1024)
            throw new InvalidDataException("Browser state exceeds its limit; the original is preserved.");
        var value = JsonSerializer.Deserialize<NativeBrowserPreferences>(await File.ReadAllTextAsync(path)) ?? throw new InvalidDataException("Browser state is empty.");
        if (value.Version != 1)
            throw new InvalidDataException("This browser state version is not supported.");
        value.Workspaces = new(value.Workspaces ?? [], StringComparer.OrdinalIgnoreCase);
        Value = value;
    }

    public static string WorkspaceKey(string cwd) => Path.GetFullPath(cwd).TrimEnd(Path.DirectorySeparatorChar);
    public NativeBrowserWorkspace? Restore(string cwd, bool enabled)
    {
        if (!enabled || !Value.Workspaces.TryGetValue(WorkspaceKey(cwd), out var value))
            return null;
        var seen = new HashSet<string>();
        var tabs = value.Tabs.Where(t => Guid.TryParse(t.Id, out _) && seen.Add(t.Id) && (t.Url.Length == 0 || BrowserOrigin.IsWeb(t.Url))).Take(32).ToArray();
        return new(tabs, tabs.Any(t => t.Id == value.SelectedId) ? value.SelectedId : tabs.FirstOrDefault()?.Id, NormalizeViewport(value.Viewport));
    }

    public async Task SaveWorkspaceAsync(string cwd, NativeBrowserWorkspace workspace, bool restoreEnabled)
    {
        var key = WorkspaceKey(cwd);
        if (restoreEnabled)
            Value.Workspaces[key] = workspace;
        else
            Value.Workspaces.Remove(key);
        await SaveAsync();
    }

    public async Task SaveAsync()
    {
        var data = JsonSerializer.Serialize(Value);
        await writer.WaitAsync();
        string? temporary = null;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            await File.WriteAllTextAsync(temporary, data);
            File.Move(temporary, path, true);
        }
        finally
        {
            if (temporary is not null && File.Exists(temporary))
                File.Delete(temporary);
            writer.Release();
        }
    }

    public static string NormalizeViewport(string? value) => value is "Desktop" or "Tablet" or "Mobile" ? value : "Responsive";
}

public static class BrowserOrigin
{
    public static bool IsWeb(string value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" && string.IsNullOrEmpty(uri.UserInfo);
    public static string Of(Uri uri)
    {
        if (!IsWeb(uri.AbsoluteUri))
            throw new ArgumentException("A web origin without embedded credentials is required.");
        return uri.GetLeftPart(UriPartial.Authority).ToLowerInvariant();
    }

    public static bool Same(string? first, string? second) => Uri.TryCreate(first, UriKind.Absolute, out var a) && Uri.TryCreate(second, UriKind.Absolute, out var b) && IsWeb(a.AbsoluteUri) && IsWeb(b.AbsoluteUri) && Of(a) == Of(b);
    public static string Key(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
