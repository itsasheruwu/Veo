using System.Text.Json;
using System.Text.Json.Serialization;

namespace Veo.Core;

public sealed record VeoPreferences
{
    public int Version { get; init; } = 1;
    public string Appearance { get; set; } = "System";
    public const string NativePicker = "Native";
    public const string SliderPicker = "Slider / Advanced";
    public string ModelPicker { get; set; } = SliderPicker;
    public bool ModelPickerUpgradeApplied { get; set; }
    public bool ModelPickerUpgradeNoticePending { get; set; }
    public string Streaming { get; set; } = "Token";
    public string ViewedImages { get; set; } = "Expanded";
    public string Accent { get; set; } = "#2E8CFA";
    public string SidebarMaterial { get; set; } = "Solid";
    public string UtilityMaterial { get; set; } = "Mica";
    public string ComposerMaterial { get; set; } = "Acrylic";
    public string CanvasMaterial { get; set; } = "Solid";
    public string NotificationMaterial { get; set; } = "Mica";
    public string MinimapMaterial { get; set; } = "Acrylic";
    public bool ShowMinimap { get; set; } = true;
    public bool ShowStatus { get; set; } = true;
    public bool ShowUsage { get; set; } = true;
    public string ContextStyle { get; set; } = "Bar";
    public string ContextLabel { get; set; } = "Percent";
    public string DefaultAccess { get; set; } = "Workspace";
    public string SearchEngine { get; set; } = "Google";
    public bool RestoreBrowserTabs { get; set; }
    public bool JavaScript { get; set; } = true;
    public bool BrowserAutoFill { get; set; } = true;
    public bool BrowserFraudWarning { get; set; } = true;
    public bool AgentClis { get; set; }
    public bool CodexFullAccess { get; set; }
    public bool ClaudeFullAccess { get; set; }
    public bool ShowArchived { get; set; }
    public bool ShowCodexHistory { get; set; }
    public bool GroupByProject { get; set; } = true;
    public bool Notifications { get; set; } = true;
    public bool ShowTrayIcon { get; set; }
    public bool KeepRunningWhenClosed { get; set; }
    public bool CompletionSound { get; set; }
    public string? CompletionSoundPath { get; set; }
    public string? CodexExecutable { get; set; }
    public string? SelectedThread { get; set; }
    public double WindowWidth { get; set; } = 1380;
    public double WindowHeight { get; set; } = 900;
    public int? WindowX { get; set; }
    public int? WindowY { get; set; }
    public bool WindowMaximized { get; set; }
    public double UtilityWidth { get; set; } = 360;
    public bool UtilityVisible { get; set; } = true;
    public bool SteerFollowUps { get; set; }
    public string UtilityTab { get; set; } = "Review";
    public Dictionary<string, BrowserTabState[]> BrowserTabs { get; set; } = [];
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
}
public sealed record BrowserTabState(string Id, string Url, string Title);
public sealed class PreferencesStore(string dataRoot)
{
    readonly string path = Path.Combine(dataRoot, "Settings", "settings.json");
    readonly SemaphoreSlim writer = new(1, 1);
    public async Task<VeoPreferences> LoadAsync()
    {
        if (!File.Exists(path))
        {
            var fresh = new VeoPreferences { ModelPickerUpgradeApplied = true };
            await SaveAsync(fresh);
            return fresh;
        }
        try
        {
            using var settings = JsonDocument.Parse(await File.ReadAllTextAsync(path));
            var root = settings.RootElement;
            var value = root.Deserialize<VeoPreferences>() ?? throw new JsonException("Expected a settings object.");
            if (!value.ModelPickerUpgradeApplied)
            {
                var alreadyUsesSlider = root.TryGetProperty(nameof(VeoPreferences.ModelPicker), out var previous)
                    && previous.ValueKind == JsonValueKind.String
                    && previous.GetString() == VeoPreferences.SliderPicker;
                value.ModelPicker = VeoPreferences.SliderPicker;
                value.ModelPickerUpgradeApplied = true;
                value.ModelPickerUpgradeNoticePending = !alreadyUsesSlider;
                await SaveAsync(value);
            }
            value.WindowWidth = double.IsFinite(value.WindowWidth) ? Math.Clamp(value.WindowWidth, 640, 10000) : 1380;
            value.WindowHeight = double.IsFinite(value.WindowHeight) ? Math.Clamp(value.WindowHeight, 480, 10000) : 900;
            value.UtilityWidth = double.IsFinite(value.UtilityWidth) ? Math.Clamp(value.UtilityWidth, 280, 800) : 360;
            value.UtilityTab = value.UtilityTab is "Review" or "Browser" or "Files" or "Side chat" ? value.UtilityTab : "Review";
            value.BrowserTabs ??= [];
            return value;
        }
        catch (JsonException error) { throw new InvalidDataException($"Settings are invalid; preserved at {path}", error); }
    }
    public async Task SaveAsync(VeoPreferences value)
    {
        // Capture the caller's state before waiting for a previous disk write.
        var snapshot = JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true });
        await writer.WaitAsync();
        string? temporary = null;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            await File.WriteAllTextAsync(temporary, snapshot);
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        finally { if (temporary is not null && File.Exists(temporary)) File.Delete(temporary); writer.Release(); }
    }
}
public static class BrowserSearch
{
    public static Uri Resolve(string input, string engine)
    {
        input = input.Trim();
        if (Uri.TryCreate(input, UriKind.Absolute, out var absolute) && absolute.Scheme is "https" or "http")
        {
            if (!string.IsNullOrEmpty(absolute.UserInfo)) throw new ArgumentException("Enter an address without embedded credentials.");
            return absolute;
        }
        if (!input.Any(char.IsWhiteSpace) && Uri.TryCreate("http://" + input, UriKind.Absolute, out var local) &&
            (local.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || System.Net.IPAddress.TryParse(local.Host.Trim('[', ']'), out var ip) && System.Net.IPAddress.IsLoopback(ip)))
        {
            if (!string.IsNullOrEmpty(local.UserInfo)) throw new ArgumentException("Enter an address without embedded credentials.");
            return local;
        }
        if (!input.Any(char.IsWhiteSpace) && input.Contains('.') && !input.Contains("://") && !input.Contains('@') && Uri.TryCreate("https://" + input, UriKind.Absolute, out var domain)) return domain;
        var q = Uri.EscapeDataString(input);
        return new(engine switch
        {
            "ChatGPT" => $"https://chatgpt.com/?temporary-chat=true&hints=search&q={q}",
            "DuckDuckGo" => $"https://duckduckgo.com/?q={q}", "Bing" => $"https://www.bing.com/search?q={q}",
            "Kagi" => $"https://kagi.com/search?q={q}", "Brave" => $"https://search.brave.com/search?q={q}",
            "Ecosia" => $"https://www.ecosia.org/search?q={q}", _ => $"https://www.google.com/search?q={q}"
        });
    }
}
