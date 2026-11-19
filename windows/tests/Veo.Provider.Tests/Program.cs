using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Veo.Infrastructure.Providers;

var passed = new List<string>();
void Check(bool condition, string name) { if (!condition) throw new Exception("FAILED " + name); passed.Add(name); Console.WriteLine("PASS " + name); }
async Task<Exception> Refuses(Func<Task> action, string name)
{ try { await action(); } catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or OperationCanceledException) { Check(true, name); return error; } throw new Exception("FAILED accepted " + name); }
static JsonElement Json(string json) { using var doc = JsonDocument.Parse(json); return doc.RootElement.Clone(); }
static HttpResponseMessage Body(string json, HttpStatusCode status = HttpStatusCode.OK) => new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
var root = Path.Combine(Path.GetTempPath(), "Veo.Provider.Tests-" + Guid.NewGuid().ToString("N"));
var config = new ProviderConfigurationStore(root); var secrets = new MemorySecrets();
var provider = ExternalProvider.Create(ProviderPreset.OpenRouter) with { Enabled = true };
await config.SaveAsync([provider]);
Check((await config.LoadAsync()).Single() == provider, "nonsecret provider configuration round-trips without credentials");
await Refuses(() => config.SaveAsync([provider with { BaseUrl = "http://insecure.invalid/v1" }]), "insecure provider URL refused");
await Refuses(() => config.SaveAsync([provider with { BaseUrl = "https://user:password@provider.invalid/v1" }]), "embedded credential URL refused");
Check((await config.LoadAsync()).Single() == provider, "invalid configuration save preserves prior provider file");

var transport = new FakeTransport((request, body, token) => Task.FromResult(Body("""{"data":[{"id":"vendor/fixture-model","name":"Fixture model","context_length":12345,"future_field":true},{"id":"vendor/fixture-model"}]}""")));
using var service = new ExternalProviderService(secrets, "fixture-device", transport);
await service.Authentication.SaveApiKeyAsync(provider, "fixture-key-redacted");
Check(service.State(provider.Id) == ProviderConnectionState.Disconnected, "saving an API key does not claim a successful connection");
await Refuses(async () => { await service.ProbeAsync(provider, new(provider.Identity, ProviderRequestPurpose.Catalog, false)); }, "catalog request requires explicit consent");
await Refuses(async () => { await service.ProbeAsync(provider, ProviderConsent.Approve(provider, ProviderRequestPurpose.Inference)); }, "consent purpose cannot be reused for a different action");
Check(transport.Requests.Count == 0, "denied consent sends no network traffic");
var models = await service.ProbeAsync(provider, ProviderConsent.Approve(provider, ProviderRequestPurpose.Catalog));
Check(models.Count == 1 && models[0].UpstreamId == "vendor/fixture-model" && !models[0].Enabled, "live catalog deduplicates IDs and leaves discovered models disabled");
Check(models[0].ContextWindow == 12345 && models[0].MaximumContextWindow is null && models[0].Metadata.GetProperty("future_field").GetBoolean(), "catalog preserves reported context and unknown metadata without invented limits");
Check(transport.Requests[0].Uri.AbsolutePath.EndsWith("/models") && transport.Requests[0].Headers.ContainsKey("Authorization")
    && !transport.Requests[0].Uri.ToString().Contains("fixture-key"), "API credentials are injected as headers to the configured model endpoint");
Check(service.State(provider.Id) == ProviderConnectionState.Connected, "successful catalog response establishes connected state");
var changedOrigin = provider with { BaseUrl = "https://other.invalid/v1" };
await Refuses(async () => { await service.ProbeAsync(changedOrigin, ProviderConsent.Approve(provider, ProviderRequestPurpose.Catalog)); }, "consent cannot cross provider origin/configuration changes");
Check(!await service.Authentication.HasCredentialAsync(changedOrigin), "provider credentials are bound to the saved endpoint identity");

using var deniedService = new ExternalProviderService(secrets, "fixture-device", new FakeTransport((r, b, t) => Task.FromResult(Body("""{"error":{"code":"invalid_api_key","message":"fixture-key-redacted private prompt text"}}""", HttpStatusCode.Unauthorized))));
var denied = await Refuses(async () => { await deniedService.ProbeAsync(provider, ProviderConsent.Approve(provider, ProviderRequestPurpose.Catalog)); }, "provider HTTP authorization failure is surfaced");
Check(!denied.Message.Contains("fixture-key") && !denied.Message.Contains("private prompt") && deniedService.State(provider.Id) == ProviderConnectionState.NeedsSignIn,
    "provider errors redact response bodies and clear connected status");
