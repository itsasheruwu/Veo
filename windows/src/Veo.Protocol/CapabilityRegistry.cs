using System.Collections.Concurrent;
using System.Text.Json;

namespace Veo.Protocol;

public enum ProtocolDirection { ClientRequest, ServerRequest, ClientNotification, ServerNotification }
public enum CapabilityAvailability { Unknown, Available, Unavailable }

/// <summary>Schema inventory is evidence for method presence, not proof of account or platform availability.</summary>
public sealed class CapabilityRegistry
{
    private readonly Dictionary<ProtocolDirection, HashSet<string>> _methods = [];
    private readonly ConcurrentDictionary<string, string> _unavailable = new(StringComparer.Ordinal);
    private readonly HashSet<string> _turnCyberPrograms = new(StringComparer.Ordinal);
    public bool HasSchema => _methods.Count > 0;
    public bool ExperimentalApiEnabled { get; internal set; }
    public string? SchemaDirectory { get; private set; }
    public IReadOnlyDictionary<string, string> UnavailableMethods => _unavailable;

    public IReadOnlyCollection<string> Methods(ProtocolDirection direction) => _methods.TryGetValue(direction, out var methods) ? methods : Array.Empty<string>();
    public CapabilityAvailability Availability(string method, ProtocolDirection direction = ProtocolDirection.ClientRequest)
        => _unavailable.ContainsKey(method) ? CapabilityAvailability.Unavailable
            : !_methods.TryGetValue(direction, out var inventory) ? CapabilityAvailability.Unknown
            : inventory.Contains(method) ? CapabilityAvailability.Available : CapabilityAvailability.Unavailable;
    public bool SupportsAll(IEnumerable<string> methods) => methods.All(method => Availability(method) == CapabilityAvailability.Available);
    public bool SupportsAny(IEnumerable<string> methods) => methods.Any(method => Availability(method) == CapabilityAvailability.Available);
    public bool SupportsTurnCyberAccessProgram(string program) =>
        ExperimentalApiEnabled && Availability("turn/start") == CapabilityAvailability.Available && _turnCyberPrograms.Contains(program);
    public void RecordUnavailable(string method, string reason) => _unavailable[method] = DiagnosticRedactor.Redact(reason);

    public CapabilityAvailability Availability(CapabilityDefinition capability)
    {
        if (capability.Experimental && !ExperimentalApiEnabled) return CapabilityAvailability.Unavailable;
        var states = capability.Methods.Select(method => _unavailable.ContainsKey(method)
            ? CapabilityAvailability.Unavailable
            : !HasSchema ? CapabilityAvailability.Unknown
            : _methods.Values.Any(methods => methods.Contains(method)) ? CapabilityAvailability.Available : CapabilityAvailability.Unavailable).ToArray();
        if (capability.RequiresAllMethods)
            return states.Contains(CapabilityAvailability.Unavailable) ? CapabilityAvailability.Unavailable
                : states.Contains(CapabilityAvailability.Unknown) ? CapabilityAvailability.Unknown : CapabilityAvailability.Available;
        return states.Contains(CapabilityAvailability.Available) ? CapabilityAvailability.Available
            : states.Contains(CapabilityAvailability.Unknown) ? CapabilityAvailability.Unknown : CapabilityAvailability.Unavailable;
    }

    public static CapabilityRegistry Load(string directory)
    {
        var registry = new CapabilityRegistry { SchemaDirectory = Path.GetFullPath(directory) };
        foreach (var direction in Enum.GetValues<ProtocolDirection>())
        {
            var path = Path.Combine(directory, direction + ".json");
            if (!File.Exists(path)) continue;
            using var document = JsonDocument.Parse(File.ReadAllBytes(path));
            var methods = new HashSet<string>(StringComparer.Ordinal);
            CollectMethods(document.RootElement, methods);
            registry._methods.Add(direction, methods);
        }
        registry._turnCyberPrograms.UnionWith(ReadTurnCyberPrograms(directory));
        return registry;
    }

    private static string[] ReadTurnCyberPrograms(string directory)
    {
        var file = new FileInfo(Path.Combine(directory, "v2", "TurnStartParams.json"));
        try
        {
            if (!file.Exists || file.Length is < 2 or > 1024 * 1024) return [];
            using var schema = JsonDocument.Parse(File.ReadAllBytes(file.FullName));
            var root = schema.RootElement;
            if (!TryObject(root, "properties", out var properties) ||
                !TryObject(properties, "cyberAccessProgram", out var parameter)) return [];
            var variants = parameter.TryGetProperty("anyOf", out var anyOf) && anyOf.ValueKind == JsonValueKind.Array
                ? anyOf.EnumerateArray().ToArray() : new[] { parameter };
            var values = new List<string>();
            foreach (var variant in variants)
            {
                if (variant.ValueKind != JsonValueKind.Object) continue;
                var definition = variant;
                if (variant.TryGetProperty("$ref", out var reference) && reference.ValueKind == JsonValueKind.String &&
                    reference.GetString() == "#/definitions/CyberAccessProgram" &&
                    TryObject(root, "definitions", out var definitions) &&
                    TryObject(definitions, "CyberAccessProgram", out var referenced))
                    definition = referenced;
                if (definition.ValueKind != JsonValueKind.Object ||
                    !definition.TryGetProperty("enum", out var choices) || choices.ValueKind != JsonValueKind.Array) continue;
                foreach (var choice in choices.EnumerateArray())
                    if (choice.ValueKind == JsonValueKind.String) values.Add(choice.GetString()!);
            }
            return values.ToArray();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        { return []; }
    }

    private static bool TryObject(JsonElement parent, string name, out JsonElement value)
    {
        value = default;
        return parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out value) &&
            value.ValueKind == JsonValueKind.Object;
    }

    private static void CollectMethods(JsonElement element, HashSet<string> methods)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            if (element.TryGetProperty("properties", out var properties) && properties.TryGetProperty("method", out var method))
            {
                if (method.TryGetProperty("const", out var constant) && constant.ValueKind == JsonValueKind.String) methods.Add(constant.GetString()!);
                if (method.TryGetProperty("enum", out var values))
                    foreach (var value in values.EnumerateArray()) if (value.ValueKind == JsonValueKind.String) methods.Add(value.GetString()!);
            }
            foreach (var property in element.EnumerateObject()) CollectMethods(property.Value, methods);
        }
        else if (element.ValueKind == JsonValueKind.Array)
            foreach (var child in element.EnumerateArray()) CollectMethods(child, methods);
    }
}
