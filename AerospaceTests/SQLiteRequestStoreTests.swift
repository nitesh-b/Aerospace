//
//  SQLiteRequestStoreTests.swift
//  AerospaceTests
//

import XCTest
import SQLite3
@testable import Aerospace

final class SavedRequestCodableTests: XCTestCase {
    func testRoundTrip() throws {
        let original = SavedRequest(
            name: "Login", method: .post, urlString: "https://api/x",
            queryParams: [KeyValueItem(key: "a", value: "1", isEnabled: false)],
            headers: [KeyValueItem(key: "H", value: "v")],
            authKind: .bearer, bearerToken: "tok",
            bodyKind: .json, bodyText: "{}"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedRequest.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.queryParams.first?.isEnabled, false)
        XCTAssertEqual(decoded.queryParams.first?.id, original.queryParams.first?.id)
    }

    func testFolderFieldsRoundTripAndDefault() throws {
        // Default values when omitted.
        let plain = SavedRequest(name: "X")
        XCTAssertNil(plain.folderID)
        XCTAssertEqual(plain.sortIndex, 0)

        // Explicit values survive a Codable round-trip.
        let folder = UUID()
        let original = SavedRequest(name: "Y", folderID: folder, sortIndex: 7)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedRequest.self, from: data)
        XCTAssertEqual(decoded.folderID, folder)
        XCTAssertEqual(decoded.sortIndex, 7)
    }
}

final class SQLiteRequestStoreTests: XCTestCase {

    private func makeStore() throws -> SQLiteRequestStore {
        let path = NSTemporaryDirectory() + "aerospace-req-\(UUID().uuidString).sqlite"
        return try SQLiteRequestStore(path: path)
    }

    private func request(_ name: String, at offset: TimeInterval = 0) -> SavedRequest {
        SavedRequest(name: name, urlString: "https://example.com/\(name)",
                     createdAt: Date(timeIntervalSince1970: 1_000_000 + offset),
                     updatedAt: Date(timeIntervalSince1970: 1_000_000 + offset))
    }

    func testInsertAndFetchAll() throws {
        let store = try makeStore()
        XCTAssertTrue(store.fetchAll().isEmpty)
        try store.upsert(request("A"))
        try store.upsert(request("B"))
        XCTAssertEqual(store.fetchAll().count, 2)
    }

    func testFetchAllOrderedByUpdatedDesc() throws {
        let store = try makeStore()
        try store.upsert(request("old", at: 0))
        try store.upsert(request("new", at: 100))
        XCTAssertEqual(store.fetchAll().first?.name, "new")
        XCTAssertEqual(store.fetchAll().last?.name, "old")
    }

