import Foundation
import SQLite3

/// Thin READ-ONLY SQLite reader for OpenCode's session db, plus the row→`ProviderSession` mapping.
///
/// OpenCode stores sessions in `~/.local/share/opencode/opencode.db` (WAL mode), NOT flat JSONL.
/// `import SQLite3` is a macOS system module — no new SwiftPM dependency, no Package.swift linker
/// flags (verified, libversion 3.51.0). Confirmed schema (see `spike/FINDINGS.md`):
///   session(id, project_id, parent_id, slug, directory, title, time_updated, time_archived, …)
///   message(id, session_id, time_created, time_updated, data TEXT)   -- data is JSON
///
/// All db work is read-only and TOTAL: an absent / locked / corrupt / empty db yields `[]`, never a
/// throw or crash (the App polls this on a timer and merges the result; OpenCode being unavailable
/// must never take down the island). We open with `SQLITE_OPEN_READONLY` (no `immutable`, so the WAL
/// is honored — the db may be open while OpenCode runs) and `query_only`, so we cannot write,
/// checkpoint, or otherwise perturb a live db. Tests run against a TINY fixture db in a temp dir,
/// never the real one.
public enum OpenCodeStore {
    /// A raw session row joined with its messages, in chronological message order. The pure layer
    /// (`OpenCodeState`) turns this into status/tokens; this struct is the seam between the SQLite
    /// read and the (db-free) mapping, so the mapping is testable from hand-built rows.
    public struct SessionRow: Equatable, Sendable {
        public let id: String
        public let parentID: String?
        public let directory: String       // session.directory = cwd
        public let title: String           // session.title (NOT NULL in the schema)
        public let timeCreatedMs: Int?
        public let timeUpdatedMs: Int?
        public let timeArchivedMs: Int?    // non-nil ⇒ archived (exclude from top-level rows)
        public let messages: [OpenCodeMessage]

        public init(id: String, parentID: String?, directory: String, title: String,
                    timeCreatedMs: Int?, timeUpdatedMs: Int?, timeArchivedMs: Int?,
                    messages: [OpenCodeMessage]) {
            self.id = id
            self.parentID = parentID
            self.directory = directory
            self.title = title
            self.timeCreatedMs = timeCreatedMs
            self.timeUpdatedMs = timeUpdatedMs
            self.timeArchivedMs = timeArchivedMs
            self.messages = messages
        }

        public var isSubSession: Bool { parentID != nil }
        public var isArchived: Bool { timeArchivedMs != nil }
    }

    public static let defaultPath = (("~/.local/share/opencode/opencode.db") as NSString).expandingTildeInPath

    /// A session updated within this window is "active" — mirrors the Claude poll path's
    /// `ClaudeCodeProvider.activeWindow` (1800s) so OpenCode discovery is bounded by recency, not by
    /// total session history. Without it the per-poll read of sessions+messages scales with all-time
    /// usage and stale top-level rows linger forever.
    public static let activeWindow: TimeInterval = 1800

