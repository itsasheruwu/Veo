using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Veo.Infrastructure.Providers;

/// <summary>An app-owned inference adapter, never an app-server or conversation owner.</summary>
public sealed class LocalProviderForwarder : IAsyncDisposable
{
    public const int MaximumBodyBytes = 8 * 1024 * 1024;
    readonly Func<ExternalProvider, JsonElement, ProviderConsent, CancellationToken, IAsyncEnumerable<JsonObject>> stream;
    readonly ConcurrentDictionary<string, Route> routes = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<int, TcpClient> clients = new();
    readonly ConcurrentDictionary<int, Task> requests = new();
    readonly ConcurrentBag<CancellationTokenSource> retired = [];
    readonly CancellationTokenSource lifetime = new();
    readonly SemaphoreSlim capacity = new(8, 8);
    readonly byte[] capability = RandomNumberGenerator.GetBytes(32);
    TcpListener? listener;
    Task? accepting;
    int serial;
    bool disposed;
    sealed record Route(ExternalProvider Provider, ProviderConsent Consent, CancellationTokenSource Lifetime);
    public string EnvironmentKey { get; } = "VEO_LOOPBACK_TOKEN_" + Guid.NewGuid().ToString("N").ToUpperInvariant();
    public int? Port => listener?.LocalEndpoint is IPEndPoint endpoint ? endpoint.Port : null;
    public IReadOnlyDictionary<string, string> EnvironmentOverrides => new Dictionary<string, string> { [EnvironmentKey] = Convert.ToHexString(capability) };
    public LocalProviderForwarder(ExternalProviderService service) : this(service.StreamAsync) { }
    public LocalProviderForwarder(Func<ExternalProvider, JsonElement, ProviderConsent, CancellationToken, IAsyncEnumerable<JsonObject>> stream) => this.stream = stream;

