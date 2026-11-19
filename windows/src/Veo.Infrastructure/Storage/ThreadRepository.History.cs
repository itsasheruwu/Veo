using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace Veo.Infrastructure.Storage;

public sealed record LocalMessageOccurrence(PersistedThread Thread, string ItemId, string? TurnId, string Snippet,
    int MatchStart, int MatchLength, long SortIndex);
public sealed record LocalMessageSearchPage(IReadOnlyList<LocalMessageOccurrence> Data, string? NextCursor);
public sealed partial class ThreadRepository
{
    private sealed record SearchCursor(string QueryHash, bool Archived, double Updated, string ThreadId, long SortIndex, string ItemId);
    public async Task<LocalMessageSearchPage> SearchMessagesAsync(string query, bool archived = false, int limit = 50,
        string? cursor = null, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(query)) return new([], null);
        limit = Math.Clamp(limit, 1, 500); var queryHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(query)));
        SearchCursor? anchor = null;
        if (cursor is not null)
        {
            try { anchor = JsonSerializer.Deserialize<SearchCursor>(Convert.FromBase64String(cursor)); }
            catch (Exception error) when (error is FormatException or JsonException) { throw new ArgumentException("The message-search cursor is invalid."); }
            if (anchor is null || anchor.QueryHash != queryHash || anchor.Archived != archived) throw new ArgumentException("A message-search cursor belongs to a different query.");
        }
        var results = new List<LocalMessageOccurrence>(); SearchCursor? next = null; var hasMore = false;
        await WithConnectionAsync(async (db, token) =>
        {
            using var command = db.CreateCommand();
            command.CommandText = """
                SELECT t.veo_id,t.codex_thread_id,t.cwd,t.title,t.preview,t.updated_at,t.status,t.is_pinned,t.is_archived,
                       t.parent_thread_id,t.meta_json,t.workspace_kind,i.item_id,i.turn_id,i.raw_json,i.sort_index
                FROM items i JOIN threads t ON t.veo_id=i.veo_id WHERE t.is_archived=$archived
                AND i.type IN ('userMessage','agentMessage','assistant')
                AND ($time IS NULL OR t.updated_at<$time OR (t.updated_at=$time AND
                  (t.veo_id>$thread OR (t.veo_id=$thread AND (i.sort_index>$sort OR (i.sort_index=$sort AND i.item_id>$item))))))
                ORDER BY t.updated_at DESC,t.veo_id,i.sort_index,i.item_id;
                """;
            Add(command, "$archived", archived, "$time", anchor?.Updated, "$thread", anchor?.ThreadId,
                "$sort", anchor?.SortIndex, "$item", anchor?.ItemId);
            using var reader = await command.ExecuteReaderAsync(token);
            while (await reader.ReadAsync(token))
            {
                using var raw = JsonDocument.Parse(reader.GetString(14)); var text = MessageText(raw.RootElement);
                var index = text.IndexOf(query, StringComparison.OrdinalIgnoreCase); if (index < 0) continue;
                if (results.Count == limit) { hasMore = true; break; }
                var start = Math.Max(0, index - 70); var length = Math.Min(text.Length - start, Math.Max(160, query.Length + 50));
                var thread = new PersistedThread(reader.GetString(0), Text(reader, 1), reader.GetString(2), reader.GetString(3), reader.GetString(4),
                    Date(reader.GetDouble(5)), reader.GetString(6), reader.GetBoolean(7), reader.GetBoolean(8), Text(reader, 9), reader.GetString(10), reader.GetString(11));
                results.Add(new(thread, reader.GetString(12), Text(reader, 13), text.Substring(start, length), index - start, query.Length, reader.GetInt64(15)));
                next = new(queryHash, archived, reader.GetDouble(5), thread.VeoId, reader.GetInt64(15), reader.GetString(12));
            }
            // Only publish a cursor if a later matching row was actually observed.
            if (!hasMore) next = null;
        }, cancellationToken);
        return new(results, next is null ? null : Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(next)));
    }

    public Task ReplaceHistoryAsync(string veoId, IReadOnlyList<PersistedTurn> turns, IReadOnlyList<PersistedItem> items,
        CancellationToken cancellationToken = default)
    {
        foreach (var item in items) ValidateJson(item.RawJson);
        return WithConnectionAsync(async (db, token) =>
        {
            using var transaction = db.BeginTransaction();
            using var retained = db.CreateCommand(); retained.Transaction = transaction;
            retained.CommandText = "CREATE TEMP TABLE IF NOT EXISTS veo_retained_turns(id TEXT PRIMARY KEY); DELETE FROM veo_retained_turns;";
            await retained.ExecuteNonQueryAsync(token);
            foreach (var id in turns.Select(turn => turn.TurnId).Concat(items.Select(item => item.TurnId).OfType<string>()).Distinct(StringComparer.Ordinal))
            {
                retained.CommandText = "INSERT INTO veo_retained_turns(id) VALUES($id);"; retained.Parameters.Clear(); Add(retained, "$id", id); await retained.ExecuteNonQueryAsync(token);
            }
            using var prune = db.CreateCommand(); prune.Transaction = transaction;
            prune.CommandText = """
                DELETE FROM items WHERE veo_id=$thread AND NOT(coalesce(type,'') IN ('veoUserInputAnswer','veoPlanArtifact') AND turn_id IS NOT NULL AND turn_id IN (SELECT id FROM veo_retained_turns));
                DELETE FROM turns WHERE veo_id=$thread;
                DELETE FROM plan_artifacts WHERE thread_key=$thread AND turn_id IS NOT NULL AND turn_id NOT IN (SELECT id FROM veo_retained_turns);
                """;
            Add(prune, "$thread", veoId); await prune.ExecuteNonQueryAsync(token);
            foreach (var turn in turns)
            {
                await UpsertTurnMetadataAsync(db, transaction, veoId, turn, token);
            }
            foreach (var item in items)
            {
                using var command = db.CreateCommand(); command.Transaction = transaction;
                command.CommandText = """
                    INSERT INTO items VALUES($thread,$id,$turn,$type,$client,$status,$raw,$sort,$updated)
                    ON CONFLICT(veo_id,item_id) DO UPDATE SET turn_id=excluded.turn_id,type=excluded.type,client_id=excluded.client_id,
                    status=excluded.status,raw_json=excluded.raw_json,sort_index=excluded.sort_index,updated_at=excluded.updated_at;
                    """;
                Add(command, "$thread", veoId, "$id", item.ItemId, "$turn", item.TurnId, "$type", item.Type, "$client", item.ClientId, "$status", item.Status, "$raw", item.RawJson, "$sort", item.SortIndex, "$updated", Timestamp(item.UpdatedAt));
                await command.ExecuteNonQueryAsync(token);
            }
            transaction.Commit();
        }, cancellationToken);
    }
    private static string MessageText(JsonElement item)
    {
        if (item.ValueKind != JsonValueKind.Object) return "";
        foreach (var key in new[] { "veoRenderedText", "text" }) if (item.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String) return value.GetString() ?? "";
        if (item.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
            return string.Join("\n", content.EnumerateArray().Where(part => part.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String).Select(part => part.GetProperty("text").GetString()));
        return "";
    }
}
