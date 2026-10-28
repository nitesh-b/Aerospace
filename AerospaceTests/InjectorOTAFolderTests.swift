//
//  InjectorOTAFolderTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class InjectorOTAFolderTests: XCTestCase {

    private var root: URL!
    private var folder: InjectorOTAFolder!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ota-test-\(UUID().uuidString)", isDirectory: true)
        let release = root.appendingPathComponent("myapp/ios/staging/r1", isDirectory: true)
        try FileManager.default.createDirectory(at: release.appendingPathComponent("assets"),
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("myapp/ios/staging/manifest.json"))
        try Data("bundle".utf8).write(to: release.appendingPathComponent("main.jsbundle"))
        try Data([1]).write(to: release.appendingPathComponent("assets/logo@2x.png"))
        try Data("secret".utf8).write(to: release.appendingPathComponent(".hidden"))
        folder = InjectorOTAFolder(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func resolvedFile(_ path: String) -> String? {
        if case .file(let url, _) = folder.resolve(requestPath: path) { return url.lastPathComponent }
        return nil
    }

    func testResolvesManifestAsJSON() {
        guard case .file(let url, let mime) = folder.resolve(requestPath: "/ota/myapp/ios/staging/manifest.json")
        else { return XCTFail("manifest not served") }
        XCTAssertEqual(url.lastPathComponent, "manifest.json")
        XCTAssertEqual(mime, "application/json")
    }

    func testResolvesPercentEncodedReleaseFilesAndIgnoresQuery() {
        XCTAssertEqual(resolvedFile("/ota/myapp/ios/staging/r1/main.jsbundle?_=123"), "main.jsbundle")
        XCTAssertEqual(resolvedFile("/ota/myapp/ios/staging/r1/assets/logo%402x.png"), "logo@2x.png")
    }

    func testRejectsTraversalAndHiddenFiles() {
        XCTAssertEqual(folder.resolve(requestPath: "/ota/myapp/../myapp/ios/staging/manifest.json"), .forbidden)
        XCTAssertEqual(folder.resolve(requestPath: "/ota/myapp/ios/staging/r1/%2E%2E/manifest.json"), .forbidden)
        XCTAssertEqual(folder.resolve(requestPath: "/ota/myapp/ios/staging/r1/.hidden"), .notFound)
    }

    func testDirectoriesAndMissingFilesAreNotFound() {
        XCTAssertEqual(folder.resolve(requestPath: "/ota/myapp/ios/staging/r1"), .notFound)
        XCTAssertEqual(folder.resolve(requestPath: "/ota/"), .notFound)
        XCTAssertEqual(folder.resolve(requestPath: "/ota/myapp/ios/prod/manifest.json"), .notFound)
    }

    func testListFilesSkipsHiddenFilesAndHashesContents() throws {
        let files = try InjectorOTAFolder.listFiles(in: root.appendingPathComponent("myapp/ios/staging/r1"))
        XCTAssertEqual(files.map(\.path), ["assets/logo@2x.png", "main.jsbundle"])
        XCTAssertEqual(files.last?.sha256, InjectorOTAFolder.sha256Hex(Data("bundle".utf8)))
    }

    func testValidPathComponents() {
        for valid in ["myapp", "my-app_2", "v1.2", "ios"] {
            XCTAssertTrue(InjectorOTAFolder.isValidPathComponent(valid), valid)
        }
        for invalid in ["", ".", "..", ".hidden", "a/b", "my app", "ä", "a%2F"] {
            XCTAssertFalse(InjectorOTAFolder.isValidPathComponent(invalid), invalid)
        }
    }

    func testManifestSkipsReleasesWithoutFileListsAndSortsNewestFirst() {
        func release(_ id: String, at seconds: TimeInterval, files: [InjectorReleaseFile]) -> InjectorRelease {
            InjectorRelease(id: id, app: "myapp", platform: "ios", channel: "staging", version: id,
                            minNativeVersion: "1.0", maxNativeVersion: "1.x", bundleHash: "h",
                            bundlePath: "/x/\(id)/main.jsbundle", createdAt: Date(timeIntervalSince1970: seconds),
                            files: files)
        }
        let file = [InjectorReleaseFile(path: "main.jsbundle", sha256: "h")]
        let manifest = InjectorOTAFolder.manifest(
            for: [release("old", at: 1, files: file), release("legacy", at: 5, files: []),
                  release("new", at: 9, files: file)],
            app: "myapp", platform: "ios", channel: "staging")
        XCTAssertEqual(manifest.releases.map(\.id), ["new", "old"])
        XCTAssertEqual(manifest.releases.first?.bundle, "main.jsbundle")
    }
}
