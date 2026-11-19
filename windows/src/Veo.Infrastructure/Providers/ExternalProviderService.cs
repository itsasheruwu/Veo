using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Veo.Infrastructure.Providers;

/// <summary>Optional direct-provider HTTP. This is never a workspace transport or hosted service.</summary>
public sealed class ExternalProviderService : IDisposable
{
    private readonly HttpClient http;
    private readonly ConcurrentDictionary<string, ProviderConnectionState> states = new(StringComparer.Ordinal);
    public ProviderOAuthService Authentication { get; }
    public event Action<string, ProviderConnectionState>? StateChanged;
    public ExternalProviderService(IProviderSecretStore secrets, string deviceId, HttpMessageHandler? handler = null,
        TimeProvider? time = null, Func<TimeSpan, CancellationToken, Task>? oauthDelay = null)
    {
        http = new(handler ?? new SocketsHttpHandler { AllowAutoRedirect = false, AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate }) { Timeout = Timeout.InfiniteTimeSpan };
        Authentication = new(http, secrets, deviceId, time, oauthDelay);
        Authentication.StateChanged += SetState;
    }
    public ProviderConnectionState State(string providerId) => states.GetValueOrDefault(providerId, ProviderConnectionState.Disconnected);
    private void SetState(string id, ProviderConnectionState state) { states[id] = state; StateChanged?.Invoke(id, state); }

