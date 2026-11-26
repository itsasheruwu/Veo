using System.Text.Json;
using Veo.Infrastructure.Storage;

namespace Veo.Core;

public enum CatalogOrigin { Veo, Codex }
public enum CatalogSort { Priority, LastUpdated, Manual }
public sealed record CatalogOptions(CatalogSort Sort = CatalogSort.Priority, string[]? ManualOrder = null,
    Dictionary<string, string>? ProjectLabels = null, string[]? CollapsedProjects = null);
public sealed record CatalogEntry(string Key, CatalogOrigin Origin, PersistedThread Thread, JsonElement? Runtime = null);
public sealed record CatalogGroup(string CollapseKey, string Label, bool IsCollapsed, IReadOnlyList<CatalogEntry> Entries, bool IsProjectless);
public sealed record CatalogPage(IReadOnlyList<CatalogEntry> Veo, IReadOnlyList<CatalogEntry> Codex, string? NextCodexCursor);
public sealed record CatalogSearchResult(CatalogEntry Entry, string Snippet, string? ItemId = null, string? TurnId = null,
    string? TurnCursor = null, int MatchStart = 0, int MatchLength = 0);
public sealed record CatalogSearchPage(IReadOnlyList<CatalogSearchResult> Data, string? NextCursor);

/// <summary>Owns sidebar ordering and optional CLI history without changing repository visibility.</summary>
public sealed class ThreadCatalogCoordinator(WorkspaceCoordinator workspace, ICoordinatorRpc? transport = null)
{
    const string VeoProjectlessKey = "veo://catalog/projectless/veo";
    const string CodexProjectlessKey = "veo://catalog/projectless/codex";
    readonly ICoordinatorRpc rpc = transport ?? new WorkspaceCoordinatorRpc(workspace);
    readonly Dictionary<string, CatalogEntry> external = new(StringComparer.Ordinal);
    readonly HashSet<string> cursors = new(StringComparer.Ordinal);
    long generation = -1;
    public CatalogOptions Options { get; private set; } = new();
    public string? NextCodexCursor { get; private set; }
    public event Action? Changed;
    public async Task InitializeAsync(CancellationToken token = default)
    {
        var saved = await workspace.Threads.ReadStateAsync("catalog", "options", token);
        if (saved is not null) Options = JsonSerializer.Deserialize<CatalogOptions>(saved) ?? new();
    }
    public async Task SaveOptionsAsync(CatalogOptions options, CancellationToken token = default)
    {
        if (options.ProjectLabels?.Any(x => string.IsNullOrWhiteSpace(x.Key) || x.Value.Length > 160) == true) throw new ArgumentException("Project labels need a path and at most 160 characters.");
        Options = options with { ManualOrder = options.ManualOrder?.Distinct(StringComparer.Ordinal).ToArray(), ProjectLabels = options.ProjectLabels is null ? null : new(options.ProjectLabels, StringComparer.OrdinalIgnoreCase), CollapsedProjects = options.CollapsedProjects?.ToArray() };
        await workspace.Threads.SaveStateAsync("catalog", "options", JsonSerializer.Serialize(Options), token); Changed?.Invoke(); workspace.NotifyChanged();
    }
    public async Task SetCodexHistoryAsync(bool enabled)
    {
        workspace.Preferences.ShowCodexHistory = enabled; await workspace.SavePreferencesAsync();
        if (!enabled) { external.Clear(); NextCodexCursor = null; cursors.Clear(); }
        Changed?.Invoke(); workspace.NotifyChanged();
    }
    public async Task<CatalogPage> LoadAsync(bool nextCodexPage = false, CancellationToken token = default)
    {
        var locals = await workspace.Threads.ListThreadsAsync(workspace.Preferences.ShowArchived, limit: 100000, cancellationToken: token);
        var owned = locals.Where(x => !IsCodexShadow(x)).Select(x => new CatalogEntry(x.VeoId, CatalogOrigin.Veo, x)).ToArray();
        if (generation != rpc.Generation || !nextCodexPage) { external.Clear(); NextCodexCursor = null; cursors.Clear(); generation = rpc.Generation; }
        if (workspace.Preferences.ShowCodexHistory && rpc.Supports("thread/list") && (!nextCodexPage || NextCodexCursor is not null))
        {
            var cursor = nextCodexPage ? NextCodexCursor : null;
            var response = await rpc.RequestAsync("thread/list", new { archived = workspace.Preferences.ShowArchived, cursor, limit = 100, sortKey = "updated_at", currentAccountOnly = false }, token);
            var localRuntimeIds = owned.Select(x => x.Thread.CodexThreadId).OfType<string>().ToHashSet(StringComparer.Ordinal);
            foreach (var row in Rows(response, "data"))
                if (row.Str("id") is { Length: > 0 } id && !localRuntimeIds.Contains(id)) external[id] = RuntimeEntry(row, workspace.Preferences.ShowArchived);
            NextCodexCursor = response.Str("nextCursor");
            if (NextCodexCursor is not null && !cursors.Add(NextCodexCursor)) { NextCodexCursor = null; throw new InvalidDataException("Codex history repeated a page cursor."); }
        }
        if (!workspace.Preferences.ShowCodexHistory) external.Clear();
        return new(Sort(owned), Sort(external.Values), NextCodexCursor);
    }
    public IReadOnlyList<CatalogEntry> Sort(IEnumerable<CatalogEntry> entries)
    {
        var rows = entries.ToArray(); var manual = (Options.ManualOrder ?? []).Select((id, index) => (id, index)).ToDictionary(x => x.id, x => x.index, StringComparer.Ordinal);
        var ordered = Options.Sort switch
        {
            CatalogSort.Manual => rows.OrderBy(x => manual.GetValueOrDefault(x.Key, int.MaxValue)).ThenByDescending(x => x.Thread.UpdatedAt),
            CatalogSort.LastUpdated => rows.OrderByDescending(x => x.Thread.UpdatedAt),
            _ => rows.OrderByDescending(x => x.Thread.IsPinned).ThenByDescending(x => workspace.LoadedSessions.Any(s => s.Record.VeoId == x.Thread.VeoId && s.Timeline.IsRunning) || x.Thread.Status is "active" or "inProgress" or "running").ThenByDescending(x => x.Thread.UpdatedAt)
        };
        return ordered.ThenBy(x => x.Key, StringComparer.Ordinal).ToArray();
    }
    public IReadOnlyList<CatalogGroup> Group(IEnumerable<CatalogEntry> entries, IReadOnlyDictionary<string, string>? projectPaths = null) =>
        entries.GroupBy(entry => (entry.Thread.WorkspaceKind, entry.Origin) switch
        {
            ("scratch" or "temporary", CatalogOrigin.Codex) => CodexProjectlessKey,
            ("scratch" or "temporary", _) => VeoProjectlessKey,
            _ => ProjectKey(projectPaths?.GetValueOrDefault(entry.Thread.Cwd) ?? entry.Thread.Cwd)
        }, StringComparer.OrdinalIgnoreCase)
        .Select(group =>
        {
            var projectless = group.Key is VeoProjectlessKey or CodexProjectlessKey;
            var label = projectless ? "Projectless Chats" : Options.ProjectLabels?.GetValueOrDefault(group.Key) ?? ProjectName(group.Key);
            var collapsed = Options.CollapsedProjects?.Contains(group.Key, StringComparer.OrdinalIgnoreCase) == true;
            return new CatalogGroup(group.Key, label, collapsed, Sort(group), projectless);
        })
        .OrderByDescending(group => group.IsProjectless).ThenBy(group => group.Label, StringComparer.OrdinalIgnoreCase).ToArray();
    public Task ReorderVisibleAsync(IReadOnlyList<string> visibleOrder, IReadOnlyList<string> allKeys, CancellationToken token = default)
    {
        if (visibleOrder.Distinct(StringComparer.Ordinal).Count() != visibleOrder.Count || visibleOrder.Any(key => !allKeys.Contains(key, StringComparer.Ordinal))) throw new ArgumentException("The reordered rows must be distinct catalog rows.");
        var selected = visibleOrder.ToHashSet(StringComparer.Ordinal); var queue = new Queue<string>(visibleOrder);
        var master = (Options.ManualOrder ?? []).Concat(allKeys).Distinct(StringComparer.Ordinal).Where(allKeys.Contains).Select(id => selected.Contains(id) ? queue.Dequeue() : id).ToArray();
        return SaveOptionsAsync(Options with { Sort = CatalogSort.Manual, ManualOrder = master }, token);
    }
    public async Task<ThreadSession> OpenAsync(CatalogEntry entry)
    {
        if (entry.Origin == CatalogOrigin.Veo) return await workspace.LoadAsync(entry.Thread);
        if (!workspace.Preferences.ShowCodexHistory) throw new InvalidOperationException("Enable optional Codex history first.");
        var all = (await workspace.Threads.ListThreadsAsync(false, limit: 100000)).Concat(await workspace.Threads.ListThreadsAsync(true, limit: 100000));
        var record = all.FirstOrDefault(x => x.CodexThreadId == entry.Thread.CodexThreadId);
        if (record is null)
        {
            record = entry.Thread with { VeoId = Guid.NewGuid().ToString("N"), MetaJson = "{\"catalogOrigin\":\"codex\"}" };
            await workspace.Threads.UpsertThreadAsync(record);
        }
        return await workspace.LoadAsync(record);
    }
    public async Task RenameAsync(CatalogEntry entry, string title, CancellationToken token = default)
    {
        title = title.Trim(); if (title.Length is 0 or > 200) throw new ArgumentException("A chat name needs 1–200 characters.");
        if (entry.Origin == CatalogOrigin.Codex && entry.Thread.CodexThreadId is { } id)
        {
            if (!rpc.Supports("thread/name/set")) throw new NotSupportedException("This Codex version cannot rename runtime chats.");
            await rpc.RequestAsync("thread/name/set", new { threadId = id, name = title }, token);
        }
        if (entry.Origin == CatalogOrigin.Veo) await workspace.RenameAsync(await workspace.LoadAsync(entry.Thread), title);
        else
        {
            var local = (await workspace.Threads.ListThreadsAsync(false, limit: 100000, cancellationToken: token)).Concat(await workspace.Threads.ListThreadsAsync(true, limit: 100000, cancellationToken: token)).FirstOrDefault(x => IsCodexShadow(x) && x.CodexThreadId == entry.Thread.CodexThreadId);
            if (local is not null) await workspace.RenameAsync(await workspace.LoadAsync(local), title);
        }
        if (entry.Origin == CatalogOrigin.Codex && entry.Thread.CodexThreadId is { } runtimeId) external[runtimeId] = entry with { Thread = entry.Thread with { Title = title } };
        Changed?.Invoke(); workspace.NotifyChanged();
    }
    public Task SetArchivedAsync(CatalogEntry entry, bool archived, CancellationToken token = default) => ArchiveAsync(entry, archived, token);
    public async Task ArchiveAsync(CatalogEntry entry, bool archived, CancellationToken token = default)
    {
        RefuseActive(entry);
        if (entry.Origin == CatalogOrigin.Codex)
        {
            var method = archived ? "thread/archive" : "thread/unarchive"; Require(method);
            await rpc.RequestAsync(method, new { threadId = entry.Thread.CodexThreadId }, token);
            external.Remove(entry.Thread.CodexThreadId!);
            var shadows = (await workspace.Threads.ListThreadsAsync(!archived, limit: 100000, cancellationToken: token)).Where(x => IsCodexShadow(x) && x.CodexThreadId == entry.Thread.CodexThreadId);
            foreach (var shadow in shadows) await workspace.SetArchivedAsync(await workspace.LoadAsync(shadow), archived);
        }
        else await workspace.SetArchivedAsync(await workspace.LoadAsync(entry.Thread), archived);
        Changed?.Invoke(); workspace.NotifyChanged();
    }
    public async Task DeleteAsync(CatalogEntry entry, CancellationToken token = default)
    {
        RefuseActive(entry);
        var all = (await workspace.Threads.ListThreadsAsync(false, limit: 100000, cancellationToken: token)).Concat(await workspace.Threads.ListThreadsAsync(true, limit: 100000, cancellationToken: token)).ToArray();
        if (entry.Origin == CatalogOrigin.Codex)
        {
            Require("thread/delete"); await rpc.RequestAsync("thread/delete", new { threadId = entry.Thread.CodexThreadId }, token); external.Remove(entry.Thread.CodexThreadId!);
            foreach (var shadow in all.Where(x => IsCodexShadow(x) && x.CodexThreadId == entry.Thread.CodexThreadId)) await DeleteLocalAsync(shadow);
        }
        else
        {
            var family = new HashSet<string>(StringComparer.Ordinal) { entry.Thread.VeoId };
            while (true) { var before = family.Count; foreach (var row in all) if (row.ParentThreadId is { } parent && family.Contains(parent)) family.Add(row.VeoId); if (before == family.Count) break; }
            if (workspace.LoadedSessions.Any(s => family.Contains(s.Record.VeoId) && (s.Timeline.IsRunning || s.IsSubmitting))) throw new InvalidOperationException("Stop every active chat in this fork family before deleting it.");
            foreach (var row in all.Where(x => family.Contains(x.VeoId))) await DeleteLocalAsync(row);
        }
        Changed?.Invoke(); workspace.NotifyChanged();
    }
    async Task DeleteLocalAsync(PersistedThread record)
    {
        var loaded = workspace.LoadedSessions.FirstOrDefault(x => x.Record.VeoId == record.VeoId);
        if (loaded is not null) await workspace.DeleteAsync(loaded); else await workspace.Threads.DeleteThreadAsync(record.VeoId);
    }
    public async Task<ThreadSession> ForkAsync(ThreadSession source, string? lastTurnId = null, string? beforeTurnId = null, CancellationToken token = default)
    {
        if (lastTurnId is not null && beforeTurnId is not null) throw new ArgumentException("A fork can use one turn boundary.");
        if (source.Timeline.IsRunning || source.IsSubmitting) throw new InvalidOperationException("Stop the source chat before forking.");
        Require("thread/fork"); var id = source.Record.CodexThreadId ?? throw new InvalidOperationException("This chat has no runtime history yet.");
        var permission = ComposerPermission.Get(source.EffectiveAccess);
        var parameters = new Dictionary<string, object?> { ["threadId"] = id, ["lastTurnId"] = lastTurnId,
            ["beforeTurnId"] = beforeTurnId, ["cwd"] = source.Record.Cwd, ["approvalPolicy"] = permission.Policy,
            ["sandbox"] = permission.Sandbox };
        workspace.AddApprovalsReviewer(parameters, permission.Id);
        var response = await rpc.RequestAsync("thread/fork", parameters, token);
        var runtime = response.GetProperty("thread"); var runtimeId = runtime.Str("id") ?? throw new InvalidDataException("The fork has no runtime identity.");
        var record = source.Record with { VeoId = Guid.NewGuid().ToString("N"), CodexThreadId = runtimeId, Title = source.Record.Title + " (fork)", ParentThreadId = source.Record.VeoId, IsArchived = false, IsPinned = false, UpdatedAt = DateTimeOffset.UtcNow, Status = "idle" };
        await workspace.Threads.UpsertThreadAsync(record, token);
        await workspace.Threads.SaveDraftAsync(record.VeoId, new("", OptionsJson: source.Draft.OptionsJson), token);
        var session = await workspace.LoadAsync(record);
        Changed?.Invoke();
        return session;
    }
    public async Task<CatalogSearchPage> SearchContentAsync(string query, string? cursor = null, CancellationToken token = default)
    {
        var page = await workspace.Threads.SearchMessagesAsync(query, workspace.Preferences.ShowArchived, 50, cursor, token);
        return new(page.Data.Where(x => workspace.Preferences.ShowCodexHistory || !IsCodexShadow(x.Thread)).Select(x => new CatalogSearchResult(new(x.Thread.VeoId, IsCodexShadow(x.Thread) ? CatalogOrigin.Codex : CatalogOrigin.Veo, x.Thread), x.Snippet, x.ItemId, x.TurnId, null, x.MatchStart, x.MatchLength)).ToArray(), page.NextCursor);
    }
    public async Task<CatalogSearchPage> SearchRuntimeAsync(string query, string? cursor = null, CancellationToken token = default)
    {
        Require("thread/search"); if (string.IsNullOrWhiteSpace(query)) return new([], null);
        var owned = (await workspace.Threads.ListThreadsAsync(workspace.Preferences.ShowArchived, limit: 100000, cancellationToken: token)).Where(x => !IsCodexShadow(x) && x.CodexThreadId is not null).ToDictionary(x => x.CodexThreadId!, StringComparer.Ordinal);
        var result = await rpc.RequestAsync("thread/search", new { searchTerm = query, cursor, limit = 50, archived = workspace.Preferences.ShowArchived, sortKey = "updated_at", sortDirection = "desc" }, token);
        var found = new List<CatalogSearchResult>(); foreach (var row in Rows(result, "data"))
        {
            if (!row.TryObjectProperty("thread", out var thread) || thread.Str("id") is not { } id) continue;
            var entry = owned.TryGetValue(id, out var local) ? new CatalogEntry(local.VeoId, CatalogOrigin.Veo, local) : workspace.Preferences.ShowCodexHistory ? RuntimeEntry(thread, workspace.Preferences.ShowArchived) : null;
            if (entry is not null) found.Add(new(entry, row.Str("snippet") ?? ""));
        }
        return new(found, result.Str("nextCursor"));
    }
    public async Task<CatalogSearchPage> OccurrencesAsync(CatalogEntry entry, string query, string? cursor = null, CancellationToken token = default)
    {
        Require("thread/search/occurrences"); var result = await rpc.RequestAsync("thread/search/occurrences", new { threadId = entry.Thread.CodexThreadId, searchTerm = query, cursor, limit = 50 }, token);
        return new(Rows(result, "data").Select(row => new CatalogSearchResult(entry, row.Str("snippet") ?? "", row.Str("itemId"), row.Str("turnId"), row.Str("turnCursor"), row.TryObjectProperty("snippetMatchRange", out var range) ? Int(range, "start") : 0, row.TryObjectProperty("snippetMatchRange", out range) ? Math.Max(0, Int(range, "end") - Int(range, "start")) : 0)).ToArray(), result.Str("nextCursor"));
    }
    void RefuseActive(CatalogEntry entry) { if (workspace.LoadedSessions.Any(s => s.Record.CodexThreadId == entry.Thread.CodexThreadId && s.Record.VeoId == entry.Thread.VeoId && (s.Timeline.IsRunning || s.IsSubmitting))) throw new InvalidOperationException("Stop the active chat first."); }
    void Require(string method) { if (!rpc.Supports(method)) throw new NotSupportedException("The connected Codex runtime does not support " + method + "."); }
    public static bool IsCodexShadow(PersistedThread row) { try { using var json = JsonDocument.Parse(row.MetaJson); return json.RootElement.Str("catalogOrigin") == "codex"; } catch (JsonException) { return false; } }
    public static string ProjectKey(string cwd) { try { return Path.GetFullPath(cwd).TrimEnd(Path.DirectorySeparatorChar); } catch (ArgumentException) { return cwd; } }
    static string ProjectName(string path) => string.IsNullOrWhiteSpace(Path.GetFileName(path)) ? path : Path.GetFileName(path);
    static CatalogEntry RuntimeEntry(JsonElement row, bool archived)
    {
        var id = row.Str("id")!; var updated = row.TryGetProperty("updatedAt", out var time) && time.TryGetInt64(out var seconds) ? DateTimeOffset.FromUnixTimeSeconds(seconds) : DateTimeOffset.UnixEpoch;
        return new("codex:" + id, CatalogOrigin.Codex, new("codex:" + id, id, row.Str("cwd") ?? "", row.Str("name") ?? row.Str("preview") ?? "Codex chat", row.Str("preview") ?? "", updated, row.TryObjectProperty("status", out var status) ? status.Str("type") ?? "idle" : row.Str("status") ?? "idle", IsArchived: archived, MetaJson: "{\"catalogOrigin\":\"codex\"}"), row.Clone());
    }
    internal static JsonElement[] Rows(JsonElement value, string key) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(key, out var data) && data.ValueKind == JsonValueKind.Array ? data.EnumerateArray().Select(x => x.Clone()).ToArray() : [];
    static int Int(JsonElement value, string key) => value.TryGetProperty(key, out var n) && n.TryGetInt32(out var number) ? number : 0;
}
