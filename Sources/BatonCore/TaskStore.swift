import Foundation

/// The shared task store. The app and every `baton-mcp` process open the same
/// file. SQLite in WAL mode handles the concurrent access, so no daemon has to
/// be running for an agent to submit a task.
public final class TaskStore: @unchecked Sendable {
    public static let shared = TaskStore()

    private let lock = NSLock()
    private var database: Database?
    private let path: String
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(path: String = BatonPaths.databaseURL.path) {
        self.path = path
    }

    // MARK: - Setup

    private func connection() throws -> Database {
        if let database { return database }
        BatonPaths.ensureSupportDirectory()
        let database = try Database(path: path)
        try database.execute(
            """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            """
        )
        try Self.migrate(database)
        self.database = database
        return database
    }

    private static func migrate(_ database: Database) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
              id TEXT PRIMARY KEY,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL,
              responded_at REAL,
              status TEXT NOT NULL,
              kind TEXT NOT NULL,
              priority TEXT NOT NULL,
              title TEXT NOT NULL,
              session_id TEXT,
              agent_name TEXT,
              worktree TEXT,
              branch TEXT,
              dedupe_key TEXT,
              timeout_at REAL,
              snoozed_until REAL,
              payload TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS tasks_status_idx ON tasks(status);
            CREATE INDEX IF NOT EXISTS tasks_session_idx ON tasks(session_id);
            CREATE INDEX IF NOT EXISTS tasks_dedupe_idx ON tasks(dedupe_key);
            CREATE TABLE IF NOT EXISTS meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            INSERT OR IGNORE INTO meta(key, value) VALUES('revision', '0');
            """
        )
    }

    /// Opens the database now so a caller can report a clear failure early.
    public func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try connection()
    }

    // MARK: - Revision

    /// A counter that grows on every write. The app compares it to decide
    /// whether it needs to reload.
    public func revision() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        do {
            let database = try connection()
            let rows = try database.query("SELECT value FROM meta WHERE key = 'revision'") { row in
                Int64(row.string(0) ?? "0") ?? 0
            }
            return rows.first ?? 0
        } catch {
            return 0
        }
    }

    private func bumpRevision(_ database: Database) throws {
        try database.run("UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'revision'")
    }

    // MARK: - Writes

    public enum SubmitResult: Sendable {
        case created(BatonTask)
        case deduplicated(BatonTask)

        public var task: BatonTask {
            switch self {
            case .created(let task), .deduplicated(let task): return task
            }
        }

        public var wasDeduplicated: Bool {
            if case .deduplicated = self { return true }
            return false
        }
    }

    /// Inserts a task. A matching `dedupeKey` on an open task returns that task
    /// instead, so a retrying agent cannot flood the queue.
    @discardableResult
    public func submit(_ task: BatonTask) throws -> SubmitResult {
        lock.lock()
        defer { lock.unlock() }
        let database = try connection()
        return try database.transaction {
            if let key = task.dedupeKey, !key.isEmpty {
                let existing = try loadRows(
                    database,
                    where: "dedupe_key = ? AND status IN ('pending','active','snoozed')",
                    bindings: [.text(key)],
                    limit: 1
                )
                if let found = existing.first {
                    return .deduplicated(found)
                }
            }
            try insert(database, task)
            try bumpRevision(database)
            return .created(task)
        }
    }

    /// Replaces a task row. Bumps `updatedAt`.
    public func update(_ task: BatonTask) throws {
        lock.lock()
        defer { lock.unlock() }
        let database = try connection()
        var updated = task
        updated.updatedAt = Date()
        try database.transaction {
            try insert(database, updated)
            try bumpRevision(database)
        }
    }

    /// Applies a change to one task inside a transaction. Returns the new value.
    @discardableResult
    public func mutate(id: String, _ change: (inout BatonTask) -> Void) throws -> BatonTask? {
        lock.lock()
        defer { lock.unlock() }
        let database = try connection()
        return try database.transaction {
            guard var task = try loadRows(database, where: "id = ?", bindings: [.text(id)], limit: 1).first else {
                return nil
            }
            change(&task)
            task.updatedAt = Date()
            try insert(database, task)
            try bumpRevision(database)
            return task
        }
    }

    /// Records a human response and closes the task.
    @discardableResult
    public func respond(id: String, response: BatonTask.Response) throws -> BatonTask? {
        try mutate(id: id) { task in
            task.response = response
            task.respondedAt = response.respondedAt
            task.snoozedUntil = nil
            switch response.decision {
            case .approved, .answered, .chose: task.status = .done
            case .sentBack: task.status = .sentBack
            case .expired: task.status = .expired
            case .cancelled: task.status = .cancelled
            }
        }
    }

    /// Expires every open task whose deadline passed. Returns the changed tasks.
    @discardableResult
    public func expireOverdue(now: Date = Date()) throws -> [BatonTask] {
        let open = try tasks(statuses: BatonTask.Status.allCases.filter(\.isOpen))
        var changed: [BatonTask] = []
        for task in open {
            guard let deadline = task.timeoutAt, deadline <= now, task.onTimeout != .wait else { continue }
            if let updated = try respond(id: task.id, response: .init(decision: .expired, text: "No answer before the deadline.")) {
                changed.append(updated)
            }
        }
        return changed
    }

    /// Deletes resolved tasks older than the cutoff.
    @discardableResult
    public func pruneResolved(olderThan interval: TimeInterval = 60 * 60 * 24 * 7) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let database = try connection()
        let cutoff = Date().addingTimeInterval(-interval)
        return try database.transaction {
            let before = try countAll(database)
            try database.run(
                "DELETE FROM tasks WHERE status NOT IN ('pending','active','snoozed') AND updated_at < ?",
                [.date(cutoff)]
            )
            let after = try countAll(database)
            try bumpRevision(database)
            return Int(before - after)
        }
    }

    // MARK: - Reads

    public func task(id: String) throws -> BatonTask? {
        lock.lock()
        defer { lock.unlock() }
        let database = try connection()
        return try loadRows(database, where: "id = ?", bindings: [.text(id)], limit: 1).first
    }

    public func tasks(
        statuses: [BatonTask.Status]? = nil,
        sessionId: String? = nil,
        limit: Int = 500
    ) throws -> [BatonTask] {
        lock.lock()
        defer { lock.unlock() }
        let database = try connection()
        var clauses: [String] = []
        var bindings: [Database.Value] = []
        if let statuses, !statuses.isEmpty {
            let placeholders = statuses.map { _ in "?" }.joined(separator: ",")
            clauses.append("status IN (\(placeholders))")
            bindings.append(contentsOf: statuses.map { .text($0.rawValue) })
        }
        if let sessionId, !sessionId.isEmpty {
            clauses.append("session_id = ?")
            bindings.append(.text(sessionId))
        }
        let predicate = clauses.isEmpty ? nil : clauses.joined(separator: " AND ")
        return try loadRows(database, where: predicate, bindings: bindings, limit: limit)
    }

    /// Open tasks in the order the queue shows them. Urgent first, then oldest.
    public func openTasks() throws -> [BatonTask] {
        let statuses = BatonTask.Status.allCases.filter(\.isOpen)
        return try tasks(statuses: statuses).sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// How many tasks this session created since the given time. Feeds the rate limit.
    public func recentCount(sessionId: String?, since: Date) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let database = try connection()
        var sql = "SELECT COUNT(*) FROM tasks WHERE created_at >= ?"
        var bindings: [Database.Value] = [.date(since)]
        if let sessionId, !sessionId.isEmpty {
            sql += " AND session_id = ?"
            bindings.append(.text(sessionId))
        }
        let rows = try database.query(sql, bindings) { Int($0.int(0) ?? 0) }
        return rows.first ?? 0
    }

    // MARK: - Row plumbing

    private func countAll(_ database: Database) throws -> Int64 {
        let rows = try database.query("SELECT COUNT(*) FROM tasks") { $0.int(0) ?? 0 }
        return rows.first ?? 0
    }

    private func insert(_ database: Database, _ task: BatonTask) throws {
        let payload = String(data: try encoder.encode(task), encoding: .utf8) ?? "{}"
        try database.run(
            """
            INSERT INTO tasks (
              id, created_at, updated_at, responded_at, status, kind, priority, title,
              session_id, agent_name, worktree, branch, dedupe_key, timeout_at,
              snoozed_until, payload
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              updated_at = excluded.updated_at,
              responded_at = excluded.responded_at,
              status = excluded.status,
              kind = excluded.kind,
              priority = excluded.priority,
              title = excluded.title,
              session_id = excluded.session_id,
              agent_name = excluded.agent_name,
              worktree = excluded.worktree,
              branch = excluded.branch,
              dedupe_key = excluded.dedupe_key,
              timeout_at = excluded.timeout_at,
              snoozed_until = excluded.snoozed_until,
              payload = excluded.payload
            """,
            [
                .text(task.id),
                .date(task.createdAt),
                .date(task.updatedAt),
                .date(task.respondedAt),
                .text(task.status.rawValue),
                .text(task.kind.rawValue),
                .text(task.priority.rawValue),
                .text(task.title),
                .text(task.agent.sessionId),
                .text(task.agent.name),
                .text(task.repo?.worktreePath),
                .text(task.repo?.branch),
                .text(task.dedupeKey),
                .date(task.timeoutAt),
                .date(task.snoozedUntil),
                .text(payload),
            ]
        )
    }

    private func loadRows(
        _ database: Database,
        where predicate: String? = nil,
        bindings: [Database.Value] = [],
        limit: Int = 500
    ) throws -> [BatonTask] {
        var sql = "SELECT payload FROM tasks"
        if let predicate { sql += " WHERE \(predicate)" }
        sql += " ORDER BY created_at ASC LIMIT \(max(1, limit))"
        let payloads = try database.query(sql, bindings) { $0.string(0) }
        return payloads.compactMap { payload -> BatonTask? in
            guard let payload, let data = payload.data(using: .utf8) else { return nil }
            return try? decoder.decode(BatonTask.self, from: data)
        }
    }
}
