using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace Veo.Protocol;

/// <summary>Application-scoped owner of exactly one direct local Codex stdio runtime.</summary>
public sealed class CodexRuntimeService : IAsyncDisposable
{
    private static long globalGeneration;
    private sealed record PendingRequest(string Method, TaskCompletionSource<JsonElement> Completion);
    private sealed class Session(Process process, long generation)
    {
        public Process Process { get; } = process;
        public long Generation { get; } = generation;
        public CancellationTokenSource Lifetime { get; } = new();
        public ConcurrentDictionary<string, PendingRequest> Pending { get; } = new(StringComparer.Ordinal);
        public Task Stdout { get; set; } = Task.CompletedTask;
        public Task Stderr { get; set; } = Task.CompletedTask;
        public Task Monitor { get; set; } = Task.CompletedTask;
        public bool IntentionalStop { get; set; }
    }

    private readonly CodexRuntimeOptions _options;
    private readonly SemaphoreSlim _lifecycle = new(1, 1);
    private readonly SemaphoreSlim _write = new(1, 1);
    private readonly Channel<RuntimeEvent> _events;
    private readonly object _diagnosticLock = new();
    private Session? _session;
    private long _generation;
    private long _nextRequestId;
    private string _diagnostics = "";
    private volatile CodexRuntimeState _state;
    private bool _disposed;

    public CodexRuntimeService(string? executablePath = null) : this(new CodexRuntimeOptions { ExecutablePath = executablePath }) { }

    public CodexRuntimeService(CodexRuntimeOptions options)
    {
        _options = options;
        if (_options.EventCapacity < 1) throw new ArgumentOutOfRangeException(nameof(options));
        _events = Channel.CreateBounded<RuntimeEvent>(new BoundedChannelOptions(_options.EventCapacity)
        {
            FullMode = BoundedChannelFullMode.Wait, SingleReader = true, SingleWriter = true,
            AllowSynchronousContinuations = false,
        });
        Capabilities = !_options.GenerateSchemaOnStart && _options.SchemaDirectory is { } directory ? CapabilityRegistry.Load(directory) : new();
    }

