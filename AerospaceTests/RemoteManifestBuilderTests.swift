//
//  RemoteManifestBuilderTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class RemoteManifestBuilderTests: XCTestCase {

    private var root: URL!
    private var server: URL { root.appendingPathComponent("v1/server", isDirectory: true) }
    private var bundle: URL { root.appendingPathComponent("v1/manifests/RemoteManifest", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteManifestBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ text: String = "x", in base: URL? = nil) throws {
        let url = (base ?? server).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: bundle.appendingPathComponent(relative).path)
    }

    private func makeHandOff() throws {
        try write("Brand.aep", "aep")
        try write("data.json", "{}")
        try write("images/b.png", "b")
        try write("images/a.jpg", "a")
        try write("assets/drawable/default/a.jpg", "a")
        try write("assets/layout/tv/Brand_main.layout", "layout")
        try write("assets/layout/tv/Brand_main.timeline", "timeline")
        try write("assets/layout/tv/Brand_main.timeline.log", "log")
        try write("assets/layout/tv/Brand_main.layout.log", "log")
    }

    // MARK: - Catalog

    func testCatalogMirrorsTreeExcludingLogAndAep() throws {
        try makeHandOff()
        let catalog = try RemoteManifestBuilder.catalog(of: server)
        typealias E = RemoteManifestBuilder.Entry
        XCTAssertEqual(catalog, [
            E(name: "assets", children: [
                E(name: "drawable", children: [
                    E(name: "default", children: [E(name: "a.jpg")]),
                ]),
                E(name: "layout", children: [
                    E(name: "tv", children: [E(name: "Brand_main.layout"), E(name: "Brand_main.timeline")]),
                ]),
            ]),
            E(name: "data.json"),
            E(name: "images", children: [E(name: "a.jpg"), E(name: "b.png")]),
        ])
    }

    func testDefaultIgnoresAndDotFilesAreSkipped() throws {
        try write("data.json")
        try write(".DS_Store")
        try write("._data.json")
        try write(".gitkeep")
        try write("__MACOSX/._data.json")
        try write(".git/HEAD")
        let names = try RemoteManifestBuilder.catalog(of: server).map(\.name)
        XCTAssertEqual(names, ["data.json"])
    }

    func testExcludedExtensionsAreCaseInsensitive() throws {
        try write("data.json")
        try write("Brand.AEP")
        try write("export.LOG")
        XCTAssertEqual(try RemoteManifestBuilder.catalog(of: server).map(\.name), ["data.json"])
    }

    func testEmptyDirectoriesAreListedWithEmptyChildren() throws {
        // Ruby keeps a folder whose only contents were excluded.
        try write("Adobe After Effects Auto-Save/Brand auto-save 1.aep")
        XCTAssertEqual(try RemoteManifestBuilder.catalog(of: server),
                       [.init(name: "Adobe After Effects Auto-Save", children: [])])
    }

    func testCustomExclusions() throws {
        try write("data.json")
        try write("notes.txt")
        try write("logo/a.png")
        try write("keep/logo.png")
        let options = RemoteManifestBuilder.Options(excludedExtensions: [".txt"], excludedNames: ["logo"])
        let catalog = try RemoteManifestBuilder.catalog(of: server, options: options)
        XCTAssertEqual(catalog, [.init(name: "data.json"), .init(name: "keep", children: [])],
                       "excludedNames match the base name without extension, like Ruby")
    }

    func testCatalogOfMissingDirectoryThrows() {
        XCTAssertThrowsError(try RemoteManifestBuilder.catalog(of: root.appendingPathComponent("nope")))
    }

    // MARK: - JSON (byte-compatible with Ruby JSON.pretty_generate)

    func testManifestJSONMatchesRubyPrettyGenerate() {
        let catalog: [RemoteManifestBuilder.Entry] = [
            .init(name: "assets", children: [.init(name: "empty", children: [])]),
            .init(name: "data.json"),
        ]
        let expected = """
        {
          "manifest_version": "1.0.0",
          "minimum_engine_version": "4.6.0",
          "maximum_engine_version": "999.999.999",
          "asset_catalog": [
            {
              "name": "assets",
              "children": [
                {
                  "name": "empty",
                  "children": []
                }
              ]
            },
            {
              "name": "data.json"
            }
          ]
        }

        """
        XCTAssertEqual(String(decoding: RemoteManifestBuilder.manifestJSON(catalog: catalog), as: UTF8.self), expected)
    }

    func testManifestJSONEmptyCatalog() {
        let text = String(decoding: RemoteManifestBuilder.manifestJSON(catalog: []), as: UTF8.self)
        XCTAssertTrue(text.contains("\"asset_catalog\": []\n}"), text)
    }

    func testManifestJSONEscapesLikeRuby() {
        let text = String(decoding: RemoteManifestBuilder.manifestJSON(
            catalog: [.init(name: "é \"q\" / \\ tab\t")]), as: UTF8.self)
        XCTAssertTrue(text.contains(#""name": "é \"q\" / \\ tab\t""#), text)
    }

    func testManifestJSONCustomVersion() {
        let text = String(decoding: RemoteManifestBuilder.manifestJSON(catalog: [], version: "2.0.0"), as: UTF8.self)
        XCTAssertTrue(text.contains(#""manifest_version": "2.0.0""#))
    }

    // MARK: - Build

    func testBuildCopiesFilesAndWritesManifest() throws {
        try makeHandOff()
        let result = try RemoteManifestBuilder.build(serverDirectory: server)

        XCTAssertEqual(result.bundleURL.standardizedFileURL, bundle.standardizedFileURL)
        XCTAssertEqual(result.manifestURL.lastPathComponent, "RemoteManifest.json")
        XCTAssertTrue(exists("data.json"))
        XCTAssertTrue(exists("images/a.jpg"))
        XCTAssertTrue(exists("assets/layout/tv/Brand_main.timeline"))
        XCTAssertFalse(exists("Brand.aep"))
        XCTAssertFalse(exists("assets/layout/tv/Brand_main.timeline.log"))
        XCTAssertEqual(try String(contentsOf: bundle.appendingPathComponent("images/a.jpg"), encoding: .utf8), "a")
        XCTAssertEqual(result.fileCount, 6)
        XCTAssertEqual(result.totalBytes, 2 + 1 + 1 + 1 + 6 + 8)

        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: result.manifestURL)) as? [String: Any])
        XCTAssertEqual((manifest["asset_catalog"] as? [[String: Any]])?.count, 3)
    }

    func testRebuildReplacesPreviousBundle() throws {
        try makeHandOff()
        try RemoteManifestBuilder.build(serverDirectory: server)
        try write("stale.png", "s", in: bundle)
        try FileManager.default.removeItem(at: server.appendingPathComponent("images/b.png"))

        try RemoteManifestBuilder.build(serverDirectory: server)
        XCTAssertFalse(exists("stale.png"))
        XCTAssertFalse(exists("images/b.png"))
        XCTAssertTrue(exists("images/a.jpg"))
    }

    func testBuildLeavesSiblingsOfBundleAlone() throws {
        try makeHandOff()
        try write("Other/keep.txt", "k", in: root.appendingPathComponent("v1/manifests"))
        try write("metadata.json", "{}", in: root.appendingPathComponent("v1"))
        try RemoteManifestBuilder.build(serverDirectory: server)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("v1/manifests/Other/keep.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("v1/metadata.json").path))
    }

    func testBuildFromMissingServerThrowsAndKeepsExistingBundle() throws {
        try makeHandOff()
        try RemoteManifestBuilder.build(serverDirectory: server)
        try FileManager.default.removeItem(at: server)
        XCTAssertThrowsError(try RemoteManifestBuilder.build(serverDirectory: server))
        XCTAssertTrue(exists("data.json"))
    }

    func testBuildLeavesNoTemporaryFolders() throws {
        try makeHandOff()
        try RemoteManifestBuilder.build(serverDirectory: server)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("v1/manifests").path)
        XCTAssertEqual(names, ["RemoteManifest"])
    }

    func testCustomFileName() throws {
        try write("data.json")
        let result = try RemoteManifestBuilder.build(
            serverDirectory: server, options: .init(fileName: "Custom"))
        XCTAssertEqual(result.bundleURL.lastPathComponent, "Custom")
        XCTAssertEqual(result.manifestURL.lastPathComponent, "Custom.json")
    }
}
