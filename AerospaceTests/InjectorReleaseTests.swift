//
//  InjectorReleaseTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class InjectorReleaseTests: XCTestCase {

    private func release(min: String = "1.0.0", max: String = "1.x", createdAt: Date = Date(timeIntervalSince1970: 0)) -> InjectorRelease {
        InjectorRelease(id: "r1", app: "myapp", platform: "ios", channel: "staging",
                        version: "1", minNativeVersion: min, maxNativeVersion: max,
                        bundleHash: "abc123", bundlePath: "/tmp/x", createdAt: createdAt)
    }

    func testIsCompatibleDelegatesToInjectorVersion() {
        let r = release(min: "1.0.0", max: "1.x")
        XCTAssertTrue(r.isCompatible(withNativeVersion: "1.5.0"))
        XCTAssertFalse(r.isCompatible(withNativeVersion: "2.0.0"))
    }

    func testEquatable() {
        XCTAssertEqual(release(), release())
    }
}
