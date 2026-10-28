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
        let otaDir = base.appendingPathComponent("ota", isDirectory: true)
        let sqliteStore = try SQLiteInjectorReleaseStore(path: dbPath)
        let defaults = UserDefaults(suiteName: "InjectorStoreTests-\(UUID().uuidString)")!
        return InjectorStore(store: sqliteStore, otaDirectory: otaDir, defaults: defaults)
    }

    private func readManifest(_ store: InjectorStore, app: String = "myapp", platform: String = "ios",
                              channel: String = "staging") throws -> InjectorManifest {
        let url = store.otaFolder.channelDirectory(app: app, platform: platform, channel: channel)
            .appendingPathComponent(InjectorOTAFolder.manifestFileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InjectorManifest.self, from: Data(contentsOf: url))
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

    @MainActor
    func testPublishLaysOutReleaseInOTAFolderAndWritesManifest() throws {
        let store = try makeStore()
        let content = "console.log('v1')"
        let bundleURL = try writeTestBundle(content: content)

        XCTAssertTrue(store.publish(bundleURL: bundleURL, app: "myapp", platform: "ios", channel: "staging",
                                    version: "1", minNativeVersion: "1.0.0", maxNativeVersion: "1.x"))

        let release = try XCTUnwrap(store.releases.first)
        let releaseDir = store.otaFolder.releaseDirectory(app: "myapp", platform: "ios", channel: "staging",
                                                          releaseId: release.id)
        XCTAssertEqual(URL(fileURLWithPath: release.bundlePath).deletingLastPathComponent().standardizedFileURL,
                       releaseDir.standardizedFileURL)

        let manifest = try readManifest(store)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.releases.map(\.id), [release.id])
        let entry = try XCTUnwrap(manifest.releases.first)
        XCTAssertEqual(entry.bundle, release.bundleFileName)
        XCTAssertEqual(entry.files, [InjectorReleaseFile(path: release.bundleFileName,
                                                         sha256: release.bundleHash)])
        XCTAssertEqual(entry.minNativeVersion, "1.0.0")
        XCTAssertEqual(entry.maxNativeVersion, "1.x")
    }

    @MainActor
    func testManifestListsNewestReleaseFirst() throws {
        let store = try makeStore()
        XCTAssertTrue(store.publish(bundleURL: try writeTestBundle(content: "a"), app: "myapp", platform: "ios",
                                    channel: "staging", version: "1", minNativeVersion: "1.0.0",
                                    maxNativeVersion: "1.x"))
        XCTAssertTrue(store.publish(bundleURL: try writeTestBundle(content: "b"), app: "myapp", platform: "ios",
                                    channel: "staging", version: "2", minNativeVersion: "1.0.0",
                                    maxNativeVersion: "1.x"))

        XCTAssertEqual(try readManifest(store).releases.map(\.version), ["2", "1"])
    }

    @MainActor
    func testPublishCopiesAssetsAlongsideTheBundle() throws {
        let store = try makeStore()
        let assets = FileManager.default.temporaryDirectory
            .appendingPathComponent("assets-\(UUID().uuidString)", isDirectory: true)
        let image = assets.appendingPathComponent("assets/src/img/logo@2x.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: image)
        try "hidden".write(to: assets.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        let bundleURL = try writeTestBundle(content: "fresh")
        let bundleName = bundleURL.lastPathComponent
        // The bundler often writes the bundle into the assets folder too; the picked bundle wins.
        try "stale".write(to: assets.appendingPathComponent(bundleName), atomically: true, encoding: .utf8)

        XCTAssertTrue(store.publish(bundleURL: bundleURL, assetsURL: assets, app: "myapp", platform: "ios",
                                    channel: "staging", version: "1", minNativeVersion: "1.0.0",
                                    maxNativeVersion: "1.x"))

        let entry = try XCTUnwrap(try readManifest(store).releases.first)
        XCTAssertEqual(entry.files.map(\.path), ["assets/src/img/logo@2x.png", bundleName].sorted())
        XCTAssertEqual(entry.files.first { $0.path == "assets/src/img/logo@2x.png" }?.sha256,
                       InjectorOTAFolder.sha256Hex(Data([1, 2, 3])))
        XCTAssertEqual(entry.files.first { $0.path == bundleName }?.sha256,
                       InjectorOTAFolder.sha256Hex(Data("fresh".utf8)))
    }

    @MainActor
    func testPublishRejectsUnsafeIdentifiers() throws {
        let store = try makeStore()
        for (app, channel) in [("my app", "staging"), ("../escape", "staging"), ("myapp", "a/b"), ("myapp", "")] {
            XCTAssertFalse(store.publish(bundleURL: try writeTestBundle(), app: app, platform: "ios",
                                         channel: channel, version: "1", minNativeVersion: "1.0.0",
                                         maxNativeVersion: "1.x"), "\(app)/\(channel)")
        }
        XCTAssertEqual(store.releases.count, 0)
    }
}
