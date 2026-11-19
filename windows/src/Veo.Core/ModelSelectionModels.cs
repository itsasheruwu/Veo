using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Veo.Core;

public sealed record AutoRouterPolicy(bool OptedIn = false, string Provider = "Utility", bool AllowFast = false, bool AllowUltra = false, string? UtilityModelId = null, bool VisionOptedIn = false);
public sealed record FamilyAutoLane(string ModelId, string Model, string Name, string Effort);
public sealed record FamilyAutoPlan(string Family, FamilyAutoLane Parent, FamilyAutoLane Routine, FamilyAutoLane Escalation, FamilyAutoLane Reviewer, string Availability, string[] Warnings)
{
    public bool UsesMultiAgent => Availability != "single";
}
public sealed record ModelReasoning(string Id, string Description)
{
    public string Title => Id.ToLowerInvariant() switch { "low" => "Light", "xhigh" => "Extra", "max" => "Maximum", _ => CultureInfo.InvariantCulture.TextInfo.ToTitleCase(Id.Replace('_', ' ')) };
    public override string ToString() => Title;
}
public sealed record ModelServiceTier(string Id, string Name, string Description)
{
    public bool IsFast => !IsUltrafast && SpeedNames.Any(name => name is "fast" or "fastmode" or "priority");
    public bool IsUltrafast => SpeedNames.Any(name => name is "ultrafast" or "ultrafastmode");
    public bool IsAccelerated => IsFast || IsUltrafast;
    IEnumerable<string> SpeedNames => new[] { Id, Name }.Select(value =>
        string.Concat(value.ToLowerInvariant().Where(char.IsLetter)));
    public override string ToString() => Name;
}
public enum ModelSpeed { Standard, Fast, Ultrafast }

public sealed record ModelSpeedChoice(ModelSpeed Speed, ModelServiceTier? Tier)
{
    public string? TierId => Tier?.Id;
    public string Title => Speed == ModelSpeed.Fast ? "Fast Mode" : Speed.ToString();
    public string Description => Tier?.Description is { Length: > 0 } detail
        ? detail : Speed == ModelSpeed.Standard ? "Default speed" : "Faster, uses more of your limits";
}

public sealed record ModelContextLimits(long? Suggested, long Maximum)
{
    public static ModelContextLimits? Validated(long? suggested, long maximum) => maximum > 0 && (suggested is null || suggested > 0 && suggested <= maximum) ? new(suggested, maximum) : null;
}
public sealed record ModelContextChoice(string Kind = "Default", long? Tokens = null)
{
    public static IReadOnlyList<long> Presets { get; } = [200_000, 300_000, 500_000, 1_000_000];
    public string Title => Kind == "Default" ? "Default" : Tokens?.ToString("N0", CultureInfo.CurrentCulture) + " tokens";
    public static long? Parse(string input)
    {
        var text = input.Trim().Replace(",", "").ToLowerInvariant();
        var multiplier = text.EndsWith('k') ? 1000m : text.EndsWith('m') ? 1000000m : 1m;
        if (multiplier != 1) text = text[..^1];
        if (!Regex.IsMatch(text, @"^\d+(?:\.\d+)?$", RegexOptions.CultureInvariant) || !decimal.TryParse(text, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var value)) return null;
        try { var result = value * multiplier; return result >= 1 && result <= long.MaxValue && decimal.Truncate(result) == result ? (long)result : null; }
        catch (OverflowException) { return null; }
    }
}
public sealed record ModelProviderTools(bool WebSearch, bool ImageGeneration);

