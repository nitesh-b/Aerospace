//
//  PauseAdDeployerTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class PauseAdDeployerTests: XCTestCase {

    private var base: URL!
    private var source: URL { base.appendingPathComponent("handoff", isDirectory: true) }
    private var destination: URL { base.appendingPathComponent("youi.ads", isDirectory: true) }
    private let prefix = "Brand-2026-PremiumPause-Ad"
    private let v1 = "ads/sales/2026/brand/10Oct/pause/p-19583/v1"
    private let zipPath = "deployments/sales/2026/brand/10Oct/pause/p-19583/v1/Brand-2026-PremiumPause-Ad-dpm-2026-10-13.zip"

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }
    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9))! }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PauseAdDeployerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try write("\(prefix).aep", "aep", in: source)
        try write("data.json", #"{"fr":60,"assets":[],"markers":[{"tm":0,"cm":"Ad-In","dr":240}]}"#, in: source)
        try write("assets/layout/tv/\(prefix)_main.layout", "layout", in: source)
        try write("assets/layout/tv/\(prefix)_main.timeline", "timeline", in: source)
        try write("assets/drawable/default/logo.png", "png", in: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Helpers

    private func write(_ relative: String, _ text: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func job() throws -> PauseAdJob {
        try PauseAdJob.make(adType: .sales, folderName: "brand", jobCode: "19583", date: today, calendar: calendar)
    }

    private func metadata(brand: String = "Brand", campaign: String = "Spring", industry: String = "Retail") -> PauseAdMetadata {
        PauseAdMetadata(target: "\(prefix)_main", lottieTarget: "data.json", duration: 4,
                        adBrandName: brand, adCampaign: campaign, adIndustry: industry)
    }

    private func generate(_ m: PauseAdMetadata? = nil) throws {
        try PauseAdGenerator.generate(.init(source: source, destinationRoot: destination, job: job(), version: 1,
                                            mode: .create, metadata: m ?? metadata()))
    }

    private func deploy() throws -> PauseAdDeployer.Result {
        try PauseAdDeployer.deploy(.init(destinationRoot: destination, job: job(), version: 1,
                                         date: today, calendar: calendar))
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: destination.appendingPathComponent(relative).path)
    }

    // MARK: - Happy path

    func testDeployWritesZipWithRemoteManifestRoot() throws {
        try generate()
        let result = try deploy()

        XCTAssertEqual(result.relativePath, zipPath)
        XCTAssertTrue(exists(zipPath))
        XCTAssertEqual(result.entries, [
            "RemoteManifest/RemoteManifest.json",
            "RemoteManifest/assets/drawable/default/logo.png",
            "RemoteManifest/assets/layout/tv/\(prefix)_main.layout",
            "RemoteManifest/assets/layout/tv/\(prefix)_main.timeline",
            "RemoteManifest/data.json",
            "RemoteManifest/metadata.json",
        ])
        XCTAssertEqual(try PauseAdDeployer.zipEntries(of: result.zipURL).filter { !$0.hasSuffix("/") }.sorted(), result.entries)
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertEqual(result.metadata.adBrandName, "brand", "the shipped (normalized) metadata")
    }

    func testRedeploySameDayReplacesZipAndLeavesOtherDeploymentsAlone() throws {
        try write("deployments/house/2026/other/01Jan/pause/p-1/v1/Other-dpm-2026-01-01.zip", "keep", in: destination)
        try generate()
        _ = try deploy()
        let second = try deploy()
        XCTAssertTrue(exists(zipPath))
        XCTAssertTrue(exists("deployments/house/2026/other/01Jan/pause/p-1/v1/Other-dpm-2026-01-01.zip"))
        let names = try FileManager.default.contentsOfDirectory(atPath: second.zipURL.deletingLastPathComponent().path)
        XCTAssertEqual(names, [second.zipURL.lastPathComponent], "no staging leftovers")
    }

    // MARK: - Refusals

    func testNotGeneratedIsRefused() {
        XCTAssertThrowsError(try deploy()) {
            XCTAssertEqual($0 as? PauseAdDeployer.DeployError, .notGenerated)
        }
    }

    func testIncompleteMetadataIsRefused() throws {
        try generate(metadata(brand: "", campaign: " ", industry: "Retail"))
        XCTAssertThrowsError(try deploy()) {
            XCTAssertEqual($0 as? PauseAdDeployer.DeployError, .metadataIncomplete([.adBrandName, .adCampaign]))
        }
        XCTAssertFalse(exists("deployments"))
    }

    func testHandEditedMetadataAfterGenerateIsRefused() throws {
        try generate()
        var edited = metadata()
        edited.adCampaign = "Summer"
        try edited.jsonData().write(to: destination.appendingPathComponent("\(v1)/metadata.json"))
        XCTAssertThrowsError(try deploy()) {
            XCTAssertEqual($0 as? PauseAdDeployer.DeployError, .manifestOutOfDate)
        }
    }

    func testMissingLottieInBundleIsRefused() throws {
        try generate()
        try FileManager.default.removeItem(at: destination.appendingPathComponent("\(v1)/manifests/RemoteManifest/data.json"))
        XCTAssertThrowsError(try deploy()) {
            XCTAssertEqual($0 as? PauseAdDeployer.DeployError, .bundleIncomplete("data.json"))
        }
    }

    // MARK: - updateMetadata (fill brand fields after testing)

    func testUpdateMetadataThenDeploy() throws {
        try generate(metadata(brand: "", campaign: "", industry: ""))
        let manifestJSON = try Data(contentsOf: destination.appendingPathComponent("\(v1)/manifests/RemoteManifest/RemoteManifest.json"))

        try PauseAdGenerator.updateMetadata(metadata(brand: "Big-Brand", campaign: "Spring  Sale", industry: "Retail"),
                                            job: job(), version: 1, destinationRoot: destination)

        let raw = try PauseAdMetadata(jsonData: Data(contentsOf: destination.appendingPathComponent("\(v1)/metadata.json")))
        XCTAssertEqual(raw.adBrandName, "Big-Brand")
        let hosted = try PauseAdMetadata(jsonData: Data(contentsOf: destination.appendingPathComponent("\(v1)/manifests/RemoteManifest/metadata.json")))
        XCTAssertEqual(hosted.adBrandName, "bigbrand")
        XCTAssertEqual(hosted.adCampaign, "spring sale")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("\(v1)/manifests/RemoteManifest/RemoteManifest.json")),
                       manifestJSON, "assets untouched")

        XCTAssertNoThrow(try deploy())
    }

    func testUpdateMetadataRequiresGeneratedVersion() {
        XCTAssertThrowsError(try PauseAdGenerator.updateMetadata(metadata(), job: job(), version: 1,
                                                                 destinationRoot: destination)) {
            XCTAssertEqual($0 as? PauseAdGenerator.GenerateError, .notGenerated(1))
        }
    }

    func testUpdateMetadataValidatesDuration() throws {
        try generate()
        var m = metadata()
        m.duration = -1
        XCTAssertThrowsError(try PauseAdGenerator.updateMetadata(m, job: job(), version: 1, destinationRoot: destination)) {
            XCTAssertEqual($0 as? PauseAdGenerator.GenerateError, .invalidDuration)
        }
    }

    // MARK: - Zip entry validation

    func testUnexpectedEntriesAreDetected() {
        XCTAssertEqual(PauseAdDeployer.unexpectedEntries(in: [
            "RemoteManifest/data.json",
            "RemoteManifest/images/._bg.png",
            "__MACOSX/RemoteManifest/._data.json",
            "Other/data.json",
            "RemoteManifest/.DS_Store",
        ]), [
            "RemoteManifest/images/._bg.png",
            "__MACOSX/RemoteManifest/._data.json",
            "Other/data.json",
            "RemoteManifest/.DS_Store",
        ])
    }

    func testZipEntriesRejectsNonZip() throws {
        let junk = base.appendingPathComponent("junk.zip")
        try Data("not a zip".utf8).write(to: junk)
        XCTAssertThrowsError(try PauseAdDeployer.zipEntries(of: junk))
    }
}
