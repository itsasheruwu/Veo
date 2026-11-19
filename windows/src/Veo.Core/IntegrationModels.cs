using System.Text.Json;

namespace Veo.Core;

public sealed record IntegrationContext(string? Cwd, string? RuntimeThreadId)
{
    public string Key => (Cwd ?? "global") + "|" + (RuntimeThreadId ?? "");
    public static IntegrationContext For(ThreadSession? session) => new(session?.Record.Cwd, session?.Record.CodexThreadId);
}
public sealed record IntegrationIssue(string Method, string Message, bool Unavailable);
public sealed record SkillIntegration(string Id, string Name, string Title, string Description, string? Path, string Scope, bool Enabled, JsonElement Raw);
public sealed record PluginSelector(string Name, string? MarketplacePath, string? MarketplaceName)
{
    public Dictionary<string, object?> Parameters()
    {
        var result = new Dictionary<string, object?> { ["pluginName"] = Name };
        if (MarketplacePath is not null) result["marketplacePath"] = MarketplacePath;
        else if (MarketplaceName is not null) result["remoteMarketplaceName"] = MarketplaceName;
        return result;
    }
}
public sealed record PluginIntegration(string Id, string Name, string Title, string Description, bool Installed, bool Enabled, string Availability, string InstallPolicy, PluginSelector Selector, JsonElement Raw)
{
    public bool CanInstall => !Installed && Availability == "AVAILABLE" && InstallPolicy is "AVAILABLE" or "INSTALLED_BY_DEFAULT";
}
public sealed record MarketplaceIntegration(string Name, string? Path, string Title, PluginIntegration[] Plugins);
public sealed record AppIntegration(string Id, string Name, string Description, bool Enabled, bool Accessible, bool? Callable, Uri? InstallUrl, JsonElement Raw);
public sealed record McpToolIntegration(string Name, string Title, string Description, NativeSchemaForm Form, JsonElement Raw);
public sealed record McpResourceIntegration(string Uri, string Name, string? MimeType, string? Description);
public sealed record McpTemplateIntegration(string UriTemplate, string Name, string? Description);
public sealed record McpServerIntegration(string Name, string AuthStatus, string RuntimeStatus, string? Error, McpToolIntegration[] Tools, McpResourceIntegration[] Resources, McpTemplateIntegration[] Templates, JsonElement Raw);
public sealed record IntegrationSnapshot(SkillIntegration[] Skills, MarketplaceIntegration[] Marketplaces, AppIntegration[] Apps, McpServerIntegration[] McpServers, IntegrationIssue[] Issues)
{
    public static IntegrationSnapshot Empty { get; } = new([], [], [], [], []);
}
public sealed record ExternalImportItem(string Id, string Type, string Description, string? Cwd, string[] DetailCounts, JsonElement Raw);
public sealed record ExternalImportProgress(string ImportId, bool Complete, int Successes, int Failures, string[] Errors);
public sealed record IntegrationResourceContent(string Uri, string? MimeType, string? Text, byte[]? Data);
public sealed record IntegrationToolResult(bool IsError, string[] Text, JsonElement? Structured, JsonElement[] Content);
public sealed record IntegrationOAuthSession(string Name, string? LoginId, Uri AuthorizationUrl, string State, string? Error = null);
