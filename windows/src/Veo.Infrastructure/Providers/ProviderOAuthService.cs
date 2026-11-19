using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Veo.Infrastructure.Providers;

public sealed record ProviderOAuthDescriptor(Uri DeviceEndpoint, Uri TokenEndpoint, string ClientId, string? Scope)
{
    public static ProviderOAuthDescriptor For(ExternalProvider provider) => provider.Preset switch
    {
        ProviderPreset.KimiOAuth => new(new("https://auth.kimi.com/api/oauth/device_authorization"), new("https://auth.kimi.com/api/oauth/token"), "17e5f671-d194-4dfb-9706-5516cb48c098", null),
        ProviderPreset.GrokOAuth => new(new("https://auth.x.ai/oauth2/device/code"), new("https://auth.x.ai/oauth2/token"), "b1a00492-073a-47ea-816f-4c329264a828", "openid profile email offline_access grok-cli:access api:access"),
        _ => throw new NotSupportedException("This provider does not expose the supported device-code sign-in flow.")
    };
}

public sealed class ProviderOAuthService
{
    private readonly HttpClient http;
    private readonly IProviderSecretStore secrets;
    private readonly string deviceId;
    private readonly TimeProvider time;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;
    private readonly ConcurrentDictionary<string, SemaphoreSlim> gates = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, long> epochs = new(StringComparer.Ordinal);
    public event Action<string, ProviderConnectionState>? StateChanged;
    public ProviderOAuthService(HttpClient http, IProviderSecretStore secrets, string deviceId, TimeProvider? time = null,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    { this.http = http; this.secrets = secrets; this.deviceId = deviceId; this.time = time ?? TimeProvider.System; this.delay = delay ?? ((duration, token) => Task.Delay(duration, token)); }

    public async Task SaveApiKeyAsync(ExternalProvider provider, string key, CancellationToken token = default)
    {
        if (provider.IsOAuth) throw new InvalidOperationException("Use device sign-in for this provider.");
        key = key.Trim(); ValidateHeaderSecret(key);
        epochs.AddOrUpdate(provider.CredentialKey, 1, (_, value) => value + 1);
        await secrets.SaveAsync(provider.CredentialKey, JsonSerializer.Serialize(new ProviderCredential { ApiKey = key }), token);
        StateChanged?.Invoke(provider.Id, ProviderConnectionState.Disconnected); // Saving a key is not a successful connection check.
    }
    public async Task DisconnectAsync(ExternalProvider provider, CancellationToken token = default)
    {
        epochs.AddOrUpdate(provider.CredentialKey, 1, (_, value) => value + 1);
        await secrets.DeleteAsync(provider.CredentialKey, token);
        StateChanged?.Invoke(provider.Id, ProviderConnectionState.Disconnected);
    }
    public async Task<bool> HasCredentialAsync(ExternalProvider provider, CancellationToken token = default) => await secrets.ReadAsync(provider.CredentialKey, token) is not null;

    public async Task<string> AccessTokenAsync(ExternalProvider provider, ProviderConsent consent,
        ProviderRequestPurpose purpose, CancellationToken token = default)
    {
        consent.Demand(provider, purpose);
        var gate = gates.GetOrAdd(provider.CredentialKey, _ => new(1, 1)); await gate.WaitAsync(token);
        try
        {
            var epoch = epochs.GetOrAdd(provider.CredentialKey, 0);
            var raw = await secrets.ReadAsync(provider.CredentialKey, token);
            var credential = raw is null ? null : JsonSerializer.Deserialize<ProviderCredential>(raw);
            if (credential is null) { StateChanged?.Invoke(provider.Id, ProviderConnectionState.NeedsSignIn); throw new InvalidOperationException("Connect this provider before sending a request."); }
            if (!provider.IsOAuth)
            { var key = credential.ApiKey ?? throw new InvalidOperationException("This provider has no saved API key."); ValidateHeaderSecret(key); return key; }
            if (credential.AccessToken is { Length: > 0 } access && credential.ExpiresAt > time.GetUtcNow().AddSeconds(60)) { ValidateHeaderSecret(access); return access; }
            if (string.IsNullOrEmpty(credential.RefreshToken)) { StateChanged?.Invoke(provider.Id, ProviderConnectionState.NeedsSignIn); throw new InvalidOperationException("Sign in again; the provider did not supply a usable refresh token."); }
            var descriptor = ProviderOAuthDescriptor.For(provider);
            try
            {
                var refreshed = DecodeToken(await FormAsync(provider, descriptor.TokenEndpoint, new()
                { ["grant_type"] = "refresh_token", ["refresh_token"] = credential.RefreshToken, ["client_id"] = descriptor.ClientId }, token), credential.RefreshToken);
                if (epochs.GetOrAdd(provider.CredentialKey, 0) != epoch) throw new OperationCanceledException("Provider sign-in changed while refreshing credentials.");
                await secrets.SaveAsync(provider.CredentialKey, JsonSerializer.Serialize(refreshed), token);
                return refreshed.AccessToken!;
            }
            catch
            {
                StateChanged?.Invoke(provider.Id, ProviderConnectionState.NeedsSignIn); throw;
            }
        }
        finally { gate.Release(); }
    }

    public async Task<ProviderDeviceChallenge> StartAsync(ExternalProvider provider, ProviderConsent consent, CancellationToken token = default)
    {
        consent.Demand(provider, ProviderRequestPurpose.Authentication);
        var descriptor = ProviderOAuthDescriptor.For(provider); var form = new Dictionary<string, string> { ["client_id"] = descriptor.ClientId };
        if (descriptor.Scope is not null) form["scope"] = descriptor.Scope;
        var result = await FormAsync(provider, descriptor.DeviceEndpoint, form, token);
        var code = ExternalRequestAdapter.String(result["user_code"]); var device = ExternalRequestAdapter.String(result["device_code"]);
        var uriText = ExternalRequestAdapter.String(result["verification_uri_complete"]) ?? ExternalRequestAdapter.String(result["verification_uri"]);
        if (string.IsNullOrWhiteSpace(code) || string.IsNullOrWhiteSpace(device) || !Uri.TryCreate(uriText, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.UserInfo.Length > 0)
            throw new InvalidDataException("The provider returned an invalid device sign-in challenge.");
        var expires = result["expires_in"]?.GetValue<int>() ?? 600; if (expires <= 0) throw new InvalidDataException("The provider returned an expired sign-in challenge.");
        return new() { UserCode = code, DeviceCode = device, VerificationUri = uri, Interval = TimeSpan.FromSeconds(Math.Max(2, result["interval"]?.GetValue<int>() ?? 5)), ExpiresAt = time.GetUtcNow().AddSeconds(expires) };
    }

    public async Task CompleteAsync(ExternalProvider provider, ProviderDeviceChallenge challenge, ProviderConsent consent, CancellationToken token = default)
    {
        consent.Demand(provider, ProviderRequestPurpose.Authentication); var descriptor = ProviderOAuthDescriptor.For(provider);
        var epoch = epochs.GetOrAdd(provider.CredentialKey, 0); var interval = challenge.Interval;
        StateChanged?.Invoke(provider.Id, ProviderConnectionState.Connecting);
        try
        {
            while (time.GetUtcNow() < challenge.ExpiresAt)
            {
                await delay(interval, token); token.ThrowIfCancellationRequested();
                using var pollingTimeout = CancellationTokenSource.CreateLinkedTokenSource(token); pollingTimeout.CancelAfter(TimeSpan.FromSeconds(20));
                using var response = await FormResponseAsync(provider, descriptor.TokenEndpoint, new()
                { ["grant_type"] = "urn:ietf:params:oauth:grant-type:device_code", ["device_code"] = challenge.DeviceCode, ["client_id"] = descriptor.ClientId }, pollingTimeout.Token);
                var result = await ProviderHttp.ReadObjectAsync(response, pollingTimeout.Token); var error = ExternalRequestAdapter.String(result["error"]);
                if (response.IsSuccessStatusCode && result["access_token"] is not null)
                {
                    var credential = DecodeToken(result, null);
                    if (epochs.GetOrAdd(provider.CredentialKey, 0) != epoch) throw new OperationCanceledException("Provider connection was removed while sign-in was pending.");
                    await secrets.SaveAsync(provider.CredentialKey, JsonSerializer.Serialize(credential), token);
                    StateChanged?.Invoke(provider.Id, ProviderConnectionState.Connected); return;
                }
                if (error == "authorization_pending") continue;
                if (error == "slow_down") { interval += TimeSpan.FromSeconds(5); continue; }
                if (error == "access_denied") throw new InvalidOperationException("Provider sign-in was denied.");
                if (error == "expired_token") throw new InvalidOperationException("The provider sign-in code expired. Start again.");
                throw ProviderHttp.Error(response, result);
            }
            throw new InvalidOperationException("The provider sign-in code expired. Start again.");
        }
        catch { StateChanged?.Invoke(provider.Id, ProviderConnectionState.Disconnected); throw; }
    }

    private ProviderCredential DecodeToken(JsonObject result, string? previousRefresh)
    {
        var access = ExternalRequestAdapter.String(result["access_token"]);
        if (string.IsNullOrEmpty(access)) throw new InvalidDataException("The provider did not return a valid access token.");
        ValidateHeaderSecret(access);
        var seconds = result["expires_in"]?.GetValue<int>() ?? 3600;
        if (seconds <= 0) throw new InvalidDataException("The provider returned an expired access token.");
        return new() { AccessToken = access, RefreshToken = ExternalRequestAdapter.String(result["refresh_token"]) ?? previousRefresh,
            ExpiresAt = time.GetUtcNow().AddSeconds(seconds), TokenType = ExternalRequestAdapter.String(result["token_type"]) ?? "Bearer" };
    }
    private async Task<JsonObject> FormAsync(ExternalProvider provider, Uri endpoint, Dictionary<string, string> form, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(20));
        using var response = await FormResponseAsync(provider, endpoint, form, timeout.Token);
        var value = await ProviderHttp.ReadObjectAsync(response, timeout.Token);
        if (!response.IsSuccessStatusCode) throw ProviderHttp.Error(response, value); return value;
    }
    private async Task<HttpResponseMessage> FormResponseAsync(ExternalProvider provider, Uri endpoint, Dictionary<string, string> form, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(20));
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint) { Content = new FormUrlEncodedContent(form) };
        AddHeaders(request, provider); return await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
    }
    private static void ValidateHeaderSecret(string secret)
    {
        if (secret.Length == 0 || secret.Any(character => character < '!' || character > '~'))
            throw new ArgumentException("The provider credential contains invalid header characters. Re-enter the API key or sign in again.");
    }
    internal void AddHeaders(HttpRequestMessage request, ExternalProvider provider)
    {
        request.Headers.UserAgent.ParseAdd("Veo/0.1.0"); request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (provider.Preset != ProviderPreset.KimiOAuth) return;
        request.Headers.Add("X-Msh-Platform", "veo"); request.Headers.Add("X-Msh-Version", "0.1.0");
        request.Headers.Add("X-Msh-Device-Name", "Windows"); request.Headers.Add("X-Msh-Device-Model", "Windows");
        request.Headers.Add("X-Msh-Os-Version", Environment.OSVersion.Version.ToString()); request.Headers.Add("X-Msh-Device-Id", deviceId);
    }
}