public sealed record NativeModelDescriptor(string Id, string Model, string Name, string Description, bool IsDefault,
    string DefaultEffort, ModelReasoning[] Efforts, ModelServiceTier[] Tiers, string? DefaultTier, string[] InputModalities,
    string? Specialty, DateTimeOffset? RetirementAt, JsonElement Raw)
{
    public bool SupportsPersonality => Raw.ValueKind == JsonValueKind.Object && Bool(Raw, "supportsPersonality");
    public string? AvailabilityNotice => Raw.TryObjectProperty("availabilityNux", out var availability) ? availability.Str("message") : null;
    public string? MultiAgentVersion => Raw.Str("multiAgentVersion");
    JsonElement UpgradeInfo => Raw.TryObjectProperty("upgradeInfo", out var upgrade) ? upgrade : default;
    public string? Upgrade => Raw.Str("upgrade") ?? UpgradeInfo.Str("model");
    public string? UpgradeCopy => UpgradeInfo.Str("upgradeCopy");
    public string? UpgradeLink => UpgradeInfo.Str("modelLink");
    public string? MigrationMarkdown => UpgradeInfo.Str("migrationMarkdown");

    public string DisplayName => IsExternal ? Name : ModelPickerCatalog.FormatName(Name);
    public bool SupportsImages => InputModalities.Contains("image", StringComparer.Ordinal);
    public bool IsExternal => Id.Contains('/');
    public bool IsStandaloneDaybreak => !IsExternal && Names.Any(ModelPickerCatalog.IsStandaloneDaybreakAlias);
    public bool SupportsDaybreakBlue => !IsExternal && AdvertisesCyberProgram(Raw, "daybreakBlue");
    public bool SupportsStandardCyberAccess => !IsExternal && AdvertisesCyberProgram(Raw, "standard");
    public bool IsSpark => Names.Any(x => Normalize(x).Contains("gpt-5.3-codex-spark", StringComparison.Ordinal));
    public IEnumerable<string> Names => [Id, Model, Name];
    public bool IsGPT56 => !IsExternal && Family("5.6");
    public ModelServiceTier? FastTier => Tiers.FirstOrDefault(tier => tier.IsFast);
    public ModelServiceTier? UltrafastTier => Tiers.FirstOrDefault(tier => tier.IsUltrafast);
    public ModelServiceTier? StandardTier => Tiers.FirstOrDefault(tier => !tier.IsAccelerated);

    public ModelSpeed SpeedFor(string? tier) => IsSpark || UltrafastTier is { } ultrafast && ultrafast.Id == tier
        ? ModelSpeed.Ultrafast : FastTier is { } fast && fast.Id == tier ? ModelSpeed.Fast : ModelSpeed.Standard;

    public IReadOnlyList<ModelSpeedChoice> SpeedChoices()
    {
        var fast = FastTier;
        var ultrafast = UltrafastTier;
        if (IsSpark || fast is null && ultrafast is null) return [];
        var speeds = new List<ModelSpeedChoice> { new(ModelSpeed.Standard, StandardTier) };
        if (fast is not null) speeds.Add(new(ModelSpeed.Fast, fast));
        if (ultrafast is not null) speeds.Add(new(ModelSpeed.Ultrafast, ultrafast));
        return speeds;
    }
    public bool Family(string family) => Names.Any(x => Normalize(x).Contains(family == "5.6" ? "gpt-5.6" : "gpt-6-", StringComparison.Ordinal));
    public bool Variant(string variant) => Names.Select(Normalize).Any(x => x.EndsWith("-" + variant, StringComparison.Ordinal));
    public static string Normalize(string text) => text.ToLowerInvariant().Replace('_', '-').Replace(' ', '-');
    public static NativeModelDescriptor? Parse(JsonElement raw)
    {
        if (raw.Str("id") is not { Length: > 0 } id || raw.Str("model") is not { Length: > 0 } model) return null;
        var efforts = raw.TryGetProperty("supportedReasoningEfforts", out var e) && e.ValueKind == JsonValueKind.Array
            ? e.EnumerateArray().Where(x => x.Str("reasoningEffort") is not null).Select(x => new ModelReasoning(x.Str("reasoningEffort")!, x.Str("description") ?? "")).ToArray() : [];
        var tiers = raw.TryGetProperty("serviceTiers", out var t) && t.ValueKind == JsonValueKind.Array
            ? t.EnumerateArray().Where(x => x.Str("id") is not null).Select(x => new ModelServiceTier(x.Str("id")!, x.Str("name") ?? x.Str("id")!, x.Str("description") ?? "")).ToArray() : [];
        var modalities = raw.TryGetProperty("inputModalities", out var m) && m.ValueKind == JsonValueKind.Array ? m.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray() : new[] { "text", "image" };
        DateTimeOffset? retirement = null;
        if (raw.TryObjectProperty("upgradeInfo", out var upgrade) && upgrade.TryGetProperty("retirementAt", out var date) && date.ValueKind == JsonValueKind.Number && date.TryGetInt64(out var unix))
            try { retirement = DateTimeOffset.FromUnixTimeSeconds(unix); } catch (ArgumentOutOfRangeException) { }
        return new(id, model, raw.Str("displayName") ?? model, raw.Str("description") ?? "", Bool(raw, "isDefault"), raw.Str("defaultReasoningEffort") ?? efforts.FirstOrDefault()?.Id ?? "",
            efforts, tiers, raw.Str("defaultServiceTier"), modalities, raw.Str("modelSpecialty"), retirement, raw.Clone());
    }
    static bool Bool(JsonElement value, string property) => value.TryGetProperty(property, out var result) && result.ValueKind == JsonValueKind.True;
    internal static bool AdvertisesCyberProgram(JsonElement model, string program) =>
        model.TryObjectProperty("availableAccessPrograms", out var programs)
        && programs.TryGetProperty("cyber", out var cyber) && cyber.ValueKind == JsonValueKind.Array
        && cyber.EnumerateArray().Any(value => value.ValueKind == JsonValueKind.String && value.GetString() == program);
    public override string ToString() => DisplayName;
}

