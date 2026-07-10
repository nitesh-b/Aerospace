//
//  SQLiteInjectorReleaseStoreTests.swift
//  AerospaceTests
//

import XCTest
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
}