var redirect = new FakeTransport((r, b, t) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Redirect) { Headers = { Location = new Uri("https://unrelated.invalid/") }, Content = new StringContent("{}") }));
using var redirectService = new ExternalProviderService(secrets, "fixture-device", redirect);
await Refuses(async () => { await redirectService.ProbeAsync(provider, ProviderConsent.Approve(provider, ProviderRequestPurpose.Catalog)); }, "provider redirects do not silently forward a connection");
Check(redirect.Requests.Count == 1, "redirect response produces one credentialed request only");

var responsesProvider = ExternalProvider.Create(ProviderPreset.Xai);
var request = Json("""
    {"model":"xai/vendor/fixture-model","reasoning":{"effort":"max"},"tools":[
      {"type":"namespace","name":"workspace","tools":[{"type":"custom","name":"apply_patch","description":"Edit text","format":{"syntax":"grammar","definition":"patch := raw-text"}}]},
      {"type":"function","name":"read","parameters":{"anyOf":[{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]},{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"}},"required":["path","line"]}]}}
    ],"tool_choice":{"type":"custom","namespace":"workspace","name":"apply_patch"},"input":[
      {"type":"message","role":"developer","content":[{"type":"input_text","text":"Instructions"}]},
      {"id":"non-function-id","type":"custom_tool_call","namespace":"workspace","name":"apply_patch","call_id":"call1","input":"raw $ patch\nexact bytes"},
      {"type":"custom_tool_call_output","call_id":"call1","output":"done"}
    ]}
    """);
var adapted = ExternalRequestAdapter.Adapt(request, responsesProvider);
Check(adapted.Body["model"]!.GetValue<string>() == "vendor/fixture-model" && adapted.Body["reasoning"]!["effort"]!.GetValue<string>() == "xhigh", "request adapter preserves upstream model path and maps Maximum effort");
Check(adapted.Restore.Tools["workspace__apply_patch"].Custom && adapted.Body["tools"]![0]!["name"]!.GetValue<string>() == "workspace__apply_patch", "namespaced custom tool identity survives wire flattening");
Check(adapted.Body["tools"]![1]!["parameters"]!["required"]!.AsArray().Count == 1 && adapted.Body["tools"]![1]!["parameters"]!["properties"]!["line"] is not null,
    "object-root tool unions preserve properties and shared required fields");
Check(adapted.Body["input"]![0]!["role"]!.GetValue<string>() == "system" && adapted.Body["input"]![1]!["id"] is null && adapted.Body["input"]![1]!["name"]!.GetValue<string>() == "workspace__apply_patch",
    "request history converts developer/custom items while retaining call identity");
Check(adapted.Body["tool_choice"]!["name"]!.GetValue<string>() == "workspace__apply_patch", "forced custom-tool choice follows namespace mapping");
var chatAdapted = ExternalRequestAdapter.Adapt(request, responsesProvider with { WireApi = ProviderWireApi.Chat });
Check(chatAdapted.Body["messages"]!.AsArray().Count == 3 && chatAdapted.Body["tools"]![0]!["function"]!["name"]!.GetValue<string>() == "workspace__apply_patch", "Responses history and tools convert to native Chat Completions shape");
Check(chatAdapted.Body["tool_choice"]!["function"]!["name"]!.GetValue<string>() == "workspace__apply_patch", "forced tool choice survives Chat conversion");

var restore = new ExternalResponseAdapter(adapted.Restore);
var added = restore.RestoreEvent(JsonNode.Parse("""{"type":"response.output_item.added","item":{"id":"item1","type":"function_call","name":"workspace__apply_patch","call_id":"call1","arguments":""}}""")!.AsObject());
Check(added!["item"]!["type"]!.GetValue<string>() == "custom_tool_call" && added["item"]!["namespace"]!.GetValue<string>() == "workspace", "provider tool item restores original namespace and custom type");
Check(restore.RestoreEvent(JsonNode.Parse("""{"type":"response.function_call_arguments.delta","item_id":"item1","delta":"{\"input\":\"raw $ patch\\nexact bytes\"}"}""")!.AsObject()) is null,
    "custom-tool JSON fragments are buffered instead of exposed as raw freeform input");
var done = restore.RestoreEvent(JsonNode.Parse("""{"type":"response.function_call_arguments.done","item_id":"item1"}""")!.AsObject());
Check(done!["type"]!.GetValue<string>() == "response.custom_tool_call_input.done" && done["input"]!.GetValue<string>() == "raw $ patch\nexact bytes", "streamed custom tool input is restored byte-for-byte");

