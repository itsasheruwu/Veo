using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Veo.Infrastructure.Files;
using Veo.Infrastructure.Storage;
using Veo.Infrastructure.PromptLibrary;

namespace Veo.Core;

[JsonConverter(typeof(JsonStringEnumConverter<ComposerAttachmentKind>))]
public enum ComposerAttachmentKind { LocalImage, Image, LocalAudio, Audio, FileMention, Skill }
public sealed record ComposerAttachment(ComposerAttachmentKind Kind, string Source, string Name, string Id = "")
{
    public object UserInput() => Kind switch
    {
        ComposerAttachmentKind.LocalImage => new { type = "localImage", path = Source },
        ComposerAttachmentKind.Image => (object)new { type = "image", url = Source },
        ComposerAttachmentKind.LocalAudio => new { type = "localAudio", path = Source },
        ComposerAttachmentKind.Audio => new { type = "audio", url = Source },
        ComposerAttachmentKind.FileMention => new { type = "mention", name = Name, path = Source },
        ComposerAttachmentKind.Skill => new { type = "skill", name = Name, path = Source },
        _ => throw new InvalidDataException("Unknown composer attachment kind.")
    };
    public PromptAttachment ToPromptAttachment() => new((PromptAttachmentKind)Kind, Source, Name);
    public static ComposerAttachment FromPromptAttachment(PromptAttachment value) => new((ComposerAttachmentKind)value.Kind, value.Source, value.Name, Guid.NewGuid().ToString("N"));
    public static ComposerAttachment FileMention(string workspace, string path)
    {
        var policy = new WorkspacePathPolicy(workspace); var resolved = policy.Resolve(path);
        if (!File.Exists(resolved) && !Directory.Exists(resolved)) throw new FileNotFoundException("The mentioned file is unavailable.");
        return new(ComposerAttachmentKind.FileMention, resolved, policy.Relative(resolved), Guid.NewGuid().ToString("N"));
    }
    public static ComposerAttachment FromUserInput(JsonElement value)
    {
        var kind = value.Str("type") switch { "localImage" => ComposerAttachmentKind.LocalImage, "image" => ComposerAttachmentKind.Image, "localAudio" => ComposerAttachmentKind.LocalAudio, "audio" => ComposerAttachmentKind.Audio, "mention" => ComposerAttachmentKind.FileMention, "skill" => ComposerAttachmentKind.Skill, _ => throw new InvalidDataException("This input has no supported composer attachment representation.") };
        var source = value.Str(kind is ComposerAttachmentKind.Image or ComposerAttachmentKind.Audio ? "url" : "path") ?? throw new InvalidDataException("The attachment has no source.");
        return new(kind, source, value.Str("name") ?? Path.GetFileName(source), Guid.NewGuid().ToString("N"));
    }
}

