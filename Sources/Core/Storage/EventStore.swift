import Foundation

/// Persisted session record (summary of a completed or active session).
public struct SessionRecord {
    public let id: String
    public let projectId: String
    public let projectPath: String?
    public let name: String
    public let agentType: String?
    public let model: String?
    public let startedAt: Date
    public let endedAt: Date?
    public let totalCost: Double
    public let totalTasks: Int
    public let totalErrors: Int
    public let totalFilesChanged: Int
    public let totalCommands: Int
    public let totalSubagents: Int
    public let totalIdleTime: TimeInterval
}

/// Persisted task record (a single task block within a session).
public struct TaskRecord {
    public let id: Int
    public let sessionId: String
    public let startedAt: Date
    public let endedAt: Date?
    public let duration: TimeInterval?
    public let cost: Double?
    public let filesChanged: Int
    public let commandsRun: Int
    public let errorCount: Int
    public let classification: String?
    public let files: [String]
}

/// Snapshot of SessionStats for persistence.
public struct SessionStatsSnapshot {
    public let totalCost: Double
    public let totalTasks: Int
    public let totalErrors: Int
    public let totalFilesChanged: Int
    public let totalCommands: Int
    public let totalSubagents: Int
    public let totalIdleTime: TimeInterval

    public init(totalCost: Double, totalTasks: Int, totalErrors: Int,
                totalFilesChanged: Int, totalCommands: Int,
                totalSubagents: Int, totalIdleTime: TimeInterval) {
        self.totalCost = totalCost
        self.totalTasks = totalTasks
        self.totalErrors = totalErrors
        self.totalFilesChanged = totalFilesChanged
        self.totalCommands = totalCommands
        self.totalSubagents = totalSubagents
        self.totalIdleTime = totalIdleTime
    }
}

/// Domain-specific persistence layer for Cosmodrome events, sessions, and stats.
/// All methods are safe to call from any thread — SQLiteStore serializes on its own queue.
public final class EventStore {
    private let db: SQLiteStore

    private static let migrations: [(version: Int, sql: String)] = [
        (version: 1, sql: """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                project_path TEXT,
                name TEXT NOT NULL,
                agent_type TEXT,
                model TEXT,
                started_at REAL NOT NULL,
                ended_at REAL,
                total_cost REAL DEFAULT 0,
                total_tasks INTEGER DEFAULT 0,
                total_errors INTEGER DEFAULT 0,
                total_files_changed INTEGER DEFAULT 0,
                total_commands INTEGER DEFAULT 0,
                total_subagents INTEGER DEFAULT 0,
                total_idle_time REAL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                timestamp REAL NOT NULL,
                kind TEXT NOT NULL,
                data TEXT,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            );
            CREATE INDEX IF NOT EXISTS idx_events_session_time ON events(session_id, timestamp);
            CREATE INDEX IF NOT EXISTS idx_events_kind_time ON events(kind, timestamp);

            CREATE TABLE IF NOT EXISTS cost_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                timestamp REAL NOT NULL,
                cumulative_cost REAL NOT NULL,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            );

            CREATE TABLE IF NOT EXISTS task_records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                duration REAL,
                cost REAL,
                files_changed INTEGER DEFAULT 0,
                commands_run INTEGER DEFAULT 0,
                error_count INTEGER DEFAULT 0,
                classification TEXT,
                files_json TEXT,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            );
            CREATE INDEX IF NOT EXISTS idx_tasks_session ON task_records(session_id);
        """),
        (version: 2, sql: """
            CREATE TABLE IF NOT EXISTS error_patterns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                pattern_hash TEXT NOT NULL,
                pattern_text TEXT NOT NULL,
                occurrences INTEGER DEFAULT 1,
                stuck_count INTEGER DEFAULT 0,
                resolved_count INTEGER DEFAULT 0,
                last_seen REAL NOT NULL,
                avg_resolution_time REAL
            );
            CREATE INDEX IF NOT EXISTS idx_error_patterns_hash ON error_patterns(pattern_hash);

            CREATE TABLE IF NOT EXISTS workflow_sequences (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_path TEXT,
                trigger_kind TEXT NOT NULL,
                trigger_context TEXT,
                follow_kind TEXT NOT NULL,
                follow_context TEXT,
                count INTEGER DEFAULT 1,
                total_trigger_count INTEGER DEFAULT 1,
                last_seen REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_workflow_trigger
                ON workflow_sequences(project_path, trigger_kind, trigger_context);
        """),
    ]