internal static class ProviderHttp
{
    public static async Task<JsonObject> ReadObjectAsync(HttpResponseMessage response, CancellationToken token, int maximum = 2 * 1024 * 1024)
    {
        if (response.Content.Headers.ContentLength > maximum) throw new InvalidDataException("The provider response exceeds the supported bound.");
        await using var stream = await response.Content.ReadAsStreamAsync(token); using var output = new MemoryStream(); var buffer = new byte[8192];
        while (await stream.ReadAsync(buffer, token) is var count && count > 0)
        { if (output.Length + count > maximum) throw new InvalidDataException("The provider response exceeds the supported bound."); await output.WriteAsync(buffer.AsMemory(0, count), token); }
        try { return JsonNode.Parse(output.ToArray()) as JsonObject ?? throw new InvalidDataException("The provider response is not a JSON object."); }
        catch (JsonException) { throw new InvalidDataException("The provider returned unreadable JSON."); }
    }
    public static ProviderHttpException Error(HttpResponseMessage response, JsonObject? body = null)
    {
        var code = ExternalRequestAdapter.String(body?["error"] is JsonObject detail ? detail["code"] ?? detail["type"] : body?["error"]);
        if (code is not null && !Regex.IsMatch(code, "^[a-zA-Z0-9_]{1,64}$", RegexOptions.CultureInvariant)) code = null;
        return new((int)response.StatusCode, response.RequestMessage?.RequestUri?.Host ?? "Provider", code);
    }
}