    /// Read every session row + its messages from the db at `path`, as of `now`. The per-poll read is
    /// bounded by recency: top-level non-archived sessions older than `activeWindow` are dropped IN
    /// SQL (so the messages join stays cheap too), while archived / sub-session rows are kept
    /// regardless (they're excluded by `sessions(from:)`, but reading them lets callers/tests still
    /// observe them). Returns `[]` for any failure (absent / unreadable / locked / no `session` table
    /// / corrupt). NEVER writes.
    public static func readSessions(path: String = defaultPath, now: Date = Date()) -> [SessionRow] {
        // Fast bail: no file ⇒ no sessions (the common case when OpenCode isn't installed/used).
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        var db: OpaquePointer?
        // READONLY (no `immutable`) so the WAL is read too; NOMUTEX is fine (single-threaded use).
        let openRC = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close(db) }
        guard openRC == SQLITE_OK, let db = db else { return [] }
        // Belt-and-suspenders: forbid any write at the connection level. Ignore its result — a RO
        // connection already can't write; this just documents intent and guards future changes.
        sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)

        // Recency cutoff (ms since epoch). A top-level, non-archived session must have been updated at
        // or after this to be read; archived / sub-session rows are kept regardless. This bounds the
        // per-poll read (sessions AND their messages) to recent history, never all-time usage.
        let cutoffMs = Int64(now.addingTimeInterval(-activeWindow).timeIntervalSince1970 * 1000)

        // Read sessions first (recency-bounded), so the messages read can be scoped to just these IDs.
        var rows: [SessionRow] = []
        let sql = """
        SELECT id, parent_id, directory, title, time_created, time_updated, time_archived
        FROM session
        WHERE parent_id IS NOT NULL OR time_archived IS NOT NULL OR time_updated >= ?;
        """
        forEachRow(db, sql, bind: { stmt in sqlite3_bind_int64(stmt, 1, cutoffMs) }) { stmt in
            guard let id = textColumn(stmt, 0) else { return }
            rows.append(SessionRow(
                id: id,
                parentID: textColumn(stmt, 1),
                directory: textColumn(stmt, 2) ?? "",
                title: textColumn(stmt, 3) ?? "",
                timeCreatedMs: intColumn(stmt, 4),
                timeUpdatedMs: intColumn(stmt, 5),
                timeArchivedMs: intColumn(stmt, 6),
                messages: []))
        }
        guard !rows.isEmpty else { return [] }

        // Pull messages only for the sessions we kept, grouped + in chronological order. Scoping the
        // join to the recent session set keeps this read cheap as total history grows.
        let keptIDs = Set(rows.map(\.id))
        var messagesBySession: [String: [OpenCodeMessage]] = [:]
        forEachRow(db, "SELECT session_id, data FROM message ORDER BY time_created ASC;") { stmt in
            guard let sid = textColumn(stmt, 0), keptIDs.contains(sid) else { return }
            guard let data = textColumn(stmt, 1), let msg = OpenCodeMessage.parse(data) else { return }
            messagesBySession[sid, default: []].append(msg)
        }
        return rows.map { row in
            SessionRow(id: row.id, parentID: row.parentID, directory: row.directory, title: row.title,
                       timeCreatedMs: row.timeCreatedMs, timeUpdatedMs: row.timeUpdatedMs,
                       timeArchivedMs: row.timeArchivedMs, messages: messagesBySession[row.id] ?? [])
        }
    }

    // MARK: - Pure mapping (db-free; testable from hand-built rows)

    /// Map raw session rows into the shared `ProviderSession` model, applying the OpenCode session
    /// policy: only TOP-LEVEL, non-archived, RECENTLY-updated sessions become rows. A sub-session
    /// (`parent_id` set) is the analogue of a Claude sub-agent rollup — it isn't listed as its own
    /// top-level row (we exclude it here; the parent already represents the work). Archived sessions
    /// are dropped. A row whose `time_updated` is older than `activeWindow` (or missing entirely) is
    /// dropped too — mirroring the Claude poll path's `activeWindow` discovery filter so a stale
    /// session can't linger as a permanent row. (The SQL read already applies this cutoff; re-applying
    /// here keeps the pure mapping correct for hand-built rows and defends against any future caller.)
    /// Sorted like the Claude poll path: action-priority first, then most-recently-updated.
    public static func sessions(from rows: [SessionRow], now: Date = Date()) -> [ProviderSession] {
        let cutoff = now.addingTimeInterval(-activeWindow)
        return rows
            .filter { !$0.isSubSession && !$0.isArchived }
            .filter { row in
                // Missing time_updated → treat conservatively (filter out). Otherwise require recency.
                guard let ms = row.timeUpdatedMs else { return false }
                return Date(timeIntervalSince1970: Double(ms) / 1000) >= cutoff
            }
            .map { row in providerSession(from: row, now: now) }
            .sorted {
                let ra = DisplayPriority.rank($0.status), rb = DisplayPriority.rank($1.status)
                if ra != rb { return ra < rb }
                return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            }
    }

    /// Map ONE row → a `ProviderSession`. Label prefers the session title, falling back to the
    /// directory's last path component, then a short id. Status + tokens come from the pure layer.
    public static func providerSession(from row: SessionRow, now: Date = Date()) -> ProviderSession {
        let lastUpdated = row.timeUpdatedMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        let startedAt = row.timeCreatedMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        let status = OpenCodeState.deriveStatus(messages: row.messages, lastUpdated: lastUpdated, now: now)
        let tokens = OpenCodeState.tokens(messages: row.messages)

        let dirName = (row.directory as NSString).lastPathComponent
        let label = !dirName.isEmpty ? dirName : String(row.id.prefix(8))
        let trimmedTitle = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? nil : trimmedTitle

        return ProviderSession(provider: .opencode, fullID: row.id, label: label, title: title,
                               status: status, tokens: tokens, startedAt: startedAt,
                               steps: 0, subDigests: [], lastActivity: lastUpdated)
    }

    // MARK: - SQLite helpers (read-only)

    /// Prepare + (optionally) bind + step a SELECT, calling `onRow` per row; finalize always. Swallows
    /// prepare/step failures (a missing table on a foreign/corrupt db) — the caller's contract is "no
    /// rows, never crash". `bind` runs once after a successful prepare to bind any `?` placeholders.
    /// `@convention(block)` not needed: a plain closure is fine here.
    private static func forEachRow(_ db: OpaquePointer, _ sql: String,
                                   bind: ((OpaquePointer) -> Void)? = nil,
                                   _ onRow: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            sqlite3_finalize(stmt)
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { onRow(stmt) }
    }

    private static func textColumn(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private static func intColumn(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        // A NULL integer column reads as type NULL; distinguish it from a real 0.
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }
}

/// The OpenCode session source, behind the `SessionProvider` protocol. Poll-only (OpenCode has no
/// hook/event mechanism we can hook into) — every refresh re-reads the db read-only and maps the
/// top-level, non-archived sessions into the shared model. Absent/locked/empty db ⇒ no sessions.
public struct OpenCodeProvider: SessionProvider {
    public let kind: SessionProviderKind = .opencode
    private let dbPath: String

    public init(dbPath: String = OpenCodeStore.defaultPath) {
        self.dbPath = dbPath
    }

    public func poll(now: Date) -> [ProviderSession] {
        OpenCodeStore.sessions(from: OpenCodeStore.readSessions(path: dbPath, now: now), now: now)
    }
}
