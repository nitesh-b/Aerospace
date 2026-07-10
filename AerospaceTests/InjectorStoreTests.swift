//
//  InjectorStoreTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class InjectorStoreTests: XCTestCase {

    @MainActor
    private func makeStore() throws -> InjectorStore {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("injector-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dbPath = base.appendingPathComponent("injector.sqlite").path
        let bundlesDir = base.appendingPathComponent("bundles", isDirectory: true)
        let sqliteStore = try SQLiteInjectorReleaseStore(path: dbPath)
        let defaults = UserDefaults(suiteName: "InjectorStoreTests-\(UUID().uuidString)")!
        return InjectorStore(store: sqliteStore, bundlesDirectory: bundlesDir, defaults: defaults)
    }

    private func writeTestBundle(named name: String = "main.jsbundle",
                                content: String = "console.log('hi')") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor
    func testPublishSucceedsAndAppearsInReleases() throws {
        let store = try makeStore()
        let bundleURL = try writeTestBundle()

        let ok = store.publish(bundleURL: bundleURL, app: "myapp", platform: "ios", channel: "staging",
                               version: "1", minNativeVersion: "1.0.0", maxNativeVersion: "1.x")

        XCTAssertTrue(ok)
        XCTAssertNil(store.publishError)
        XCTAssertEqual(store.releases.count, 1)
        XCTAssertEqual(store.releases.first?.app, "myapp")
    }

    @MainActor
    func testPublishRejectsInvertedNativeVersionRange() throws {
        let store = try makeStore()
        let bundleURL = try writeTestBundle()

        let ok = store.publish(bundleURL: bundleURL, app: "myapp", platform: "ios", channel: "staging",
                               version: "1", minNativeVersion: "2.0.0", maxNativeVersion: "1.0.0")

        XCTAssertFalse(ok)
        XCTAssertEqual(store.releases.count, 0)
        XCTAssertNotNil(store.publishError)
    }

    @MainActor
    func testPublishRejectsUnreadableBundleFile() throws {
        let store = try makeStore()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist.bundle")

        let ok = store.publish(bundleURL: missingURL, app: "myapp", platform: "ios", channel: "staging",
                               version: "1", minNativeVersion: "1.0.0", maxNativeVersion: "1.x")

        XCTAssertFalse(ok)
        XCTAssertNotNil(store.publishError)
    }

    @MainActor
    func testPublishedBundleContentIsCopiedByteForByte() throws {
        let store = try makeStore()
        let content = "console.log('exact bytes')"
        let bundleURL = try writeTestBundle(content: content)

        _ = store.publish(bundleURL: bundleURL, app: "myapp", platform: "ios", channel: "staging",
                          version: "1", minNativeVersion: "1.0.0", maxNativeVersion: "1.x")

        let stored = try XCTUnwrap(store.releases.first)
        let copied = try String(contentsOfFile: stored.bundlePath, encoding: .utf8)
        XCTAssertEqual(copied, content)
    }
}
