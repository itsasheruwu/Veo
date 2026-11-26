using Veo.Infrastructure.Files;

namespace Veo.Core;

public enum ComposerSuggestionKind { Command, File, Skill, Plugin }
public sealed record ComposerCompletionToken(string Text, int Start, int Length, char Trigger, string Query)
{
    public static ComposerCompletionToken? Parse(string text, int caret, int selectionLength = 0, bool isComposing = false)
    {
        if (isComposing || selectionLength != 0 || caret != text.Length || text.Length == 0 || char.IsWhiteSpace(text[^1])) return null;
        var start = text.Length - 1; while (start > 0 && !char.IsWhiteSpace(text[start - 1])) start--;
        var token = text[start..]; if (token[0] is not ('@' or '$' or '/')) return null;
        if (token[0] == '/' && (text.Trim() != token || token.StartsWith("//", StringComparison.Ordinal))) return null;
        return new(text, start, token.Length, token[0], token[1..]);
    }
    public string RemoveFrom(string current)
    { if (current != Text) throw new InvalidOperationException("Composer text changed; the stale completion was not applied."); return current.Remove(Start, Length); }
}
public sealed record ComposerSuggestion(ComposerSuggestionKind Kind, string Title, string Description, string Source,
    CommandDefinition? Command = null, ComposerAttachment? Attachment = null, string? BrandColor = null);

/// <summary>File suggestions are confined to the actual workspace; skills come only from runtime inventory.</summary>
public sealed class ComposerSuggestionService(CommandRegistry registry, ICoordinatorRpc? transport = null)
{
    public async Task<IReadOnlyList<ComposerSuggestion>> QueryAsync(ThreadSession session, ComposerCompletionToken token,
        IReadOnlyList<SkillIntegration>? skills = null, CancellationToken cancellation = default,
        IReadOnlyList<PluginIntegration>? plugins = null)
    {
        cancellation.ThrowIfCancellationRequested();
        if (token.Trigger == '/')
            return registry.Suggestions("").Where(x => x.SlashName is not null && (x.SlashName.Contains(token.Query, StringComparison.OrdinalIgnoreCase) || x.Description.Contains(token.Query, StringComparison.OrdinalIgnoreCase)))
                .OrderByDescending(x => x.SlashName!.StartsWith(token.Query, StringComparison.OrdinalIgnoreCase)).Take(12)
                .Select(x => new ComposerSuggestion(ComposerSuggestionKind.Command, "/" + x.SlashName, x.Description, x.Id, x)).ToArray();
        if (token.Trigger == '$')
            return (skills ?? []).Where(x => x.Enabled && !string.IsNullOrWhiteSpace(x.Path) && (x.Name.Contains(token.Query, StringComparison.OrdinalIgnoreCase) || x.Title.Contains(token.Query, StringComparison.OrdinalIgnoreCase))).Take(8)
                .Select(x => new ComposerSuggestion(ComposerSuggestionKind.Skill, x.Name, x.Description, x.Path!, Attachment: new(ComposerAttachmentKind.Skill, x.Path!, x.Name, Guid.NewGuid().ToString("N")))).ToArray();
        if (token.Trigger != '@') return [];
        var pluginRows = PluginSuggestions(plugins ?? [], token.Query).Take(8).ToArray();
        if (session.Record.WorkspaceKind != "project" || pluginRows.Length == 8) return pluginRows;
        var policy = new WorkspacePathPolicy(session.Record.Cwd); var paths = new List<string>();
        if (transport?.Supports("fuzzyFileSearch") == true)
        {
            var result = await transport.RequestAsync("fuzzyFileSearch", new { query = token.Query, roots = new[] { policy.RootPath }, cancellationToken = Guid.NewGuid().ToString("N") }, cancellation);
            foreach (var row in ThreadCatalogCoordinator.Rows(result, "files"))
            {
                if (row.Str("match_type") == "directory" || row.Str("path") is not { } path) continue;
                try { paths.Add(policy.Resolve(Path.IsPathFullyQualified(path) ? path : Path.Combine(row.Str("root") ?? policy.RootPath, path))); }
                catch (Exception error) when (error is UnauthorizedAccessException or IOException or ArgumentException) { }
            }
        }
        else
        {
            var files = new WorkspaceFileService(policy.RootPath);
            var found = token.Query.Length == 0 ? (await files.ListChildrenAsync(cancellationToken: cancellation)).Where(x => !x.IsDirectory).ToArray() : await files.SearchAsync(token.Query, 8, cancellation);
            foreach (var file in found) { cancellation.ThrowIfCancellationRequested(); try { paths.Add(policy.Resolve(file.RelativePath)); } catch (UnauthorizedAccessException) { } }
        }
        return pluginRows.Concat(paths.Distinct(StringComparer.OrdinalIgnoreCase)
            .Where(path => File.Exists(path) && !IsGitMetadata(policy.Relative(path)))
            .Take(8 - pluginRows.Length)
            .Select(path => new ComposerSuggestion(ComposerSuggestionKind.File, Path.GetFileName(path),
                policy.Relative(path), path, Attachment: ComposerAttachment.FileMention(policy.RootPath, path)))).ToArray();
    }

    public static IEnumerable<ComposerSuggestion> PluginSuggestions(IEnumerable<PluginIntegration> plugins, string query = "") =>
        plugins.Where(plugin => plugin.Installed && plugin.Enabled && InlineChatContext.ValidPluginId(plugin.Id)
            && plugin.Availability != "DISABLED_BY_ADMIN"
            && (plugin.Title.Contains(query, StringComparison.OrdinalIgnoreCase) || plugin.Id.Contains(query, StringComparison.OrdinalIgnoreCase)))
        .DistinctBy(plugin => plugin.Id).Select(plugin => new ComposerSuggestion(ComposerSuggestionKind.Plugin,
            plugin.Title, plugin.Description, plugin.Id, BrandColor: plugin.Raw.TryObjectProperty("interface", out var info)
                ? info.Str("brandColor") : null));

    static bool IsGitMetadata(string relativePath) =>
        relativePath.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            .Contains(".git", StringComparer.OrdinalIgnoreCase);

    public static ComposerAttachment ValidateAttachment(ThreadSession session, ComposerSuggestion suggestion, IReadOnlyList<SkillIntegration>? currentSkills = null)
    {
        if (suggestion.Kind == ComposerSuggestionKind.File)
        {
            var attachment = ComposerAttachment.FileMention(session.Record.Cwd, suggestion.Source);
            if (!IsGitMetadata(attachment.Name)) return attachment;
        }
        if (suggestion.Kind == ComposerSuggestionKind.Skill && (currentSkills ?? []).Any(x => x.Enabled && x.Path == suggestion.Source && x.Name == suggestion.Attachment?.Name)) return suggestion.Attachment!;
        throw new InvalidOperationException("This suggestion is no longer available from the current workspace or runtime skill inventory.");
    }
}