public sealed record ModelPickerGroup(string Family, IReadOnlyList<NativeModelDescriptor> Models)
{
    public string Title => Family.Length == 0 ? "Other models" : $"{Family} family";
}

public static class ModelPickerCatalog
{
    static readonly Regex GptName = new(@"^gpt[-_ ]+(?<family>[0-9]+(?:\.[0-9]+)*)(?:[-_ ]+(?<variant>.+))?$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static IReadOnlyList<ModelPickerGroup> Groups(IEnumerable<NativeModelDescriptor> models) => models
        .Where(model => !model.IsStandaloneDaybreak)
        .GroupBy(Family, StringComparer.Ordinal)
        .OrderByDescending(group => FamilyVersion(group.Key))
        .Select(group => new ModelPickerGroup(group.Key, group.ToArray()))
        .ToArray();

    public static string FormatName(string name)
    {
        var match = GptName.Match(name.Trim());
        if (!match.Success) return name;
        var nameParts = match.Groups["variant"].Value.Split(['-', '_', ' '], StringSplitOptions.RemoveEmptyEntries);
        return string.Join(' ', nameParts.Select(part => char.ToUpperInvariant(part[0]) + part[1..])
            .Prepend(match.Groups["family"].Value));
    }

    public static bool IsStandaloneDaybreakAlias(string name)
    {
        var normalized = NativeModelDescriptor.Normalize(name.Trim());
        return normalized is "daybreak-blue" or "gpt-daybreak-blue"
            || normalized.StartsWith("daybreak-blue-", StringComparison.Ordinal)
            || normalized.StartsWith("gpt-daybreak-blue-", StringComparison.Ordinal);
    }

    static string Family(NativeModelDescriptor model) => model.IsExternal ? "" : model.Names
        .Select(name => GptName.Match(name.Trim()))
        .FirstOrDefault(match => match.Success)?.Groups["family"].Value ?? "";

    static Version? FamilyVersion(string family) => Version.TryParse(family.Contains('.') ? family : family + ".0", out var version)
        ? version : null;
}

public sealed record ModelSelectionChoice(string ModelId, string Model, string? Effort, string? Tier, long? ContextTokens = null,
    string RoutingMode = "Direct", AutoRouterPolicy? RouterPolicy = null, FamilyAutoPlan? FamilyPlan = null, bool? Daybreak = null);
public sealed record ModelSelectionPreferences
{
    public ModelSelectionChoice? Global { get; init; }
    public Dictionary<string, ModelSelectionChoice> Projects { get; init; } = new(StringComparer.Ordinal);
    public Dictionary<string, ModelContextChoice> Contexts { get; init; } = new(StringComparer.Ordinal);
    public HashSet<string> DisabledModels { get; init; } = new(StringComparer.Ordinal);
    public bool IncludeGPT56Models { get; init; }
    public AutoRouterPolicy Router { get; init; } = new();
}
