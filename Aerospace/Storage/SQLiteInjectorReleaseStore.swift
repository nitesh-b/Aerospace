//
//  SQLiteInjectorReleaseStore.swift
//  Aerospace
//
//  Thread-safe SQLite persistence for Injector release metadata, built
//  directly on the system SQLite3 C library (no third-party dependencies).
//  Bundle binaries live as flat files on disk; only metadata is stored here.
//  `SQLiteError` is defined in SQLiteLogStore.swift and reused as-is.
//

import Foundation
import SQLite3

private nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated final class SQLiteInjectorReleaseStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.networkten.aerospace.injector.sqlite")

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
        CREATE TABLE IF NOT EXISTS releases (
            id TEXT PRIMARY KEY,
            app TEXT NOT NULL,
            platform TEXT NOT NULL,
            channel TEXT NOT NULL,
            version TEXT NOT NULL,
            min_native_version TEXT NOT NULL,
            max_native_version TEXT NOT NULL,
            bundle_hash TEXT NOT NULL,
            bundle_path TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)
        try exec("""
        CREATE INDEX IF NOT EXISTS idx_releases_target
        ON releases(app, platform, channel, created_at);
        """)
    }

    // MARK: - Writes

    func insert(_ release: InjectorRelease) throws {
        try queue.sync {
            let sql = """
            INSERT OR REPLACE INTO releases
            (id, app, platform, channel, version, min_native_version, max_native_version,
             bundle_hash, bundle_path, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, release.id)
            bindText(stmt, 2, release.app)
            bindText(stmt, 3, release.platform)
            bindText(stmt, 4, release.channel)
            bindText(stmt, 5, release.version)
            bindText(stmt, 6, release.minNativeVersion)
            bindText(stmt, 7, release.maxNativeVersion)
            bindText(stmt, 8, release.bundleHash)
            bindText(stmt, 9, release.bundlePath)
            sqlite3_bind_double(stmt, 10, release.createdAt.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SQLiteError.step(lastMessage())
            }
        }
    }

    // MARK: - Reads

    private static let selectColumns = """
    id, app, platform, channel, version, min_native_version, max_native_version,
    bundle_hash, bundle_path, created_at
    """

    func fetchAll() -> [InjectorRelease] {
        (try? queue.sync {
            let stmt = try prepare("SELECT \(Self.selectColumns) FROM releases ORDER BY created_at DESC;")
            defer { sqlite3_finalize(stmt) }
            var results: [InjectorRelease] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(row(from: stmt))
            }
            return results
        }) ?? []
    }

    /// All releases targeting `app + platform + channel`, newest first.
    func releases(app: String, platform: String, channel: String) -> [InjectorRelease] {
        (try? queue.sync {
            let stmt = try prepare("""
            SELECT \(Self.selectColumns) FROM releases
            WHERE app = ? AND platform = ? AND channel = ?
            ORDER BY created_at DESC;
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, app)
            bindText(stmt, 2, platform)
            bindText(stmt, 3, channel)
            var results: [InjectorRelease] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(row(from: stmt))
            }
            return results
        }) ?? []
    }

    /// The newest release targeting `app + platform + channel` whose native
    /// version range covers `nativeVersion`, or nil if none match.
    func latestCompatibleRelease(app: String, platform: String, channel: String,
                                 nativeVersion: String) -> InjectorRelease? {
        releases(app: app, platform: platform, channel: channel)
            .first { $0.isCompatible(withNativeVersion: nativeVersion) }
    }

    func release(id: String) -> InjectorRelease? {
        try? queue.sync {
            let stmt = try prepare("SELECT \(Self.selectColumns) FROM releases WHERE id = ? LIMIT 1;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return row(from: stmt)
        } ?? nil
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

    private func row(from stmt: OpaquePointer?) -> InjectorRelease {
        InjectorRelease(
            id: columnText(stmt, 0),
            app: columnText(stmt, 1),
            platform: columnText(stmt, 2),
            channel: columnText(stmt, 3),
            version: columnText(stmt, 4),
            minNativeVersion: columnText(stmt, 5),
            maxNativeVersion: columnText(stmt, 6),
            bundleHash: columnText(stmt, 7),
            bundlePath: columnText(stmt, 8),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        )
    }

    private func lastMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
