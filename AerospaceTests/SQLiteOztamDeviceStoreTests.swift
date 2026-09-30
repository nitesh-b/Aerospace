//
//  SQLiteOztamDeviceStoreTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class SQLiteOztamDeviceStoreTests: XCTestCase {

    private func makeStore() throws -> SQLiteOztamDeviceStore {
        try SQLiteOztamDeviceStore(path: ":memory:")
    }

    func testUpsertAndFetchRoundTripsEveryField() throws {
        let store = try makeStore()
        let device = OztamDevice(name: "Lounge", kind: .oztamDeviceId, value: "oz-1",
                                 isSelected: false)
        try store.upsert(device)

        let fetched = try XCTUnwrap(store.fetchAll().first)
        XCTAssertEqual(fetched.id, device.id)
        XCTAssertEqual(fetched.name, "Lounge")
        XCTAssertEqual(fetched.kind, .oztamDeviceId)
        XCTAssertEqual(fetched.value, "oz-1")
        XCTAssertFalse(fetched.isSelected)
        XCTAssertEqual(fetched.createdAt.timeIntervalSince1970,
                       device.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testUpsertReplacesExistingDevice() throws {
        let store = try makeStore()
        var device = OztamDevice(name: "Lounge", kind: .ipAddress, value: "1.2.3.4")
        try store.upsert(device)

        device.name = "Bedroom"
        device.isSelected = false
        try store.upsert(device)

        let all = store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Bedroom")
        XCTAssertEqual(all.first?.isSelected, false)
    }

    func testFetchAllIsOrderedOldestFirst() throws {
        let store = try makeStore()
        let older = OztamDevice(name: "Older", kind: .deviceId, value: "a",
                                createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = OztamDevice(name: "Newer", kind: .deviceId, value: "b",
                                createdAt: Date(timeIntervalSince1970: 2_000))
        try store.upsert(newer)
        try store.upsert(older)
        XCTAssertEqual(store.fetchAll().map(\.name), ["Older", "Newer"])
    }

    func testDeleteRemovesOnlyTheNamedDevice() throws {
        let store = try makeStore()
        let keep = OztamDevice(name: "Keep", kind: .deviceId, value: "a")
        let drop = OztamDevice(name: "Drop", kind: .deviceId, value: "b")
        try store.upsert(keep)
        try store.upsert(drop)

        try store.delete(id: drop.id)
        XCTAssertEqual(store.fetchAll().map(\.name), ["Keep"])
    }

    func testDeleteAllEmptiesTheTable() throws {
        let store = try makeStore()
        try store.upsert(OztamDevice(name: "A", kind: .deviceId, value: "a"))
        try store.upsert(OztamDevice(name: "B", kind: .sessionId, value: "b"))
        store.deleteAll()
        XCTAssertTrue(store.fetchAll().isEmpty)
    }

    func testFetchAllOnEmptyStoreReturnsEmpty() throws {
        XCTAssertTrue(try makeStore().fetchAll().isEmpty)
    }
}