    func testUpsertUpdatesNotDuplicates() throws {
        let store = try makeStore()
        var r = request("A")
        try store.upsert(r)
        r.name = "A2"
        try store.upsert(r)
        let all = store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "A2")
    }

    func testJSONColumnsPersist() throws {
        let store = try makeStore()
        var r = request("R")
        r.headers = [KeyValueItem(key: "Content-Type", value: "application/json")]
        r.queryParams = [KeyValueItem(key: "limit", value: "100", isEnabled: false)]
        try store.upsert(r)
        let fetched = try XCTUnwrap(store.fetch(id: r.id))
        XCTAssertEqual(fetched.headers.first?.key, "Content-Type")
        XCTAssertEqual(fetched.queryParams.first?.isEnabled, false)
        XCTAssertEqual(fetched.headers.first?.id, r.headers.first?.id)
    }

    func testN10FieldsPersist() throws {
        let store = try makeStore()
        var r = request("Signed")
        r.n10SigningEnabled = true
        r.n10AppVersion = "3.4.1"
        r.n10SystemName = "iPadOS"
        r.n10SystemVersion = "17.2"
        try store.upsert(r)
        let fetched = try XCTUnwrap(store.fetch(id: r.id))
        XCTAssertTrue(fetched.n10SigningEnabled)
        XCTAssertEqual(fetched.n10AppVersion, "3.4.1")
        XCTAssertEqual(fetched.n10SystemName, "iPadOS")
        XCTAssertEqual(fetched.n10SystemVersion, "17.2")
    }

    func testFetchByID() throws {
        let store = try makeStore()
        let r = request("A")
        try store.upsert(r)
        XCTAssertEqual(store.fetch(id: r.id)?.name, "A")
        XCTAssertNil(store.fetch(id: UUID()))
    }

    func testDelete() throws {
        let store = try makeStore()
        let r = request("A")
        try store.upsert(r)
        XCTAssertEqual(store.delete(id: r.id), 1)
        XCTAssertEqual(store.fetchAll().count, 0)
        XCTAssertEqual(store.delete(id: r.id), 0)
    }

    func testDuplicateProducesIndependentCopy() throws {
        let store = try makeStore()
        var r = request("A")
        r.headers = [KeyValueItem(key: "H", value: "v")]
        try store.upsert(r)

        let copy = r.duplicated()
        try store.upsert(copy)

        XCTAssertNotEqual(copy.id, r.id)
        XCTAssertEqual(copy.name, "A copy")
        XCTAssertNotEqual(copy.headers.first?.id, r.headers.first?.id) // fresh row identity
        XCTAssertEqual(copy.headers.first?.key, "H")
        XCTAssertEqual(store.fetchAll().count, 2)
    }

    func testCorruptJSONColumnFallsBackToEmpty() throws {
        // Write a row with deliberately invalid JSON in the headers column,
        // then confirm the row mapper doesn't crash and yields [].
        let path = NSTemporaryDirectory() + "aerospace-req-corrupt-\(UUID().uuidString).sqlite"
        let store = try SQLiteRequestStore(path: path)
        let r = request("A")
        try store.upsert(r)
        // Corrupt via a second raw connection.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let sql = "UPDATE api_requests SET headers_json = 'not json' WHERE id = '\(r.id.uuidString)';"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let fetched = try XCTUnwrap(store.fetch(id: r.id))
        XCTAssertEqual(fetched.headers, [])
    }
}

final class SQLiteFolderStoreTests: XCTestCase {

    private func makeStore() throws -> SQLiteRequestStore {
        let path = NSTemporaryDirectory() + "aerospace-fold-\(UUID().uuidString).sqlite"
        return try SQLiteRequestStore(path: path)
    }

    func testFolderInsertFetchDelete() throws {
        let store = try makeStore()
        XCTAssertTrue(store.fetchAllFolders().isEmpty)
        let f = RequestFolder(name: "Auth", sortIndex: 1)
        try store.upsertFolder(f)
        XCTAssertEqual(store.fetchAllFolders().map(\.name), ["Auth"])
        XCTAssertEqual(store.deleteFolder(id: f.id), 1)
        XCTAssertTrue(store.fetchAllFolders().isEmpty)
    }

    func testFoldersOrderedBySortIndex() throws {
        let store = try makeStore()
        try store.upsertFolder(RequestFolder(name: "B", sortIndex: 2))
        try store.upsertFolder(RequestFolder(name: "A", sortIndex: 1))
        XCTAssertEqual(store.fetchAllFolders().map(\.name), ["A", "B"])
    }

    func testRequestFolderAndSortPersist() throws {
        let store = try makeStore()
        let folderID = UUID()
        var r = SavedRequest(name: "R", urlString: "https://x")
        r.folderID = folderID
        r.sortIndex = 5
        try store.upsert(r)
        let fetched = try XCTUnwrap(store.fetch(id: r.id))
        XCTAssertEqual(fetched.folderID, folderID)
        XCTAssertEqual(fetched.sortIndex, 5)
    }

    func testRootRequestHasNilFolder() throws {
        let store = try makeStore()
        let r = SavedRequest(name: "Root", urlString: "https://x")
        try store.upsert(r)
        XCTAssertNil(try XCTUnwrap(store.fetch(id: r.id)).folderID)
    }
}
