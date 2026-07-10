//
//  InjectorVersionTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class InjectorVersionTests: XCTestCase {

    func testIsCompatibleWithinRange() {
        XCTAssertTrue(InjectorVersion.isCompatible(reported: "3.5.0", min: "3.2.0", max: "3.9.0"))
    }

    func testIsCompatibleBelowMin() {
        XCTAssertFalse(InjectorVersion.isCompatible(reported: "3.1.0", min: "3.2.0", max: "3.9.0"))
    }

    func testIsCompatibleAboveMax() {
        XCTAssertFalse(InjectorVersion.isCompatible(reported: "4.0.0", min: "3.2.0", max: "3.9.0"))
    }

    func testIsCompatibleAtExactBounds() {
        XCTAssertTrue(InjectorVersion.isCompatible(reported: "3.2.0", min: "3.2.0", max: "3.9.0"))
        XCTAssertTrue(InjectorVersion.isCompatible(reported: "3.9.0", min: "3.2.0", max: "3.9.0"))
    }

    func testIsCompatibleWithWildcardMaxAllowsAnyMinorPatch() {
        XCTAssertTrue(InjectorVersion.isCompatible(reported: "3.99.4", min: "3.0.0", max: "3.x"))
    }

    func testIsCompatibleWithWildcardMaxExcludesNextMajor() {
        XCTAssertFalse(InjectorVersion.isCompatible(reported: "4.0.0", min: "3.0.0", max: "3.x"))
    }

    func testIsOrderedTrueWhenLowerLessThanUpper() {
        XCTAssertTrue(InjectorVersion.isOrdered("3.2.0", lessOrEqualTo: "3.9.0"))
    }

    func testIsOrderedFalseWhenLowerGreaterThanUpper() {
        XCTAssertFalse(InjectorVersion.isOrdered("3.9.0", lessOrEqualTo: "3.2.0"))
    }

    func testIsOrderedTrueWhenEqual() {
        XCTAssertTrue(InjectorVersion.isOrdered("3.2.0", lessOrEqualTo: "3.2.0"))
    }
}
