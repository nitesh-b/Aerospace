//
//  SQLiteLogStoreTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class SQLiteLogStoreTests: XCTestCase {

    private func makeStore() throws -> SQLiteLogStore {
        // Unique temp-file DB per test (WAL is unsupported on :memory:).
        let path = NSTemporaryDirectory() + "aerospace-test-\(UUID().uuidString).sqlite"
        return try SQLiteLogStore(path: path)
    }

    private func event(_ category: String, _ sub: String, level: LogLevel = .info,
                       at offset: TimeInterval = 0, payload: String = "{}") -> LogEvent {
        LogEvent(timestamp: Date(timeIntervalSince1970: 1_000_000 + offset),
                 category: category, subCategory: sub, payload: payload, level: level)
    }

    func testInsertAndCount() throws {
        let store = try makeStore()
        XCTAssertEqual(store.count(), 0)
        try store.insert(event("Auth", "Login"))
        try store.insert(event("Auth", "Logout"))
        XCTAssertEqual(store.count(), 2)
    }

    func testFetchReturnsNewestFirst() throws {
        let store = try makeStore()
        try store.insert(event("A", "1", at: 0))
        try store.insert(event("A", "2", at: 100))
        let all = store.fetch()
        XCTAssertEqual(all.first?.subCategory, "2")
        XCTAssertEqual(all.last?.subCategory, "1")
    }

    func testFilterByCategory() throws {
        let store = try makeStore()
        try store.insertBatch([event("Auth", "Login"), event("API", "Request")])
        let result = store.fetch(LogQuery(category: "Auth"))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.category, "Auth")
    }

    func testFilterBySubCategory() throws {
        let store = try makeStore()
        try store.insertBatch([event("Auth", "Login"), event("Auth", "Logout")])
        let result = store.fetch(LogQuery(category: "Auth", subCategory: "Logout"))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.subCategory, "Logout")
    }

    func testFilterByMinLevel() throws {
        let store = try makeStore()
        try store.insertBatch([
            event("A", "1", level: .debug),
            event("A", "2", level: .warning),
            event("A", "3", level: .error),
            event("A", "4", level: .critical),
        ])
        let result = store.fetch(LogQuery(minLevel: .error))
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.level >= .error })
    }

    func testSearchAcrossPayload() throws {
        let store = try makeStore()
        try store.insertBatch([
            event("A", "1", payload: "{\"token\":\"xyz\"}"),
            event("A", "2", payload: "{\"status\":\"ok\"}"),
        ])
        let result = store.fetch(LogQuery(searchText: "xyz"))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.subCategory, "1")
    }

    func testDeleteOlderThan() throws {
        let store = try makeStore()
        try store.insert(event("A", "old", at: 0))
        try store.insert(event("A", "new", at: 10_000))
        let cutoff = Date(timeIntervalSince1970: 1_000_000 + 5_000)
        let removed = store.deleteOlderThan(cutoff)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(store.fetch().first?.subCategory, "new")
    }

    func testDeleteAll() throws {
        let store = try makeStore()
        try store.insertBatch([event("A", "1"), event("A", "2")])
        XCTAssertEqual(store.deleteAll(), 2)
        XCTAssertEqual(store.count(), 0)
    }

    func testCategoriesOrderedByFrequency() throws {
        let store = try makeStore()
        try store.insertBatch([
            event("API", "1"), event("API", "2"), event("API", "3"),
            event("Auth", "1"),
        ])
        XCTAssertEqual(store.categories(), ["API", "Auth"])
    }

    func testInsertOrReplacePreservesIdentity() throws {
        let store = try makeStore()
        let id = UUID()
        let a = LogEvent(id: id, category: "A", subCategory: "1", payload: "{}")
        try store.insert(a)
        try store.insert(a) // same id
        XCTAssertEqual(store.count(), 1)
    }

    func testRoundTripFidelity() throws {
        let store = try makeStore()
        let original = LogEvent(category: "Payments", subCategory: "Refund",
                                payload: "{\"amount\":50}", level: .warning,
                                sessionId: "s1", application: "POS", component: "Checkout screen")
        try store.insert(original)
        let fetched = try XCTUnwrap(store.fetch().first)
        XCTAssertEqual(fetched.category, original.category)
        XCTAssertEqual(fetched.subCategory, original.subCategory)
        XCTAssertEqual(fetched.payload, original.payload)
        XCTAssertEqual(fetched.level, original.level)
        XCTAssertEqual(fetched.sessionId, original.sessionId)
        XCTAssertEqual(fetched.application, original.application)
        XCTAssertEqual(fetched.component, original.component)
        XCTAssertEqual(fetched.id, original.id)
    }

    func testSearchMatchesComponentColumn() throws {
        let store = try makeStore()
        // Component supplied out-of-band (not in the payload string), so only
        // the dedicated column can match it.
        try store.insertBatch([
            LogEvent(category: "UI", subCategory: "Tap", payload: "{}", component: "Home screen"),
            LogEvent(category: "UI", subCategory: "Tap", payload: "{}", component: "Settings screen"),
        ])
        let result = store.fetch(LogQuery(searchText: "Home"))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.component, "Home screen")
    }
}