var sseText = ": keepalive\r\nid: evt1\r\nevent: response.delta\r\ndata: {\"text\":\"🦊\"}\r\ndata: second line\r\n\r\n";
var events = new List<SseEvent>();
await foreach (var item in SseReader.ReadAsync(new ByteChunks(Encoding.UTF8.GetBytes(sseText)))) events.Add(item);
Check(events.Single().Data == "{\"text\":\"🦊\"}\nsecond line" && events[0].Event == "response.delta" && events[0].Id == "evt1", "SSE handles split UTF8, CRLF, comments, IDs and multiline payloads");
await Refuses(async () => { await foreach (var _ in SseReader.ReadAsync(new MemoryStream(Encoding.UTF8.GetBytes("data: " + new string('x', 1000) + "\n\n")), 100)) { } }, "SSE rejects an oversized line before unbounded accumulation");

var chat = new ChatStreamAdapter(adapted.Restore); var rewritten = new List<JsonObject>();
rewritten.AddRange(chat.Append(JsonNode.Parse("""{"id":"fixture-response","choices":[{"index":0,"delta":{"reasoning_content":"Reasoning "}}]}""")!.AsObject()));
rewritten.AddRange(chat.Append(JsonNode.Parse("""{"id":"fixture-response","choices":[{"index":0,"delta":{"content":"Answer 🦊","tool_calls":[{"index":0,"id":"upstream-call","function":{"name":"workspace__apply_patch","arguments":"{\"input\":"}}]}}]}""")!.AsObject()));
rewritten.AddRange(chat.Append(JsonNode.Parse("""{"id":"fixture-response","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"exact patch\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":7,"completion_tokens":9,"total_tokens":16}}""")!.AsObject()));
rewritten.AddRange(chat.Complete());
var final = rewritten.Last()["response"]!;
Check(final["output"]!.AsArray().Select(node => node!["type"]!.GetValue<string>()).SequenceEqual(["reasoning", "message", "custom_tool_call"]), "Chat stream keeps reasoning, message and tool output item-scoped in arrival order");
Check(final["output"]![2]!["call_id"]!.GetValue<string>() == "upstream-call" && final["output"]![2]!["input"]!.GetValue<string>() == "exact patch", "Chat tool-call fragments retain upstream call ID and exact custom input");
Check(final["usage"]!["input_tokens"]!.GetValue<int>() == 7 && final["usage"]!["output_tokens"]!.GetValue<int>() == 9, "stream usage maps provider-reported values without invented balances");
await Refuses(() => Task.Run(() => new ChatStreamAdapter(new()).Complete()), "truncated Chat stream cannot become a fake completed response");