    public async Task<IReadOnlyList<ExternalModelRecord>> ProbeAsync(ExternalProvider provider, ProviderConsent consent, CancellationToken token = default)
    {
        consent.Demand(provider, ProviderRequestPurpose.Catalog); SetState(provider.Id, ProviderConnectionState.Connecting);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(20));
            using var request = await RequestAsync(provider, HttpMethod.Get, provider.Endpoint("models"), consent, ProviderRequestPurpose.Catalog, timeout.Token);
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            var body = await ProviderHttp.ReadObjectAsync(response, timeout.Token);
            if (!response.IsSuccessStatusCode) throw ProviderHttp.Error(response, body);
            if (body["data"] is not JsonArray rows) throw new InvalidDataException("The provider did not return a model catalog.");
            var known = (provider.Models ?? []).ToDictionary(model => model.UpstreamId, StringComparer.Ordinal);
            var seen = new HashSet<string>(StringComparer.Ordinal); var models = new List<ExternalModelRecord>();
            foreach (var row in rows.OfType<JsonObject>())
            {
                if (ExternalRequestAdapter.String(row["id"]) is not { Length: > 0 } id || !seen.Add(id)) continue;
                var name = ExternalRequestAdapter.String(row["display_name"]) ?? ExternalRequestAdapter.String(row["name"]) ?? id;
                using var metadata = JsonDocument.Parse(row.ToJsonString());
                models.Add(new(provider.Id + "/" + id, id, name, known.TryGetValue(id, out var old) && old.Enabled,
                    Positive(row["context_window"] ?? row["context_length"]), Positive(row["max_context_window"] ?? row["max_context_length"]), metadata.RootElement.Clone()));
            }
            if (models.Count == 0) throw new InvalidDataException("The provider did not list any models for this account. No model names were invented.");
            SetState(provider.Id, ProviderConnectionState.Connected); return models.OrderBy(model => model.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToArray();
        }
        catch (ProviderHttpException error) { SetState(provider.Id, error.Status is 401 or 403 ? ProviderConnectionState.NeedsSignIn : ProviderConnectionState.Failed); throw; }
        catch { if (State(provider.Id) != ProviderConnectionState.NeedsSignIn) SetState(provider.Id, ProviderConnectionState.Failed); throw; }
    }

    public async IAsyncEnumerable<JsonObject> StreamAsync(ExternalProvider provider, JsonElement requestBody,
        ProviderConsent consent, [EnumeratorCancellation] CancellationToken token = default)
    {
        consent.Demand(provider, ProviderRequestPurpose.Inference); var complete = false;
        SetState(provider.Id, ProviderConnectionState.Connecting);
        try
        {
            await foreach (var item in StreamCoreAsync(provider, requestBody, consent, token)) yield return item;
            complete = true;
        }
        finally
        {
            if (!complete && State(provider.Id) != ProviderConnectionState.NeedsSignIn) SetState(provider.Id, ProviderConnectionState.Failed);
        }
    }

    private async IAsyncEnumerable<JsonObject> StreamCoreAsync(ExternalProvider provider, JsonElement requestBody,
        ProviderConsent consent, [EnumeratorCancellation] CancellationToken token)
    {
        consent.Demand(provider, ProviderRequestPurpose.Inference);
        if (!provider.Enabled) throw new InvalidOperationException("Enable this optional provider before sending a prompt.");
        var adapted = ExternalRequestAdapter.Adapt(requestBody, provider); adapted.Body["stream"] = true;
        var model = ExternalRequestAdapter.String(adapted.Body["model"]);
        if (!(provider.Models ?? []).Any(entry => entry.Enabled && entry.UpstreamId == model)) throw new InvalidOperationException("Enable a model from this provider's live catalog before sending a prompt.");
        using var request = await RequestAsync(provider, HttpMethod.Post, provider.Endpoint(provider.WireApi == ProviderWireApi.Responses ? "responses" : "chat/completions"), consent, ProviderRequestPurpose.Inference, token);
        request.Headers.Accept.Clear(); request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        request.Content = new StringContent(adapted.Body.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        if (!response.IsSuccessStatusCode)
        {
            var body = await ProviderHttp.ReadObjectAsync(response, token); SetState(provider.Id, response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden ? ProviderConnectionState.NeedsSignIn : ProviderConnectionState.Failed);
            throw ProviderHttp.Error(response, body);
        }
        if (response.Content.Headers.ContentType?.MediaType != "text/event-stream") throw new InvalidDataException("The provider did not return the requested event stream.");
        SetState(provider.Id, ProviderConnectionState.Connected);
        await using var stream = await response.Content.ReadAsStreamAsync(token);
        var chat = new ChatStreamAdapter(adapted.Restore); var restorer = new ExternalResponseAdapter(adapted.Restore); var completed = false;
        await foreach (var frame in SseReader.ReadAsync(stream, token: token))
        {
            if (frame.Data == "[DONE]")
            {
                if (provider.WireApi == ProviderWireApi.Chat) foreach (var item in chat.Complete()) yield return item;
                else if (!completed) throw new InvalidDataException("The provider closed a Responses stream without response.completed.");
                completed = true; break;
            }
            JsonObject parsed;
            try { parsed = JsonNode.Parse(frame.Data) as JsonObject ?? throw new InvalidDataException("The provider streamed a non-object event."); }
            catch (JsonException) { throw new InvalidDataException("The provider streamed invalid JSON."); }
            if (parsed["error"] is not null || ExternalRequestAdapter.String(parsed["type"]) == "error")
                throw new InvalidDataException("The provider reported an error while streaming. The response is incomplete.");
            if (provider.WireApi == ProviderWireApi.Chat) foreach (var item in chat.Append(parsed)) yield return item;
            else if (restorer.RestoreEvent(parsed) is { } item)
            {
                var type = ExternalRequestAdapter.String(item["type"]) ?? frame.Event;
                if (type == "response.failed") throw new InvalidDataException("The provider reported a failed response.");
                if (type == "response.completed") completed = true;
                yield return item;
            }
        }
        if (!completed)
        {
            if (provider.WireApi == ProviderWireApi.Chat) { foreach (var item in chat.Complete()) yield return item; }
            else throw new InvalidDataException("The provider disconnected before completing its response.");
        }
    }

    private async Task<HttpRequestMessage> RequestAsync(ExternalProvider provider, HttpMethod method, Uri endpoint,
        ProviderConsent consent, ProviderRequestPurpose purpose, CancellationToken token)
    {
        consent.Demand(provider, purpose);
        var secret = await Authentication.AccessTokenAsync(provider, consent, purpose, token);
        var request = new HttpRequestMessage(method, endpoint); Authentication.AddHeaders(request, provider);
        if (provider.Preset == ProviderPreset.Anthropic)
        { request.Headers.Add("x-api-key", secret); request.Headers.Add("anthropic-version", "2023-06-01"); }
        else request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", secret);
        return request;
    }
    private static long? Positive(JsonNode? node) => node is JsonValue value && value.TryGetValue<long>(out var number) && number > 0 ? number : null;
    public void Dispose() => http.Dispose();
}
