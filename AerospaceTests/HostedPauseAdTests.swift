//
//  HostedPauseAdTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class HostedPauseAdTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostedPauseAdTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func host(_ versionPath: String, brand: String = "brand", modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent("\(versionPath)/manifests/RemoteManifest/metadata.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PauseAdMetadata(target: "T_main", lottieTarget: "data.json", duration: 4, adBrandName: brand)
            .jsonData().write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - Scan

    func testScanFindsEveryHostedVersionNewestFirst() throws {
        try host("ads/sales/2026/specsavers/09Sept/pause/p-1/v1", brand: "a", modified: Date(timeIntervalSince1970: 100))
        try host("ads/sales/2026/specsavers/09Sept/pause/p-1/v2", brand: "b", modified: Date(timeIntervalSince1970: 300))
        try host("ads/house/2025/show/01jan/pause/tenplay-9/v1", brand: "c", modified: Date(timeIntervalSince1970: 200))

        let ads = HostedPauseAd.scan(root: root)
        XCTAssertEqual(ads.map(\.metadata.adBrandName), ["b", "c", "a"])
        XCTAssertEqual(ads.first?.version, 2)
        XCTAssertEqual(ads.first?.job.ticket, "p-1")
        XCTAssertEqual(ads.first?.metadataPath,
                       "ads/sales/2026/specsavers/09Sept/pause/p-1/v2/manifests/RemoteManifest/metadata.json")
        XCTAssertEqual(ads.first?.id, ads.first?.metadataPath)
    }

    func testScanSkipsUngeneratedBrokenAndNonPauseFolders() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ads/sales/2026/x/10Oct/pause/p-2/v1/server"), withIntermediateDirectories: true)
        let broken = root.appendingPathComponent("ads/sales/2026/x/10Oct/pause/p-3/v1/manifests/RemoteManifest/metadata.json")
        try FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: broken)
        try host("ads/house/2021/show/one/v1")
        try host("ads/testads/2022/x/01jan/pause/p-4/v1")
        try host("ads/sales/2026/x/10Oct/pause/p-5/vx")

        XCTAssertEqual(HostedPauseAd.scan(root: root), [])
    }

    func testScanWithoutAdsFolderIsEmpty() {
        XCTAssertEqual(HostedPauseAd.scan(root: root.appendingPathComponent("nope")), [])
    }

    // MARK: - URLs

    private func ad(_ versionPath: String = "ads/sales/2026/specsavers/10Oct/pause/p-19583/v1") throws -> HostedPauseAd {
        try host(versionPath)
        return try XCTUnwrap(HostedPauseAd.scan(root: root).first)
    }

    func testURL() throws {
        XCTAssertEqual(try ad().url(host: "192.168.1.146", port: 57333),
                       "http://192.168.1.146:57333/files/ads/sales/2026/specsavers/10Oct/pause/p-19583/v1/manifests/RemoteManifest/metadata.json")
    }

    func testURLPercentEncodesPathComponents() throws {
        let spaced = try ad("ads/sales/2026/my brand/10Oct/pause/p-1/v1")
        XCTAssertEqual(spaced.url(host: "localhost", port: 57333),
                       "http://localhost:57333/files/ads/sales/2026/my%20brand/10Oct/pause/p-1/v1/manifests/RemoteManifest/metadata.json")
    }

    func testRotationSnippetMatchesParametersJS() throws {
        try host("ads/sales/2026/a/10Oct/pause/p-1/v1", modified: Date(timeIntervalSince1970: 200))
        try host("ads/house/2026/b/10Oct/pause/p-2/v3", modified: Date(timeIntervalSince1970: 100))
        let ads = HostedPauseAd.scan(root: root)

        XCTAssertEqual(HostedPauseAd.rotationSnippet(ads, host: "192.168.1.146", port: 57333), """
        export const pauseAdHost = 'http://192.168.1.146:57333/';
        export const pauseAdRotation = [
        \t`${pauseAdHost}files/ads/sales/2026/a/10Oct/pause/p-1/v1/manifests/RemoteManifest/metadata.json`,
        \t`${pauseAdHost}files/ads/house/2026/b/10Oct/pause/p-2/v3/manifests/RemoteManifest/metadata.json`,
        ];
        // Also required in devMenu: useLocalPauseAds: true
        """)
    }

    func testRotationSnippetEmpty() {
        XCTAssertTrue(HostedPauseAd.rotationSnippet([], host: "localhost", port: 57333)
            .contains("export const pauseAdRotation = [\n];"))
    }

    // MARK: - Host choice

    func testHostAddresses() {
        XCTAssertEqual(PauseAdHost.localhost.address(lan: "10.1.1.5"), "localhost")
        XCTAssertEqual(PauseAdHost.androidEmulator.address(lan: "10.1.1.5"), "10.0.2.2")
        XCTAssertEqual(PauseAdHost.lan.address(lan: "10.1.1.5"), "10.1.1.5")
        XCTAssertEqual(PauseAdHost.lan.address(lan: nil), "localhost", "no network: fall back")
    }
}
