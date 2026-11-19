using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace Veo.Infrastructure.Storage;

/// <summary>Application-owned catalog. All access uses one coordinated connection and writer.</summary>
public sealed partial class ThreadRepository : IAsyncDisposable
{
    private const int SchemaVersion = 5;
    private readonly SemaphoreSlim gate = new(1, 1);
    private SqliteConnection? connection;
    private bool disposed;
    public string DatabasePath { get; }

    public ThreadRepository(string databasePath) => DatabasePath = Path.GetFullPath(databasePath);

    public Task InitializeAsync(CancellationToken cancellationToken = default) =>
        WithConnectionAsync(static (_, _) => Task.CompletedTask, cancellationToken);

    private async Task WithConnectionAsync(Func<SqliteConnection, CancellationToken, Task> action,
        CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            connection ??= await OpenAsync(cancellationToken).ConfigureAwait(false);
            await action(connection, cancellationToken).ConfigureAwait(false);
        }
        finally { gate.Release(); }
    }

    private async Task<SqliteConnection> OpenAsync(CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(DatabasePath)!);
        var db = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath, Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false, ForeignKeys = true, DefaultTimeout = 10
        }.ToString());
        try
        {
            await db.OpenAsync(cancellationToken).ConfigureAwait(false);
            await ExecuteAsync(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;", cancellationToken);
            using var versionCommand = db.CreateCommand();
            versionCommand.CommandText = "PRAGMA user_version;";
            var version = Convert.ToInt32(await versionCommand.ExecuteScalarAsync(cancellationToken));
            if (version > SchemaVersion)
                throw new InvalidDataException($"This database uses schema {version}; this Veo supports {SchemaVersion}.");
            if (version < SchemaVersion)
            {
                // SQLite's online backup includes committed WAL contents; copying the main file does not.
                if (new FileInfo(DatabasePath).Length > 0 && await HasTablesAsync(db, cancellationToken))
                    await BackupConnectionAsync(db, DatabasePath + $".pre-v{SchemaVersion}-{DateTime.UtcNow:yyyyMMddHHmmssfff}.bak", cancellationToken);
                using var tx = db.BeginTransaction();
                if (version < 1)
                {
                    await ExecuteAsync(db, """
                        CREATE TABLE IF NOT EXISTS threads (
                          veo_id TEXT PRIMARY KEY NOT NULL, codex_thread_id TEXT UNIQUE,
                          cwd TEXT NOT NULL, title TEXT NOT NULL, preview TEXT NOT NULL DEFAULT '',
                          updated_at REAL NOT NULL, status TEXT NOT NULL DEFAULT 'idle',
                          is_pinned INTEGER NOT NULL DEFAULT 0, is_archived INTEGER NOT NULL DEFAULT 0,
                          parent_thread_id TEXT, meta_json TEXT NOT NULL DEFAULT '{}',
                          workspace_kind TEXT NOT NULL DEFAULT 'project');
                        CREATE TABLE IF NOT EXISTS turns (
                          veo_id TEXT NOT NULL, turn_id TEXT NOT NULL, status TEXT, started_at REAL,
                          error_json TEXT, sort_index INTEGER NOT NULL DEFAULT 0,
                          PRIMARY KEY(veo_id,turn_id), FOREIGN KEY(veo_id) REFERENCES threads(veo_id) ON DELETE CASCADE);
                        CREATE TABLE IF NOT EXISTS items (
                          veo_id TEXT NOT NULL, item_id TEXT NOT NULL, turn_id TEXT, type TEXT,
                          client_id TEXT, status TEXT, raw_json TEXT NOT NULL, sort_index INTEGER NOT NULL DEFAULT 0,
                          updated_at REAL NOT NULL, PRIMARY KEY(veo_id,item_id),
                          FOREIGN KEY(veo_id) REFERENCES threads(veo_id) ON DELETE CASCADE);
                        CREATE TABLE IF NOT EXISTS plan_artifacts (
                          thread_key TEXT NOT NULL, item_id TEXT NOT NULL, turn_id TEXT,
                          original_markdown TEXT NOT NULL, edited_markdown TEXT,
                          lifecycle TEXT NOT NULL DEFAULT 'ready', implementation_client_id TEXT,
                          implementation_turn_id TEXT, updated_at REAL NOT NULL, PRIMARY KEY(thread_key,item_id));
                        CREATE INDEX IF NOT EXISTS idx_threads_archived_updated ON threads(is_archived,updated_at DESC);
                        CREATE INDEX IF NOT EXISTS idx_items_veo_sort ON items(veo_id,sort_index);
                        CREATE INDEX IF NOT EXISTS idx_plan_artifacts_thread ON plan_artifacts(thread_key,updated_at);
                        """, cancellationToken, tx);
                }
                if (version < 2)
                    await ExecuteAsync(db, """
                        CREATE TABLE IF NOT EXISTS drafts (
                          veo_id TEXT PRIMARY KEY NOT NULL, text TEXT NOT NULL DEFAULT '',
                          attachments_json TEXT NOT NULL DEFAULT '[]', options_json TEXT NOT NULL DEFAULT '{}',
                          updated_at REAL NOT NULL, FOREIGN KEY(veo_id) REFERENCES threads(veo_id) ON DELETE CASCADE);
                        CREATE TABLE IF NOT EXISTS durable_state (
                          scope TEXT NOT NULL, key TEXT NOT NULL, value_json TEXT NOT NULL,
                          updated_at REAL NOT NULL, PRIMARY KEY(scope,key));
                        """, cancellationToken, tx);
                if (version < 3)
                {
                    if (!await HasColumnAsync(db, tx, "turns", "terminal_observed", cancellationToken))
                        await ExecuteAsync(db, "ALTER TABLE turns ADD COLUMN terminal_observed INTEGER NOT NULL DEFAULT 0;", cancellationToken, tx);
                    await ExecuteAsync(db, "UPDATE turns SET terminal_observed=1 WHERE status IN ('completed','interrupted','failed','aborted','cancelled','canceled');", cancellationToken, tx);
                }
                if (version < 4)
                {
                    if (!await HasColumnAsync(db, tx, "turns", "completed_at", cancellationToken))
                        await ExecuteAsync(db, "ALTER TABLE turns ADD COLUMN completed_at REAL;", cancellationToken, tx);
                    if (!await HasColumnAsync(db, tx, "turns", "unified_diff", cancellationToken))
                        await ExecuteAsync(db, "ALTER TABLE turns ADD COLUMN unified_diff TEXT;", cancellationToken, tx);
                }
                if (version < 5 && !await HasColumnAsync(db, tx, "turns", "steer_times", cancellationToken))
                    await ExecuteAsync(db, "ALTER TABLE turns ADD COLUMN steer_times TEXT;", cancellationToken, tx);
                await ExecuteAsync(db, $"PRAGMA user_version={SchemaVersion};", cancellationToken, tx);
                tx.Commit();
            }
            return db;
        }
        catch { await db.DisposeAsync(); throw; }
    }

    private static async Task<bool> HasTablesAsync(SqliteConnection db, CancellationToken token)
    {
        using var command = db.CreateCommand();
        command.CommandText = "SELECT count(*) FROM sqlite_master WHERE type='table';";
        return Convert.ToInt32(await command.ExecuteScalarAsync(token)) > 0;
    }

    public Task UpsertThreadAsync(PersistedThread thread, CancellationToken cancellationToken = default)
    {
        ValidateJson(thread.MetaJson);
        return WithConnectionAsync(async (db, token) =>
        {
            using var command = db.CreateCommand();
            command.CommandText = """
                INSERT INTO threads VALUES($id,$runtime,$cwd,$title,$preview,$updated,$status,$pinned,$archived,$parent,$meta,$kind)
                ON CONFLICT(veo_id) DO UPDATE SET codex_thread_id=excluded.codex_thread_id,cwd=excluded.cwd,
                title=excluded.title,preview=excluded.preview,updated_at=excluded.updated_at,status=excluded.status,
                is_pinned=excluded.is_pinned,is_archived=excluded.is_archived,parent_thread_id=excluded.parent_thread_id,
                meta_json=excluded.meta_json,workspace_kind=excluded.workspace_kind;
                """;
            Add(command, "$id", thread.VeoId, "$runtime", thread.CodexThreadId, "$cwd", thread.Cwd,
                "$title", thread.Title, "$preview", thread.Preview, "$updated", Timestamp(thread.UpdatedAt),
                "$status", thread.Status, "$pinned", thread.IsPinned, "$archived", thread.IsArchived,
                "$parent", thread.ParentThreadId, "$meta", thread.MetaJson, "$kind", thread.WorkspaceKind);
            await command.ExecuteNonQueryAsync(token);
        }, cancellationToken);
    }

    public async Task<IReadOnlyList<PersistedThread>> ListThreadsAsync(bool archived = false,
        string? search = null, int limit = 200, int offset = 0, CancellationToken cancellationToken = default)
    {
        var result = new List<PersistedThread>();
        await WithConnectionAsync(async (db, token) =>
        {
            using var command = db.CreateCommand();
            command.CommandText = """
                SELECT veo_id,codex_thread_id,cwd,title,preview,updated_at,status,is_pinned,is_archived,
                parent_thread_id,meta_json,workspace_kind FROM threads WHERE is_archived=$archived
                AND ($search IS NULL OR instr(lower(title),lower($search))>0 OR instr(lower(preview),lower($search))>0)
                ORDER BY is_pinned DESC,updated_at DESC,veo_id LIMIT $limit OFFSET $offset;
                """;
            Add(command, "$archived", archived, "$search", search, "$limit", Math.Clamp(limit, 1, 1000), "$offset", Math.Max(0, offset));
            using var reader = await command.ExecuteReaderAsync(token);
            while (await reader.ReadAsync(token))
                result.Add(new(reader.GetString(0), Text(reader, 1), reader.GetString(2), reader.GetString(3),
                    reader.GetString(4), Date(reader.GetDouble(5)), reader.GetString(6), reader.GetBoolean(7),
                    reader.GetBoolean(8), Text(reader, 9), reader.GetString(10), reader.GetString(11)));
        }, cancellationToken);
        return result;
    }

    public Task SaveItemAsync(string veoId, PersistedItem item, CancellationToken cancellationToken = default) =>
        SaveTimelineAsync(veoId, [], [item], cancellationToken);

    public Task SaveTimelineAsync(string veoId, IReadOnlyList<PersistedTurn> turns,
        IReadOnlyList<PersistedItem> items, CancellationToken cancellationToken = default)
    {
        foreach (var item in items) ValidateJson(item.RawJson);
        return WithConnectionAsync(async (db, token) =>
        {
            using var tx = db.BeginTransaction();
            foreach (var turn in turns)
            {
                await UpsertTurnMetadataAsync(db, tx, veoId, turn, token);
            }
            foreach (var item in items)
            {
                using var command = db.CreateCommand(); command.Transaction = tx;
                command.CommandText = """
                    INSERT INTO items VALUES($thread,$id,$turn,$type,$client,$status,$raw,$sort,$updated)
                    ON CONFLICT(veo_id,item_id) DO UPDATE SET turn_id=excluded.turn_id,type=excluded.type,
                    client_id=excluded.client_id,status=excluded.status,raw_json=excluded.raw_json,
                    sort_index=excluded.sort_index,updated_at=excluded.updated_at;
                    """;
                Add(command, "$thread", veoId, "$id", item.ItemId, "$turn", item.TurnId, "$type", item.Type,
                    "$client", item.ClientId, "$status", item.Status, "$raw", item.RawJson,
                    "$sort", item.SortIndex, "$updated", Timestamp(item.UpdatedAt));
                await command.ExecuteNonQueryAsync(token);
            }
            tx.Commit();
        }, cancellationToken);
    }

    public async Task<IReadOnlyList<PersistedItem>> ReadItemsAsync(string veoId, int limit = 1000,
        long afterSortIndex = -1, CancellationToken cancellationToken = default)
    {
        var result = new List<PersistedItem>();
        await WithConnectionAsync(async (db, token) =>
        {
            using var command = db.CreateCommand();
            command.CommandText = "SELECT item_id,turn_id,type,client_id,status,raw_json,sort_index,updated_at FROM items WHERE veo_id=$id AND sort_index>$after ORDER BY sort_index,item_id LIMIT $limit;";
            Add(command, "$id", veoId, "$after", afterSortIndex, "$limit", Math.Clamp(limit, 1, 10000));
            using var reader = await command.ExecuteReaderAsync(token);
            while (await reader.ReadAsync(token)) result.Add(new(reader.GetString(0), Text(reader, 1), Text(reader, 2),
                Text(reader, 3), Text(reader, 4), reader.GetString(5), reader.GetInt64(6), Date(reader.GetDouble(7))));
        }, cancellationToken);
        return result;
    }

    public Task SaveDraftAsync(string veoId, PersistedDraft draft, CancellationToken cancellationToken = default)
    {
        ValidateJson(draft.AttachmentsJson); ValidateJson(draft.OptionsJson);
        return WithConnectionAsync(async (db, token) =>
        {
            using var command = db.CreateCommand();
            command.CommandText = """
                INSERT INTO drafts VALUES($id,$text,$attachments,$options,$updated)
                ON CONFLICT(veo_id) DO UPDATE SET text=excluded.text,attachments_json=excluded.attachments_json,
                options_json=excluded.options_json,updated_at=excluded.updated_at;
                """;
            Add(command, "$id", veoId, "$text", draft.Text, "$attachments", draft.AttachmentsJson,
                "$options", draft.OptionsJson, "$updated", Timestamp(draft.UpdatedAt));
            await command.ExecuteNonQueryAsync(token);
        }, cancellationToken);
    }

    public async Task<PersistedDraft?> ReadDraftAsync(string veoId, CancellationToken cancellationToken = default)
    {
        PersistedDraft? draft = null;
        await WithConnectionAsync(async (db, token) =>
        {
            using var command = db.CreateCommand();
            command.CommandText = "SELECT text,attachments_json,options_json,updated_at FROM drafts WHERE veo_id=$id;";
            Add(command, "$id", veoId);
            using var reader = await command.ExecuteReaderAsync(token);
            if (await reader.ReadAsync(token)) draft = new(reader.GetString(0), reader.GetString(1), reader.GetString(2), Date(reader.GetDouble(3)));
        }, cancellationToken);
        return draft;
    }

    public Task SavePlanAsync(PersistedPlan plan, CancellationToken cancellationToken = default) =>
        WithConnectionAsync(async (db, token) =>
        {
            using var command = db.CreateCommand();
            command.CommandText = """
                INSERT INTO plan_artifacts VALUES($thread,$id,$turn,$original,$edited,$lifecycle,$client,$implementation,$updated)
                ON CONFLICT(thread_key,item_id) DO UPDATE SET turn_id=excluded.turn_id,
                original_markdown=excluded.original_markdown,edited_markdown=excluded.edited_markdown,
                lifecycle=excluded.lifecycle,implementation_client_id=excluded.implementation_client_id,
                implementation_turn_id=excluded.implementation_turn_id,updated_at=excluded.updated_at;
                """;
            Add(command, "$thread", plan.ThreadKey, "$id", plan.ItemId, "$turn", plan.TurnId,
                "$original", plan.OriginalMarkdown, "$edited", plan.EditedMarkdown, "$lifecycle", plan.Lifecycle,
                "$client", plan.ImplementationClientId, "$implementation", plan.ImplementationTurnId, "$updated", Timestamp(plan.UpdatedAt));
            await command.ExecuteNonQueryAsync(token);
        }, cancellationToken);

    public async Task<IReadOnlyList<PersistedPlan>> ReadPlansAsync(string threadKey, CancellationToken cancellationToken = default)
    {
        var result = new List<PersistedPlan>();
        await WithConnectionAsync(async (db, token) =>
        {
            using var command = db.CreateCommand();
            command.CommandText = "SELECT thread_key,item_id,turn_id,original_markdown,edited_markdown,lifecycle,implementation_client_id,implementation_turn_id,updated_at FROM plan_artifacts WHERE thread_key=$thread ORDER BY updated_at,item_id;";
            Add(command, "$thread", threadKey);
            using var reader = await command.ExecuteReaderAsync(token);
            while (await reader.ReadAsync(token)) result.Add(new(reader.GetString(0), reader.GetString(1), Text(reader, 2),
                reader.GetString(3), Text(reader, 4), reader.GetString(5), Text(reader, 6), Text(reader, 7), Date(reader.GetDouble(8))));
        }, cancellationToken);
        return result;
    }

    public Task DeleteThreadAsync(string veoId, CancellationToken cancellationToken = default) => WithConnectionAsync(async (db, token) =>
    {
        using var tx = db.BeginTransaction();
        using var command = db.CreateCommand(); command.Transaction = tx;
        command.CommandText = "DELETE FROM plan_artifacts WHERE thread_key=$id; DELETE FROM durable_state WHERE scope=$id; DELETE FROM threads WHERE veo_id=$id;";
        Add(command, "$id", veoId); await command.ExecuteNonQueryAsync(token); tx.Commit();
    }, cancellationToken);

    public Task DeleteItemsAsync(string veoId, IReadOnlyCollection<string> itemIds, CancellationToken cancellationToken = default) =>
        WithConnectionAsync(async (db, token) =>
        {
            using var tx = db.BeginTransaction();
            using var command = db.CreateCommand(); command.Transaction = tx;
            command.CommandText = "DELETE FROM items WHERE veo_id=$thread AND item_id=$item;";
            Add(command, "$thread", veoId, "$item", "");
            foreach (var id in itemIds)
            {
                command.Parameters["$item"].Value = id;
                await command.ExecuteNonQueryAsync(token);
            }
            tx.Commit();
        }, cancellationToken);

    public Task SaveStateAsync(string scope, string key, string valueJson, CancellationToken cancellationToken = default)
    {
        ValidateJson(valueJson);
        return WithConnectionAsync(async (db, token) =>
        {
            using var command = db.CreateCommand();
            command.CommandText = "INSERT INTO durable_state VALUES($scope,$key,$value,$updated) ON CONFLICT(scope,key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at;";
            Add(command, "$scope", scope, "$key", key, "$value", valueJson, "$updated", Timestamp(default));
            await command.ExecuteNonQueryAsync(token);
        }, cancellationToken);
    }

    public async Task<string?> ReadStateAsync(string scope, string key, CancellationToken cancellationToken = default)
    {
        string? value = null;
        await WithConnectionAsync(async (db, token) =>
        {
            using var command = db.CreateCommand();
            command.CommandText = "SELECT value_json FROM durable_state WHERE scope=$scope AND key=$key;";
            Add(command, "$scope", scope, "$key", key);
            value = await command.ExecuteScalarAsync(token) as string;
        }, cancellationToken);
        return value;
    }

    public async Task<IReadOnlyList<(string Key, string Json)>> ReadWorkspaceCheckpointStatesAsync(string workspacePath, CancellationToken cancellationToken = default)
    {
        var states = new List<(string, string)>();
        await WithConnectionAsync(async (db, token) =>
        {
            using var command = db.CreateCommand();
            command.CommandText = """
                SELECT state.key,state.value_json FROM durable_state state JOIN threads thread ON thread.veo_id=state.scope
                WHERE state.key IN ('turn-checkpoints','checkpoint') AND thread.cwd=$workspace COLLATE NOCASE;
                """;
            Add(command, "$workspace", workspacePath);
            await using var rows = await command.ExecuteReaderAsync(token);
            while (await rows.ReadAsync(token)) states.Add((rows.GetString(0), rows.GetString(1)));
        }, cancellationToken);
        return states;
    }

    public Task BackupAsync(string destination, CancellationToken cancellationToken = default) =>
        WithConnectionAsync((db, token) => BackupConnectionAsync(db, destination, token), cancellationToken);

    private static async Task BackupConnectionAsync(SqliteConnection source, string path, CancellationToken token)
    {
        path = Path.GetFullPath(path); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (File.Exists(path)) throw new IOException("The database backup destination already exists.");
        await using var destination = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
        await destination.OpenAsync(token); token.ThrowIfCancellationRequested(); source.BackupDatabase(destination);
    }

    private static async Task ExecuteAsync(SqliteConnection db, string sql, CancellationToken token, SqliteTransaction? tx = null)
    {
        using var command = db.CreateCommand(); command.Transaction = tx; command.CommandText = sql;
        await command.ExecuteNonQueryAsync(token).ConfigureAwait(false);
    }
    private static void Add(SqliteCommand command, params object?[] pairs)
    {
        for (var i = 0; i < pairs.Length; i += 2) command.Parameters.AddWithValue((string)pairs[i]!, pairs[i + 1] ?? DBNull.Value);
    }
    private static string? Text(SqliteDataReader reader, int column) => reader.IsDBNull(column) ? null : reader.GetString(column);
    private static double Timestamp(DateTimeOffset date) => (date == default ? DateTimeOffset.UtcNow : date).ToUnixTimeMilliseconds() / 1000d;
    private static DateTimeOffset Date(double timestamp) => DateTimeOffset.FromUnixTimeMilliseconds((long)(timestamp * 1000));
    private static void ValidateJson(string json) { using var _ = JsonDocument.Parse(json); }

    public async ValueTask DisposeAsync()
    {
        await gate.WaitAsync();
        try { if (disposed) return; disposed = true; if (connection is { } db) await db.DisposeAsync(); connection = null; }
        finally { gate.Release(); }
    }
}