provider = provider with { Models = models.Select(model => model with { Enabled = true }).ToArray() };
var chatTransport = new FakeTransport((r, b, t) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("data: {\"id\":\"stream-id\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"test result\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n", Encoding.UTF8, "text/event-stream") }));
using var streamService = new ExternalProviderService(secrets, "fixture-device", chatTransport);
var streamed = new List<JsonObject>();
await foreach (var item in streamService.StreamAsync(provider, Json("""{"model":"openrouter/vendor/fixture-model","input":"Explicit test prompt"}"""), ProviderConsent.Approve(provider, ProviderRequestPurpose.Inference))) streamed.Add(item);
Check(streamed.Last()["type"]!.GetValue<string>() == "response.completed" && chatTransport.Requests.Single().Uri.AbsolutePath.EndsWith("/chat/completions"), "direct Chat HTTP streaming completes through the configured endpoint");
Check(!chatTransport.Requests.Single().Body.Contains("fixture-key") && JsonNode.Parse(chatTransport.Requests.Single().Body)!["model"]!.GetValue<string>() == "vendor/fixture-model", "direct request body excludes credentials and retains vendor model identity");
await Refuses(async () => { await foreach (var _ in streamService.StreamAsync(provider with { Enabled = false }, Json("""{"model":"openrouter/vendor/fixture-model","input":"Do not send"}"""), ProviderConsent.Approve(provider with { Enabled = false }, ProviderRequestPurpose.Inference))) { } }, "disabled optional provider cannot send inference");

var oauthProvider = ExternalProvider.Create(ProviderPreset.GrokOAuth); var oauthSecrets = new MemorySecrets(); var polls = 0; var delays = new List<TimeSpan>();
var oauthTransport = new FakeTransport((r, b, t) =>
{
    if (r.RequestUri!.AbsolutePath.EndsWith("/device/code")) return Task.FromResult(Body("""{"user_code":"SAFE-CODE","device_code":"redacted-device-code","verification_uri":"https://accounts.x.ai/oauth2/device","interval":2,"expires_in":600}"""));
    polls++;
    return Task.FromResult(polls switch { 1 => Body("""{"error":"authorization_pending"}""", HttpStatusCode.BadRequest), 2 => Body("""{"error":"slow_down"}""", HttpStatusCode.BadRequest), _ => Body("""{"access_token":"redacted-access","refresh_token":"redacted-refresh","expires_in":3600,"token_type":"Bearer"}""") });
});
using var oauthService = new ExternalProviderService(oauthSecrets, "fixture-device", oauthTransport, oauthDelay: (duration, token) => { token.ThrowIfCancellationRequested(); delays.Add(duration); return Task.CompletedTask; });
var challenge = await oauthService.Authentication.StartAsync(oauthProvider, ProviderConsent.Approve(oauthProvider, ProviderRequestPurpose.Authentication));
await oauthService.Authentication.CompleteAsync(oauthProvider, challenge, ProviderConsent.Approve(oauthProvider, ProviderRequestPurpose.Authentication));
Check(challenge.UserCode == "SAFE-CODE" && delays.Select(d => d.TotalSeconds).SequenceEqual([2d, 2d, 7d]), "device sign-in obeys pending and slow-down polling intervals");
Check(await oauthService.Authentication.HasCredentialAsync(oauthProvider) && oauthService.State(oauthProvider.Id) == ProviderConnectionState.Connected, "successful device sign-in stores token only in secret store and marks connected");
await oauthService.Authentication.DisconnectAsync(oauthProvider);
Check(!await oauthService.Authentication.HasCredentialAsync(oauthProvider) && oauthService.State(oauthProvider.Id) == ProviderConnectionState.Disconnected, "provider disconnect removes local protected tokens and connection state");

await oauthSecrets.SaveAsync(oauthProvider.CredentialKey, JsonSerializer.Serialize(new ProviderCredential { AccessToken = "expired-redacted", RefreshToken = "redacted-refresh", ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1) }));
using var refreshFailed = new ExternalProviderService(oauthSecrets, "fixture-device", new FakeTransport((r, b, t) => Task.FromResult(Body("""{"error":"invalid_grant","error_description":"redacted-refresh must never appear"}""", HttpStatusCode.BadRequest))));
var refreshError = await Refuses(async () => { await refreshFailed.Authentication.AccessTokenAsync(oauthProvider, ProviderConsent.Approve(oauthProvider, ProviderRequestPurpose.Catalog), ProviderRequestPurpose.Catalog); }, "expired OAuth credential refresh failure is surfaced");
Check(refreshFailed.State(oauthProvider.Id) == ProviderConnectionState.NeedsSignIn && !refreshError.Message.Contains("redacted-refresh"), "refresh failure cannot retain a connected badge or expose token response text");

var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
using var raceService = new ExternalProviderService(oauthSecrets, "fixture-device", new FakeTransport(async (r, b, t) => { started.SetResult(); await release.Task; return Body("""{"access_token":"new-redacted-access","refresh_token":"new-redacted-refresh","expires_in":3600}"""); }));
var refreshing = raceService.Authentication.AccessTokenAsync(oauthProvider, ProviderConsent.Approve(oauthProvider, ProviderRequestPurpose.Catalog), ProviderRequestPurpose.Catalog);
await started.Task; await raceService.Authentication.DisconnectAsync(oauthProvider); release.SetResult();
await Refuses(async () => { await refreshing; }, "disconnect invalidates an in-flight OAuth refresh");
Check(!await raceService.Authentication.HasCredentialAsync(oauthProvider), "late token refresh cannot recreate revoked local credentials");

Console.WriteLine(JsonSerializer.Serialize(new { Passed = passed.Count, Root = root, Scenarios = passed }));

sealed class MemorySecrets : IProviderSecretStore
{
    private readonly Dictionary<string, string> data = new(StringComparer.Ordinal);
    public ValueTask<string?> ReadAsync(string key, CancellationToken token = default) { lock (data) return ValueTask.FromResult(data.GetValueOrDefault(key)); }
    public ValueTask SaveAsync(string key, string secret, CancellationToken token = default) { lock (data) data[key] = secret; return ValueTask.CompletedTask; }
    public ValueTask DeleteAsync(string key, CancellationToken token = default) { lock (data) data.Remove(key); return ValueTask.CompletedTask; }
}
sealed record Captured(Uri Uri, Dictionary<string, string> Headers, string Body);
sealed class FakeTransport(Func<HttpRequestMessage, string, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
{
    public List<Captured> Requests { get; } = [];
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(token);
        Requests.Add(new(request.RequestUri!, request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value)), body));
        var result = await respond(request, body, token); result.RequestMessage = request; return result;
    }
}
sealed class ByteChunks(byte[] bytes) : MemoryStream(bytes)
{
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default) => base.ReadAsync(buffer[..Math.Min(1, buffer.Length)], token);
}