/// <summary>Lossless options and typed media/reference drafts, with legacy string-array image compatibility.</summary>
public sealed record ComposerDraft(string Text, ComposerAttachment[] Attachments, string OptionsJson = "{}", DateTimeOffset UpdatedAt = default)
{
    static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
    public ComposerDraft Freeze() => this with { Attachments = Attachments.ToArray() };
    public static ComposerDraft Read(PersistedDraft value)
    {
        using var options = JsonDocument.Parse(value.OptionsJson); if (options.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Composer options must be an object; the original draft was kept.");
        using var json = JsonDocument.Parse(value.AttachmentsJson); if (json.RootElement.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Composer attachments must be an array; the original draft was kept.");
        var attachments = json.RootElement.EnumerateArray().Select((item, index) =>
        {
            var attachment = item.ValueKind == JsonValueKind.String
                ? new ComposerAttachment(ComposerAttachmentKind.LocalImage, item.GetString()!, Path.GetFileName(item.GetString()!))
                : item.Deserialize<ComposerAttachment>(Json) ?? throw new InvalidDataException("A saved composer attachment is invalid.");
            if (!Enum.IsDefined(attachment.Kind) || string.IsNullOrWhiteSpace(attachment.Source) || attachment.Source.Contains('\0')) throw new InvalidDataException("A saved composer attachment has an invalid source or kind.");
            return string.IsNullOrEmpty(attachment.Id) ? attachment with { Id = "draft-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{index}|{attachment.Kind}|{attachment.Source}")))[..24] } : attachment;
        }).ToArray();
        return new(value.Text, attachments, value.OptionsJson, value.UpdatedAt);
    }
    public PersistedDraft Persisted() => new(Text, JsonSerializer.Serialize(Attachments), OptionsJson, UpdatedAt == default ? DateTimeOffset.UtcNow : UpdatedAt);
    public static async Task SaveAsync(WorkspaceCoordinator workspace, ThreadSession session, ComposerDraft draft, CancellationToken token = default)
    {
        var persisted = draft.Persisted(); await workspace.Threads.SaveDraftAsync(session.Record.VeoId, persisted, token);
        session.Draft = persisted; workspace.NotifyChanged();
    }
    public ComposerSnapshot Snapshot(string? clientId = null, ComposerSnapshot? defaults = null, bool includeInput = true)
    {
        var root = JsonNode.Parse(OptionsJson)?.AsObject() ?? throw new InvalidDataException("Invalid composer options.");
        JsonNode? Value(string name) => root.FirstOrDefault(x => x.Key.Equals(name, StringComparison.OrdinalIgnoreCase)).Value;
        bool Has(string name) => root.Any(x => x.Key.Equals(name, StringComparison.OrdinalIgnoreCase));
        string? String(string name, string? fallback = null) => Value(name) is { } value ? value.GetValue<string>() : fallback;
        string? NullableString(string name, string? fallback = null) => Has(name) ? Value(name)?.GetValue<string>() : fallback;
        T? Record<T>(string name, T? fallback) where T : class => Has(name) ? Value(name)?.Deserialize<T>(Json) : fallback;
        var access = String("access", defaults?.Access ?? "Workspace")!; if (!ComposerPermission.IsKnown(access)) throw new InvalidDataException("The saved access mode is unknown. Choose an explicit access mode before sending.");
        var context = Value("contextTokens") is { } count ? count.GetValue<long>() : Has("contextTokens") ? null : defaults?.ContextTokens;
        if (context is <= 0) throw new InvalidDataException("Saved context tokens must be positive.");
        var selected = includeInput ? Attachments.ToArray() : [];
        var daybreak = Has("daybreak") ? Value("daybreak")?.GetValue<bool>() : defaults?.Daybreak;
        return new ComposerSnapshot(clientId ?? Guid.NewGuid().ToString("N"), includeInput ? Text : "", String("model", defaults?.Model), String("effort", defaults?.Effort), NullableString("tier", defaults?.Tier), access,
            String("mode", defaults?.Mode ?? "Agentic")!, selected.Where(x => x.Kind == ComposerAttachmentKind.LocalImage).Select(x => x.Source).ToArray(),
            defaults?.PreserveDraft ?? false, context, String("routingMode", defaults?.RoutingMode ?? "Direct")!, Record("routerPolicy", defaults?.RouterPolicy), Record("familyPlan", defaults?.FamilyPlan), Record("visionFallback", defaults?.VisionFallback),
            String("modelCatalogId", String("catalogModelId", defaults?.CatalogModelId)), selected, OptionsJson, daybreak).Freeze();
    }
    public static ComposerSnapshot Snapshot(ThreadSession session, bool includeInput = false, ComposerSnapshot? defaults = null, string? clientId = null) => Read(session.Draft).Snapshot(clientId, defaults, includeInput);
    public static ComposerDraft FromSnapshot(ComposerSnapshot snapshot, string originalOptions = "{}") => new(snapshot.Text, ComposerProtocol.Attachments(snapshot).ToArray(), MergeOptions(snapshot.DraftOptionsJson ?? originalOptions, snapshot), DateTimeOffset.UtcNow);
    public ComposerDraft WithSettings(ComposerSnapshot settings) => this with { OptionsJson = MergeOptions(OptionsJson, settings) };
    public static string MergeOptions(string original, ComposerSnapshot settings)
    {
        var root = JsonNode.Parse(original)?.AsObject() ?? throw new InvalidDataException("Invalid composer options.");
        var values = new Dictionary<string, object?> { ["model"] = settings.Model, ["effort"] = settings.Effort, ["tier"] = settings.Tier, ["access"] = settings.Access, ["mode"] = settings.Mode, ["contextTokens"] = settings.ContextTokens, ["routingMode"] = settings.RoutingMode, ["routerPolicy"] = settings.RouterPolicy, ["familyPlan"] = settings.FamilyPlan, ["visionFallback"] = settings.VisionFallback, ["modelCatalogId"] = settings.CatalogModelId, ["daybreak"] = settings.Daybreak };
        foreach (var pair in values)
        {
            foreach (var key in root.Select(x => x.Key).Where(key => key.Equals(pair.Key, StringComparison.OrdinalIgnoreCase)).ToArray()) root.Remove(key);
            root[pair.Key] = JsonSerializer.SerializeToNode(pair.Value);
        }
        return root.ToJsonString();
    }
    public ComposerDraft Append(string text, IEnumerable<ComposerAttachment> attachments) => this with
    { Text = Text + (Text.Length == 0 || text.Length == 0 ? "" : "\n\n") + text, Attachments = Attachments.Concat(attachments).ToArray(), UpdatedAt = DateTimeOffset.UtcNow };
}
