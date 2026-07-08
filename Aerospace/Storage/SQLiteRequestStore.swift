//
//  SQLiteRequestStore.swift
//  Aerospace
//
//  Thread-safe SQLite persistence for saved API requests, mirroring
//  SQLiteLogStore. Headers and query parameters are stored as JSON-encoded TEXT
//  columns: a request is always read and written as a whole, so relational
//  sub-tables would add joins without benefit. Reuses the module-visible
//  `SQLiteError` defined in SQLiteLogStore.swift.
//

import Foundation
import SQLite3

/// Tells SQLite to copy bound text rather than retain the Swift String pointer.
private nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated final class SQLiteRequestStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.networkten.aerospace.sqlite.requests")

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
        CREATE TABLE IF NOT EXISTS api_requests (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            method TEXT NOT NULL,
            url TEXT NOT NULL,
            query_json TEXT NOT NULL DEFAULT '[]',
            headers_json TEXT NOT NULL DEFAULT '[]',
            auth_kind TEXT NOT NULL DEFAULT 'none',
            bearer_token TEXT NOT NULL DEFAULT '',
            body_kind TEXT NOT NULL DEFAULT 'none',
            body_text TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_api_requests_updated ON api_requests(updated_at);")
        migrate()
    }

    /// Additive migrations for databases created by earlier versions.
    private func migrate() {
        let additions: [String] = []
        for statement in additions {
            _ = sqlite3_exec(db, statement, nil, nil, nil)
        }
    }

    // MARK: - Writes

    func upsert(_ request: SavedRequest) throws {
        try queue.sync {
            try exec("BEGIN TRANSACTION;")
            do {
                let sql = """
                INSERT OR REPLACE INTO api_requests
                (id, name, method, url, query_json, headers_json, auth_kind,
                 bearer_token, body_kind, body_text, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
                let stmt = try prepare(sql)
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, 1, request.id.uuidString)
                bindText(stmt, 2, request.name)
                bindText(stmt, 3, request.method.rawValue)
                bindText(stmt, 4, request.urlString)
                bindText(stmt, 5, Self.encode(request.queryParams))
                bindText(stmt, 6, Self.encode(request.headers))
                bindText(stmt, 7, request.authKind.rawValue)
                bindText(stmt, 8, request.bearerToken)
                bindText(stmt, 9, request.bodyKind.rawValue)
                bindText(stmt, 10, request.bodyText)
                sqlite3_bind_double(stmt, 11, request.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 12, request.updatedAt.timeIntervalSince1970)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw SQLiteError.step(lastMessage())
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: - Reads

    func fetchAll() -> [SavedRequest] {
        (try? queue.sync {
            let stmt = try prepare("SELECT \(Self.columns) FROM api_requests ORDER BY updated_at DESC;")
            defer { sqlite3_finalize(stmt) }
            var results: [SavedRequest] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(row(from: stmt))
            }
            return results
        }) ?? []
    }

    func fetch(id: UUID) -> SavedRequest? {
        try? queue.sync {
            let stmt = try prepare("SELECT \(Self.columns) FROM api_requests WHERE id = ? LIMIT 1;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            return sqlite3_step(stmt) == SQLITE_ROW ? row(from: stmt) : nil
        }
    }

    @discardableResult
    func delete(id: UUID) -> Int {
        (try? queue.sync {
            let stmt = try prepare("DELETE FROM api_requests WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteError.step(lastMessage()) }
            return Int(sqlite3_changes(db))
        }) ?? 0
    }

    // MARK: - JSON column coding

    private static func encode(_ items: [KeyValueItem]) -> String {
        guard let data = try? JSONEncoder().encode(items),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    private static func decode(_ json: String?) -> [KeyValueItem] {
        guard let json, let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([KeyValueItem].self, from: data) else { return [] }
        return items
    }

    // MARK: - Row mapping

    private static let columns =
        "id, name, method, url, query_json, headers_json, auth_kind, bearer_token, body_kind, body_text, created_at, updated_at"

    private func row(from stmt: OpaquePointer?) -> SavedRequest {
        let id = UUID(uuidString: columnText(stmt, 0) ?? "") ?? UUID()
        let name = columnText(stmt, 1) ?? "Request"
        let method = HTTPMethod(rawValue: columnText(stmt, 2) ?? "GET") ?? .get
        let url = columnText(stmt, 3) ?? ""
        let query = Self.decode(columnText(stmt, 4))
        let headers = Self.decode(columnText(stmt, 5))
        let auth = AuthKind(rawValue: columnText(stmt, 6) ?? "none") ?? .none
        let bearer = columnText(stmt, 7) ?? ""
        let bodyKind = BodyKind(rawValue: columnText(stmt, 8) ?? "none") ?? .none
        let bodyText = columnText(stmt, 9) ?? ""
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        return SavedRequest(
            id: id, name: name, method: method, urlString: url,
            queryParams: query, headers: headers, authKind: auth, bearerToken: bearer,
            bodyKind: bodyKind, bodyText: bodyText, createdAt: createdAt, updatedAt: updatedAt
        )
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

    private func lastMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