    /// Create an EventStore backed by a SQLite database at the default location.
    public static func defaultStore() throws -> EventStore {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "Cosmodrome", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application Support directory not found"])
        }
        let dir = appSupport.appendingPathComponent("Cosmodrome")
        let dbPath = dir.appendingPathComponent("cosmodrome.db").path
        return try EventStore(path: dbPath)
    }

    /// Create an EventStore at a specific path.
    public init(path: String) throws {
        self.db = try SQLiteStore(path: path)
        try db.migrate(Self.migrations)
    }

    /// Create an EventStore with an in-memory database (for tests).
    public init() throws {
        self.db = try SQLiteStore()
        try db.migrate(Self.migrations)
    }

    // MARK: - Session CRUD

    /// Record a new session start.
    public func recordSessionStart(sessionId: UUID, projectId: String, projectPath: String?,
                                   name: String, agentType: String?) throws {
        try db.execute(
            """
            INSERT OR REPLACE INTO sessions (id, project_id, project_path, name, agent_type, started_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            params: [
                .text(sessionId.uuidString),
                .text(projectId),
                projectPath.map { .text($0) } ?? .null,
                .text(name),
                agentType.map { .text($0) } ?? .null,
                .double(Date().timeIntervalSince1970),
            ]
        )
    }

    /// Record a session end with final stats.
    public func recordSessionEnd(sessionId: UUID, stats: SessionStatsSnapshot) throws {
        try db.execute(
            """
            UPDATE sessions SET
                ended_at = ?,
                total_cost = ?,
                total_tasks = ?,
                total_errors = ?,
                total_files_changed = ?,
                total_commands = ?,
                total_subagents = ?,
                total_idle_time = ?
            WHERE id = ?
            """,
            params: [
                .double(Date().timeIntervalSince1970),
                .double(stats.totalCost),
                .int(stats.totalTasks),
                .int(stats.totalErrors),
                .int(stats.totalFilesChanged),
                .int(stats.totalCommands),
                .int(stats.totalSubagents),
                .double(stats.totalIdleTime),
                .text(sessionId.uuidString),
            ]
        )
    }

    /// Update session stats without ending the session.
    public func updateSessionStats(sessionId: UUID, stats: SessionStatsSnapshot) throws {
        try db.execute(
            """
            UPDATE sessions SET
                total_cost = ?,
                total_tasks = ?,
                total_errors = ?,
                total_files_changed = ?,
                total_commands = ?,
                total_subagents = ?,
                total_idle_time = ?
            WHERE id = ?
            """,
            params: [
                .double(stats.totalCost),
                .int(stats.totalTasks),
                .int(stats.totalErrors),
                .int(stats.totalFilesChanged),
                .int(stats.totalCommands),
                .int(stats.totalSubagents),
                .double(stats.totalIdleTime),
                .text(sessionId.uuidString),
            ]
        )
    }

    /// Update the detected model for a session.
    public func updateSessionModel(sessionId: UUID, model: String) throws {
        try db.execute(
            "UPDATE sessions SET model = ? WHERE id = ?",
            params: [.text(model), .text(sessionId.uuidString)]
        )
    }

    /// Load session history, optionally filtered by project path.
    public func loadSessionHistory(projectPath: String? = nil, limit: Int = 100) throws -> [SessionRecord] {
        let sql: String
        let params: [SQLiteValue]

        if let path = projectPath {
            sql = "SELECT * FROM sessions WHERE project_path = ? ORDER BY started_at DESC LIMIT ?"
            params = [.text(path), .int(limit)]
        } else {
            sql = "SELECT * FROM sessions ORDER BY started_at DESC LIMIT ?"
            params = [.int(limit)]
        }

        return try db.query(sql, params: params) { row in
            SessionRecord(
                id: row.text(0) ?? "",
                projectId: row.text(1) ?? "",
                projectPath: row.optionalText(2),
                name: row.text(3) ?? "",
                agentType: row.optionalText(4),
                model: row.optionalText(5),
                startedAt: Date(timeIntervalSince1970: row.double(6)),
                endedAt: row.optionalDouble(7).map { Date(timeIntervalSince1970: $0) },
                totalCost: row.double(8),
                totalTasks: row.int(9),
                totalErrors: row.int(10),
                totalFilesChanged: row.int(11),
                totalCommands: row.int(12),
                totalSubagents: row.int(13),
                totalIdleTime: row.double(14)
            )
        }
    }

    // MARK: - Event Persistence

    /// Persist a batch of activity events.
    public func persistEvents(_ events: [ActivityEvent]) throws {
        guard !events.isEmpty else { return }

        let sql = """
            INSERT INTO events (session_id, timestamp, kind, data) VALUES (?, ?, ?, ?)
        """

        let paramSets: [[SQLiteValue]] = events.map { event in
            [
                .text(event.sessionId.uuidString),
                .double(event.timestamp.timeIntervalSince1970),
                .text(event.kind.label),
                .text(event.kind.jsonData),
            ]
        }

        try db.batchInsert(sql, paramSets: paramSets)
    }

    /// Load events for a session, optionally filtered.
    public func loadEvents(sessionId: UUID? = nil, since: Date? = nil,
                           kind: String? = nil, limit: Int = 1000) throws -> [PersistedEvent] {
        var conditions: [String] = []
        var params: [SQLiteValue] = []

        if let sid = sessionId {
            conditions.append("session_id = ?")
            params.append(.text(sid.uuidString))
        }
        if let since = since {
            conditions.append("timestamp > ?")
            params.append(.double(since.timeIntervalSince1970))
        }
        if let kind = kind {
            conditions.append("kind = ?")
            params.append(.text(kind))
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = "SELECT id, session_id, timestamp, kind, data FROM events \(whereClause) ORDER BY timestamp DESC LIMIT ?"
        params.append(.int(limit))

        return try db.query(sql, params: params) { row in
            PersistedEvent(
                id: row.int(0),
                sessionId: row.text(1) ?? "",
                timestamp: Date(timeIntervalSince1970: row.double(2)),
                kind: row.text(3) ?? "",
                data: row.optionalText(4)
            )
        }
    }

    /// Count events matching criteria.
    public func countEvents(sessionId: UUID? = nil, kind: String? = nil, since: Date? = nil) throws -> Int {
        var conditions: [String] = []
        var params: [SQLiteValue] = []

        if let sid = sessionId {
            conditions.append("session_id = ?")
            params.append(.text(sid.uuidString))
        }
        if let kind = kind {
            conditions.append("kind = ?")
            params.append(.text(kind))
        }
        if let since = since {
            conditions.append("timestamp > ?")
            params.append(.double(since.timeIntervalSince1970))
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = "SELECT COUNT(*) FROM events \(whereClause)"

        return try db.scalar(sql, params: params) ?? 0
    }

    // MARK: - Cost History

    /// Record a cost data point.
    public func recordCost(sessionId: UUID, cumulativeCost: Double) throws {
        try db.execute(
            "INSERT INTO cost_history (session_id, timestamp, cumulative_cost) VALUES (?, ?, ?)",
            params: [
                .text(sessionId.uuidString),
                .double(Date().timeIntervalSince1970),
                .double(cumulativeCost),
            ]
        )
    }

    /// Load cost history for a session.
    public func loadCostHistory(sessionId: UUID, limit: Int = 200) throws -> [(Date, Double)] {
        return try db.query(
            "SELECT timestamp, cumulative_cost FROM cost_history WHERE session_id = ? ORDER BY timestamp DESC LIMIT ?",
            params: [.text(sessionId.uuidString), .int(limit)]
        ) { row in
            (Date(timeIntervalSince1970: row.double(0)), row.double(1))
        }.reversed()
    }

    // MARK: - Task Records

    /// Record a task start. Returns the task record ID.
    @discardableResult
    public func recordTaskStart(sessionId: UUID) throws -> Int {
        try db.execute(
            "INSERT INTO task_records (session_id, started_at) VALUES (?, ?)",
            params: [
                .text(sessionId.uuidString),
                .double(Date().timeIntervalSince1970),
            ]
        )
        // Return the last inserted row id
        return try db.scalar("SELECT last_insert_rowid()") ?? 0
    }

    /// Record a task completion.
    public func recordTaskEnd(taskId: Int, duration: TimeInterval, cost: Double?,
                              filesChanged: Int, commandsRun: Int, errorCount: Int,
                              classification: String?, files: [String]) throws {
        let filesJson = files.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: files))
            .flatMap { String(data: $0, encoding: .utf8) }

        try db.execute(
            """
            UPDATE task_records SET
                ended_at = ?, duration = ?, cost = ?,
                files_changed = ?, commands_run = ?, error_count = ?,
                classification = ?, files_json = ?
            WHERE id = ?
            """,
            params: [
                .double(Date().timeIntervalSince1970),
                .double(duration),
                cost.map { .double($0) } ?? .null,
                .int(filesChanged),
                .int(commandsRun),
                .int(errorCount),
                classification.map { .text($0) } ?? .null,
                filesJson.map { .text($0) } ?? .null,
                .int(taskId),
            ]
        )
    }

    /// Load task records for a session.
    public func loadTaskRecords(sessionId: UUID? = nil, classification: String? = nil,
                                limit: Int = 100) throws -> [TaskRecord] {
        var conditions: [String] = []
        var params: [SQLiteValue] = []

        if let sid = sessionId {
            conditions.append("session_id = ?")
            params.append(.text(sid.uuidString))
        }
        if let cls = classification {
            conditions.append("classification = ?")
            params.append(.text(cls))
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = """
            SELECT id, session_id, started_at, ended_at, duration, cost,
                   files_changed, commands_run, error_count, classification, files_json
            FROM task_records \(whereClause) ORDER BY started_at DESC LIMIT ?
        """
        params.append(.int(limit))

        return try db.query(sql, params: params) { row in
            let filesJson = row.optionalText(10)
            let files: [String] = filesJson
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }
                ?? []

            return TaskRecord(
                id: row.int(0),
                sessionId: row.text(1) ?? "",
                startedAt: Date(timeIntervalSince1970: row.double(2)),
                endedAt: row.optionalDouble(3).map { Date(timeIntervalSince1970: $0) },
                duration: row.optionalDouble(4),
                cost: row.optionalDouble(5),
                filesChanged: row.int(6),
                commandsRun: row.int(7),
                errorCount: row.int(8),
                classification: row.optionalText(9),
                files: files
            )
        }
    }

    /// Aggregate cost by project path.
    public func costByProject(since: Date? = nil) throws -> [(projectPath: String, cost: Double, tasks: Int)] {
        let sinceClause = since != nil ? "AND started_at > ?" : ""
        let params: [SQLiteValue] = since.map { [.double($0.timeIntervalSince1970)] } ?? []

        return try db.query(
            """
            SELECT project_path, SUM(total_cost), SUM(total_tasks)
            FROM sessions
            WHERE project_path IS NOT NULL \(sinceClause)
            GROUP BY project_path
            ORDER BY SUM(total_cost) DESC
            """,
            params: params
        ) { row in
            (projectPath: row.text(0) ?? "", cost: row.double(1), tasks: row.int(2))
        }
    }

    // MARK: - Error Patterns

    /// Record or update an error pattern occurrence.
    public func recordErrorPattern(hash: String, text: String, ledToStuck: Bool,
                                   resolutionTime: TimeInterval?) throws {
        // Try to update existing
        let updated = try db.execute(
            """
            UPDATE error_patterns SET
                occurrences = occurrences + 1,
                stuck_count = stuck_count + ?,
                resolved_count = resolved_count + ?,
                last_seen = ?,
                avg_resolution_time = CASE
                    WHEN ? IS NOT NULL THEN
                        COALESCE((avg_resolution_time * resolved_count + ?) / (resolved_count + 1), ?)
                    ELSE avg_resolution_time
                END
            WHERE pattern_hash = ?
            """,
            params: [
                .int(ledToStuck ? 1 : 0),
                .int(ledToStuck ? 0 : 1),
                .double(Date().timeIntervalSince1970),
                resolutionTime.map { .double($0) } ?? .null,
                resolutionTime.map { .double($0) } ?? .null,
                resolutionTime.map { .double($0) } ?? .null,
                .text(hash),
            ]
        )

        if updated == 0 {
            try db.execute(
                """
                INSERT INTO error_patterns (pattern_hash, pattern_text, occurrences,
                    stuck_count, resolved_count, last_seen, avg_resolution_time)
                VALUES (?, ?, 1, ?, ?, ?, ?)
                """,
                params: [
                    .text(hash),
                    .text(text),
                    .int(ledToStuck ? 1 : 0),
                    .int(ledToStuck ? 0 : 1),
                    .double(Date().timeIntervalSince1970),
                    resolutionTime.map { .double($0) } ?? .null,
                ]
            )
        }
    }

    /// Look up an error pattern by hash. Returns (stuck_count, resolved_count, occurrences).
    public func lookupErrorPattern(hash: String) throws -> ErrorPatternRecord? {
        return try db.queryOne(
            "SELECT pattern_hash, pattern_text, occurrences, stuck_count, resolved_count, avg_resolution_time FROM error_patterns WHERE pattern_hash = ?",
            params: [.text(hash)]
        ) { row in
            ErrorPatternRecord(
                hash: row.text(0) ?? "",
                text: row.text(1) ?? "",
                occurrences: row.int(2),
                stuckCount: row.int(3),
                resolvedCount: row.int(4),
                avgResolutionTime: row.optionalDouble(5)
            )
        }
    }

    // MARK: - Workflow Sequences

    /// Record or update a workflow sequence observation.
    public func recordWorkflowSequence(projectPath: String?, triggerKind: String,
                                       triggerContext: String?, followKind: String,
                                       followContext: String?) throws {
        let updated = try db.execute(
            """
            UPDATE workflow_sequences SET
                count = count + 1,
                last_seen = ?
            WHERE project_path IS ? AND trigger_kind = ? AND trigger_context IS ?
                AND follow_kind = ? AND follow_context IS ?
            """,
            params: [
                .double(Date().timeIntervalSince1970),
                projectPath.map { .text($0) } ?? .null,
                .text(triggerKind),
                triggerContext.map { .text($0) } ?? .null,
                .text(followKind),
                followContext.map { .text($0) } ?? .null,
            ]
        )

        if updated == 0 {
            try db.execute(
                """
                INSERT INTO workflow_sequences
                    (project_path, trigger_kind, trigger_context, follow_kind, follow_context, count, total_trigger_count, last_seen)
                VALUES (?, ?, ?, ?, ?, 1, 1, ?)
                """,
                params: [
                    projectPath.map { .text($0) } ?? .null,
                    .text(triggerKind),
                    triggerContext.map { .text($0) } ?? .null,
                    .text(followKind),
                    followContext.map { .text($0) } ?? .null,
                    .double(Date().timeIntervalSince1970),
                ]
            )
        }
    }

    /// Increment the trigger count for a given trigger (used to compute probability).
    public func incrementTriggerCount(projectPath: String?, triggerKind: String,
                                      triggerContext: String?) throws {
        try db.execute(
            """
            UPDATE workflow_sequences SET total_trigger_count = total_trigger_count + 1
            WHERE project_path IS ? AND trigger_kind = ? AND trigger_context IS ?
            """,
            params: [
                projectPath.map { .text($0) } ?? .null,
                .text(triggerKind),
                triggerContext.map { .text($0) } ?? .null,
            ]
        )
    }

    /// Find workflow suggestions for a given trigger.
    public func lookupWorkflowSuggestions(projectPath: String?, triggerKind: String,
                                          triggerContext: String?,
                                          minCount: Int = 5) throws -> [WorkflowSuggestion] {
        return try db.query(
            """
            SELECT follow_kind, follow_context, count, total_trigger_count
            FROM workflow_sequences
            WHERE project_path IS ? AND trigger_kind = ? AND trigger_context IS ?
                AND count >= ?
            ORDER BY CAST(count AS REAL) / total_trigger_count DESC
            """,
            params: [
                projectPath.map { .text($0) } ?? .null,
                .text(triggerKind),
                triggerContext.map { .text($0) } ?? .null,
                .int(minCount),
            ]
        ) { row in
            let count = row.int(2)
            let total = max(row.int(3), 1)
            return WorkflowSuggestion(
                followKind: row.text(0) ?? "",
                followContext: row.optionalText(1),
                count: count,
                probability: Double(count) / Double(total)
            )
        }
    }

    // MARK: - Cleanup

    /// Delete events older than the specified number of days.
    public func cleanupEvents(olderThanDays: Int) throws {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86400)
        try db.execute(
            "DELETE FROM events WHERE timestamp < ?",
            params: [.double(cutoff.timeIntervalSince1970)]
        )
        try db.execute(
            "DELETE FROM cost_history WHERE timestamp < ?",
            params: [.double(cutoff.timeIntervalSince1970)]
        )
    }

    /// Delete completed sessions older than the specified number of days.
    public func cleanupSessions(olderThanDays: Int) throws {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86400)
        try db.execute(
            "DELETE FROM sessions WHERE ended_at IS NOT NULL AND ended_at < ?",
            params: [.double(cutoff.timeIntervalSince1970)]
        )
    }

    /// Run full cleanup with default retention.
    public func cleanup(eventRetentionDays: Int = 90, sessionRetentionDays: Int = 365) throws {
        try cleanupEvents(olderThanDays: eventRetentionDays)
        try cleanupSessions(olderThanDays: sessionRetentionDays)
    }
}

// MARK: - Persisted Event

/// A persisted event loaded from the database.
public struct PersistedEvent {
    public let id: Int
    public let sessionId: String
    public let timestamp: Date
    public let kind: String
    public let data: String?
}

/// A recorded error pattern with stuck/resolved statistics.
public struct ErrorPatternRecord {
    public let hash: String
    public let text: String
    public let occurrences: Int
    public let stuckCount: Int
    public let resolvedCount: Int
    public let avgResolutionTime: TimeInterval?

    /// Probability that this error pattern leads to a stuck loop.
    public var stuckProbability: Double {
        let total = stuckCount + resolvedCount
        guard total > 0 else { return 0 }
        return Double(stuckCount) / Double(total)
    }
}

/// A workflow suggestion mined from historical sequences.
public struct WorkflowSuggestion {
    public let followKind: String
    public let followContext: String?
    public let count: Int
    public let probability: Double
}

// MARK: - ActivityEvent.EventKind JSON serialization

extension ActivityEvent.EventKind {
    /// Serialize the event-specific data as a JSON string for storage.
    var jsonData: String {
        var dict: [String: Any] = [:]
        switch self {
        case .taskStarted:
            break
        case .taskCompleted(let duration):
            dict["duration"] = duration
        case .fileRead(let path):
            dict["path"] = path
        case .fileWrite(let path, let added, let removed):
            dict["path"] = path
            if let a = added { dict["added"] = a }
            if let r = removed { dict["removed"] = r }
        case .commandRun(let command):
            dict["command"] = command
        case .commandCompleted(let cmd, let exitCode, let duration):
            if let c = cmd { dict["command"] = c }
            if let e = exitCode { dict["exitCode"] = e }
            dict["duration"] = duration
        case .error(let message):
            dict["message"] = message
        case .modelChanged(let model):
            dict["model"] = model
        case .stateChanged(let from, let to):
            dict["from"] = from.rawValue
            dict["to"] = to.rawValue
        case .subagentStarted(let name, let desc):
            dict["name"] = name
            dict["description"] = desc
        case .subagentCompleted(let name, let duration):
            dict["name"] = name
            dict["duration"] = duration
        }
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