    public long Generation => Interlocked.Read(ref _generation);
    public string? ExecutablePath { get; private set; }
    public string State => _state.ToString();
    public CodexRuntimeState RuntimeState => _state;
    public string? LastError { get; private set; }
    public JsonElement Initialization { get; private set; }
    public CapabilityRegistry Capabilities { get; private set; }
    public string? SelectedCliVersion { get; private set; }
    public CodexSchemaProvenance? SchemaProvenance { get; private set; }
    public event Action<long, string>? Faulted;
    public int? ProcessId => _session is { } session && !session.Process.HasExited ? session.Process.Id : null;
    public string DiagnosticTail
    {
        get
        {
            lock (_diagnosticLock)
            {
                var text = _diagnostics;
                foreach (var capability in _options.EnvironmentOverrides.Values) if (capability.Length > 0) text = text.Replace(capability, "[redacted]", StringComparison.OrdinalIgnoreCase);
                return DiagnosticRedactor.Redact(text);
            }
        }
    }

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        await _lifecycle.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_state == CodexRuntimeState.Ready) return;
            if (_session is { } previous) await StopSessionAsync(previous).ConfigureAwait(false);
            ExecutablePath = CodexExecutableDiscovery.Resolve(_options.ExecutablePath)
                ?? throw new FileNotFoundException("Codex CLI was not found. Select an existing native executable in Runtime settings.");
            _state = CodexRuntimeState.Starting;
            LastError = null;
            lock (_diagnosticLock) _diagnostics = "";
            if (_options.GenerateSchemaOnStart)
            {
                Capabilities = new(); SelectedCliVersion = null; SchemaProvenance = null;
                try
                {
                    var exported = await CodexSchemaProbe.GenerateAsync(ExecutablePath, _options, cancellationToken).ConfigureAwait(false);
                    Capabilities = exported.Registry; SchemaProvenance = exported.Provenance;
                    SelectedCliVersion = exported.Provenance.CliVersion;
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    throw new InvalidOperationException("The selected Codex CLI could not provide its protocol schema. In Runtime settings, verify the selected executable and writable schema directory, then reconnect. " + DiagnosticRedactor.Redact(error.Message), error);
                }
            }
            var start = new ProcessStartInfo(ExecutablePath)
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardInputEncoding = new UTF8Encoding(false), StandardErrorEncoding = Encoding.UTF8,
                WorkingDirectory = _options.WorkingDirectory ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            };
            start.ArgumentList.Add("app-server");
            start.ArgumentList.Add("--stdio");
            foreach (var argument in _options.AdditionalArguments) start.ArgumentList.Add(argument);
            foreach (var entry in _options.EnvironmentOverrides)
            {
                if (!entry.Key.StartsWith("VEO_LOOPBACK_TOKEN_", StringComparison.Ordinal) || entry.Key.Length != 51 ||
                    entry.Key[19..].Any(c => !Uri.IsHexDigit(c)) || entry.Value.Length != 64 || entry.Value.Any(c => !Uri.IsHexDigit(c)))
                    throw new ArgumentException("Runtime environment overrides accept only Veo's ephemeral loopback capabilities.");
                start.Environment[entry.Key] = entry.Value;
            }
            var process = new Process { StartInfo = start, EnableRaisingEvents = true };
            var session = new Session(process, AdvanceGeneration());
            _session = session;
            try
            {
                if (!process.Start()) throw new IOException("Codex could not start.");
                session.Stdout = ReadStdoutAsync(session);
                session.Stderr = ReadStderrAsync(session);
                session.Monitor = MonitorAsync(session);
                using var startup = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                startup.CancelAfter(_options.StartupTimeout);
                Initialization = await RequestCoreAsync(session, "initialize", new
                {
                    clientInfo = new { name = _options.ClientName, title = "Veo", version = _options.ClientVersion },
                    capabilities = new { experimentalApi = true, mcpServerOpenaiFormElicitation = false },
                }, startup.Token).ConfigureAwait(false);
                if (!IsCurrent(session) || process.HasExited) throw new IOException("Codex stopped during initialization.");
                await SendAsync(session, new { method = "initialized" }, startup.Token).ConfigureAwait(false);
                Capabilities.ExperimentalApiEnabled = true;
                _state = CodexRuntimeState.Ready;
            }
            catch
            {
                await StopSessionAsync(session).ConfigureAwait(false);
                throw;
            }
        }
        catch (Exception exception)
        {
            _state = CodexRuntimeState.Faulted;
            LastError = DiagnosticRedactor.Redact(exception.Message);
            throw;
        }
        finally { _lifecycle.Release(); }
    }

    /// <summary>No implicit timeout and no retry: a cancelled/uncertain mutation must be reconciled by its coordinator.</summary>
    public Task<JsonElement> RequestAsync(string method, object? parameters = null, CancellationToken cancellationToken = default)
    {
        var session = GetReadySession();
        if (Capabilities.Availability(method) == CapabilityAvailability.Unavailable)
            throw new NotSupportedException($"The selected Codex runtime does not expose {method}.");
        return RequestCoreAsync(session, method, parameters, cancellationToken);
    }

    public Task NotifyAsync(string method, object? parameters = null, CancellationToken cancellationToken = default)
        => SendAsync(GetReadySession(), Envelope(method, parameters), cancellationToken);

    public Task RespondAsync(JsonElement id, object? result, CancellationToken cancellationToken = default)
        => RespondAsync(Generation, id, result, cancellationToken);

    /// <summary>Use this overload for UI responses: stale approval/question completions cannot reach a replacement process.</summary>
    public Task RespondAsync(RuntimeEvent request, object? result, CancellationToken cancellationToken = default)
        => request.Id is { } id ? RespondAsync(request.Generation, id, result, cancellationToken)
            : throw new ArgumentException("The event is not a server request.", nameof(request));

    public Task RespondAsync(long generation, JsonElement id, object? result, CancellationToken cancellationToken = default)
    {
        if (id.ValueKind is not (JsonValueKind.Number or JsonValueKind.String)) throw new ArgumentException("Invalid RPC request ID.", nameof(id));
        var session = GetReadySession();
        if (generation != session.Generation) throw new InvalidOperationException("This request belongs to a previous Codex runtime.");
        return SendAsync(session, new Dictionary<string, object?> { ["id"] = id, ["result"] = result }, cancellationToken);
    }

    public Task RespondErrorAsync(RuntimeEvent request, int code, string message, CancellationToken cancellationToken = default)
    {
        var session = GetReadySession();
        if (request.Generation != session.Generation || request.Id is not { } id) throw new InvalidOperationException("The server request is no longer active.");
        return SendAsync(session, new { id, error = new { code, message } }, cancellationToken);
    }

    public Task RespondErrorAsync(JsonElement id, int code, string message, CancellationToken cancellationToken = default)
        => RespondErrorAsync(new RuntimeEvent(Generation, JsonSerializer.SerializeToElement(new { id, method = "server/request" })), code, message, cancellationToken);

    /// <summary>Exactly one application coordinator consumes this ordered event stream and fans out domain updates.</summary>
    public async IAsyncEnumerable<RuntimeEvent> ReadEventsAsync([EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        await foreach (var item in _events.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            if (item.Generation == Generation) yield return item;
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        await _lifecycle.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_session is { } session) await StopSessionAsync(session).ConfigureAwait(false);
            if (!_disposed) _state = CodexRuntimeState.Stopped;
        }
        finally { _lifecycle.Release(); }
    }

    private async Task<JsonElement> RequestCoreAsync(Session session, string method, object? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var id = Interlocked.Increment(ref _nextRequestId);
        var key = id.ToString(System.Globalization.CultureInfo.InvariantCulture);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!session.Pending.TryAdd(key, new(method, completion))) throw new InvalidOperationException("Duplicate RPC ID.");
        using var registration = cancellationToken.Register(() =>
        {
            if (session.Pending.TryRemove(key, out var pending)) pending.Completion.TrySetCanceled(cancellationToken);
        });
        try
        {
            var envelope = Envelope(method, parameters);
            envelope["id"] = id;
            await SendAsync(session, envelope, cancellationToken).ConfigureAwait(false);
            return await completion.Task.ConfigureAwait(false);
        }
        finally { session.Pending.TryRemove(key, out _); }
    }

    private static Dictionary<string, object?> Envelope(string method, object? parameters)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(method);
        var envelope = new Dictionary<string, object?> { ["method"] = method };
        if (parameters is not null) envelope["params"] = parameters;
        return envelope;
    }

    private async Task SendAsync(Session session, object envelope, CancellationToken cancellationToken)
    {
        await _write.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!IsCurrent(session) || session.Process.HasExited) throw new IOException("The local Codex runtime stopped.");
            var line = JsonSerializer.Serialize(envelope);
            await session.Process.StandardInput.WriteLineAsync(line.AsMemory(), cancellationToken).ConfigureAwait(false);
            await session.Process.StandardInput.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _write.Release(); }
    }

    private async Task ReadStdoutAsync(Session session)
    {
        try
        {
            using var framer = new NdjsonFramer(_options.MaximumFrameBytes);
            var buffer = new byte[64 * 1024];
            while (true)
            {
                var count = await session.Process.StandardOutput.BaseStream.ReadAsync(buffer, session.Lifetime.Token).ConfigureAwait(false);
                if (count == 0) { framer.Complete(); break; }
                foreach (var message in framer.Append(buffer.AsSpan(0, count)))
                {
                    if (!IsCurrent(session)) return;
                    if (!message.TryGetProperty("method", out _) && message.TryGetProperty("id", out var id))
                    {
                        if (!session.Pending.TryRemove(id.GetRawText(), out var pending)) continue;
                        if (message.TryGetProperty("error", out var error))
                        {
                            var code = error.TryGetProperty("code", out var c) && c.TryGetInt32(out var number) ? number : (int?)null;
                            var text = error.TryGetProperty("message", out var m) ? m.GetString() ?? "Codex request failed." : "Codex request failed.";
                            if (code == -32601 || text.Contains("requires experimentalApi", StringComparison.OrdinalIgnoreCase)) Capabilities.RecordUnavailable(pending.Method, text);
                            pending.Completion.TrySetException(new CodexRpcException(code, DiagnosticRedactor.Redact(text), error.TryGetProperty("data", out var data) ? data.Clone() : null));
                        }
                        else pending.Completion.TrySetResult(message.TryGetProperty("result", out var result) ? result.Clone() : JsonSerializer.SerializeToElement<object?>(null));
                    }
                    else await _events.Writer.WriteAsync(new(session.Generation, message), session.Lifetime.Token).ConfigureAwait(false);
                }
            }
        }
        catch (Exception exception) when (exception is not OperationCanceledException || !session.Lifetime.IsCancellationRequested)
        {
            Fault(session, exception);
        }
    }

    private async Task ReadStderrAsync(Session session)
    {
        var buffer = new char[4096];
        try
        {
            while (true)
            {
                var count = await session.Process.StandardError.ReadAsync(buffer.AsMemory(), session.Lifetime.Token).ConfigureAwait(false);
                if (count == 0) break;
                if (!IsCurrent(session)) return;
                lock (_diagnosticLock)
                {
                    _diagnostics += new string(buffer, 0, count);
                    if (_diagnostics.Length > 64 * 1024) _diagnostics = _diagnostics[^65536..];
                }
            }
        }
        catch (Exception exception) when (exception is IOException or OperationCanceledException or ObjectDisposedException) { }
    }

    private async Task MonitorAsync(Session session)
    {
        try
        {
            await session.Process.WaitForExitAsync(session.Lifetime.Token).ConfigureAwait(false);
            // Descendants may retain pipe handles. Give buffered frames a bounded drain, never wait forever for EOF.
            try { await Task.WhenAll(session.Stdout, session.Stderr).WaitAsync(TimeSpan.FromSeconds(2), session.Lifetime.Token).ConfigureAwait(false); }
            catch (TimeoutException) { }
            if (!session.IntentionalStop) Fault(session, new IOException($"Codex exited with status {session.Process.ExitCode}. {DiagnosticTail}".Trim()));
        }
        catch (OperationCanceledException) when (session.Lifetime.IsCancellationRequested) { }
        catch (Exception exception) when (exception is IOException or InvalidOperationException) { Fault(session, exception); }
    }

    private void Fault(Session session, Exception exception)
    {
        if (!IsCurrent(session) || session.IntentionalStop) return;
        LastError = DiagnosticRedactor.Redact(exception.Message);
        _state = CodexRuntimeState.Faulted;
        try { Faulted?.Invoke(session.Generation, LastError); } catch { /* Diagnostics observers cannot own runtime teardown. */ }
        foreach (var entry in session.Pending)
            if (session.Pending.TryRemove(entry.Key, out var completion)) completion.Completion.TrySetException(new IOException(LastError, exception));
        session.Lifetime.Cancel();
        TryKill(session.Process);
    }

    private async Task StopSessionAsync(Session session)
    {
        session.IntentionalStop = true;
        if (ReferenceEquals(_session, session)) { _session = null; AdvanceGeneration(); }
        session.Lifetime.Cancel();
        foreach (var entry in session.Pending)
            if (session.Pending.TryRemove(entry.Key, out var pending)) pending.Completion.TrySetException(new IOException("The local Codex runtime restarted."));
        TryKill(session.Process);
        try { await Task.WhenAll(session.Stdout, session.Stderr, session.Monitor).WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false); }
        catch (Exception exception) when (exception is TimeoutException or OperationCanceledException or IOException or ObjectDisposedException) { }
        session.Process.Dispose();
        session.Lifetime.Dispose();
    }

    private bool IsCurrent(Session session) => ReferenceEquals(_session, session) && session.Generation == Generation;
    private long AdvanceGeneration()
    {
        var next = Interlocked.Increment(ref globalGeneration);
        Interlocked.Exchange(ref _generation, next);
        return next;
    }
    private Session GetReadySession() => _state == CodexRuntimeState.Ready && _session is { } session
        ? session : throw new InvalidOperationException("The local Codex runtime is not ready.");
    private static void TryKill(Process process)
    {
        // Only the process started by this owner and its descendants are ever targeted.
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException) { }
    }

    public async ValueTask DisposeAsync()
    {
        await _lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed) return;
            _disposed = true;
            if (_session is { } session) await StopSessionAsync(session).ConfigureAwait(false);
            _state = CodexRuntimeState.Disposed;
            _events.Writer.TryComplete();
        }
        finally { _lifecycle.Release(); }
    }
}
