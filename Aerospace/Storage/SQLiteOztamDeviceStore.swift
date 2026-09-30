//
//  SQLiteOztamDeviceStore.swift
//  Aerospace
//
//  Thread-safe SQLite persistence for the Oztam Log tool's saved tail targets.
//  Only the device list is persisted; tailed events are transient and live in
//  memory for the session. `SQLiteError` is defined in SQLiteLogStore.swift
//  and reused as-is.
//

import Foundation
import SQLite3

private nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated final class SQLiteOztamDeviceStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.networkten.aerospace.oztam.sqlite")

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
        CREATE TABLE IF NOT EXISTS oztam_devices (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            value TEXT NOT NULL,
            is_selected INTEGER NOT NULL,
            created_at REAL NOT NULL
        );
        """)
    }

    // MARK: - Writes

    /// Inserts a device, or overwrites it when the id already exists.
    func upsert(_ device: OztamDevice) throws {
        try queue.sync {
            let stmt = try prepare("""
            INSERT OR REPLACE INTO oztam_devices
            (id, name, kind, value, is_selected, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, device.id.uuidString)
            bindText(stmt, 2, device.name)
            bindText(stmt, 3, device.kind.rawValue)
            bindText(stmt, 4, device.value)
            sqlite3_bind_int(stmt, 5, device.isSelected ? 1 : 0)
            sqlite3_bind_double(stmt, 6, device.createdAt.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SQLiteError.step(lastMessage())
            }
        }
    }

    func delete(id: UUID) throws {
        try queue.sync {
            let stmt = try prepare("DELETE FROM oztam_devices WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SQLiteError.step(lastMessage())
            }
        }
    }

    func deleteAll() {
        try? queue.sync { try exec("DELETE FROM oztam_devices;") }
    }

    // MARK: - Reads

    /// All saved devices, oldest first, so the list stays stable as new ones
    /// are appended.
    func fetchAll() -> [OztamDevice] {
        (try? queue.sync {
            let stmt = try prepare("""
            SELECT id, name, kind, value, is_selected, created_at
            FROM oztam_devices ORDER BY created_at ASC;
            """)
            defer { sqlite3_finalize(stmt) }
            var results: [OztamDevice] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let device = row(from: stmt) { results.append(device) }
            }
            return results
        }) ?? []
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

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private func row(from stmt: OpaquePointer?) -> OztamDevice? {
        guard let id = UUID(uuidString: columnText(stmt, 0)),
              let kind = OztamDeviceKind(rawValue: columnText(stmt, 2))
        else { return nil }
        return OztamDevice(
            id: id,
            name: columnText(stmt, 1),
            kind: kind,
            value: columnText(stmt, 3),
            isSelected: sqlite3_column_int(stmt, 4) != 0,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        )
    }

    private func lastMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
