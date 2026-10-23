//
//  DynamicConfigTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

/// A cut-down dynamic_config_2026_10_23.json, in its file layout.
let sampleDynamicConfig = #"""
{
  "tealiumEventPermissionMap": {
    "app_launch": { "all": 1 },
    "home_screen": { "all": 1 },
    "ad_start": { "all": 0 }
  },
  "errorReportPermissionMap": {
    "liveTvSlateImageLoadError": { "all": 1 },
    "oztamDataError": { "all": 0 }
  },
  "bvodConstants": {
    "maxBvodFetchTimeMs": { "all": 2500 },
    "retryLimit": { "all": 1 }
  },
  "votingSettings": {
    "authLandscapeImageUrl": "https://10.com.au/ip/s3/2026/10/23/09acdfbc2902f632e9ba239232d1d207-1468660.jpg",
    "closeButtonColour": "#FFFFFF00"
  },
  "activationCodeSettings": {
    "baseUrl": "https://link.10.com.au/lwfe4vvo3"
  },
  "playerErrorMessageMap": {
    "5301": {
      "title": "Oops, something went wrong...",
      "message": "Looks like you're using an ad blocker!\n\nIf you're experiencing issues, let us know!"
    }
  }
}

"""#

final class DynamicConfigTests: XCTestCase {

    private func sample() throws -> DynamicConfig { try DynamicConfig(text: sampleDynamicConfig) }

    func testUnchangedConfigWritesBackIdentically() throws {
        XCTAssertEqual(try sample().text, sampleDynamicConfig)
    }

    func testRootMustBeAnObject() {
        XCTAssertThrowsError(try DynamicConfig(text: "[1]")) { error in
            XCTAssertEqual(error as? DynamicConfig.ConfigError, .rootNotObject)
        }
    }

    func testPlatformMapDetection() throws {
        XCTAssertTrue(try JSONValue(parsing: #"{"all": 1}"#).isPlatformMap)
        XCTAssertTrue(try JSONValue(parsing: #"{"roku": "x", "vegatv": "y"}"#).isPlatformMap)
        XCTAssertFalse(try JSONValue(parsing: #"{"all": 1, "web": 0}"#).isPlatformMap)
        XCTAssertFalse(try JSONValue(parsing: #"{}"#).isPlatformMap)
        XCTAssertFalse(JSONValue.number("1").isPlatformMap)
    }

    func testSections() throws {
        let sections = try sample().sections
        XCTAssertEqual(sections.map(\.key), ["tealiumEventPermissionMap", "errorReportPermissionMap", "bvodConstants",
                                             "votingSettings", "activationCodeSettings", "playerErrorMessageMap"])
        XCTAssertEqual(sections.map(\.hasPlatformMaps), [true, true, true, false, false, false])
        XCTAssertEqual(sections.map(\.isFlagSection), [true, true, false, false, false, false])
        XCTAssertEqual(sections[0].entries.map(\.key), ["app_launch", "home_screen", "ad_start"])
        XCTAssertEqual(sections[0].entries[2].path, ["tealiumEventPermissionMap", "ad_start"])
    }

    func testTopLevelValuesThatAreNotSectionsAreSingleEntries() throws {
        let sections = try DynamicConfig(text: #"{"flag": {"all": true, "roku": false}, "name": "x"}"#).sections
        XCTAssertEqual(sections.map { $0.entries.map(\.path) }, [[["flag"]], [["name"]]])
        XCTAssertEqual(sections[0].entries[0].overrides, [.roku])
    }

    func testCellsFallBackToAll() throws {
        var config = try sample()
        config.setPlatformValue(.number("0"), for: .roku, at: ["tealiumEventPermissionMap", "app_launch"])
        let entry = try XCTUnwrap(config.entry(at: ["tealiumEventPermissionMap", "app_launch"]))
        XCTAssertEqual(entry.cell(for: .roku).value, .number("0"))
        XCTAssertTrue(entry.cell(for: .roku).isOwn)
        XCTAssertEqual(entry.cell(for: .tvos).value, .number("1"))
        XCTAssertFalse(entry.cell(for: .tvos).isOwn)
        XCTAssertEqual(entry.overrides, [.roku])

        let plain = try XCTUnwrap(config.entry(at: ["activationCodeSettings", "baseUrl"]))
        XCTAssertTrue(plain.cell(for: .all).isOwn)
        XCTAssertFalse(plain.cell(for: .roku).isOwn)
    }

    func testPlatformValuesAreKeptInPlatformOrder() throws {
        var config = try sample()
        let path = ["tealiumEventPermissionMap", "ad_start"]
        config.setPlatformValue(.number("1"), for: .vegatv, at: path)
        config.setPlatformValue(.number("1"), for: .roku, at: path)
        config.setPlatformValue(.number("0"), for: .firetv, at: path)
        XCTAssertEqual(config.root.value(at: path)?.members?.map(\.key), ["all", "roku", "firetv", "vegatv"])
        XCTAssertTrue(config.text.contains(#""ad_start": { "all": 0, "roku": 1, "firetv": 0, "vegatv": 1 }"#))

        config.setPlatformValue(nil, for: .firetv, at: path)
        XCTAssertEqual(config.root.value(at: path)?.members?.map(\.key), ["all", "roku", "vegatv"])
    }

    func testLastPlatformValueCannotBeRemoved() throws {
        var config = try sample()
        let path = ["bvodConstants", "retryLimit"]
        config.setPlatformValue(nil, for: .all, at: path)
        XCTAssertEqual(config.root.value(at: path), .object([.init(key: "all", value: .number("1"))]))
    }

    func testPlatformValuesOnlyApplyToPlatformMaps() throws {
        var config = try sample()
        config.setPlatformValue(.string("x"), for: .roku, at: ["activationCodeSettings", "baseUrl"])
        XCTAssertEqual(config, try sample())
    }

    func testClearOverridesKeepsAll() throws {
        var config = try sample()
        let path = ["bvodConstants", "maxBvodFetchTimeMs"]
        config.setPlatformValue(.number("5000"), for: .roku, at: path)
        config.setPlatformValue(.number("4000"), for: .xbox, at: path)
        XCTAssertEqual(config.overrideCount, 2)
        config.clearOverrides(at: path)
        XCTAssertEqual(config.root.value(at: path), .object([.init(key: "all", value: .number("2500"))]))
        XCTAssertEqual(config.overrideCount, 0)
    }

    func testOverrideCounts() throws {
        var config = try sample()
        config.setPlatformValue(.number("0"), for: .roku, at: ["tealiumEventPermissionMap", "app_launch"])
        config.setPlatformValue(.number("0"), for: .roku, at: ["tealiumEventPermissionMap", "home_screen"])
        config.setPlatformValue(.number("5"), for: .tvos, at: ["bvodConstants", "retryLimit"])
        XCTAssertEqual(config.overrideCount, 3)
        XCTAssertEqual(config.overrideCount(for: .roku), 2)
        XCTAssertEqual(config.overrideCount(for: .tvos), 1)
        XCTAssertEqual(config.overrideCount(for: .ios), 0)
        XCTAssertEqual(config.section("tealiumEventPermissionMap")?.overrideCount, 2)
    }

    func testResolvedForPlatform() throws {
        var config = try sample()
        config.setPlatformValue(.number("0"), for: .roku, at: ["tealiumEventPermissionMap", "app_launch"])
        let roku = config.resolved(for: .roku)
        XCTAssertEqual(roku.value(at: ["tealiumEventPermissionMap", "app_launch"]), .number("0"))
        XCTAssertEqual(roku.value(at: ["tealiumEventPermissionMap", "home_screen"]), .number("1"))
        XCTAssertEqual(roku.value(at: ["bvodConstants", "maxBvodFetchTimeMs"]), .number("2500"))
        XCTAssertEqual(roku.value(at: ["activationCodeSettings", "baseUrl"]), .string("https://link.10.com.au/lwfe4vvo3"))
        XCTAssertEqual(roku.value(at: ["playerErrorMessageMap", "5301", "title"]), .string("Oops, something went wrong..."))
        XCTAssertEqual(config.resolved(for: .tvos).value(at: ["tealiumEventPermissionMap", "app_launch"]), .number("1"))
    }

    func testResolvedDropsValuesAPlatformDoesNotHave() throws {
        let config = try DynamicConfig(text: #"{"s": {"rokuOnly": {"roku": 3}, "nested": {"x": {"all": 1, "ios": 2}}}}"#)
        XCTAssertEqual(config.resolved(for: .roku).compactText, #"{ "s": { "rokuOnly": 3, "nested": { "x": 1 } } }"#)
        XCTAssertEqual(config.resolved(for: .ios).compactText, #"{ "s": { "nested": { "x": 2 } } }"#)
    }

    func testValueStyles() {
        XCTAssertEqual(DynamicConfig.style(for: .number("1"), inFlagSection: true), .flag)
        XCTAssertEqual(DynamicConfig.style(for: .number("1"), inFlagSection: false), .number)
        XCTAssertEqual(DynamicConfig.style(for: .number("2"), inFlagSection: true), .number)
        XCTAssertEqual(DynamicConfig.style(for: .string(""), inFlagSection: false), .string)
        XCTAssertEqual(DynamicConfig.style(for: .bool(true), inFlagSection: false), .bool)
        XCTAssertEqual(DynamicConfig.style(for: .object([]), inFlagSection: false), .json)
    }

    func testAddEntry() throws {
        var config = try sample()
        let tealium = try XCTUnwrap(config.section("tealiumEventPermissionMap"))
        try config.addEntry(" video_start ", value: DynamicConfig.newEntryValue(in: tealium),
                            toSection: tealium.key)
        XCTAssertEqual(config.root.value(at: [tealium.key, "video_start"])?.compactText, #"{ "all": 1 }"#)
        XCTAssertEqual(config.section(tealium.key)?.entries.last?.key, "video_start")

        XCTAssertThrowsError(try config.addEntry("app_launch", value: .null, toSection: tealium.key)) { error in
            XCTAssertEqual(error as? DynamicConfig.ConfigError, .duplicateKey("app_launch"))
        }
        XCTAssertThrowsError(try config.addEntry("  ", value: .null, toSection: tealium.key)) { error in
            XCTAssertEqual(error as? DynamicConfig.ConfigError, .emptyKey)
        }
    }

    func testNewEntryValueFollowsTheSection() throws {
        let config = try sample()
        func newValue(_ key: String) throws -> String {
            DynamicConfig.newEntryValue(in: try XCTUnwrap(config.section(key))).compactText
        }
        XCTAssertEqual(try newValue("errorReportPermissionMap"), #"{ "all": 1 }"#)
        XCTAssertEqual(try newValue("bvodConstants"), #"{ "all": 0 }"#)
        XCTAssertEqual(try newValue("votingSettings"), #""""#)
        XCTAssertEqual(try newValue("playerErrorMessageMap"), #"{ "title": "", "message": "" }"#)
    }

    func testRemoveEntry() throws {
        var config = try sample()
        config.removeEntry(at: ["tealiumEventPermissionMap", "home_screen"])
        XCTAssertEqual(config.section("tealiumEventPermissionMap")?.entries.map(\.key), ["app_launch", "ad_start"])
    }

    func testLongPlatformStringsAreWrittenOnSeparateLines() throws {
        var config = try sample()
        let long = String(repeating: "x", count: 130)
        config.setValue(.object([.init(key: "all", value: .string(long))]), at: ["votingSettings", "closeButtonColour"])
        XCTAssertTrue(config.text.contains("\"closeButtonColour\": {\n      \"all\": \"\(long)\"\n    }"))
    }
}
