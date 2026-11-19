using System.Text.Json;
using Veo.Core;
using Veo.Infrastructure.PromptLibrary;
using Veo.Infrastructure.Storage;

var count = 0;
void Check(bool value, string name) { if (!value) throw new Exception("FAILED " + name); count++; Console.WriteLine("PASS " + name); }
async Task Refuses(Func<Task> action, string name) { try { await action(); } catch (Exception error) when (error is InvalidOperationException or InvalidDataException or ArgumentException or IOException or UnauthorizedAccessException or OperationCanceledException or JsonException) { Check(true, name); return; } throw new Exception("FAILED accepted " + name); }
static JsonElement J(string json) => JsonDocument.Parse(json).RootElement.Clone();
static JsonElement E(object value) => JsonSerializer.SerializeToElement(value);
var root = Path.Combine(Path.GetTempPath(), "Veo.Composer.Tests-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
var image = Path.Combine(root, "image 🦊.png"); var audio = Path.Combine(root, "recording.wav"); var mentioned = Path.Combine(root, "quoted file.txt");
await File.WriteAllBytesAsync(image, [1, 2, 3, 4]); await File.WriteAllBytesAsync(audio, [7, 8, 9]); await File.WriteAllTextAsync(mentioned, "reference");
var attachments = new ComposerAttachment[]
{
    new(ComposerAttachmentKind.LocalImage, image, "Screenshot", "i1"), new(ComposerAttachmentKind.Image, "https://media.invalid/image.png?fixture=redacted", "Remote picture", "i2"),
    new(ComposerAttachmentKind.LocalAudio, audio, "Recording", "a1"), new(ComposerAttachmentKind.Audio, "https://media.invalid/audio.wav?fixture=redacted", "Remote recording", "a2"),
    new(ComposerAttachmentKind.FileMention, mentioned, "quoted file.txt", "m1"), new(ComposerAttachmentKind.Skill, "C:\\fixture skills\\SKILL.md", "fixture-skill", "s1")
};
var lane = new FamilyAutoLane("family:model", "wire-model", "Fixture model", "high"); var family = new FamilyAutoPlan("fixture", lane, lane, lane, lane, "single", ["captured"]);
var policy = new AutoRouterPolicy(true, "Utility", true, false, "fixture-utility", true);
var settings = new ComposerSnapshot("client", "Prompt", "fixture-model", "high", "priority", "Read only", "Debug", [image], ContextTokens: 123456, RoutingMode: "Family Auto", RouterPolicy: policy, FamilyPlan: family, CatalogModelId: "family:model", StructuredAttachments: attachments, DraftOptionsJson: "{\"future_option\":{\"unknown\":[1,true,\"retained\"]}}");
var frozen = settings.Freeze(); var inputs = E(ComposerProtocol.Input(frozen));
Check(inputs.EnumerateArray().Select(x => x.Str("type")).SequenceEqual(["text", "localImage", "image", "localAudio", "audio", "mention", "skill"]), "all six source attachment kinds map to exact Codex UserInput variants");
Check(inputs[1].Str("path") == image && inputs[2].Str("url") == attachments[1].Source && inputs[5].Str("path") == mentioned && inputs[5].Str("name") == "quoted file.txt" && inputs[6].Str("name") == "fixture-skill", "typed protocol preserves Unicode paths, remote URLs and mention/skill names exactly");
Check(inputs[5].TryGetProperty("url", out _) == false && inputs[2].TryGetProperty("path", out _) == false, "wire media URL and local reference path fields remain distinct");
attachments[0] = attachments[0] with { Source = "changed by caller" }; family.Warnings[0] = "changed";
Check(ComposerProtocol.Attachments(frozen)[0].Source == image && frozen.FamilyPlan!.Warnings[0] == "captured", "snapshot Freeze copies attachment and family arrays before caller mutation");
var vision = new VisionFallbackContext("utility", "Fixture Utility", [new(image, "Image", "SHA", "description")]);
var visionInputs = E(ComposerProtocol.Input(frozen with { VisionFallback = vision }));
Check(visionInputs.GetArrayLength() == 5 && visionInputs.EnumerateArray().Any(x => x.Str("type") == "localAudio") && visionInputs.EnumerateArray().Any(x => x.Str("type") == "mention"), "vision fallback suppresses only images and retains audio, files and skills");
var legacy = ComposerDraft.Read(new("old draft", JsonSerializer.Serialize(new[] { audio, image }), "{}"));
Check(legacy.Attachments.All(x => x.Kind == ComposerAttachmentKind.LocalImage) && legacy.Attachments[0].Source == audio, "legacy string-array drafts remain images without extension-based reclassification");
Check(legacy.Attachments.Select(x => x.Id).SequenceEqual(ComposerDraft.Read(new("old draft", JsonSerializer.Serialize(new[] { audio, image }))).Attachments.Select(x => x.Id)), "legacy attachment identities remain stable across draft reads");
var draft = ComposerDraft.FromSnapshot(frozen); var saved = draft.Persisted(); var reopened = ComposerDraft.Read(saved);
Check(reopened.Attachments.SequenceEqual(frozen.StructuredAttachments!) && reopened.Text == "Prompt", "typed draft round-trip retains all identities, kinds, names and exact sources");
var restored = reopened.Snapshot("same-client");
Check(restored.ContextTokens == 123456 && restored.RoutingMode == "Family Auto" && restored.RouterPolicy == policy && restored.FamilyPlan!.Family == "fixture" && restored.CatalogModelId == "family:model", "shared snapshot parser retains full custom context and routing/family/catalog settings");
Check(restored.Access == "Read only" && restored.Mode == "Debug" && restored.Model == "fixture-model" && restored.Effort == "high" && restored.Tier == "priority", "shared snapshot parser retains model effort speed access and mode");
Check(J(restored.DraftOptionsJson!).GetProperty("future_option").GetProperty("unknown")[2].GetString() == "retained", "unknown draft options survive typed settings and snapshot conversion");
var settingsOnly = reopened.Snapshot(includeInput: false);
Check(settingsOnly.Attachments.Length == 0 && settingsOnly.StructuredAttachments!.Length == 0 && settingsOnly.Text == "" && settingsOnly.ContextTokens == restored.ContextTokens && settingsOnly.RouterPolicy == restored.RouterPolicy, "plan settings snapshot excludes draft input while retaining context and routing choices");
var changedSettings = reopened.WithSettings(restored with { Model = "changed-model", Tier = null, ContextTokens = null, RouterPolicy = null });
var cleared = changedSettings.Snapshot(defaults: frozen);
Check(cleared.Tier is null && cleared.ContextTokens is null && cleared.RouterPolicy is null && J(changedSettings.OptionsJson).TryGetProperty("future_option", out _), "explicit null clears prior settings while unknown option fields remain intact");
await Refuses(() => Task.FromResult(ComposerDraft.Read(new("draft", "{}"))), "invalid attachment JSON shape is preserved and refused");
await Refuses(() => Task.FromResult(ComposerDraft.Read(new("draft", "[]", "{\"access\":\"unknown-mode\"}")).Snapshot()), "unknown saved access is refused rather than broadened");
await Refuses(() => Task.FromResult(ComposerDraft.Read(new("draft", "[]", "{\"contextTokens\":-1}")).Snapshot()), "invalid saved custom context is refused");
foreach (var raw in inputs.EnumerateArray().Skip(1)) Check(ComposerAttachment.FromUserInput(raw).UserInput() is not null, "typed user-input media/reference parser accepts " + raw.Str("type"));

var record = new PersistedThread("typed", null, root, "Typed fixture");
await using (var workspace = new WorkspaceCoordinator(Path.Combine(root, "profile")))
{
    await workspace.Threads.InitializeAsync(); await workspace.Threads.UpsertThreadAsync(record); var session = await workspace.LoadAsync(record);
    await ComposerDraft.SaveAsync(workspace, session, draft); await workspace.Threads.SaveStateAsync(record.VeoId, "queue", JsonSerializer.Serialize(new[] { frozen }));
    Check(ComposerDraft.Snapshot(session, includeInput: true).StructuredAttachments!.Length == 6 && ComposerDraft.Snapshot(session).ContextTokens == 123456, "durable typed draft and settings-only plan helper share complete snapshot logic");
}
await using (var workspace = new WorkspaceCoordinator(Path.Combine(root, "profile")))
{
    var session = await workspace.LoadAsync(record); var snapshot = ComposerDraft.Snapshot(session, true);
    Check(snapshot.StructuredAttachments!.SequenceEqual(frozen.StructuredAttachments!) && snapshot.RouterPolicy == policy && session.Queue.Single().StructuredAttachments!.Length == 6, "SQLite draft and frozen queued typed input survive application-owner reopen");
    var rpc = new FakeRpc { Supported = false }; using var queue = new QueueCoordinator(workspace, rpc);
    await queue.EditAsync(session, frozen.ClientId, "edited queue text", [image]); var edited = session.Queue.Single();
    Check(edited.StructuredAttachments!.Length == 6 && edited.StructuredAttachments.Any(x => x.Kind == ComposerAttachmentKind.Skill) && edited.ContextTokens == 123456 && edited.RouterPolicy == policy, "legacy image-only queue editor preserves all structured nonimage attachments and frozen options");
}

var library = new PromptLibraryService(Path.Combine(root, "library-profile"));
var prompt = await library.SaveAsync(draft.Text, draft.Attachments.Select(x => x.ToPromptAttachment()).ToArray(), root);
var restoredPrompt = await library.RestoreAsync(prompt.Id, root); var merged = new ComposerDraft("existing", [new(ComposerAttachmentKind.Skill, "existing skill", "existing")], draft.OptionsJson).Append(restoredPrompt.Text, restoredPrompt.Attachments.Select(ComposerAttachment.FromPromptAttachment));
Check(merged.Attachments.Length == 7 && merged.Attachments[0].Source == "existing skill" && merged.Text == "existing\n\nPrompt", "prompt restore appends all typed references and media without dropping existing draft attachments");
Check(merged.Attachments.First(x => x.Kind == ComposerAttachmentKind.FileMention).Source == mentioned && merged.Attachments.First(x => x.Kind == ComposerAttachmentKind.Image).Source == frozen.StructuredAttachments![1].Source, "prompt library preserves exact mention and remote media sources");
Check((await File.ReadAllBytesAsync(merged.Attachments.First(x => x.Kind == ComposerAttachmentKind.LocalAudio).Source)).SequenceEqual(new byte[] { 7, 8, 9 }) && await File.ReadAllTextAsync(mentioned) == "reference", "library copies local audio bytes independently and preserves original mention file");

await using (var repository = new ThreadRepository(Path.Combine(root, "suggestions.sqlite")))
{
    var registry = new CommandRegistry(repository); await registry.InitializeAsync(); var service = new ComposerSuggestionService(registry); var session = new ThreadSession(record);
    Check(ComposerCompletionToken.Parse("email@example.invalid", 21) is null && ComposerCompletionToken.Parse("edit /plan", 10) is null, "autocomplete does not capture email text or slash paths inside prose");
    Check(ComposerCompletionToken.Parse("/pl", 3, isComposing: true) is null && ComposerCompletionToken.Parse("/pl", 2) is null && ComposerCompletionToken.Parse("/pl", 3, 1) is null, "IME composition, interior caret and selected text suppress completion");
    var commandToken = ComposerCompletionToken.Parse("/pl", 3)!; var commandSuggestions = await service.QueryAsync(session, commandToken);
    Check(commandSuggestions.First().Command!.SlashName == "plan" && commandSuggestions.All(x => x.Kind == ComposerSuggestionKind.Command), "slash suggestions use the shared source command catalog");
    var fileToken = ComposerCompletionToken.Parse("inspect @quoted", 15)!; var fileSuggestions = await service.QueryAsync(session, fileToken);
    Check(fileSuggestions.Single().Attachment!.Source == mentioned && fileSuggestions.Single().Attachment!.Kind == ComposerAttachmentKind.FileMention, "file autocomplete resolves real project file and creates exact typed mention");
    Check(fileToken.RemoveFrom("inspect @quoted") == "inspect ", "mention acceptance removes only its trailing token");
    await Refuses(() => Task.FromResult(fileToken.RemoveFrom("inspect changed")), "stale completion cannot remove changed composer text");
    var outside = Path.Combine(Path.GetDirectoryName(root)!, "outside-" + Guid.NewGuid().ToString("N") + ".txt"); await File.WriteAllTextAsync(outside, "outside");
    await Refuses(() => Task.FromResult(ComposerAttachment.FileMention(root, outside)), "file mention refuses an outside workspace path");
    var skill = new SkillIntegration("skill-id", "fixture-skill", "Fixture skill", "From runtime inventory", "C:\\fixture skills\\SKILL.md", "user", true, J("{}"));
    var skillToken = ComposerCompletionToken.Parse("use $fixture", 12)!; var skillSuggestions = await service.QueryAsync(session, skillToken, [skill, skill with { Name = "disabled", Enabled = false }]);
    Check(skillSuggestions.Count == 1 && skillSuggestions[0].Attachment!.Name == "fixture-skill", "skill completion uses only enabled runtime-inventory identities");
    Check(ComposerSuggestionService.ValidateAttachment(session, skillSuggestions[0], [skill]).Source == skill.Path, "skill acceptance retains exact runtime-provided path outside project");
    await Refuses(() => Task.FromResult(ComposerSuggestionService.ValidateAttachment(session, skillSuggestions[0], [skill with { Enabled = false }])), "disabled stale runtime skill cannot be accepted");
    var gitReference = Path.Combine(root, ".git", "refs", "veo", "checkpoint");
    Directory.CreateDirectory(Path.GetDirectoryName(gitReference)!);
    await File.WriteAllTextAsync(gitReference, "fixture metadata");
    var rpc = new FakeRpc { Handler = (_, p) => E(new { files = new[]
    {
        new { path = "quoted file.txt", root, match_type = "file" },
        new { path = gitReference, root, match_type = "file" },
        new { path = outside, root, match_type = "file" },
        new { path = "folder", root, match_type = "directory" }
    } }) };
    var fuzzy = new ComposerSuggestionService(registry, rpc); var fuzzyResults = await fuzzy.QueryAsync(session, fileToken);
    Check(fuzzyResults.Count == 1 && fuzzyResults[0].Attachment!.Source == mentioned && rpc.Last!.Value.GetProperty("roots")[0].GetString() == root, "runtime fuzzy file results exclude Git metadata, directories and files beyond the workspace");
    await Refuses(() => Task.FromResult(ComposerSuggestionService.ValidateAttachment(session,
        new(ComposerSuggestionKind.File, "checkpoint", "", gitReference))), "acceptance rejects a stale Git metadata suggestion");
    using var cancelled = new CancellationTokenSource(); cancelled.Cancel(); await Refuses(() => fuzzy.QueryAsync(session, fileToken, cancellation: cancelled.Token), "cancelled autocomplete does not publish a stale query");
}
Console.WriteLine($"{count} typed composer/draft/mentions checks passed; no remote media or model request was sent.");

sealed class FakeRpc : ICoordinatorRpc
{
    public long Generation => 1; public bool Supported { get; set; } = true; public JsonElement? Last;
    public Func<string, JsonElement, JsonElement> Handler { get; set; } = (_, _) => JsonSerializer.SerializeToElement(new { data = Array.Empty<object>() });
    public bool Supports(string method) => Supported;
    public Task<JsonElement> RequestAsync(string method, object? parameters, CancellationToken token = default) { token.ThrowIfCancellationRequested(); Last = JsonSerializer.SerializeToElement(parameters); return Task.FromResult(Handler(method, Last.Value)); }
}
