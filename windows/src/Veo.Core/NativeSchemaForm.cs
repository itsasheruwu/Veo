using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Veo.Core;

public sealed record NativeFormField(string Key, string Title, string Description, string Kind, bool Required, string[] Choices,
    string? Default, bool Secret, JsonElement Schema);
public sealed record NativeSchemaForm(NativeFormField[] Fields, string? UnavailableReason)
{
    public bool IsSupported => UnavailableReason is null;
    public static NativeSchemaForm Parse(JsonElement schema)
    {
        if (schema.ValueKind != JsonValueKind.Object || schema.Str("type") is not (null or "object") || !schema.TryGetProperty("properties", out var properties) || properties.ValueKind != JsonValueKind.Object)
            return new([], "This action does not provide a supported native object form.");
        if (HasComposition(schema) || new[] { "patternProperties", "dependencies", "dependentSchemas", "dependentRequired", "propertyNames", "if", "then", "else", "minProperties", "maxProperties" }.Any(key => schema.TryGetProperty(key, out _))) return new([], "This action requires object constraints that the native editor cannot safely submit.");
        var required = schema.TryGetProperty("required", out var r) && r.ValueKind == JsonValueKind.Array ? r.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToHashSet(StringComparer.Ordinal) : [];
        if (required.Any(key => !properties.TryGetProperty(key, out _))) return new([], "This action requires a field that has no native schema.");
        var fields = new List<NativeFormField>();
        foreach (var property in properties.EnumerateObject())
        {
            var value = property.Value;
            if (value.ValueKind != JsonValueKind.Object) return new(fields.ToArray(), $"{property.Name} uses an unsupported field schema.");
            if (HasComposition(value) || value.TryGetProperty("const", out _)) return new(fields.ToArray(), $"{property.Name} requires a composed or constant form schema that this native editor cannot safely submit.");
            var kind = value.Str("type");
            if (kind is null && value.TryGetProperty("type", out var variants) && variants.ValueKind == JsonValueKind.Array)
            {
                var kinds = variants.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String && x.GetString() != "null").Select(x => x.GetString()).Distinct().ToArray();
                if (kinds.Length != 1) return new(fields.ToArray(), $"{property.Name} requires selecting between unsupported field types.");
                kind = kinds[0];
            }
            var choices = value.TryGetProperty("enum", out var options) && options.ValueKind == JsonValueKind.Array ? options.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray() : [];
            if (value.TryGetProperty("enum", out options) && (kind != "string" || options.ValueKind != JsonValueKind.Array || options.GetArrayLength() == 0 || options.EnumerateArray().Any(x => x.ValueKind != JsonValueKind.String))) return new(fields.ToArray(), $"{property.Name} requires an unsupported enumeration type.");
            if (kind == "array")
            {
                if (!value.TryObjectProperty("items", out var items) || items.Str("type") != "string") return new(fields.ToArray(), $"{property.Name} requires an unsupported array item type.");
                if (HasComposition(items) || items.TryGetProperty("const", out _) || value.TryGetProperty("contains", out _) || value.TryGetProperty("prefixItems", out _)) return new(fields.ToArray(), $"{property.Name} requires unsupported array constraints.");
                if (items.TryGetProperty("enum", out var itemOptions) && (itemOptions.ValueKind != JsonValueKind.Array || itemOptions.GetArrayLength() == 0 || itemOptions.EnumerateArray().Any(x => x.ValueKind != JsonValueKind.String))) return new(fields.ToArray(), $"{property.Name} requires an unsupported array enumeration.");
                choices = items.TryGetProperty("enum", out var values) && values.ValueKind == JsonValueKind.Array ? values.EnumerateArray().Select(x => x.GetString()!).ToArray() : [];
            }
            else if (kind is not ("string" or "number" or "integer" or "boolean")) return new(fields.ToArray(), $"{property.Name} uses the unsupported field type {kind ?? "unknown"}.");
            var title = value.Str("title") ?? property.Name; var description = value.Str("description") ?? "";
            var secret = value.TryGetProperty("writeOnly", out var writeOnly) && writeOnly.ValueKind == JsonValueKind.True || value.Str("format") == "password" || Sensitive(property.Name + " " + title + " " + description);
            var initial = value.TryGetProperty("default", out var d) && d.ValueKind is not (JsonValueKind.Null or JsonValueKind.Object) ? d.ValueKind == JsonValueKind.String ? d.GetString() : d.ValueKind == JsonValueKind.Array ? string.Join("\n", d.EnumerateArray().Select(x => x.GetString())) : d.ToString() : null;
            fields.Add(new(property.Name, title, description, kind!, required.Contains(property.Name), choices, initial, secret, value.Clone()));
        }
        return new(fields.ToArray(), null);
    }
    public JsonElement Validate(IReadOnlyDictionary<string, string> input)
    {
        if (!IsSupported) throw new NotSupportedException(UnavailableReason);
        var result = new JsonObject();
        foreach (var field in Fields)
        {
            var text = input.GetValueOrDefault(field.Key) ?? field.Default ?? "";
            if (text.Length == 0 && !field.Required) continue;
            if (text.Length == 0 && field.Required && field.Kind != "boolean") throw new InvalidOperationException($"{field.Title} is required.");
            switch (field.Kind)
            {
                case "string":
                    if (field.Choices.Length > 0 && !field.Choices.Contains(text, StringComparer.Ordinal)) throw new InvalidOperationException($"Choose a listed value for {field.Title}.");
                    CheckString(field.Title, field.Schema, text);
                    result[field.Key] = text; break;
                case "boolean":
                    if (!bool.TryParse(text, out var boolean)) throw new InvalidOperationException($"Choose true or false for {field.Title}."); result[field.Key] = boolean; break;
                case "integer":
                    if (!long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var integer)) throw new InvalidOperationException($"{field.Title} needs a whole number."); CheckRange(field, integer); result[field.Key] = integer; break;
                case "number":
                    if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) || !double.IsFinite(number)) throw new InvalidOperationException($"{field.Title} needs a finite number."); CheckRange(field, number); result[field.Key] = number; break;
                case "array":
                    var values = text.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
                    if (field.Choices.Length > 0 && values.Any(x => !field.Choices.Contains(x, StringComparer.Ordinal))) throw new InvalidOperationException($"Choose listed values for {field.Title}.");
                    if (Limit(field.Schema, "minItems") is { } minimum && values.Length < minimum || Limit(field.Schema, "maxItems") is { } maximum && values.Length > maximum) throw new InvalidOperationException($"{field.Title} has an invalid number of selections.");
                    if (IntegrationCoordinator.Bool(field.Schema, "uniqueItems") && values.Distinct(StringComparer.Ordinal).Count() != values.Length) throw new InvalidOperationException($"{field.Title} requires unique selections.");
                    foreach (var item in values) CheckString(field.Title, field.Schema.GetProperty("items"), item);
                    result[field.Key] = new JsonArray(values.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray()); break;
            }
        }
        if (input.Keys.Any(key => Fields.All(field => field.Key != key))) throw new InvalidOperationException("The form contains an unknown field.");
        return JsonSerializer.SerializeToElement(result);
    }
    static long? Limit(JsonElement schema, string name) => schema.TryGetProperty(name, out var value) && value.TryGetInt64(out var result) ? result : null;
    static void CheckRange(NativeFormField field, double value)
    {
        if (field.Schema.TryGetProperty("minimum", out var minimum) && minimum.TryGetDouble(out var min) && value < min || field.Schema.TryGetProperty("maximum", out var maximum) && maximum.TryGetDouble(out var max) && value > max) throw new InvalidOperationException($"{field.Title} is outside the allowed range.");
        if (field.Schema.TryGetProperty("exclusiveMinimum", out var exclusiveMinimum) && exclusiveMinimum.TryGetDouble(out var exclusiveMin) && value <= exclusiveMin || field.Schema.TryGetProperty("exclusiveMaximum", out var exclusiveMaximum) && exclusiveMaximum.TryGetDouble(out var exclusiveMax) && value >= exclusiveMax) throw new InvalidOperationException($"{field.Title} is outside the allowed range.");
        if (field.Schema.TryGetProperty("multipleOf", out var multiple) && multiple.TryGetDouble(out var factor) && (factor <= 0 || Math.Abs(value / factor - Math.Round(value / factor)) > 1e-9)) throw new InvalidOperationException($"{field.Title} requires a multiple of the allowed step.");
    }
    static void CheckString(string title, JsonElement schema, string text)
    {
        if (Limit(schema, "minLength") is { } min && text.EnumerateRunes().LongCount() < min || Limit(schema, "maxLength") is { } max && text.EnumerateRunes().LongCount() > max) throw new InvalidOperationException($"{title} has an invalid length.");
        if (schema.Str("pattern") is { } pattern && !Regex.IsMatch(text, pattern, RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100))) throw new InvalidOperationException($"{title} does not match the requested format.");
    }
    static bool HasComposition(JsonElement schema) => new[] { "$ref", "anyOf", "allOf", "oneOf", "not" }.Any(key => schema.TryGetProperty(key, out _));
    static bool Sensitive(string value) => new[] { "password", "secret", "token", "api key", "credential" }.Any(term => value.Contains(term, StringComparison.OrdinalIgnoreCase));
}
