//
//  PauseAdInspectorTests.swift
//  AerospaceTests
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Aerospace

final class PauseAdInspectorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PauseAdInspectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture helpers

    private func write(_ relative: String, _ text: String, in base: URL? = nil) throws {
        let url = (base ?? root).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Writes a PNG. `noisy` pixels compress badly (large file); flat ones compress well (small).
    private func writePNG(_ relative: String, width: Int = 32, height: Int = 32, noisy: Bool) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        if noisy {
            var seed: UInt32 = 12345
            for i in pixels.indices {
                seed = seed &* 1_103_515_245 &+ 12345
                pixels[i] = UInt8(truncatingIfNeeded: seed >> 16)
            }
        }
        let image = try XCTUnwrap(pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeBytes(_ relative: String, count: Int) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0, count: count).write(to: url)
    }

    private func lottieJSON(images: [String], markers: [(String, Int)] = [("Ad-In", 232)],
                            fr: Int = 60) -> String {
        let assets = images.map { #"{"id":"\#($0)","w":32,"h":32,"u":"images/","p":"\#($0)","e":0}"# }
        let precomp = #"{"id":"comp_0","nm":"pre","layers":[],"fr":60}"#
        let markerJSON = markers.map { #"{"tm":128,"cm":"\#($0.0)","dr":\#($0.1)}"# }
        return #"{"v":"5.9.0","fr":\#(fr),"ip":0,"op":698,"w":1920,"h":1080,"nm":"main","assets":[\#((assets + [precomp]).joined(separator: ","))],"layers":[],"markers":[\#(markerJSON.joined(separator: ","))]}"#
    }

    private func timelineLog(_ markers: [(name: String, duration: String)]) -> String {
        var text = """
        tracks {
          binding: IS_VISIBLE
          targetid: 856
          targetname: "Loop-BG.jpg"
          keytimes {
            datatype: AE_INT_DATA
            ivalue1: 1
          }
        }

        """
        for marker in markers {
            text += """
            markers {
              starttime: 2.13333344
              duration: \(marker.duration)
              name: "\(marker.name)"
              tracksSelection {
                targetid: 857
                binding: OPACITY
              }
            }

            """
        }
        return text
    }

    /// The standard designer hand-off: AEP + lottie + youi export.
    private func makeStandardAd(prefix: String = "Brand-2026-PremiumPause-Ad",
                                timelineMarkers: [(name: String, duration: String)] = [("Ad-In", "3.86666656")],
                                lottieMarkers: [(String, Int)] = [("Ad-In", 232)]) throws {
        try writeBytes("\(prefix).aep", count: 10)
        try write("data.json", lottieJSON(images: ["\(prefix)-BG.png"], markers: lottieMarkers))
        try writePNG("images/\(prefix)-BG.png", noisy: true)
        try writePNG("assets/drawable/default/\(prefix)-BG.png", noisy: false)
        try write("assets/layout/tv/\(prefix)_main.layout", "layout")
        try write("assets/layout/tv/\(prefix)_main.timeline", "timeline")
        try write("assets/layout/tv/\(prefix)_main.timeline.log", timelineLog(timelineMarkers))
        try write("assets/layout/tv/\(prefix)_main.layout.log", "log")
    }

    private func inspect() -> PauseAdInspection { PauseAdInspector.inspect(root) }

    private func messages(_ i: PauseAdInspection, _ severity: PauseAdInspection.Severity) -> [String] {
        i.issues.filter { $0.severity == severity }.map(\.message)
    }

    // MARK: - Standard hand-off

    func testStandardAdDerivesMetadata() throws {
        try makeStandardAd()
        let i = inspect()
        XCTAssertEqual(i.aepFileName, "Brand-2026-PremiumPause-Ad.aep")
        XCTAssertTrue(i.hasLottie)
        XCTAssertEqual(i.layoutFile, "assets/layout/tv/Brand-2026-PremiumPause-Ad_main.layout")
        XCTAssertEqual(i.timelineLogFile, "assets/layout/tv/Brand-2026-PremiumPause-Ad_main.timeline.log")
        XCTAssertEqual(i.derived.target, "Brand-2026-PremiumPause-Ad_main")
        XCTAssertEqual(i.derived.lottieTarget, "data.json")
        XCTAssertEqual(i.derived.duration, 3.86666656)
        XCTAssertEqual(i.durationSource, .timelineLog)
        XCTAssertFalse(i.derived.loop)
        XCTAssertTrue(i.canGenerate, "\(i.issues)")
        XCTAssertEqual(messages(i, .error), [])
    }

    func testAepWithDotsInNameStillFindsMainLayout() throws {
        // Real case: Specsavers-2026-PremiumPause-Ad-25.x.aep + ..._25_main.layout
        try makeStandardAd(prefix: "Specsavers-2026-PremiumPause-Ad-25")
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("Specsavers-2026-PremiumPause-Ad-25.aep"),
            to: root.appendingPathComponent("Specsavers-2026-PremiumPause-Ad-25.x.aep"))
        XCTAssertEqual(inspect().derived.target, "Specsavers-2026-PremiumPause-Ad-25_main")
    }

    func testCapitalMainLayoutIsAccepted() throws {
        try makeStandardAd()
        let tv = root.appendingPathComponent("assets/layout/tv")
        for ext in ["layout", "timeline.log"] {
            try FileManager.default.moveItem(
                at: tv.appendingPathComponent("Brand-2026-PremiumPause-Ad_main.\(ext)"),
                to: tv.appendingPathComponent("Brand-2026-PremiumPause-Ad_Main.\(ext)"))
        }
        let i = inspect()
        XCTAssertEqual(i.derived.target, "Brand-2026-PremiumPause-Ad_Main")
        XCTAssertEqual(i.durationSource, .timelineLog)
    }

    func testMainLayoutNamedAfterAepWinsOverOthers() throws {
        // Real case: Kraken-2022-07-UAP-Ad.aep with X_main and X-v2_main layouts.
        try makeStandardAd()
        try write("assets/layout/tv/Brand-2026-PremiumPause-Ad-v2_main.layout", "layout")
        let i = inspect()
        XCTAssertEqual(i.derived.target, "Brand-2026-PremiumPause-Ad_main")
        XCTAssertTrue(messages(i, .warning).contains { $0.contains("Multiple main layouts") })
    }

    func testSameLayoutInSeveralDeviceFoldersIsNotAmbiguous() throws {
        try makeStandardAd()
        try write("assets/layout/tv-4k/Brand-2026-PremiumPause-Ad_main.layout", "layout")
        let i = inspect()
        XCTAssertFalse(messages(i, .warning).contains { $0.contains("Multiple main layouts") }, "\(i.issues)")
        XCTAssertEqual(i.layoutFile, "assets/layout/tv/Brand-2026-PremiumPause-Ad_main.layout")
        XCTAssertEqual(i.durationSource, .timelineLog)
    }

    func testRklowLayoutsAreIgnored() throws {
        try makeStandardAd()
        try write("assets/layout/tv-rklow/Brand-2026-PremiumPause-Ad-alt_main.layout", "layout")
        XCTAssertFalse(messages(inspect(), .warning).contains { $0.contains("Multiple main layouts") })
    }

    func testAutoSaveAepIsIgnored() throws {
        try makeStandardAd()
        try writeBytes("Adobe After Effects Auto-Save/Brand auto-save 1.aep", count: 5)
        try writeBytes("Brand-2026-PremiumPause-Ad auto-save 3.aep", count: 5)
        let i = inspect()
        XCTAssertEqual(i.aepFileName, "Brand-2026-PremiumPause-Ad.aep")
        XCTAssertFalse(i.issues.contains { $0.message.contains("Multiple") })
    }

    // MARK: - Markers

    func testLoopMarkerInTimelineSetsLoop() throws {
        try makeStandardAd(timelineMarkers: [("Ad-In", "8"), ("Loop", "1.7")])
        let i = inspect()
        XCTAssertTrue(i.derived.loop)
        XCTAssertEqual(i.derived.duration, 8)
    }

    func testLayerNamedLoopDoesNotSetLoop() throws {
        // The fixture timeline log has a track target named "Loop-BG.jpg";
        // the CLI's substring check would have flagged this as looping.
        try makeStandardAd()
        XCTAssertFalse(inspect().derived.loop)
    }

    func testLoopMarkerInLottieSetsLoop() throws {
        try makeStandardAd(lottieMarkers: [("Ad-In", 232), ("Loop", 60)])
        XCTAssertTrue(inspect().derived.loop)
    }

    func testDurationFallsBackToLottieMarkerWithoutYouiExport() throws {
        try writeBytes("Brand.aep", count: 10)
        try write("data.json", lottieJSON(images: ["bg.png"], markers: [("Ad-In", 232)]))
        try writePNG("images/bg.png", noisy: false)
        let i = inspect()
        XCTAssertEqual(i.durationSource, .lottieMarker)
        XCTAssertEqual(i.derived.duration, 3.86666667)
        XCTAssertEqual(i.derived.target, "Brand", "falls back to the AEP prefix")
        XCTAssertTrue(messages(i, .warning).contains { $0.contains("youi") }, "\(i.issues)")
        XCTAssertTrue(i.canGenerate)
    }

    func testMissingAdInMarkerWarnsAndDefaultsDuration() throws {
        try makeStandardAd(timelineMarkers: [], lottieMarkers: [])
        let i = inspect()
        XCTAssertEqual(i.durationSource, .none)
        XCTAssertEqual(i.derived.duration, 1)
        XCTAssertTrue(messages(i, .warning).contains { $0.contains("Ad-In") })
    }

    func testDurationDisagreementBetweenExportsWarns() throws {
        try makeStandardAd(timelineMarkers: [("Ad-In", "5.5333333")], lottieMarkers: [("Ad-In", 349)])
        let i = inspect()
        XCTAssertEqual(i.derived.duration, 5.5333333, "youi timeline wins, as in the CLI")
        XCTAssertTrue(messages(i, .warning).contains { $0.contains("disagree") }, "\(i.issues)")
    }

    func testLottieMarkerNameMayBeJSONEncoded() {
        let markers = PauseAdInspector.lottieMarkers(in: [
            "fr": 30,
            "markers": [["tm": 0, "cm": "{\r\n\"name\":\"Ad-In\"\r\n}", "dr": 90]],
        ])
        XCTAssertEqual(markers, [PauseAdInspector.Marker(name: "Ad-In", duration: 3)])
    }

    func testTimelineMarkerParserReadsOnlyTopLevelFields() {
        let markers = PauseAdInspector.timelineMarkers(in: timelineLog([("Ad-In", "4"), ("Loop", "1.5")]))
        XCTAssertEqual(markers, [.init(name: "Ad-In", duration: 4), .init(name: "Loop", duration: 1.5)])
    }

    // MARK: - Structural errors

    func testMissingDataJSONIsError() throws {
        try writeBytes("Brand.aep", count: 10)
        let i = inspect()
        XCTAssertFalse(i.hasLottie)
        XCTAssertFalse(i.canGenerate)
        XCTAssertTrue(messages(i, .error).contains { $0.contains("data.json") })
    }

    func testUnparsableDataJSONIsError() throws {
        try write("data.json", "{ nope")
        let i = inspect()
        XCTAssertFalse(i.hasLottie)
        XCTAssertFalse(i.canGenerate)
    }

    func testMissingReferencedImageIsError() throws {
        try makeStandardAd()
        try FileManager.default.removeItem(at: root.appendingPathComponent("images/Brand-2026-PremiumPause-Ad-BG.png"))
        let i = inspect()
        XCTAssertEqual(i.missingImages, ["images/Brand-2026-PremiumPause-Ad-BG.png"])
        XCTAssertFalse(i.canGenerate)
    }

    func testEmbeddedImagesAreNotFileReferences() throws {
        try writeBytes("Brand.aep", count: 10)
        try write("data.json", #"{"fr":60,"assets":[{"id":"x","w":1,"h":1,"u":"","p":"data:image/png;base64,AAAA","e":1}],"markers":[{"tm":0,"cm":"Ad-In","dr":60}]}"#)
        let i = inspect()
        XCTAssertEqual(i.missingImages, [])
        XCTAssertTrue(i.canGenerate, "\(i.issues)")
    }

    func testUnusedImagesWarn() throws {
        try makeStandardAd()
        try writePNG("images/leftover.png", noisy: false)
        let i = inspect()
        XCTAssertEqual(i.unusedImages, ["images/leftover.png"])
        XCTAssertTrue(messages(i, .warning).contains { $0.contains("not referenced") })
    }

    func testMissingAepIsWarning() throws {
        try write("data.json", lottieJSON(images: []))
        let i = inspect()
        XCTAssertNil(i.aepFileName)
        XCTAssertTrue(messages(i, .warning).contains { $0.contains(".aep") })
    }

    func testNoTargetAtAllIsError() throws {
        try write("data.json", lottieJSON(images: []))
        let i = inspect()
        XCTAssertEqual(i.derived.target, "")
        XCTAssertTrue(messages(i, .error).contains { $0.contains("target") })
    }

    func testNestedHandOffFolderIsDetected() throws {
        let inner = root.appendingPathComponent("Brand-PremiumPause-Ad")
        try write("data.json", lottieJSON(images: []), in: inner)
        try write("Brand.aep", "x", in: inner)
        try write("__MACOSX/._x", "x")
        let i = inspect()
        XCTAssertFalse(i.canGenerate)
        XCTAssertTrue(messages(i, .error).contains { $0.contains("Brand-PremiumPause-Ad") }, "\(i.issues)")
    }

    func testMissingSourceFolderIsError() {
        let i = PauseAdInspector.inspect(root.appendingPathComponent("nope"))
        XCTAssertFalse(i.canGenerate)
    }

    // MARK: - Images: swap and size

    func testSmallerYouiImageWithSameDimensionsIsSwapCandidate() throws {
        try makeStandardAd()
        let i = inspect()
        XCTAssertEqual(i.swaps.map(\.name), ["Brand-2026-PremiumPause-Ad-BG.png"])
        let swap = try XCTUnwrap(i.swaps.first)
        XCTAssertLessThan(swap.youiBytes, swap.lottieBytes)
        XCTAssertEqual(i.shippedImageBytes, i.lottieImageBytes - swap.lottieBytes + swap.youiBytes)
    }

    func testLargerYouiImageIsNotSwapped() throws {
        try makeStandardAd()
        try writePNG("images/Brand-2026-PremiumPause-Ad-BG.png", noisy: false)
        try writePNG("assets/drawable/default/Brand-2026-PremiumPause-Ad-BG.png", noisy: true)
        let i = inspect()
        XCTAssertEqual(i.swaps, [])
        XCTAssertEqual(i.shippedImageBytes, i.lottieImageBytes)
    }

    func testDifferentDimensionsAreNotSwappedAndWarn() throws {
        try makeStandardAd()
        try writePNG("assets/drawable/default/Brand-2026-PremiumPause-Ad-BG.png", width: 16, height: 16, noisy: false)
        let i = inspect()
        XCTAssertEqual(i.swaps, [])
        XCTAssertTrue(messages(i, .warning).contains { $0.contains("dimensions") }, "\(i.issues)")
    }

    func testShippedImagesOver3MBWarn() throws {
        try makeStandardAd()
        try writeBytes("images/big.bin", count: 3_500_000)
        let i = inspect()
        XCTAssertTrue(i.canGenerate)
        XCTAssertTrue(messages(i, .warning).contains { $0.contains("3 MB") }, "\(i.issues)")
    }

    func testShippedImagesOver5MBWarnButDoNotBlock() throws {
        // Big Brother 2026 ads shipped at 7.2 MB / 9.1 MB; the limit is advisory.
        try makeStandardAd()
        try writeBytes("images/huge.bin", count: 5_500_000)
        let i = inspect()
        XCTAssertTrue(i.canGenerate)
        XCTAssertTrue(messages(i, .warning).contains { $0.contains("5 MB limit") }, "\(i.issues)")
        XCTAssertFalse(messages(i, .warning).contains { $0.contains("recommended 3 MB") })
    }

    func testDotFilesAreIgnoredInImageTotals() throws {
        try makeStandardAd()
        try writeBytes("images/.DS_Store", count: 9_000_000)
        let i = inspect()
        XCTAssertEqual(i.unusedImages, [])
        XCTAssertTrue(i.canGenerate)
    }

    // MARK: - Existing metadata comparison

    func testDifferencesFromExistingMetadataAreReported() throws {
        try makeStandardAd()
        let existing = PauseAdMetadata(loop: false, target: "Brand-2026-PremiumPause-Ad_main",
                                       lottieTarget: "data.json", duration: 5.5333333)
        let diffs = inspect().differences(from: existing)
        XCTAssertEqual(diffs.map(\.field), [.duration])
        XCTAssertEqual(diffs.first?.existing, "5.5333333")
        XCTAssertEqual(diffs.first?.derived, "3.86666656")
    }

    func testNoDifferencesWhenExistingMatches() throws {
        try makeStandardAd()
        let i = inspect()
        var existing = i.derived
        existing.adBrandName = "Brand"
        XCTAssertEqual(i.differences(from: existing), [])
    }
}
