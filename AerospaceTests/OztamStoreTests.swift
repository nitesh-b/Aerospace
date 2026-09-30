//
//  OztamStoreTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

@MainActor
final class OztamStoreTests: XCTestCase {

    private func makeStore() throws -> OztamStore {
        let defaults = UserDefaults(suiteName: "oztam.tests.\(UUID().uuidString)")!
        return OztamStore(store: try SQLiteOztamDeviceStore(path: ":memory:"), defaults: defaults)
    }

    // MARK: - Devices

    func testAddedDeviceIsPersistedAndSelectedByDefault() throws {
        let store = try makeStore()
        store.addDevice(name: "Lounge", kind: .ipAddress, value: "192.168.0.1")
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertTrue(store.devices[0].isSelected)
        XCTAssertEqual(store.selectedDevices.count, 1)
    }

    func testDeviceWithoutIdentifierIsNotATailTarget() throws {
        let store = try makeStore()
        store.addDevice(name: "Empty", kind: .deviceId, value: "  ")
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertTrue(store.selectedDevices.isEmpty)
    }

    func testDeselectingRemovesItFromTailTargets() throws {
        let store = try makeStore()
        let device = store.addDevice(name: "Lounge", kind: .deviceId, value: "abc")
        store.setSelected(false, for: device)
        XCTAssertTrue(store.selectedDevices.isEmpty)
        XCTAssertEqual(store.devices.count, 1)
    }

    func testSetAllSelectedTogglesEveryDevice() throws {
        let store = try makeStore()
        store.addDevice(name: "A", kind: .deviceId, value: "a")
        store.addDevice(name: "B", kind: .sessionId, value: "b")
        store.setAllSelected(false)
        XCTAssertTrue(store.selectedDevices.isEmpty)
        store.setAllSelected(true)
        XCTAssertEqual(store.selectedDevices.count, 2)
    }

    func testUpdatingADeviceKeepsItsIdentity() throws {
        let store = try makeStore()
        var device = store.addDevice(name: "Lounge", kind: .deviceId, value: "abc")
        device.name = "Bedroom"
        store.update(device)
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(store.devices[0].id, device.id)
        XCTAssertEqual(store.devices[0].name, "Bedroom")
    }

    func testRemovingADeviceClearsItsDeviceFilter() throws {
        let store = try makeStore()
        let device = store.addDevice(name: "Lounge", kind: .deviceId, value: "abc")
        store.deviceFilter = device.id
        store.remove(device)
        XCTAssertTrue(store.devices.isEmpty)
        XCTAssertNil(store.deviceFilter)
    }

    // MARK: - Tail preconditions

    func testTailIsBlockedWithoutCredentials() throws {
        let store = try makeStore()
        store.addDevice(name: "Lounge", kind: .deviceId, value: "abc")
        XCTAssertNotNil(store.tailBlocker)
    }

    func testTailIsBlockedWithoutSelectedDevices() throws {
        let store = try makeStore()
        store.userId = "broadcaster"
        store.password = "secret"
        XCTAssertNotNil(store.tailBlocker)
    }

    func testTailIsUnblockedWithCredentialsAndADevice() throws {
        let store = try makeStore()
        store.userId = "broadcaster"
        store.password = "secret"
        store.addDevice(name: "Lounge", kind: .deviceId, value: "abc")
        XCTAssertNil(store.tailBlocker)
    }

    func testStartingWhileBlockedReportsTheReason() throws {
        let store = try makeStore()
        store.startTailing()
        XCTAssertFalse(store.tailState.isTailing)
        XCTAssertNotNil(store.lastError)
    }

    // MARK: - Auto-start

