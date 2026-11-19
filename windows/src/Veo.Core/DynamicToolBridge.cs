using System.Text.Json;
using Veo.Protocol;

namespace Veo.Core;

public sealed record WorkspaceToolContext(string Cwd, string AccessBoundary, string RuntimeThreadId);
public sealed record ToolText(string type, string text);
public sealed record DynamicToolResult(ToolText[] contentItems, bool success);

/// <summary>Only two read-only, empty-argument tools are advertised to their originating thread.</summary>
public sealed class DynamicToolBridge(Func<string, WorkspaceToolContext?> resolve, Func<string, CancellationToken, Task<JsonElement>> backgroundTerminals)
{
    public static object[] Specifications => [
        Spec("veo_workspace_context", "Read this Veo thread's local working directory and explicit access boundary. Does not modify files."),
        Spec("veo_background_terminals", "Read Codex background terminals belonging to this thread. Does not launch or terminate processes.")
    ];
    static object Spec(string name, string description) => new { type = "function", name, description, inputSchema = new { type = "object", properties = new { }, additionalProperties = false } };
    public async Task<DynamicToolResult> InvokeAsync(JsonElement parameters, CancellationToken token = default)
    {
        var id = parameters.Str("threadId");
        if (id is null || resolve(id) is not { } context || parameters.Str("namespace") is { Length: > 0 }
            || !parameters.TryGetProperty("arguments", out var arguments) || arguments.ValueKind != JsonValueKind.Object || arguments.EnumerateObject().Any())
            return Failure("Unknown originating thread, namespace, or unsupported arguments.");
        return parameters.Str("tool") switch
        {
            "veo_workspace_context" => Success(new { cwd = context.Cwd, accessBoundary = context.AccessBoundary, threadId = id, readOnly = true }),
            "veo_background_terminals" => Success(await backgroundTerminals(id, token)),
            _ => Failure("Veo does not advertise this tool.")
        };
    }
    public static DynamicToolResult Failure(string error) => new([new("inputText", DiagnosticRedactor.Redact(error))], false);
    static DynamicToolResult Success(object value) => new([new("inputText", JsonSerializer.Serialize(value))], true);
}
