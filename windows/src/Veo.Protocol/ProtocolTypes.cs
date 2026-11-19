using System.Text.Json;

namespace Veo.Protocol;

public enum CodexRuntimeState { Stopped, Starting, Ready, Faulted, Disposed }

/// <summary>Raw JSON is retained so newer runtime fields survive presentation and persistence.</summary>
public sealed record RuntimeEvent(long Generation, JsonElement Message)
{
    public string? Method => Message.TryGetProperty("method", out var method) ? method.GetString() : null;
    public JsonElement? Id => Message.TryGetProperty("id", out var id) ? id : null;
    public JsonElement Parameters => Message.TryGetProperty("params", out var value) ? value : default;
    public bool IsServerRequest => Id is { ValueKind: JsonValueKind.Number or JsonValueKind.String };
}

public sealed class CodexRpcException(int? code, string message, JsonElement? data = null) : Exception(message)
{
    public int? Code { get; } = code;
    public JsonElement? ErrorData { get; } = data;
}

public sealed record CodexRuntimeOptions
{
    public string? ExecutablePath { get; init; }
    public string? WorkingDirectory { get; init; }
    public string ClientName { get; init; } = "veo-windows";
    public string ClientVersion { get; init; } = "0.1.0";
    public string? SchemaDirectory { get; init; }
    /// <summary>Generate contracts from the exact selected CLI into the writable SchemaDirectory before launch.</summary>
    public bool GenerateSchemaOnStart { get; init; }
    public TimeSpan SchemaGenerationTimeout { get; init; } = TimeSpan.FromSeconds(60);
    public TimeSpan VersionProbeTimeout { get; init; } = TimeSpan.FromSeconds(10);
    public int EventCapacity { get; init; } = 256;
    public int MaximumFrameBytes { get; init; } = 32 * 1024 * 1024;
    public TimeSpan StartupTimeout { get; init; } = TimeSpan.FromSeconds(45);
    /// <summary>Optional flags such as --strict-config. Never contains shell command text.</summary>
    public IReadOnlyList<string> AdditionalArguments { get; init; } = [];
    /// <summary>Per-runtime ephemeral loopback capabilities only; provider credentials never enter this map.</summary>
    public IReadOnlyDictionary<string, string> EnvironmentOverrides { get; init; } = new Dictionary<string, string>();
}
