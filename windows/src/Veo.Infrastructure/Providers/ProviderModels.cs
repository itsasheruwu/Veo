using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Veo.Infrastructure.Providers;

public enum ProviderPreset { Anthropic, DeepSeek, Xai, GrokOAuth, Kimi, KimiOAuth, OpenRouter, Custom }
public enum ProviderWireApi { Chat, Responses }
public enum ProviderRequestPurpose { Catalog, Inference, Authentication }
public enum ProviderConnectionState { Disconnected, Connecting, Connected, NeedsSignIn, Failed }
public sealed record ExternalModelRecord(string Id, string UpstreamId, string DisplayName, bool Enabled = false,
    long? ContextWindow = null, long? MaximumContextWindow = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)] JsonElement Metadata = default)
{ public override string ToString() => DisplayName; }
public sealed record ExternalProvider(string Id, ProviderPreset Preset, string Name, string BaseUrl,
    ProviderWireApi WireApi, bool Enabled = false, ExternalModelRecord[]? Models = null)
{
    [JsonIgnore] public bool IsOAuth => Preset is ProviderPreset.GrokOAuth or ProviderPreset.KimiOAuth;
    [JsonIgnore]
    public Uri BaseUri
    {
        get
        {
            if (!Uri.TryCreate(BaseUrl.TrimEnd('/') + "/", UriKind.Absolute, out var uri) ||
                uri.Scheme != "https" || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
                throw new ArgumentException("Provider endpoints must use HTTPS without embedded credentials, query or fragment.");
            return uri;
        }
    }
    [JsonIgnore] public string Identity => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Id + "\0" + Preset + "\0" + BaseUri.AbsoluteUri)));
    [JsonIgnore] public string CredentialKey => "Provider/" + Id + "/" + Identity;
    public Uri Endpoint(string suffix) => new(BaseUri, suffix);
    public static ExternalProvider Create(ProviderPreset preset, string? customId = null) => preset switch
    {
        ProviderPreset.Anthropic => new("anthropic", preset, "Anthropic", "https://api.anthropic.com/v1", ProviderWireApi.Chat),
        ProviderPreset.DeepSeek => new("deepseek", preset, "DeepSeek", "https://api.deepseek.com/v1", ProviderWireApi.Chat),
        ProviderPreset.Xai => new("xai", preset, "xAI / Grok (API)", "https://api.x.ai/v1", ProviderWireApi.Responses),
        ProviderPreset.GrokOAuth => new("grok-oauth", preset, "Grok (OAuth)", "https://api.x.ai/v1", ProviderWireApi.Responses),
        ProviderPreset.Kimi => new("kimi", preset, "Kimi Platform (API)", "https://api.moonshot.ai/v1", ProviderWireApi.Chat),
        ProviderPreset.KimiOAuth => new("kimi-oauth", preset, "Kimi Code (OAuth)", "https://api.kimi.com/coding/v1", ProviderWireApi.Chat),
        ProviderPreset.OpenRouter => new("openrouter", preset, "OpenRouter", "https://openrouter.ai/api/v1", ProviderWireApi.Chat),
        _ => new(customId ?? "custom-" + Guid.NewGuid().ToString("N")[..8], ProviderPreset.Custom, "Custom provider", "", ProviderWireApi.Responses)
    };
    public override string ToString() => Name;
}

/// <summary>A UI-created authorization is bound to this exact provider configuration and one operation kind.</summary>
public sealed record ProviderConsent(string ProviderIdentity, ProviderRequestPurpose Purpose, bool Approved)
{
    public static ProviderConsent Approve(ExternalProvider provider, ProviderRequestPurpose purpose) => new(provider.Identity, purpose, true);
    public void Demand(ExternalProvider provider, ProviderRequestPurpose purpose)
    {
        if (!Approved || ProviderIdentity != provider.Identity || Purpose != purpose)
            throw new UnauthorizedAccessException("Approve this external-provider request and destination before sending data.");
    }
}

public interface IProviderSecretStore
{
    ValueTask<string?> ReadAsync(string key, CancellationToken token = default);
    ValueTask SaveAsync(string key, string secret, CancellationToken token = default);
    ValueTask DeleteAsync(string key, CancellationToken token = default);
}

public sealed class ProviderCredential
{
    public string? ApiKey { get; init; }
    public string? AccessToken { get; init; }
    public string? RefreshToken { get; init; }
    public DateTimeOffset? ExpiresAt { get; init; }
    public string TokenType { get; init; } = "Bearer";
    public override string ToString() => "[protected provider credential]";
}
public sealed class ProviderDeviceChallenge
{
    public required string UserCode { get; init; }
    public required string DeviceCode { get; init; }
    public required Uri VerificationUri { get; init; }
    public required TimeSpan Interval { get; init; }
    public required DateTimeOffset ExpiresAt { get; init; }
    public override string ToString() => "[pending provider authorization]";
}
public sealed class ProviderHttpException(int status, string host, string? errorCode = null)
    : IOException($"{host} returned HTTP {status}" + (errorCode is null ? "." : " (" + errorCode + ")."))
{ public int Status { get; } = status; public string? ErrorCode { get; } = errorCode; }
