// FILE: VeoThreadStore.swift
// Purpose: Persists Veo-owned chat threads and timeline items in a local SQLite database.
// Layer: Desktop app service
// Depends on: DesktopCodexModels, Foundation, SQLite3

import Foundation
import SQLite3

actor VeoThreadStore {
    struct PersistedTurn: Sendable {
        let turnID: String
        let status: String?
        let startedAt: Date?
        let errorJSON: String?
        let sortIndex: Int
    }

    struct PersistedItem: Sendable {
        let itemID: String
        let turnID: String?
        let type: String?
        let clientID: String?
        let status: String?
        let rawJSON: String
        let sortIndex: Int
        let updatedAt: Date
    }

    private var db: OpaquePointer?
    private let fileManager: FileManager
    private let databaseURL: URL

    init(
        fileManager: FileManager = .default,
        databaseURL: URL? = nil
    ) {
        self.fileManager = fileManager
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            let directory = applicationSupport
                .appendingPathComponent("com.ash.Veo", isDirectory: true)
                .appendingPathComponent("Threads", isDirectory: true)
            self.databaseURL = directory.appendingPathComponent("veo-threads.sqlite")
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func openIfNeeded() throws {
        if db != nil { return }
        let directory = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw StoreError.openFailed(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    func listThreads(archived: Bool) throws -> [DesktopThread] {
        try openIfNeeded()
        let sql = """
        SELECT veo_id, codex_thread_id, cwd, title, preview, updated_at, status,
               is_pinned, parent_thread_id, meta_json, workspace_kind
        FROM threads
        WHERE is_archived = ?
        ORDER BY updated_at DESC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, archived ? 1 : 0)
        var rows: [DesktopThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let thread = thread(from: statement) {
                rows.append(thread)
            }
        }
        return rows
    }

    func threadIDsWithStartedAutoTurns() throws -> Set<String> {
        try openIfNeeded()
        let sql = """
        SELECT DISTINCT veo_id
        FROM items
        WHERE turn_id IS NOT NULL
          AND (client_id LIKE 'veo-auto-%' OR client_id LIKE 'auto-continue-veo-auto-%');
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var threadIDs = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let bareID = columnText(statement, 0) {
                threadIDs.insert(DesktopThreadSelection.veo(bareID).storageKey)
            }
        }
        return threadIDs
    }

    func thread(veoID: String) throws -> DesktopThread? {
        try openIfNeeded()
        let bare = DesktopThreadSelection.parse(veoID).bareID
        let sql = """
        SELECT veo_id, codex_thread_id, cwd, title, preview, updated_at, status,
               is_pinned, parent_thread_id, meta_json, workspace_kind
        FROM threads
        WHERE veo_id = ?
        LIMIT 1;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, bare)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return thread(from: statement)
    }

    func upsertThread(_ thread: DesktopThread, isArchived: Bool = false) throws {
        try openIfNeeded()
        guard thread.origin == .veo else { return }
        let bare = thread.selection.bareID
        let parentBare = thread.parentThreadID.map { DesktopThreadSelection.parse($0).bareID }
        let meta: [String: Any] = [
            "sessionId": thread.sessionID as Any,
            "agentNickname": thread.agentNickname as Any,
            "agentRole": thread.agentRole as Any,
            "canAcceptDirectInput": thread.canAcceptDirectInput as Any,
            "activeFlags": thread.activeFlags,
            "agentDepth": thread.agentDepth as Any,
        ]
        let metaJSON = jsonString(meta) ?? "{}"
        let sql = """
        INSERT INTO threads (
            veo_id, codex_thread_id, cwd, title, preview, updated_at, status,
            is_pinned, is_archived, parent_thread_id, meta_json, workspace_kind
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(veo_id) DO UPDATE SET
            codex_thread_id = excluded.codex_thread_id,
            cwd = excluded.cwd,
            title = excluded.title,
            preview = excluded.preview,
            updated_at = excluded.updated_at,
            status = excluded.status,
            is_pinned = excluded.is_pinned,
            is_archived = excluded.is_archived,
            parent_thread_id = excluded.parent_thread_id,
            meta_json = excluded.meta_json,
            workspace_kind = excluded.workspace_kind;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, bare)
        try bindOptionalText(statement, 2, thread.codexThreadId)
        try bindText(statement, 3, thread.cwd)
        try bindText(statement, 4, thread.title)
        try bindText(statement, 5, thread.preview)
        sqlite3_bind_double(statement, 6, thread.updatedAt.timeIntervalSince1970)
        try bindText(statement, 7, thread.status)
        sqlite3_bind_int(statement, 8, thread.isPinned ? 1 : 0)
        sqlite3_bind_int(statement, 9, isArchived ? 1 : 0)
        try bindOptionalText(statement, 10, parentBare)
        try bindText(statement, 11, metaJSON)
        try bindText(statement, 12, thread.workspaceKind.rawValue)
        try stepDone(statement)
    }

    func setCodexThreadID(veoID: String, codexThreadID: String) throws {
        try openIfNeeded()
        let bare = DesktopThreadSelection.parse(veoID).bareID
        let sql = "UPDATE threads SET codex_thread_id = ?, updated_at = ? WHERE veo_id = ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, codexThreadID)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        try bindText(statement, 3, bare)
        try stepDone(statement)
    }

    func setArchived(veoID: String, archived: Bool) throws {
        try openIfNeeded()
        let bare = DesktopThreadSelection.parse(veoID).bareID
        let sql = "UPDATE threads SET is_archived = ?, updated_at = ? WHERE veo_id = ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, archived ? 1 : 0)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        try bindText(statement, 3, bare)
        try stepDone(statement)
    }

    func setPinned(veoID: String, pinned: Bool) throws {
        try openIfNeeded()
        let bare = DesktopThreadSelection.parse(veoID).bareID
        let sql = "UPDATE threads SET is_pinned = ?, updated_at = ? WHERE veo_id = ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        try bindText(statement, 3, bare)
        try stepDone(statement)
    }

    func rename(veoID: String, title: String) throws {
        try openIfNeeded()
        let bare = DesktopThreadSelection.parse(veoID).bareID
        let sql = "UPDATE threads SET title = ?, updated_at = ? WHERE veo_id = ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, title)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        try bindText(statement, 3, bare)
        try stepDone(statement)
    }

    func updatePreview(veoID: String, preview: String, titleIfNewChat: String? = nil) throws {
        try openIfNeeded()
        let bare = DesktopThreadSelection.parse(veoID).bareID
        if let titleIfNewChat {
            let sql = """
            UPDATE threads
            SET preview = ?, updated_at = ?,
                title = CASE WHEN title = 'New chat' OR title = '' THEN ? ELSE title END
            WHERE veo_id = ?;
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bindText(statement, 1, preview)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            try bindText(statement, 3, titleIfNewChat)
            try bindText(statement, 4, bare)
            try stepDone(statement)
        } else {
            let sql = "UPDATE threads SET preview = ?, updated_at = ? WHERE veo_id = ?;"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bindText(statement, 1, preview)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            try bindText(statement, 3, bare)
            try stepDone(statement)
        }
    }

    func deleteThread(veoID: String) throws {
        try openIfNeeded()
        let bare = DesktopThreadSelection.parse(veoID).bareID
        for table in ["items", "turns", "threads"] {
            let statement = try prepare("DELETE FROM \(table) WHERE veo_id = ?;")
            defer { sqlite3_finalize(statement) }
            try bindText(statement, 1, bare)
            try stepDone(statement)
        }
    }

    func appManagedWorkspacePaths() throws -> Set<String> {
        try openIfNeeded()
        let statement = try prepare("SELECT DISTINCT cwd FROM threads WHERE workspace_kind IN ('projectless', 'temporary');")
        defer { sqlite3_finalize(statement) }
        var paths = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = columnText(statement, 0) { paths.insert(path) }
        }
        return paths
    }

    func veoID(forCodexThreadID codexThreadID: String) throws -> String? {
        try openIfNeeded()
        let sql = "SELECT veo_id FROM threads WHERE codex_thread_id = ? LIMIT 1;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, codexThreadID)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return DesktopThreadSelection.veo(String(cString: text)).storageKey
    }

    func replaceTimeline(veoID: String, turns: [[String: Any]]) throws {
        try openIfNeeded()
        let bare = DesktopThreadSelection.parse(veoID).bareID
        try exec("BEGIN IMMEDIATE;")
        do {
            for table in ["items", "turns"] {
                let statement = try prepare("DELETE FROM \(table) WHERE veo_id = ?;")
                defer { sqlite3_finalize(statement) }
                try bindText(statement, 1, bare)
                try stepDone(statement)
            }
            for (turnIndex, turn) in turns.enumerated() {
                let turnID = turn.string("id") ?? "turn-\(turnIndex)"
                try upsertTurn(
                    veoID: bare,
                    turnID: turnID,
                    status: turn.displayString("status"),
                    startedAt: turn.number("startedAt").map { Date(timeIntervalSince1970: $0) },
                    errorJSON: (turn["error"] as? [String: Any]).flatMap(jsonString),
                    sortIndex: turnIndex
                )
                let items = turn["items"] as? [[String: Any]] ?? []
                for (itemIndex, item) in items.enumerated() {
                    guard let itemID = item.string("id") else { continue }
                    try upsertItem(
                        veoID: bare,
                        itemID: itemID,
                        turnID: turnID,
                        type: item.string("type"),
                        clientID: item.string("clientId"),
                        status: item.displayString("status"),
                        rawJSON: jsonString(item) ?? "{}",
                        sortIndex: itemIndex,
                        updatedAt: Date()
                    )
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func upsertItemJSON(
        veoID: String,
        item: [String: Any],
        turnID: String?,
        sortIndex: Int = 0
    ) throws {
        try openIfNeeded()
        let bare = DesktopThreadSelection.parse(veoID).bareID
        guard let itemID = item.string("id") else { return }
        if let turnID {
            try upsertTurn(
                veoID: bare,
                turnID: turnID,
                status: nil,
                startedAt: nil,
                errorJSON: nil,
                sortIndex: sortIndex
            )
        }
        try upsertItem(
            veoID: bare,
            itemID: itemID,
            turnID: turnID,
            type: item.string("type"),
            clientID: item.string("clientId"),
            status: item.displayString("status"),
            rawJSON: jsonString(item) ?? "{}",
            sortIndex: sortIndex,
            updatedAt: Date()
        )
    }

    func loadTimelineItems(veoID: String) throws -> [DesktopTimelineItem] {
        try openIfNeeded()
        let bare = DesktopThreadSelection.parse(veoID).bareID
        let sql = """
        SELECT turn_id, raw_json
        FROM items
        WHERE veo_id = ?
        ORDER BY sort_index ASC, updated_at ASC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, bare)
        var items: [DesktopTimelineItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let turnID = columnText(statement, 0)
            guard let raw = columnText(statement, 1),
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parsed = DesktopTimelineItem.parse(object, turnID: turnID) else {
                continue
            }
            items.append(parsed)
        }
        return items
    }

    // MARK: - Private

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS threads (
            veo_id TEXT PRIMARY KEY NOT NULL,
            codex_thread_id TEXT UNIQUE,
            cwd TEXT NOT NULL,
            title TEXT NOT NULL,
            preview TEXT NOT NULL DEFAULT '',
            updated_at REAL NOT NULL,
            status TEXT NOT NULL DEFAULT 'idle',
            is_pinned INTEGER NOT NULL DEFAULT 0,
            is_archived INTEGER NOT NULL DEFAULT 0,
            parent_thread_id TEXT,
            meta_json TEXT NOT NULL DEFAULT '{}',
            workspace_kind TEXT NOT NULL DEFAULT 'project'
        );
        """)
        if try !hasColumn("workspace_kind", in: "threads") {
            try exec("ALTER TABLE threads ADD COLUMN workspace_kind TEXT NOT NULL DEFAULT 'project';")
        }
        // The first projectless implementation called every app-managed chat
        // "temporary". Normalize those rows once; future temporary chats are
        // an explicit user choice.
        if try schemaVersion() < 1 {
            try exec("UPDATE threads SET workspace_kind = 'projectless' WHERE workspace_kind = 'temporary';")
            try exec("PRAGMA user_version = 1;")
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS turns (
            veo_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            status TEXT,
            started_at REAL,
            error_json TEXT,
            sort_index INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (veo_id, turn_id),
            FOREIGN KEY (veo_id) REFERENCES threads(veo_id) ON DELETE CASCADE
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS items (
            veo_id TEXT NOT NULL,
            item_id TEXT NOT NULL,
            turn_id TEXT,
            type TEXT,
            client_id TEXT,
            status TEXT,
            raw_json TEXT NOT NULL,
            sort_index INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL,
            PRIMARY KEY (veo_id, item_id),
            FOREIGN KEY (veo_id) REFERENCES threads(veo_id) ON DELETE CASCADE
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_threads_archived_updated ON threads(is_archived, updated_at DESC);")
        try exec("CREATE INDEX IF NOT EXISTS idx_items_veo_sort ON items(veo_id, sort_index);")
        try exec("CREATE INDEX IF NOT EXISTS idx_threads_codex ON threads(codex_thread_id);")
    }

    private func upsertTurn(
        veoID: String,
        turnID: String,
        status: String?,
        startedAt: Date?,
        errorJSON: String?,
        sortIndex: Int
    ) throws {
        let sql = """
        INSERT INTO turns (veo_id, turn_id, status, started_at, error_json, sort_index)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(veo_id, turn_id) DO UPDATE SET
            status = COALESCE(excluded.status, turns.status),
            started_at = COALESCE(excluded.started_at, turns.started_at),
            error_json = COALESCE(excluded.error_json, turns.error_json),
            sort_index = excluded.sort_index;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, veoID)
        try bindText(statement, 2, turnID)
        try bindOptionalText(statement, 3, status)
        if let startedAt {
            sqlite3_bind_double(statement, 4, startedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        try bindOptionalText(statement, 5, errorJSON)
        sqlite3_bind_int(statement, 6, Int32(sortIndex))
        try stepDone(statement)
    }

    private func upsertItem(
        veoID: String,
        itemID: String,
        turnID: String?,
        type: String?,
        clientID: String?,
        status: String?,
        rawJSON: String,
        sortIndex: Int,
        updatedAt: Date
    ) throws {
        let sql = """
        INSERT INTO items (
            veo_id, item_id, turn_id, type, client_id, status, raw_json, sort_index, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(veo_id, item_id) DO UPDATE SET
            turn_id = COALESCE(excluded.turn_id, items.turn_id),
            type = COALESCE(excluded.type, items.type),
            client_id = COALESCE(excluded.client_id, items.client_id),
            status = COALESCE(excluded.status, items.status),
            raw_json = excluded.raw_json,
            sort_index = excluded.sort_index,
            updated_at = excluded.updated_at;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, veoID)
        try bindText(statement, 2, itemID)
        try bindOptionalText(statement, 3, turnID)
        try bindOptionalText(statement, 4, type)
        try bindOptionalText(statement, 5, clientID)
        try bindOptionalText(statement, 6, status)
        try bindText(statement, 7, rawJSON)
        sqlite3_bind_int(statement, 8, Int32(sortIndex))
        sqlite3_bind_double(statement, 9, updatedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    private func thread(from statement: OpaquePointer?) -> DesktopThread? {
        guard let statement,
              let veoBare = columnText(statement, 0) else { return nil }
        let codexID = columnText(statement, 1)
        let cwd = columnText(statement, 2) ?? FileManager.default.homeDirectoryForCurrentUser.path
        let title = columnText(statement, 3) ?? "New chat"
        let preview = columnText(statement, 4) ?? ""
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        let status = columnText(statement, 6) ?? "idle"
        let isPinned = sqlite3_column_int(statement, 7) != 0
        let parentBare = columnText(statement, 8)
        let meta = jsonObject(columnText(statement, 9) ?? "{}") ?? [:]
        let workspaceKind = columnText(statement, 10)
            .flatMap(DesktopWorkspaceKind.init(rawValue:)) ?? .project
        return DesktopThread.makeVeo(
            id: veoBare,
            title: title,
            preview: preview,
            cwd: cwd,
            updatedAt: updatedAt,
            status: status,
            isPinned: isPinned,
            codexThreadId: codexID,
            parentThreadID: parentBare,
            agentNickname: meta.string("agentNickname"),
            agentRole: meta.string("agentRole"),
            canAcceptDirectInput: meta["canAcceptDirectInput"] as? Bool,
            activeFlags: meta.stringArray("activeFlags") ?? [],
            agentDepth: meta.number("agentDepth").map(Int.init),
            sessionID: meta.string("sessionId"),
            workspaceKind: workspaceKind
        )
    }

    private func hasColumn(_ column: String, in table: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, 1) == column { return true }
        }
        return false
    }

    private func schemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let db else { throw StoreError.notOpen }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw StoreError.notOpen }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error \(result)"
            sqlite3_free(errorMessage)
            throw StoreError.execFailed(message)
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "step failed"
            throw StoreError.execFailed(message)
        }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) throws {
        let result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        guard result == SQLITE_OK else { throw StoreError.bindFailed }
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) throws {
        if let value {
            try bindText(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let statement, let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private func jsonObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    enum StoreError: LocalizedError {
        case notOpen
        case openFailed(String)
        case prepareFailed(String)
        case execFailed(String)
        case bindFailed

        var errorDescription: String? {
            switch self {
            case .notOpen: return "Veo thread store is not open."
            case .openFailed(let message): return "Could not open Veo thread store: \(message)"
            case .prepareFailed(let message): return "Veo thread store prepare failed: \(message)"
            case .execFailed(let message): return "Veo thread store error: \(message)"
            case .bindFailed: return "Veo thread store bind failed."
            }
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
