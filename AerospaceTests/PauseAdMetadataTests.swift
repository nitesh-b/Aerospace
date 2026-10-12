//
//  PauseAdMetadataTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class PauseAdMetadataTests: XCTestCase {

    private func complete() -> PauseAdMetadata {
        PauseAdMetadata(
            loop: false,
            target: "Specsavers-2026-PremiumPause-Ad-25_main",
            lottieTarget: "data.json",
            duration: 3.86666656,
            adBrandName: "Specsavers",
            adCampaign: "278843",
            adIndustry: "Style and fashion",
            upNextModifierTime: 0
        )
    }

    // MARK: - Defaults

    func testDefaultsMatchStandardTemplate() {
        let m = PauseAdMetadata()
        XCTAssertFalse(m.loop)
        XCTAssertEqual(m.target, "")
        XCTAssertEqual(m.lottieTarget, "")
        XCTAssertEqual(m.duration, 1)
        XCTAssertEqual(m.adBrandName, "")
        XCTAssertEqual(m.adCampaign, "")
        XCTAssertEqual(m.adIndustry, "")
        XCTAssertEqual(m.upNextModifierTime, 0)
        XCTAssertTrue(m.extraFields.isEmpty)
    }

    // MARK: - Normalizer (parity with youi.ads generateManifest)

    func testNormalizeLowercases() {
        XCTAssertEqual(PauseAdMetadata.normalizeForManifest("Style and fashion"), "style and fashion")
    }

    func testNormalizeRemovesAmpersandsAndHyphens() {
        XCTAssertEqual(PauseAdMetadata.normalizeForManifest("Big-Brother & Co"), "bigbrother co")
    }

    func testNormalizeCollapsesRunsOfSpacesToOne() {
        XCTAssertEqual(PauseAdMetadata.normalizeForManifest("a    b  c"), "a b c")
    }

    func testNormalizeDoesNotTrimOrTouchSingleSpacesOrTabs() {
        XCTAssertEqual(PauseAdMetadata.normalizeForManifest(" A\tB "), " a\tb ")
    }

    func testNormalizedForManifestOnlyTouchesBrandCampaignIndustry() {
        var m = complete()
        m.target = "Some-Target_main"
        m.adCampaign = "Season-17 & More"
        let n = m.normalizedForManifest()
        XCTAssertEqual(n.target, "Some-Target_main")
        XCTAssertEqual(n.lottieTarget, "data.json")
        XCTAssertEqual(n.adBrandName, "specsavers")
        XCTAssertEqual(n.adCampaign, "season17 more")
        XCTAssertEqual(n.adIndustry, "style and fashion")
        XCTAssertEqual(n.duration, m.duration)
    }

    // MARK: - Deploy validation

    func testCompleteMetadataIsDeployable() {
        XCTAssertTrue(complete().missingDeployFields.isEmpty)
        XCTAssertTrue(complete().isDeployable)
    }

    func testBlankRequiredFieldsAreReported() {
        var m = complete()
        m.adBrandName = "  "
        m.adCampaign = ""
        m.adIndustry = "\n"
        XCTAssertEqual(m.missingDeployFields, [.adBrandName, .adCampaign, .adIndustry])
        XCTAssertFalse(m.isDeployable)
    }

    func testDerivedFieldsAreValidated() {
        var m = complete()
        m.target = ""
        m.lottieTarget = ""
        m.duration = 0
        XCTAssertEqual(m.missingDeployFields, [.target, .lottieTarget, .duration])
    }

    // MARK: - JSON writing

    func testJSONKeysAreInTemplateOrder() throws {
        let text = String(decoding: try complete().jsonData(), as: UTF8.self)
        let keys = ["loop", "target", "lottieTarget", "duration", "adBrandName",
                    "adCampaign", "adIndustry", "upNextModifierTime"]
        let positions = try keys.map { key -> String.Index in
            try XCTUnwrap(text.range(of: "\"\(key)\"")?.lowerBound, "missing \(key)")
        }
        XCTAssertEqual(positions, positions.sorted())
    }

    func testJSONValuesAreTypedCorrectly() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: complete().jsonData()) as? [String: Any])
        XCTAssertEqual(object["loop"] as? Bool, false)
        XCTAssertEqual(object["target"] as? String, "Specsavers-2026-PremiumPause-Ad-25_main")
        XCTAssertEqual(object["duration"] as? Double, 3.86666656)
        XCTAssertEqual(object["upNextModifierTime"] as? Double, 0)
        XCTAssertEqual(object.count, 8)
    }

    func testJSONWritesDurationWithoutFloatNoise() throws {
        let text = String(decoding: try complete().jsonData(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"duration\": 3.86666656"), text)
        XCTAssertTrue(text.contains("\"upNextModifierTime\": 0"), text)
    }

    func testNumbersMatchJSONStringify() throws {
        // Expected values from node: JSON.stringify([...])
        XCTAssertEqual(try PauseAdMetadata.number(3.86666656), "3.86666656")
        XCTAssertEqual(try PauseAdMetadata.number(4.01666689), "4.01666689")
        XCTAssertEqual(try PauseAdMetadata.number(12.3833332), "12.3833332")
        XCTAssertEqual(try PauseAdMetadata.number(0.1 + 0.2), "0.30000000000000004")
        XCTAssertEqual(try PauseAdMetadata.number(0), "0")
        XCTAssertEqual(try PauseAdMetadata.number(-0.0), "0")
        XCTAssertEqual(try PauseAdMetadata.number(4), "4")
        XCTAssertEqual(try PauseAdMetadata.number(2.5), "2.5")
    }

    func testNonFiniteDurationCannotBeWritten() {
        var m = complete()
        m.duration = .infinity
        XCTAssertThrowsError(try m.jsonData())
        m.duration = .nan
        XCTAssertThrowsError(try m.jsonData())
    }

    func testJSONEscapesStrings() throws {
        var m = complete()
        m.adBrandName = "Quote \" and \\ slash/"
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: m.jsonData()) as? [String: Any])
        XCTAssertEqual(object["adBrandName"] as? String, "Quote \" and \\ slash/")
    }

    // MARK: - JSON reading

    func testRoundTrip() throws {
        let decoded = try PauseAdMetadata(jsonData: complete().jsonData())
        XCTAssertEqual(decoded, complete())
    }

    func testReadsYouiAdsFileWithTabsAndIntegerDuration() throws {
        let json = """
        {
        \t"loop": true,
        \t"target": "X_main",
        \t"lottieTarget": "data.json",
        \t"duration": 4,
        \t"adBrandName": "B",
        \t"adCampaign": "C",
        \t"adIndustry": "I",
        \t"upNextModifierTime": 2.5
        }
        """
        let m = try PauseAdMetadata(jsonData: Data(json.utf8))
        XCTAssertTrue(m.loop)
        XCTAssertEqual(m.duration, 4)
        XCTAssertEqual(m.upNextModifierTime, 2.5)
    }

    func testMissingKeysFallBackToTemplateDefaults() throws {
        let m = try PauseAdMetadata(jsonData: Data(#"{"target": "T_main"}"#.utf8))
        XCTAssertEqual(m.target, "T_main")
        XCTAssertEqual(m.duration, 1)
        XCTAssertEqual(m.adBrandName, "")
    }

    func testUnknownKeysArePreservedAfterKnownKeys() throws {
        let json = #"{"target": "T_main", "adType": "sales", "runtimeSourcePath": {"componentId": "q"}}"#
        let m = try PauseAdMetadata(jsonData: Data(json.utf8))
        XCTAssertEqual(Set(m.extraFields.keys), ["adType", "runtimeSourcePath"])

        let written = String(decoding: try m.jsonData(), as: UTF8.self)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
        XCTAssertEqual(object["adType"] as? String, "sales")
        XCTAssertEqual((object["runtimeSourcePath"] as? [String: Any])?["componentId"] as? String, "q")
        let upNext = try XCTUnwrap(written.range(of: "\"upNextModifierTime\""))
        let adType = try XCTUnwrap(written.range(of: "\"adType\""))
        XCTAssertLessThan(upNext.lowerBound, adType.lowerBound)
    }

    func testRejectsNonObjectJSON() {
        XCTAssertThrowsError(try PauseAdMetadata(jsonData: Data("[1]".utf8)))
        XCTAssertThrowsError(try PauseAdMetadata(jsonData: Data("nope".utf8)))
    }
}
