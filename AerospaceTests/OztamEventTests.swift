//
//  OztamEventTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class OztamEventTests: XCTestCase {

    private let device = OztamDevice(name: "Lounge TV", kind: .ipAddress, value: "192.168.0.1")

    private func meterEvent(
        events: [[String: Any]],
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "createdAt": "2026-09-30T10:15:00Z",
            "vendorVersion": "10PLAY_ANDROID_7.6.0",
            "sessionId": "sess-1",
            "publisherId": "pub-1",
            "mediaId": "media-1",
            "events": events,
        ]
        for (key, value) in extra { object[key] = value }
        return object
    }

    // MARK: - Flattening

    func testOneRowPerNestedEvent() {
        let object = meterEvent(events: [
            ["event": "LOAD", "timestamp": "2026-09-30T10:15:01Z"],
            ["event": "BEGIN", "timestamp": "2026-09-30T10:15:02Z"],
        ])
        let rows = OztamEvent.rows(fromMeterEvent: object, device: device)
        XCTAssertEqual(rows.map(\.event), ["LOAD", "BEGIN"])
        XCTAssertEqual(rows.first?.deviceName, "Lounge TV")
        XCTAssertEqual(rows.first?.deviceID, device.id)
    }

    func testMeterEventWithoutNestedEventsProducesNoRows() {
        XCTAssertTrue(OztamEvent.rows(fromMeterEvent: meterEvent(events: []), device: device).isEmpty)
        XCTAssertTrue(OztamEvent.rows(fromMeterEvent: ["createdAt": "2026-09-30T10:15:00Z"],
                                      device: device).isEmpty)
    }

    func testMeterEventFieldsAreCopiedOntoEveryRow() {
        let rows = OztamEvent.rows(fromMeterEvent: meterEvent(events: [["event": "PROGRESS"]]),
                                   device: device)
        let row = try? XCTUnwrap(rows.first)
        XCTAssertEqual(row?.sessionId, "sess-1")
        XCTAssertEqual(row?.publisherId, "pub-1")
        XCTAssertEqual(row?.mediaId, "media-1")
        // oztail lowercases vendorVersion before printing it.
        XCTAssertEqual(row?.vendorVersion, "10play_android_7.6.0")
    }

    func testRowFallsBackToMeterCreatedAtWhenEventTimestampMissing() {
        let rows = OztamEvent.rows(fromMeterEvent: meterEvent(events: [["event": "LOAD"]]),
                                   device: device)
        XCTAssertEqual(rows.first?.timestamp, rows.first?.createdAt)
    }

    // MARK: - Severity

    func testSeverityIsOKWhenNoErrorsOrWarnings() {
        let rows = OztamEvent.rows(fromMeterEvent: meterEvent(events: [["event": "LOAD"]]),
                                   device: device)
        XCTAssertEqual(rows.first?.severity, .ok)
        XCTAssertNil(rows.first?.detail)
    }

    func testSeverityIsWarningWhenInputWarningsPresent() {
        let object = meterEvent(events: [["event": "LOAD"]],
                                extra: ["inputWarnings": 2, "inputWarningStr": "late event"])
        let rows = OztamEvent.rows(fromMeterEvent: object, device: device)
        XCTAssertEqual(rows.first?.severity, .warning)
        XCTAssertEqual(rows.first?.detail, "late event")
    }

    func testSeverityIsErrorWhenInputErrorsPresent() {
        let object = meterEvent(events: [["event": "LOAD"]],
                                extra: ["inputErrors": 1, "inputErrorStr": "missing mediaId",
                                        "inputWarnings": 3, "inputWarningStr": "ignored"])
        let rows = OztamEvent.rows(fromMeterEvent: object, device: device)
        XCTAssertEqual(rows.first?.severity, .error)
        XCTAssertEqual(rows.first?.detail, "missing mediaId")
    }

    func testZeroCountsAreNotFlagged() {
        let object = meterEvent(events: [["event": "LOAD"]],
                                extra: ["inputErrors": 0, "inputWarnings": 0])
        XCTAssertEqual(OztamEvent.rows(fromMeterEvent: object, device: device).first?.severity, .ok)
    }

    func testSeverityFlagsMatchOztailColumn() {
        XCTAssertEqual(OztamSeverity.ok.flag, "")
        XCTAssertEqual(OztamSeverity.warning.flag, "W")
        XCTAssertEqual(OztamSeverity.error.flag, "Q")
    }

    // MARK: - Positions & duration

    func testVODPositionsAreSecondsAndDurationIsTheDifference() {
        let object = meterEvent(events: [
            ["event": "PROGRESS", "fromPosition": 10.0, "toPosition": 40.0]
        ])
        let row = OztamEvent.rows(fromMeterEvent: object, device: device).first
        XCTAssertEqual(row?.usesEpochPositions, false)
        XCTAssertEqual(row?.duration ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(row?.fromPositionText, "10.0")
        XCTAssertEqual(row?.durationText, "30.0")
    }

    func testEpochPositionsAreConvertedToSeconds() {
        let object = meterEvent(events: [
            ["event": "PROGRESS", "fromPosition": 1_759_200_000_000, "toPosition": 1_759_200_030_000]
        ])
        let row = OztamEvent.rows(fromMeterEvent: object, device: device).first
        XCTAssertEqual(row?.usesEpochPositions, true)
        XCTAssertEqual(row?.duration ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(row?.fromPositionText, "1759200000000")
    }

    func testStringPositionsAreParsed() {
        let object = meterEvent(events: [
            ["event": "PROGRESS", "fromPosition": "10", "toPosition": "25.5"]
        ])
        let row = OztamEvent.rows(fromMeterEvent: object, device: device).first
        XCTAssertEqual(row?.duration ?? 0, 15.5, accuracy: 0.001)
    }

    func testMissingPositionsYieldNoDuration() {
        let row = OztamEvent.rows(fromMeterEvent: meterEvent(events: [["event": "LOAD"]]),
                                  device: device).first
        XCTAssertNil(row?.duration)
        XCTAssertEqual(row?.fromPositionText, "")
        XCTAssertEqual(row?.durationText, "")
    }

    // MARK: - Properties & search

    func testPropertiesAreExtracted() {
        let object = meterEvent(events: [["event": "LOAD"]],
                                extra: ["properties": ["deviceId": "dev-9", "demo1": "M25-39"]])
        let row = OztamEvent.rows(fromMeterEvent: object, device: device).first
        XCTAssertEqual(row?.propertiesDeviceId, "dev-9")
        XCTAssertEqual(row?.demo1, "M25-39")
    }

    func testSearchHaystackIsLowercasedAndCoversKeyFields() {
        let object = meterEvent(events: [["event": "LOAD"]])
        let row = OztamEvent.rows(fromMeterEvent: object, device: device).first
        XCTAssertTrue(row?.searchHaystack.contains("sess-1") ?? false)
        XCTAssertTrue(row?.searchHaystack.contains("media-1") ?? false)
        XCTAssertTrue(row?.searchHaystack.contains("lounge tv") ?? false)
    }

    func testRawJSONIsPrettyPrintedAndParseable() throws {
        let object = meterEvent(events: [["event": "LOAD"]])
        let raw = try XCTUnwrap(OztamEvent.rows(fromMeterEvent: object, device: device).first?.rawJSON)
        XCTAssertTrue(raw.contains("\n"))
        let reparsed = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        XCTAssertEqual(reparsed?["sessionId"] as? String, "sess-1")
    }

    // MARK: - Decoding a whole response

    func testDecodeFlattensAllMeterEventsAndTracksLatestCreatedAt() throws {
        let payload: [[String: Any]] = [
            meterEvent(events: [["event": "LOAD"]], extra: ["createdAt": "2026-09-30T10:15:00Z"]),
            meterEvent(events: [["event": "BEGIN"], ["event": "PROGRESS"]],
                       extra: ["createdAt": "2026-09-30T10:16:00Z"]),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let result = OztamClient.decode(data, device: device)
        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(result.latestCreatedAt,
                       OztamEvent.date(from: "2026-09-30T10:16:00Z"))
    }

    func testDecodeOfNonArrayPayloadYieldsNothing() {
        let data = Data("{\"error\":\"nope\"}".utf8)
        let result = OztamClient.decode(data, device: device)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertNil(result.latestCreatedAt)
        XCTAssertEqual(result.meterEventCount, 0)
    }

    func testDecodeReportsMeterEventCountSeparatelyFromRows() throws {
        // A meter event with no nested rows must still be counted, so the
        // Diagnostics panel can say "answered, but nothing parsed".
        let payload: [[String: Any]] = [["createdAt": "2026-09-30T10:15:00Z", "events": []]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let result = OztamClient.decode(data, device: device)
        XCTAssertEqual(result.meterEventCount, 1)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testDecodeOfEmptyArrayReportsZeroMeterEvents() throws {
        let data = try JSONSerialization.data(withJSONObject: [[String: Any]]())
        let result = OztamClient.decode(data, device: device)
        XCTAssertEqual(result.meterEventCount, 0)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testDateParsingAcceptsFractionalSeconds() {
        XCTAssertNotNil(OztamEvent.date(from: "2026-09-30T10:15:00.123Z"))
        XCTAssertNotNil(OztamEvent.date(from: "2026-09-30T10:15:00Z"))
        XCTAssertNil(OztamEvent.date(from: "not a date"))
    }
}
