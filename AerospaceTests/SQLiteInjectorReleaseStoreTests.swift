//
//  SQLiteInjectorReleaseStoreTests.swift
//  AerospaceTests
//

import XCTest
import SQLite3
@testable import Aerospace

final class SQLiteInjectorReleaseStoreTests: XCTestCase {

    private func makeStore() throws -> SQLiteInjectorReleaseStore {
        let path = NSTemporaryDirectory() + "aerospace-injector-test-\(UUID().uuidString).sqlite"
        return try SQLiteInjectorReleaseStore(path: path)
    }

    private func release(id: String = UUID().uuidString, app: String = "myapp",
                        platform: String = "ios", channel: String = "staging",
                        version: String = "1", min: String = "1.0.0", max: String = "1.x",
                        createdAt: Date = Date()) -> InjectorRelease {
        InjectorRelease(id: id, app: app, platform: platform, channel: channel, version: version,
                        minNativeVersion: min, maxNativeVersion: max, bundleHash: "hash-\(id)",
                        bundlePath: "/tmp/\(id).bundle", createdAt: createdAt)
    }

    func testInsertAndFetchAll() throws {
        let store = try makeStore()
        try store.insert(release(id: "a"))
        try store.insert(release(id: "b"))
        XCTAssertEqual(store.fetchAll().count, 2)
    }

    func testFetchAllOrdersNewestFirst() throws {
        let store = try makeStore()
        try store.insert(release(id: "old", createdAt: Date(timeIntervalSince1970: 0)))
        try store.insert(release(id: "new", createdAt: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(store.fetchAll().first?.id, "new")
        XCTAssertEqual(store.fetchAll().last?.id, "old")
    }

    func testReleasesFiltersByAppPlatformChannel() throws {
        let store = try makeStore()
        try store.insert(release(id: "match", app: "myapp", platform: "ios", channel: "staging"))
        try store.insert(release(id: "other-app", app: "otherapp", platform: "ios", channel: "staging"))
        try store.insert(release(id: "other-platform", app: "myapp", platform: "android", channel: "staging"))
        try store.insert(release(id: "other-channel", app: "myapp", platform: "ios", channel: "prod"))

        let result = store.releases(app: "myapp", platform: "ios", channel: "staging")
        XCTAssertEqual(result.map(\.id), ["match"])
    }

    func testLatestCompatibleReleaseRespectsNativeVersionRange() throws {
        let store = try makeStore()
        try store.insert(release(id: "too-old", min: "1.0.0", max: "1.x",
                                 createdAt: Date(timeIntervalSince1970: 0)))
        try store.insert(release(id: "compatible", min: "2.0.0", max: "2.x",
                                 createdAt: Date(timeIntervalSince1970: 1_000)))

        let result = store.latestCompatibleRelease(app: "myapp", platform: "ios", channel: "staging",
                                                   nativeVersion: "2.5.0")
        XCTAssertEqual(result?.id, "compatible")
    }

    func testLatestCompatibleReleaseReturnsNilWhenNoneMatch() throws {
        let store = try makeStore()
        try store.insert(release(id: "a", min: "1.0.0", max: "1.x"))

        let result = store.latestCompatibleRelease(app: "myapp", platform: "ios", channel: "staging",
                                                   nativeVersion: "9.0.0")
        XCTAssertNil(result)
    }

    func testReleaseByIdReturnsNilWhenMissing() throws {
        let store = try makeStore()
        XCTAssertNil(store.release(id: "does-not-exist"))
    }

    func testReleaseByIdReturnsMatch() throws {
        let store = try makeStore()
        try store.insert(release(id: "findme"))
        XCTAssertEqual(store.release(id: "findme")?.id, "findme")
    }

    func testFilesRoundTrip() throws {
        let store = try makeStore()
        var withFiles = release(id: "f")
        withFiles.files = [InjectorReleaseFile(path: "main.jsbundle", sha256: "aa"),
                           InjectorReleaseFile(path: "assets/x.png", sha256: "bb")]
        try store.insert(withFiles)
        XCTAssertEqual(store.release(id: "f")?.files, withFiles.files)
    }

    func testMigratesDatabaseCreatedBeforeFileLists() throws {
        let path = NSTemporaryDirectory() + "aerospace-injector-legacy-\(UUID().uuidString).sqlite"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let legacy = """
        CREATE TABLE releases (id TEXT PRIMARY KEY, app TEXT NOT NULL, platform TEXT NOT NULL,
            channel TEXT NOT NULL, version TEXT NOT NULL, min_native_version TEXT NOT NULL,
            max_native_version TEXT NOT NULL, bundle_hash TEXT NOT NULL, bundle_path TEXT NOT NULL,
            created_at REAL NOT NULL);
        INSERT INTO releases VALUES ('old', 'myapp', 'ios', 'staging', '1', '1.0', '1.x', 'h', '/tmp/b', 0);
        """
        XCTAssertEqual(sqlite3_exec(db, legacy, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = try SQLiteInjectorReleaseStore(path: path)
        XCTAssertEqual(store.release(id: "old")?.files, [])
        try store.insert(release(id: "new"))
        XCTAssertEqual(store.fetchAll().count, 2)
    }
}