    func testStartTailingIfPossibleDoesNothingWhenBlocked() throws {
        let store = try makeStore()
        store.startTailingIfPossible()
        XCTAssertFalse(store.tailState.isTailing)
        // Unlike startTailing(), the quiet variant must not surface an error.
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.tailState, .idle)
    }

    func testStartTailingIfPossibleStartsWhenConfigured() throws {
        let store = try makeStore()
        store.userId = "broadcaster"
        store.password = "secret"
        store.addDevice(name: "Lounge", kind: .deviceId, value: "abc")
        store.startTailingIfPossible()
        XCTAssertTrue(store.tailState.isTailing)
        store.stopTailing()
    }

    func testDiagnosticsResetWhenTailingStarts() throws {
        let store = try makeStore()
        store.userId = "broadcaster"
        store.password = "secret"
        store.addDevice(name: "Lounge", kind: .deviceId, value: "abc")
        store.startTailing()
        XCTAssertEqual(store.pollCount, 0)
        XCTAssertNil(store.lastPollAt)
        XCTAssertTrue(store.diagnostics.isEmpty)
        store.stopTailing()
    }

    // MARK: - Diagnostic summaries

    func testDiagnosticSummaryDistinguishesEmptyFromUnparsed() {
        func summary(_ outcome: OztamPollDiagnostic.Outcome) -> String {
            OztamPollDiagnostic(deviceID: UUID(), deviceName: "TV", outcome: outcome,
                                polledAt: Date(), totalRows: 0, cursor: Date(),
                                requestURL: nil).summary
        }
        XCTAssertEqual(summary(.answered(meterEvents: 0, rows: 0)),
                       "200 · no events in window")
        XCTAssertEqual(summary(.answered(meterEvents: 3, rows: 0)),
                       "200 · 3 meter events, no rows parsed")
        XCTAssertEqual(summary(.answered(meterEvents: 3, rows: 7)),
                       "200 · 3 meter events → 7 rows")
        XCTAssertEqual(summary(.failed("OzTAM returned HTTP 500.")),
                       "OzTAM returned HTTP 500.")
    }

    func testDiagnosticOutcomeFailureFlag() {
        XCTAssertTrue(OztamPollDiagnostic.Outcome.failed("x").isFailure)
        XCTAssertFalse(OztamPollDiagnostic.Outcome.answered(meterEvents: 0, rows: 0).isFailure)
    }

    // MARK: - Settings

    func testEnvironmentDefaultsToStaging() throws {
        XCTAssertEqual(try makeStore().environment, .staging)
    }

    func testPollAndHistoryDefaultsMatchRunoztail() throws {
        let store = try makeStore()
        XCTAssertEqual(store.pollSeconds, 5)
        XCTAssertEqual(store.historyMinutes, 100)
    }

    func testSettingsPersistAcrossStoreInstances() throws {
        let defaults = UserDefaults(suiteName: "oztam.tests.\(UUID().uuidString)")!
        let sqlite = try SQLiteOztamDeviceStore(path: ":memory:")
        let first = OztamStore(store: sqlite, defaults: defaults)
        first.environment = .production
        first.pollSeconds = 12
        first.historyMinutes = 30
        first.userId = "broadcaster"

        let second = OztamStore(store: sqlite, defaults: defaults)
        XCTAssertEqual(second.environment, .production)
        XCTAssertEqual(second.pollSeconds, 12)
        XCTAssertEqual(second.historyMinutes, 30)
        XCTAssertEqual(second.userId, "broadcaster")
    }

    // MARK: - Filters

    private func event(severity: OztamSeverity = .ok,
                       name: String = "LOAD",
                       deviceID: UUID = UUID(),
                       mediaId: String = "media-1") -> OztamEvent {
        OztamEvent(
            id: UUID(), deviceID: deviceID, deviceName: "Lounge",
            timestamp: Date(), createdAt: Date(),
            vendorVersion: "10play_android_7.6.0",
            sessionId: "sess-1", publisherId: "pub-1", mediaId: mediaId,
            event: name, fromPosition: nil, toPosition: nil,
            severity: severity, detail: nil,
            propertiesDeviceId: nil, demo1: nil, rawJSON: "{}"
        )
    }

    private func matches(_ event: OztamEvent,
                         severities: Set<OztamSeverity> = Set(OztamSeverity.allCases),
                         eventTypes: Set<String> = [],
                         device: UUID? = nil,
                         needle: String = "") -> Bool {
        OztamStore.matches(event, severities: severities, eventTypes: eventTypes,
                           device: device, needle: needle)
    }

    func testSeverityFilterExcludesUnselectedSeverities() {
        XCTAssertFalse(matches(event(severity: .ok), severities: [.error]))
        XCTAssertTrue(matches(event(severity: .error), severities: [.error]))
    }

    func testEmptyEventTypeFilterMatchesEverything() {
        XCTAssertTrue(matches(event(name: "PROGRESS")))
    }

    func testEventTypeFilterRestrictsToSelectedNames() {
        XCTAssertTrue(matches(event(name: "LOAD"), eventTypes: ["LOAD", "BEGIN"]))
        XCTAssertFalse(matches(event(name: "COMPLETE"), eventTypes: ["LOAD", "BEGIN"]))
    }

    func testDeviceFilterRestrictsToOneDevice() {
        let wanted = UUID()
        XCTAssertTrue(matches(event(deviceID: wanted), device: wanted))
        XCTAssertFalse(matches(event(deviceID: UUID()), device: wanted))
    }

    func testSearchMatchesPayloadFieldsCaseInsensitively() {
        XCTAssertTrue(matches(event(mediaId: "MEDIA-42"), needle: "media-42"))
        XCTAssertFalse(matches(event(mediaId: "MEDIA-42"), needle: "media-99"))
    }

    func testFiltersCombineAsAnAnd() {
        let wanted = UUID()
        let candidate = event(severity: .warning, name: "LOAD", deviceID: wanted)
        XCTAssertTrue(matches(candidate, severities: [.warning], eventTypes: ["LOAD"],
                              device: wanted, needle: "sess-1"))
        XCTAssertFalse(matches(candidate, severities: [.warning], eventTypes: ["BEGIN"],
                               device: wanted, needle: "sess-1"))
    }

    func testResetFiltersRestoresDefaults() throws {
        let store = try makeStore()
        store.severityFilter = [.error]
        store.eventTypeFilter = ["LOAD"]
        store.searchText = "abc"
        XCTAssertTrue(store.hasActiveFilters)

        store.resetFilters()
        XCTAssertFalse(store.hasActiveFilters)
        XCTAssertEqual(store.severityFilter, Set(OztamSeverity.allCases))
        XCTAssertTrue(store.eventTypeFilter.isEmpty)
        XCTAssertEqual(store.searchText, "")
    }

    func testToggleSeverityAddsAndRemoves() throws {
        let store = try makeStore()
        store.toggle(.error)
        XCTAssertFalse(store.severityFilter.contains(.error))
        store.toggle(.error)
        XCTAssertTrue(store.severityFilter.contains(.error))
    }
}
