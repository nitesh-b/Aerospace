//
//  PauseAdGeneratorTests.swift
//  AerospaceTests
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Aerospace

final class PauseAdGeneratorTests: XCTestCase {

    private var base: URL!
    private var source: URL { base.appendingPathComponent("Brand-PremiumPause-Ad", isDirectory: true) }
    private var destination: URL { base.appendingPathComponent("youi.ads", isDirectory: true) }
    private let prefix = "Brand-2026-PremiumPause-Ad"

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PauseAdGeneratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try makeHandOff()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Fixtures

    private func write(_ relative: String, _ text: String = "x", in root: URL? = nil) throws {
        let url = (root ?? source).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func writePNG(_ relative: String, noisy: Bool) throws {
        let url = source.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = 32
        var pixels = [UInt8](repeating: 90, count: size * size * 4)
        if noisy {
            var seed: UInt32 = 7
            for i in pixels.indices {
                seed = seed &* 1_103_515_245 &+ 12345
                pixels[i] = UInt8(truncatingIfNeeded: seed >> 16)
            }
        }
        let image = try XCTUnwrap(pixels.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func makeHandOff() throws {
        try write("\(prefix).aep", "aep")
        try write("data.json", #"{"fr":60,"assets":[{"id":"bg","w":32,"h":32,"u":"images/","p":"bg.png","e":0}],"markers":[{"tm":0,"cm":"Ad-In","dr":232}]}"#)
        try writePNG("images/bg.png", noisy: true)
        try writePNG("assets/drawable/default/bg.png", noisy: false)
        try write("assets/layout/tv/\(prefix)_main.layout", "layout")
        try write("assets/layout/tv/\(prefix)_main.timeline", "timeline")
        try write("assets/layout/tv/\(prefix)_main.timeline.log", """
        markers {
          starttime: 2
          duration: 3.86666656
          name: "Ad-In"
        }
        """)
        try write(".DS_Store")
        try write("__MACOSX/._data.json")
        try write("Adobe After Effects Auto-Save/\(prefix) auto-save 1.aep")
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }

    private func job() throws -> PauseAdJob {
        try PauseAdJob.make(adType: .sales, folderName: "brand", jobCode: "P-19583",
                            date: calendar.date(from: DateComponents(year: 2026, month: 10, day: 13))!,
                            calendar: calendar)
    }

    private func metadata() -> PauseAdMetadata {
        PauseAdMetadata(loop: false, target: "\(prefix)_main", lottieTarget: "data.json", duration: 3.86666656,
                        adBrandName: "Big-Brand & Co", adCampaign: "Season  17", adIndustry: "Style and fashion")
    }

    private func request(version: Int = 1, mode: PauseAdGenerator.Mode = .create,
                         from customSource: URL? = nil, swaps: Bool = true,
                         metadata custom: PauseAdMetadata? = nil) throws -> PauseAdGenerator.Request {
        PauseAdGenerator.Request(source: customSource ?? source, destinationRoot: destination, job: try job(),
                                 version: version, mode: mode, metadata: custom ?? metadata(),
                                 applyImageSwaps: swaps)
    }

    private let v1 = "ads/sales/2026/brand/10Oct/pause/p-19583/v1"

    private func url(_ relative: String) -> URL { destination.appendingPathComponent(relative) }
    private func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }
    private func data(_ relative: String) throws -> Data { try Data(contentsOf: url(relative)) }

    // MARK: - Fresh generate

    func testGenerateBuildsYouiAdsTree() throws {
        let result = try PauseAdGenerator.generate(try request())

        XCTAssertEqual(result.version, 1)
        XCTAssertEqual(result.hostedMetadataPath, "\(v1)/manifests/RemoteManifest/metadata.json")
        XCTAssertEqual(result.versionURL.resolvingSymlinksInPath().path, url(v1).resolvingSymlinksInPath().path)

        // server/ = hand-off, minus macOS/AE noise, AEP kept
        XCTAssertTrue(exists("\(v1)/server/\(prefix).aep"))
        XCTAssertTrue(exists("\(v1)/server/data.json"))
        XCTAssertTrue(exists("\(v1)/server/assets/layout/tv/\(prefix)_main.timeline.log"))
        XCTAssertFalse(exists("\(v1)/server/.DS_Store"))
        XCTAssertFalse(exists("\(v1)/server/__MACOSX"))
        XCTAssertFalse(exists("\(v1)/server/Adobe After Effects Auto-Save"))

        // RemoteManifest/ = what the apps load
        let manifest = "\(v1)/manifests/RemoteManifest"
        XCTAssertTrue(exists("\(manifest)/data.json"))
        XCTAssertTrue(exists("\(manifest)/images/bg.png"))
        XCTAssertTrue(exists("\(manifest)/RemoteManifest.json"))
        XCTAssertFalse(exists("\(manifest)/\(prefix).aep"))
        XCTAssertFalse(exists("\(manifest)/assets/layout/tv/\(prefix)_main.timeline.log"))
    }

    func testMetadataWrittenRawAndNormalized() throws {
        try PauseAdGenerator.generate(try request())

        let raw = try PauseAdMetadata(jsonData: data("\(v1)/metadata.json"))
        XCTAssertEqual(raw, metadata())

        let hosted = try PauseAdMetadata(jsonData: data("\(v1)/manifests/RemoteManifest/metadata.json"))
        XCTAssertEqual(hosted.adBrandName, "bigbrand co")
        XCTAssertEqual(hosted.adCampaign, "season 17")
        XCTAssertEqual(hosted.adIndustry, "style and fashion")
        XCTAssertEqual(hosted.target, "\(prefix)_main")
    }

    func testRemoteManifestJSONDoesNotListMetadata() throws {
        // As in youi.ads: metadata.json is copied in after the manifest is generated.
        try PauseAdGenerator.generate(try request())
        let text = String(decoding: try data("\(v1)/manifests/RemoteManifest/RemoteManifest.json"), as: UTF8.self)
        XCTAssertFalse(text.contains("metadata.json"))
        XCTAssertTrue(text.contains("\"data.json\""))
    }

    func testGenerateWithEmptyBrandFieldsIsAllowed() throws {
        var m = metadata()
        m.adBrandName = ""
        m.adCampaign = ""
        m.adIndustry = ""
        XCTAssertNoThrow(try PauseAdGenerator.generate(try request(metadata: m)))
    }

    // MARK: - Image swaps

    func testImageSwapAppliedToDestinationOnly() throws {
        let sourceLottie = try Data(contentsOf: source.appendingPathComponent("images/bg.png"))
        let youi = try Data(contentsOf: source.appendingPathComponent("assets/drawable/default/bg.png"))

        let result = try PauseAdGenerator.generate(try request())

        XCTAssertEqual(result.appliedSwaps.map(\.name), ["bg.png"])
        XCTAssertEqual(try data("\(v1)/server/images/bg.png"), youi)
        XCTAssertEqual(try data("\(v1)/manifests/RemoteManifest/images/bg.png"), youi)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("images/bg.png")), sourceLottie,
                       "source must never be modified")
    }

    func testImageSwapCanBeDisabled() throws {
        let sourceLottie = try Data(contentsOf: source.appendingPathComponent("images/bg.png"))
        let result = try PauseAdGenerator.generate(try request(swaps: false))
        XCTAssertEqual(result.appliedSwaps, [])
        XCTAssertEqual(try data("\(v1)/server/images/bg.png"), sourceLottie)
    }

    // MARK: - Versions

    func testCreateRefusesExistingVersion() throws {
        try PauseAdGenerator.generate(try request())
        try write("marker.txt", "keep", in: url("\(v1)/server"))
        XCTAssertThrowsError(try PauseAdGenerator.generate(try request())) {
            XCTAssertEqual($0 as? PauseAdGenerator.GenerateError, .versionExists(1))
        }
        XCTAssertTrue(exists("\(v1)/server/marker.txt"), "nothing touched")
    }

    func testOverwriteReplacesServerManifestAndMetadata() throws {
        try PauseAdGenerator.generate(try request())
        try write("stale.png", "s", in: url("\(v1)/server/images"))
        try write("stale.png", "s", in: url("\(v1)/manifests/RemoteManifest/images"))
        try write("notes.md", "keep", in: url(v1))

        var m = metadata()
        m.adCampaign = "Season 18"
        try PauseAdGenerator.generate(try request(mode: .overwrite, metadata: m))

        XCTAssertFalse(exists("\(v1)/server/images/stale.png"))
        XCTAssertFalse(exists("\(v1)/manifests/RemoteManifest/images/stale.png"))
        XCTAssertTrue(exists("\(v1)/notes.md"), "other files in the version folder are left alone")
        XCTAssertEqual(try PauseAdMetadata(jsonData: data("\(v1)/metadata.json")).adCampaign, "Season 18")
    }

    func testNextVersionLeavesPreviousUntouched() throws {
        try PauseAdGenerator.generate(try request())
        let v1Metadata = try data("\(v1)/metadata.json")
        var m = metadata()
        m.duration = 4
        let result = try PauseAdGenerator.generate(try request(version: 2, metadata: m))

        XCTAssertEqual(result.version, 2)
        XCTAssertTrue(exists("ads/sales/2026/brand/10Oct/pause/p-19583/v2/manifests/RemoteManifest/data.json"))
        XCTAssertEqual(try data("\(v1)/metadata.json"), v1Metadata)
    }

    func testRegenerateFromItsOwnServerFolder() throws {
        // e.g. metadata fixed later: source = the version's own server/ folder.
        try PauseAdGenerator.generate(try request())
        let ownServer = url("\(v1)/server")
        var m = metadata()
        m.adIndustry = "Retail"
        try PauseAdGenerator.generate(try request(mode: .overwrite, from: ownServer, metadata: m))

        XCTAssertTrue(exists("\(v1)/server/data.json"))
        XCTAssertTrue(exists("\(v1)/server/\(prefix).aep"))
        XCTAssertTrue(exists("\(v1)/manifests/RemoteManifest/images/bg.png"))
        XCTAssertEqual(try PauseAdMetadata(jsonData: data("\(v1)/metadata.json")).adIndustry, "Retail")
    }

    // MARK: - Refusals

    func testInspectionErrorsBlockGeneration() throws {
        try FileManager.default.removeItem(at: source.appendingPathComponent("data.json"))
        XCTAssertThrowsError(try PauseAdGenerator.generate(try request())) {
            guard case .inspectionFailed(let messages) = $0 as? PauseAdGenerator.GenerateError else {
                return XCTFail("\($0)")
            }
            XCTAssertTrue(messages.contains { $0.contains("data.json") })
        }
        XCTAssertFalse(exists("ads"))
    }

    func testSourceContainingDestinationIsRefused() throws {
        let inside = PauseAdGenerator.Request(
            source: source, destinationRoot: source.appendingPathComponent("out"), job: try job(),
            version: 1, mode: .create, metadata: metadata(), applyImageSwaps: true)
        XCTAssertThrowsError(try PauseAdGenerator.generate(inside)) {
            XCTAssertEqual($0 as? PauseAdGenerator.GenerateError, .sourceContainsDestination)
        }
    }

    func testInteractiveAdIsRefused() throws {
        try PauseAdGenerator.generate(try request())
        try write("code_constructor.jsx", "x", in: url(v1))
        XCTAssertThrowsError(try PauseAdGenerator.generate(try request(mode: .overwrite))) {
            XCTAssertEqual($0 as? PauseAdGenerator.GenerateError, .interactiveAdUnsupported)
        }
    }

    func testRuntimeSourcePathMetadataIsRefused() throws {
        var m = metadata()
        m.extraFields["runtimeSourcePath"] = #"{"componentId":"quiz"}"#
        XCTAssertThrowsError(try PauseAdGenerator.generate(try request(metadata: m))) {
            XCTAssertEqual($0 as? PauseAdGenerator.GenerateError, .interactiveAdUnsupported)
        }
    }

    func testNonPositiveDurationIsRefused() throws {
        var m = metadata()
        m.duration = 0
        XCTAssertThrowsError(try PauseAdGenerator.generate(try request(metadata: m))) {
            XCTAssertEqual($0 as? PauseAdGenerator.GenerateError, .invalidDuration)
        }
    }

    func testEmptyTargetOrLottieTargetIsRefused() throws {
        var m = metadata()
        m.target = " "
        XCTAssertThrowsError(try PauseAdGenerator.generate(try request(metadata: m))) {
            XCTAssertEqual($0 as? PauseAdGenerator.GenerateError, .missingField(.target))
        }
        m = metadata()
        m.lottieTarget = "missing.json"
        XCTAssertThrowsError(try PauseAdGenerator.generate(try request(metadata: m))) {
            XCTAssertEqual($0 as? PauseAdGenerator.GenerateError, .missingField(.lottieTarget))
        }
    }

    func testInvalidVersionIsRefused() throws {
        XCTAssertThrowsError(try PauseAdGenerator.generate(try request(version: 0))) {
            XCTAssertEqual($0 as? PauseAdGenerator.GenerateError, .invalidVersion)
        }
    }
}