    public IReadOnlyDictionary<string, Uri> Start(IReadOnlyList<ExternalProvider> providers, IReadOnlyDictionary<string, ProviderConsent> approvals)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (listener is not null) throw new InvalidOperationException("This forwarder already has an immutable launch snapshot. Reconnect to apply another provider configuration.");
        if (providers.Count > 64 || providers.Sum(p => p.Models?.Length ?? 0) > 4096) throw new ArgumentException("The external provider catalog exceeds its budget.");
        foreach (var provider in providers.Where(p => p.Enabled && p.Models?.Any(m => m.Enabled) == true))
        {
            _ = provider.BaseUri;
            if (provider.Id.Length is 0 or >64 || provider.Id.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '-')) throw new ArgumentException("Invalid provider route identity.");
            if (!approvals.TryGetValue(provider.Id, out var approval)) throw new UnauthorizedAccessException("This provider has no explicit inference approval.");
            approval.Demand(provider, ProviderRequestPurpose.Inference);
            var snapshot = provider with { Models = provider.Models!.ToArray() };
            if (!routes.TryAdd(provider.Id, new(snapshot, approval, CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token)))) throw new ArgumentException("Duplicate provider route.");
        }
        if (routes.IsEmpty) return new Dictionary<string, Uri>();
        listener = new TcpListener(IPAddress.Loopback, 0); listener.Start(8); accepting = AcceptAsync();
        return routes.Keys.ToDictionary(id => id, id => new Uri($"http://127.0.0.1:{Port}/p/{id}/"), StringComparer.Ordinal);
    }
    public void DisableProvider(string id)
    {
        if (routes.TryRemove(id, out var route)) { route.Lifetime.Cancel(); retired.Add(route.Lifetime); }
    }
    async Task AcceptAsync()
    {
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                var client = await listener!.AcceptTcpClientAsync(lifetime.Token);
                if (!await capacity.WaitAsync(0, lifetime.Token)) { client.Dispose(); continue; }
                var id = Interlocked.Increment(ref serial); clients[id] = client;
                var request = HandleAsync(client, id); requests[id] = request;
                _ = request.ContinueWith(_ => requests.TryRemove(id, out var ignored), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            }
        }
        catch (Exception error) when (error is OperationCanceledException or SocketException or ObjectDisposedException) { }
    }
    async Task HandleAsync(TcpClient client, int id)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); deadline.CancelAfter(TimeSpan.FromMinutes(5));
        var token = deadline.Token; var started = false; Task? disconnected = null;
        CancellationTokenSource? operation = null;
        var network = client.GetStream();
        using (client)
        try
        {
            using var headerDeadline = CancellationTokenSource.CreateLinkedTokenSource(token); headerDeadline.CancelAfter(TimeSpan.FromSeconds(15));
            var request = await ReadRequestAsync(network, headerDeadline.Token);
            if (request.Method != "POST" || request.Headers.ContainsKey("origin") || request.Headers.ContainsKey("transfer-encoding") || request.Headers.ContainsKey("upgrade")) throw new Rejected(400, "unsupported_request");
            if (!request.Headers.TryGetValue("host", out var host) || host != "127.0.0.1:" + Port) throw new Rejected(403, "invalid_host");
            if (!request.Headers.TryGetValue("authorization", out var authorization) || !Authorize(authorization)) throw new Rejected(401, "loopback_authorization_required");
            var parts = request.Target.Split('/');
            if (parts.Length != 4 || parts[0] != "" || parts[1] != "p" || parts[3] != "responses" || !routes.TryGetValue(parts[2], out var route)) throw new Rejected(404, "unknown_provider_route");
            operation = CancellationTokenSource.CreateLinkedTokenSource(token, route.Lifetime.Token);
            token = operation.Token;
            using var document = JsonDocument.Parse(request.Body);
            if (document.RootElement.ValueKind != JsonValueKind.Object || !document.RootElement.TryGetProperty("model", out var modelValue) || modelValue.ValueKind != JsonValueKind.String) throw new Rejected(400, "model_required");
            var model = modelValue.GetString();
            if (!route.Provider.Models!.Any(m => m.Enabled && (m.Id == model || m.UpstreamId == model))) throw new Rejected(403, "model_not_enabled");
            if (document.RootElement.TryGetProperty("stream", out var streaming) && streaming.ValueKind != JsonValueKind.True) throw new Rejected(400, "stream_required");
            var body = document.RootElement.Clone();
            disconnected = WatchDisconnectAsync(network, operation);
            await using var events = stream(route.Provider, body, route.Consent, token).GetAsyncEnumerator(token);
            // Resolve authentication and the first upstream event before sending a successful status.
            if (!await events.MoveNextAsync()) throw new Rejected(502, "empty_provider_stream");
            await network.WriteAsync("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"u8.ToArray(), token); started = true;
            long bytes = 0; var count = 0;
            do
            {
                var item = events.Current;
                var type = item["type"]?.GetValue<string>() ?? "message";
                if (type.Length > 128 || type.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('.' or '_' or '-'))) throw new InvalidDataException("The provider returned an invalid event type.");
                var json = item.ToJsonString();
                if (json.Length > 2 * 1024 * 1024 || ++count > 100000) throw new InvalidDataException("The provider event exceeded its stream budget.");
                var frame = Encoding.UTF8.GetBytes("event: " + type + "\ndata: " + json + "\n\n"); bytes += frame.Length;
                if (bytes > 128L * 1024 * 1024) throw new InvalidDataException("The provider response exceeded its stream budget.");
                await network.WriteAsync(frame, token);
            } while (await events.MoveNextAsync());
            operation.Cancel();
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            try
            {
                var status = error is Rejected rejected ? rejected.Status : error is JsonException or EndOfStreamException ? 400 : error is ProviderHttpException provider ? provider.Status is 401 or 403 ? 401 : 502 : 502;
                var code = error is Rejected expected ? expected.Code : error is OperationCanceledException ? "request_cancelled" : error is ProviderHttpException ? "provider_http_error" : "provider_request_failed";
                var message = "The external provider request could not complete. Check the provider connection in Veo.";
                var json = started ? JsonSerializer.Serialize(new { type = "error", code, message }) : JsonSerializer.Serialize(new { error = new { code, message } });
                var payload = started ? "event: error\ndata: " + json + "\n\n" : $"HTTP/1.1 {status} Error\r\nContent-Type: application/json\r\nContent-Length: {Encoding.UTF8.GetByteCount(json)}\r\nConnection: close\r\n\r\n" + json;
                using var tail = new CancellationTokenSource(TimeSpan.FromSeconds(2)); await network.WriteAsync(Encoding.UTF8.GetBytes(payload), tail.Token);
            }
            catch (Exception secondary) when (secondary is IOException or SocketException or ObjectDisposedException or OperationCanceledException or InvalidOperationException) { }
        }
        finally
        {
            operation?.Cancel(); deadline.Cancel(); client.Dispose(); clients.TryRemove(id, out _); capacity.Release();
            if (disconnected is not null) try { await disconnected; } catch (OperationCanceledException) { }
            operation?.Dispose();
        }
    }
    bool Authorize(string value)
    {
        const string prefix = "Bearer "; if (!value.StartsWith(prefix, StringComparison.Ordinal) || value.Length != prefix.Length + 64) return false;
        byte[] supplied; try { supplied = Convert.FromHexString(value[prefix.Length..]); } catch (FormatException) { return false; }
        try { return CryptographicOperations.FixedTimeEquals(supplied, capability); } finally { CryptographicOperations.ZeroMemory(supplied); }
    }
    static async Task WatchDisconnectAsync(NetworkStream network, CancellationTokenSource operation)
    {
        try { _ = await network.ReadAsync(new byte[1], operation.Token); if (!operation.IsCancellationRequested) operation.Cancel(); }
        catch (Exception error) when (error is IOException or SocketException or ObjectDisposedException or OperationCanceledException) { if (!operation.IsCancellationRequested) operation.Cancel(); }
    }
    sealed record Request(string Method, string Target, Dictionary<string, string> Headers, byte[] Body);
    sealed class Rejected(int status, string code) : Exception(code) { public int Status { get; } = status; public string Code { get; } = code; }
    static async Task<Request> ReadRequestAsync(NetworkStream stream, CancellationToken token)
    {
        using var received = new MemoryStream(); var buffer = new byte[4096]; var boundary = -1;
        while (boundary < 0)
        {
            var count = await stream.ReadAsync(buffer, token); if (count == 0) throw new Rejected(400, "incomplete_headers");
            received.Write(buffer, 0, count); boundary = received.GetBuffer().AsSpan(0, (int)received.Length).IndexOf("\r\n\r\n"u8);
            if (boundary > 32768 || boundary < 0 && received.Length > 32768) throw new Rejected(431, "headers_too_large");
        }
        var headersText = Encoding.ASCII.GetString(received.GetBuffer(), 0, boundary); var lines = headersText.Split("\r\n");
        var first = lines[0].Split(' '); if (first.Length != 3 || first[2] != "HTTP/1.1" || !first[1].StartsWith('/') || first[1].Length > 256) throw new Rejected(400, "invalid_request_line");
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            var split = line.IndexOf(':'); if (split <= 0 || line.Length > 8192 || !headers.TryAdd(line[..split].Trim(), line[(split + 1)..].Trim())) throw new Rejected(400, "invalid_header");
        }
        if (!headers.TryGetValue("content-length", out var raw) || !int.TryParse(raw, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var length) || length < 1 || length > MaximumBodyBytes) throw new Rejected(413, "body_size_invalid");
        var body = new byte[length]; var available = (int)received.Length - boundary - 4; if (available > length) throw new Rejected(400, "unexpected_extra_bytes");
        received.GetBuffer().AsSpan(boundary + 4, available).CopyTo(body); await stream.ReadExactlyAsync(body.AsMemory(available), token);
        return new(first[0], first[1], headers, body);
    }
    public async ValueTask DisposeAsync()
    {
        if (disposed) return; disposed = true; lifetime.Cancel(); listener?.Stop();
        foreach (var route in routes.Values) route.Lifetime.Cancel(); foreach (var client in clients.Values) client.Dispose();
        if (accepting is not null) await accepting;
        try { await Task.WhenAll(requests.Values).WaitAsync(TimeSpan.FromSeconds(10)); } catch (TimeoutException) { }
        foreach (var route in routes.Values) route.Lifetime.Dispose(); foreach (var cancellation in retired) cancellation.Dispose(); routes.Clear(); CryptographicOperations.ZeroMemory(capability); lifetime.Dispose();
    }
}
