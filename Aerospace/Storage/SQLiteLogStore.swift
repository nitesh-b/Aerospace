//
//  SQLiteLogStore.swift
//  Aerospace
//
//  Thread-safe SQLite persistence for log events, built directly on the
//  system SQLite3 C library (no third-party dependencies).
//

import Foundation
import SQLite3

/// Bind helper: tells SQLite to copy the bound text/blob (as opposed to
/// keeping the pointer alive, which would be unsafe for Swift Strings).
private nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated enum SQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): return "Failed to open database: \(m)"
        case .prepare(let m): return "Failed to prepare statement: \(m)"
        case .step(let m): return "Failed to execute statement: \(m)"
        }
    }
}

/// Filter criteria for querying stored logs.
nonisolated struct LogQuery: Sendable, Equatable {
    var category: String?
    var subCategory: String?
    var minLevel: LogLevel?
    var searchText: String?
    var limit: Int = 5_000

    static let recent = LogQuery()
}

nonisolated final class SQLiteLogStore: @unchecked Sendable {
    private var db: OpaquePointer?
    /// Serializes all access to the connection.
    private let queue = DispatchQueue(label: "com.networkten.aerospace.sqlite")

    /// Open (or create) a database at `path`. Pass ":memory:" for an
    /// in-memory database (used by tests).
    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteError.open(message)
        }
        db = handle
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA busy_timeout = 3000;")
        try createSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func createSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS logs (
            id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            category TEXT NOT NULL,
            subcategory TEXT NOT NULL,
            payload TEXT NOT NULL,
            level TEXT NOT NULL DEFAULT 'info',
            session_id TEXT,
            application TEXT
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON logs(timestamp);")
        try exec("CREATE INDEX IF NOT EXISTS idx_logs_category ON logs(category, subcategory);")
    }

    // MARK: - Writes

    func insert(_ event: LogEvent) throws {
        try insertBatch([event])
    }

    func insertBatch(_ events: [LogEvent]) throws {
        guard !events.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN TRANSACTION;")
            do {
                let sql = """
                INSERT OR REPLACE INTO logs
                (id, timestamp, category, subcategory, payload, level, session_id, application)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """
                let stmt = try prepare(sql)
                defer { sqlite3_finalize(stmt) }
                for event in events {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    bindText(stmt, 1, event.id.uuidString)
                    sqlite3_bind_double(stmt, 2, event.timestamp.timeIntervalSince1970)
                    bindText(stmt, 3, event.category)
                    bindText(stmt, 4, event.subCategory)
                    bindText(stmt, 5, event.payload)
                    bindText(stmt, 6, event.level.rawValue)
                    bindText(stmt, 7, event.sessionId)
                    bindText(stmt, 8, event.application)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw SQLiteError.step(lastMessage())
                    }
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: - Reads

    func fetch(_ query: LogQuery = .recent) -> [LogEvent] {
        (try? queue.sync {
            var conditions: [String] = []
            // Each binder captures its concrete 1-based parameter index.
            var binders: [(OpaquePointer?) -> Void] = []
            func addParam(_ value: String) {
                let index = Int32(binders.count + 1)
                binders.append { self.bindText($0, index, value) }
            }

            if let category = query.category {
                conditions.append("category = ?")
                addParam(category)
            }
            if let subCategory = query.subCategory {
                conditions.append("subcategory = ?")
                addParam(subCategory)
            }
            if let minLevel = query.minLevel {
                // Restrict to levels at or above the threshold.
                let allowed = LogLevel.allCases.filter { $0 >= minLevel }.map { "'\($0.rawValue)'" }
                if !allowed.isEmpty {
                    conditions.append("level IN (\(allowed.joined(separator: ",")))")
                }
            }
            if let search = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !search.isEmpty {
                conditions.append("(payload LIKE ? OR category LIKE ? OR subcategory LIKE ?)")
                let pattern = "%\(search)%"
                addParam(pattern)
                addParam(pattern)
                addParam(pattern)
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
            SELECT id, timestamp, category, subcategory, payload, level, session_id, application
            FROM logs \(whereClause)
            ORDER BY timestamp DESC
            LIMIT \(max(1, query.limit));
            """

            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            for binder in binders { binder(stmt) }

            var results: [LogEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(row(from: stmt))
            }
            return results
        }) ?? []
    }

    func count() -> Int {
        (try? queue.sync {
            let stmt = try prepare("SELECT COUNT(*) FROM logs;")
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }) ?? 0
    }

    /// Distinct categories, ordered by frequency then name.
    func categories() -> [String] {
        (try? queue.sync {
            let stmt = try prepare("""
            SELECT category FROM logs GROUP BY category ORDER BY COUNT(*) DESC, category ASC;
            """)
            defer { sqlite3_finalize(stmt) }
            var result: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(columnText(stmt, 0) ?? "")
            }
            return result
        }) ?? []
    }

    // MARK: - Deletes / retention

    @discardableResult
    func deleteAll() -> Int {
        (try? queue.sync {
            try exec("DELETE FROM logs;")
            return Int(sqlite3_changes(db))
        }) ?? 0
    }

    /// Delete events older than `date`. Returns the number of rows removed.
    @discardableResult
    func deleteOlderThan(_ date: Date) -> Int {
        (try? queue.sync {
            let stmt = try prepare("DELETE FROM logs WHERE timestamp < ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteError.step(lastMessage()) }
            return Int(sqlite3_changes(db))
        }) ?? 0
    }

    // MARK: - Low-level helpers

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.step(lastMessage())
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(lastMessage())
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func row(from stmt: OpaquePointer?) -> LogEvent {
        let id = UUID(uuidString: columnText(stmt, 0) ?? "") ?? UUID()
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let category = columnText(stmt, 2) ?? ""
        let subCategory = columnText(stmt, 3) ?? ""
        let payload = columnText(stmt, 4) ?? "{}"
        let level = LogLevel(rawValue: columnText(stmt, 5) ?? "info") ?? .info
        let sessionId = columnText(stmt, 6)
        let application = columnText(stmt, 7)
        return LogEvent(
            id: id, timestamp: timestamp, category: category, subCategory: subCategory,
            payload: payload, level: level, sessionId: sessionId, application: application
        )
    }

    private func lastMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
