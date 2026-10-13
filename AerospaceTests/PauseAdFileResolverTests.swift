//
//  PauseAdFileResolverTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class PauseAdFileResolverTests: XCTestCase {

    private var base: URL!
    private var root: URL { base.appendingPathComponent("youi.ads", isDirectory: true) }
    private let resolver = PauseAdFileResolver()
    private let manifest = "ads/sales/2026/brand/10Oct/pause/p-1/v1/manifests/RemoteManifest"

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PauseAdFileResolverTests-\(UUID().uuidString)", isDirectory: true)
        try write("\(manifest)/metadata.json", "{}")
        try write("\(manifest)/data.json", "{}")
        try write("\(manifest)/images/My Image.png", "png")
        try write("\(manifest)/assets/layout/tv/X_main.layout", "bin")
        try write("\(manifest)/.DS_Store", "x")
        try write("ads/sales/2026/brand/10Oct/pause/p-1/v1/.server-123/data.json", "{}")
        try write("parameters.js", "secret")
        try write("src/index.ts", "code")
        try write("deployments/sales/x.zip", "zip")
        try write("../outside.txt", "outside")
        resolver.setRoot(root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func resolve(_ path: String) -> PauseAdFileResolver.Resolution {
        resolver.resolve(requestPath: path)
    }

    private func assertFile(_ path: String, mime: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .file(let url, let mimeType) = resolve(path) else {
            return XCTFail("expected file for \(path), got \(resolve(path))", file: file, line: line)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), file: file, line: line)
        XCTAssertEqual(mimeType, mime, file: file, line: line)
    }

    // MARK: - Serving

    func testServesMetadataLottieAndImages() {
        assertFile("/files/\(manifest)/metadata.json", mime: "application/json")
        assertFile("/files/\(manifest)/data.json", mime: "application/json")
        assertFile("/files/\(manifest)/images/My%20Image.png", mime: "image/png")
        assertFile("/files/\(manifest)/assets/layout/tv/X_main.layout", mime: "application/octet-stream")
    }

    func testQueryStringAndFragmentAreIgnored() {
        assertFile("/files/\(manifest)/metadata.json?cachebust=123", mime: "application/json")
        assertFile("/files/\(manifest)/metadata.json#x", mime: "application/json")
    }

    func testDuplicateSlashesAreTolerated() {
        assertFile("/files//\(manifest)//data.json", mime: "application/json")
    }

    func testMimeTypes() {
        XCTAssertEqual(PauseAdFileResolver.mimeType(forExtension: "JPG"), "image/jpeg")
        XCTAssertEqual(PauseAdFileResolver.mimeType(forExtension: "jpeg"), "image/jpeg")
        XCTAssertEqual(PauseAdFileResolver.mimeType(forExtension: "js"), "application/javascript")
        XCTAssertEqual(PauseAdFileResolver.mimeType(forExtension: "zip"), "application/zip")
        XCTAssertEqual(PauseAdFileResolver.mimeType(forExtension: "webp"), "image/webp")
        XCTAssertEqual(PauseAdFileResolver.mimeType(forExtension: "timeline"), "application/octet-stream")
    }

    // MARK: - Not served

    func testOnlyAdsSubtreeIsServed() {
        XCTAssertEqual(resolve("/files/parameters.js"), .notFound)
        XCTAssertEqual(resolve("/files/src/index.ts"), .notFound)
        XCTAssertEqual(resolve("/files/deployments/sales/x.zip"), .notFound)
    }

    func testHiddenFilesAndStagingFoldersAreNotServed() {
        XCTAssertEqual(resolve("/files/\(manifest)/.DS_Store"), .notFound)
        XCTAssertEqual(resolve("/files/ads/sales/2026/brand/10Oct/pause/p-1/v1/.server-123/data.json"), .notFound)
    }

    func testDirectoriesAreNotListed() {
        XCTAssertEqual(resolve("/files/\(manifest)"), .notFound)
        XCTAssertEqual(resolve("/files/\(manifest)/"), .notFound)
    }

    func testMissingFileIsNotFound() {
        XCTAssertEqual(resolve("/files/\(manifest)/nope.json"), .notFound)
    }

    func testTraversalIsForbidden() {
        for path in [
            "/files/ads/../parameters.js",
            "/files/ads/%2e%2e/parameters.js",
            "/files/ads/%2E%2E/%2E%2E/outside.txt",
            "/files/ads/sales/..%2F..%2Fparameters.js",
            "/files/ads/..\\parameters.js",
        ] {
            XCTAssertEqual(resolve(path), .forbidden, path)
        }
    }

    func testEncodedNullAndBadEncodingAreForbidden() {
        XCTAssertEqual(resolve("/files/ads/a%00.json"), .forbidden)
        XCTAssertEqual(resolve("/files/ads/%E0%A4%A.json"), .forbidden)
    }

    func testSymlinkEscapingRootIsForbidden() throws {
        let link = root.appendingPathComponent("ads/escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base.appendingPathComponent("outside.txt"))
        XCTAssertEqual(resolve("/files/ads/escape.txt"), .forbidden)
    }

    func testSymlinkInsideRootIsServed() throws {
        let link = root.appendingPathComponent("ads/alias.json")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appendingPathComponent("\(manifest)/data.json"))
        assertFile("/files/ads/alias.json", mime: "application/json")
    }

    func testNonFilesPathsAreNotMatched() {
        XCTAssertNil(PauseAdFileResolver.relativePath(fromRequestPath: "/log"))
        XCTAssertNil(PauseAdFileResolver.relativePath(fromRequestPath: "/filesx/ads/a"))
        XCTAssertNil(PauseAdFileResolver.relativePath(fromRequestPath: "/files"))
        XCTAssertTrue(PauseAdFileResolver.handles(requestPath: "/files/ads/a.json"))
        XCTAssertFalse(PauseAdFileResolver.handles(requestPath: "/health"))
    }

    // MARK: - Root lifecycle

    func testNoRootConfigured() {
        let empty = PauseAdFileResolver()
        XCTAssertEqual(empty.resolve(requestPath: "/files/\(manifest)/data.json"), .noRoot)
    }

    func testRootCanBeChangedAndCleared() throws {
        let other = base.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("ads"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: other.appendingPathComponent("ads/only-here.json"))

        resolver.setRoot(other)
        assertFile("/files/ads/only-here.json", mime: "application/json")
        XCTAssertEqual(resolve("/files/\(manifest)/data.json"), .notFound)

        resolver.setRoot(nil)
        XCTAssertNil(resolver.root)
        XCTAssertEqual(resolve("/files/ads/only-here.json"), .noRoot)
    }

    func testConcurrentAccessIsSafe() {
        DispatchQueue.concurrentPerform(iterations: 500) { i in
            if i % 10 == 0 { resolver.setRoot(root) }
            _ = resolver.resolve(requestPath: "/files/\(manifest)/data.json")
        }
    }
}
