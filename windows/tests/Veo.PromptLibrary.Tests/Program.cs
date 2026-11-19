using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Veo.Infrastructure.PromptLibrary;

var passed = new List<string>();
void Check(bool condition, string name) { if (!condition) throw new Exception("FAILED " + name); passed.Add(name); Console.WriteLine("PASS " + name); }
async Task Refuses(Func<Task> action, string name)
{ try { await action(); } catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException) { Check(true, name); return; } throw new Exception("FAILED accepted " + name); }
var root = Path.Combine(Path.GetTempPath(), "Veo.PromptLibrary.Tests-" + Guid.NewGuid().ToString("N"));
var data = Path.Combine(root, "Data"); var source = Path.Combine(root, "Original media"); var workspaceA = Path.Combine(root, "Project A"); var workspaceB = Path.Combine(root, "Project B");
Directory.CreateDirectory(source); Directory.CreateDirectory(workspaceA); Directory.CreateDirectory(workspaceB);
var image = Path.Combine(source, "image ü.png"); var audio = Path.Combine(source, "voice.wav");
var imageBytes = Enumerable.Range(0, 256).Select(i => (byte)i).ToArray(); var audioBytes = Encoding.UTF8.GetBytes("redacted deterministic audio fixture bytes");
await File.WriteAllBytesAsync(image, imageBytes); await File.WriteAllBytesAsync(audio, audioBytes);
var fileMention = Path.Combine(workspaceA, "original file.txt"); var skill = Path.Combine(root, "skills", "example", "SKILL.md");
var library = new PromptLibraryService(data);
var saved = await library.SaveAsync("Exact prompt 🦊\r\nsecond line", [new(PromptAttachmentKind.LocalImage, image, "Picture"), new(PromptAttachmentKind.LocalAudio, audio, "Recording"),
    new(PromptAttachmentKind.FileMention, fileMention, "original file.txt"), new(PromptAttachmentKind.Skill, skill, "example"), new(PromptAttachmentKind.Image, "https://example.invalid/image.png", "Remote image")], workspaceA);
Check(saved.Attachments[0].LibraryFile is not null && saved.Attachments[1].LibraryFile is not null && saved.Attachments[0].Sha256 == Convert.ToHexString(SHA256.HashData(imageBytes)), "saved local image/audio have independent library files and exact hashes");
Check((await File.ReadAllBytesAsync(image)).SequenceEqual(imageBytes) && (await File.ReadAllBytesAsync(audio)).SequenceEqual(audioBytes), "saving a prompt leaves original media bytes untouched");
var reopened = new PromptLibraryService(data);
Check((await reopened.ListAsync()).Single().Text == "Exact prompt 🦊\r\nsecond line", "saved prompt text and CRLF survive library reopen");
Check((await reopened.ListAsync("original file")).Count == 1 && (await reopened.ListAsync("not found")).Count == 0, "library search matches attachment names without fabricated results");
await File.WriteAllBytesAsync(image, [9, 9, 9]); File.Delete(audio);
var restoredA = await reopened.RestoreAsync(saved.Id, workspaceA); var restoredB = await reopened.RestoreAsync(saved.Id, workspaceB);
Check((await File.ReadAllBytesAsync(restoredA.Attachments[0].Source)).SequenceEqual(imageBytes) && (await File.ReadAllBytesAsync(restoredA.Attachments[1].Source)).SequenceEqual(audioBytes), "restore uses saved media even if original media changed or disappeared");
Check(restoredA.Attachments[0].Source != restoredB.Attachments[0].Source && Path.GetRelativePath(workspaceA, restoredA.Attachments[0].Source).Split(Path.DirectorySeparatorChar)[0] == "Attachments",
    "each restored workspace gets its own designated Attachments copy");
Check(restoredA.Attachments[2].Source == fileMention && restoredA.Attachments[3].Source == skill && restoredA.Attachments[4].Source == "https://example.invalid/image.png",
    "restore preserves original file/skill mention paths and remote media URLs");
await reopened.RemoveAsync(saved.Id);
Check((await reopened.ListAsync()).Count == 0 && File.Exists(restoredA.Attachments[0].Source) && File.Exists(restoredB.Attachments[1].Source), "deleting saved prompt preserves every media copy already restored to drafts");
Check(File.Exists(image) && (await File.ReadAllBytesAsync(image)).SequenceEqual(new byte[] { 9, 9, 9 }), "deleting saved prompt never deletes or reverts its original source file");

var corrupt = await reopened.SaveAsync("Integrity", [new(PromptAttachmentKind.LocalImage, image, "Image")], workspaceA);
var storedMedia = Path.Combine(data, "PromptLibrary", corrupt.Id, corrupt.Attachments[0].LibraryFile!);
await File.WriteAllTextAsync(storedMedia, "external corruption");
await Refuses(async () => { await reopened.RestoreAsync(corrupt.Id, workspaceA); }, "restore refuses modified saved media instead of silently using corrupted bytes");
Check((await reopened.ListAsync()).Count == 1 && File.Exists(storedMedia), "integrity failure preserves library manifest and media for recovery");
await reopened.RemoveAsync(corrupt.Id);

var missing = await reopened.SaveAsync("Missing media", [new(PromptAttachmentKind.LocalImage, image, "Image")], workspaceA);
File.Delete(Path.Combine(data, "PromptLibrary", missing.Id, missing.Attachments[0].LibraryFile!));
await reopened.RemoveAsync(missing.Id);
Check((await reopened.ListAsync()).Count == 0, "user can remove a library entry whose media was already deleted externally");

await Refuses(async () => { await reopened.SaveAsync("Failed copy", [new(PromptAttachmentKind.LocalImage, image, "First"), new(PromptAttachmentKind.LocalAudio, Path.Combine(source, "missing.wav"), "Missing")], workspaceA); }, "missing second media rejects save without losing original files");
Check((await reopened.ListAsync()).Count == 0 && File.Exists(image), "failed prompt save does not publish a partial manifest entry");
await Refuses(async () => { await reopened.SaveAsync("", [], workspaceA); }, "empty prompt without attachments is refused");

var parallelA = new PromptLibraryService(data); var parallelB = new PromptLibraryService(data);
await Task.WhenAll(parallelA.SaveAsync("Concurrent A", [], workspaceA), parallelB.SaveAsync("Concurrent B", [], workspaceB));
Check((await reopened.ListAsync()).Count == 2, "concurrent library instances preserve both independently saved prompts");

var escapedWorkspace = Path.Combine(root, "Escaped project"); var outside = Path.Combine(root, "Outside"); Directory.CreateDirectory(escapedWorkspace); Directory.CreateDirectory(outside);
try
{
    Directory.CreateSymbolicLink(Path.Combine(escapedWorkspace, "Attachments"), outside);
    var mediaPrompt = await reopened.SaveAsync("Boundary", [new(PromptAttachmentKind.LocalImage, image, "Image")], workspaceA);
    await Refuses(async () => { await reopened.RestoreAsync(mediaPrompt.Id, escapedWorkspace); }, "restored media cannot escape workspace through an Attachments junction");
    Check(!Directory.EnumerateFileSystemEntries(outside).Any(), "junction escape refusal leaves outside directory untouched");
}
catch (UnauthorizedAccessException) { Console.WriteLine("GAP symbolic-link creation requires developer mode or privilege"); }

Console.WriteLine(JsonSerializer.Serialize(new { Passed = passed.Count, Root = root, Scenarios = passed }));
