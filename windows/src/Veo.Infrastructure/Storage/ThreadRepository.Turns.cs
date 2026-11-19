using Microsoft.Data.Sqlite;

namespace Veo.Infrastructure.Storage;

public sealed partial class ThreadRepository
{
    static async Task<bool> HasColumnAsync(SqliteConnection db, SqliteTransaction transaction, string table, string column, CancellationToken token)
    {
        using var command = db.CreateCommand(); command.Transaction = transaction;
        command.CommandText = "PRAGMA table_info(" + table + ");";
        using var reader = await command.ExecuteReaderAsync(token);
        while (await reader.ReadAsync(token)) if (reader.GetString(1) == column) return true;
        return false;
    }

    static async Task UpsertTurnMetadataAsync(SqliteConnection db, SqliteTransaction transaction, string veoId, PersistedTurn turn, CancellationToken token)
    {
        if (string.IsNullOrWhiteSpace(turn.TurnId)) throw new ArgumentException("Persist only a runtime-provided turn identity.");
        if (turn.ErrorJson is not null) ValidateJson(turn.ErrorJson);
        using var command = db.CreateCommand(); command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO turns(veo_id,turn_id,status,started_at,error_json,sort_index,terminal_observed)
            VALUES($thread,$id,$status,$started,$error,$sort,$terminal)
            ON CONFLICT(veo_id,turn_id) DO UPDATE SET
            status=CASE WHEN turns.terminal_observed=1 AND excluded.terminal_observed=0 THEN turns.status
                        WHEN turns.terminal_observed=0 AND excluded.terminal_observed=1 AND excluded.status IS NULL THEN NULL
                        ELSE coalesce(excluded.status,turns.status) END,
            started_at=coalesce(excluded.started_at,turns.started_at),
            error_json=CASE WHEN turns.terminal_observed=1 AND excluded.terminal_observed=0 THEN turns.error_json ELSE coalesce(excluded.error_json,turns.error_json) END,
            terminal_observed=max(turns.terminal_observed,excluded.terminal_observed);
            """;
        Add(command, "$thread", veoId, "$id", turn.TurnId, "$status", turn.Status,
            "$started", turn.StartedAt is { } date ? Timestamp(date) : null, "$error", turn.ErrorJson,
            "$sort", turn.SortIndex, "$terminal", turn.TerminalObserved || KnownTerminalStatus(turn.Status));
        await command.ExecuteNonQueryAsync(token);
    }

    static bool KnownTerminalStatus(string? status) => status is "completed" or "interrupted" or "failed" or "aborted" or "cancelled" or "canceled";

    public async Task<IReadOnlyList<PersistedTurn>> ReadTurnsAsync(string veoId, CancellationToken cancellationToken = default)
    {
        var result = new List<PersistedTurn>();
        await WithConnectionAsync(async (db, token) =>
        {
            using var command = db.CreateCommand();
            command.CommandText = "SELECT turn_id,status,started_at,error_json,sort_index,terminal_observed FROM turns WHERE veo_id=$thread ORDER BY sort_index,turn_id;";
            Add(command, "$thread", veoId);
            using var reader = await command.ExecuteReaderAsync(token);
            while (await reader.ReadAsync(token)) result.Add(new(reader.GetString(0), Text(reader, 1), reader.IsDBNull(2) ? null : Date(reader.GetDouble(2)), Text(reader, 3), reader.GetInt64(4), reader.GetBoolean(5)));
        }, cancellationToken);
        return result;
    }
}
