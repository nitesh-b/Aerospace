//
//  OztamDeviceTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class OztamDeviceTests: XCTestCase {

    func testIPAddressValueIsMD5Hashed() {
        // The hex digests crypto.createHash('md5') produces in by-address.js.
        XCTAssertEqual(OztamDevice(name: "TV", kind: .ipAddress, value: "192.168.0.1").queryValue,
                       "f0fdb4c3f58e3e3f8e77162d893d3055")
        XCTAssertEqual(OztamDevice(name: "TV", kind: .ipAddress, value: "101.111.12.1").queryValue,
                       "1e91f88d67c5c9eb45f4c5ac0b79b7f1")
    }

    func testIPAddressHashIsStableAndDistinct() {
        let a = OztamDevice(name: "A", kind: .ipAddress, value: "192.168.0.1")
        let b = OztamDevice(name: "B", kind: .ipAddress, value: "192.168.0.1")
        let c = OztamDevice(name: "C", kind: .ipAddress, value: "192.168.0.2")
        XCTAssertEqual(a.queryValue, b.queryValue)
        XCTAssertNotEqual(a.queryValue, c.queryValue)
    }

    func testNonIPAddressValueIsSentAsTyped() {
        // A pre-hashed address pasted into an IP device must not be hashed again.
        let hashed = String(repeating: "a", count: 32)
        let device = OztamDevice(name: "Hashed", kind: .ipAddress, value: hashed)
        XCTAssertEqual(device.queryValue, hashed)
    }

    func testDeviceIdValueIsNeverHashed() {
        let device = OztamDevice(name: "Box", kind: .deviceId, value: "abc-123")
        XCTAssertEqual(device.queryValue, "abc-123")
    }

    func testValueIsTrimmedBeforeUse() {
        let device = OztamDevice(name: "Box", kind: .sessionId, value: "  sess-9  ")
        XCTAssertEqual(device.queryValue, "sess-9")
    }

    func testIsIPAddressMatchesOztailFourComponentRule() {
        XCTAssertTrue(OztamDevice.isIPAddress("1.2.3.4"))
        XCTAssertTrue(OztamDevice.isIPAddress("1.2.3."))
        XCTAssertFalse(OztamDevice.isIPAddress("1.2.3"))
        XCTAssertFalse(OztamDevice.isIPAddress("deadbeef"))
    }

    func testEndpointsAndQueryNamesMatchOztail() {
        XCTAssertEqual(OztamDeviceKind.ipAddress.endpointPath, "/api/events/ipaddress")
        XCTAssertEqual(OztamDeviceKind.ipAddress.queryName, "remoteAddress")
        XCTAssertEqual(OztamDeviceKind.deviceId.endpointPath, "/api/events/devices")
        XCTAssertEqual(OztamDeviceKind.deviceId.queryName, "deviceId")
        XCTAssertEqual(OztamDeviceKind.sessionId.endpointPath, "/api/events/sessions")
        XCTAssertEqual(OztamDeviceKind.sessionId.queryName, "sessionId")
        XCTAssertEqual(OztamDeviceKind.oztamDeviceId.endpointPath, "/api/events/oztamdevices")
        XCTAssertEqual(OztamDeviceKind.oztamDeviceId.queryName, "deviceId")
    }

    func testDisplayNameFallsBackToIdentifier() {
        let unnamed = OztamDevice(name: "   ", kind: .deviceId, value: "abc-123")
        XCTAssertEqual(unnamed.displayName, "abc-123")
        let named = OztamDevice(name: "Lounge", kind: .deviceId, value: "abc-123")
        XCTAssertEqual(named.displayName, "Lounge")
    }

    func testIsUsableRequiresAnIdentifier() {
        XCTAssertFalse(OztamDevice(name: "Empty", kind: .deviceId, value: "   ").isUsable)
        XCTAssertTrue(OztamDevice(name: "Set", kind: .deviceId, value: "x").isUsable)
    }

    func testEnvironmentHosts() {
        XCTAssertEqual(OztamEnvironment.staging.hostString, "https://stail.oztam.com.au")
        XCTAssertEqual(OztamEnvironment.production.hostString, "https://tail.oztam.com.au")
    }
}
