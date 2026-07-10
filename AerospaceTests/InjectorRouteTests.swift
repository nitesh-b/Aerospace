//
//  InjectorRouteTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class InjectorRouteTests: XCTestCase {

    func testMatchesCheckWithAllParams() {
        let route = InjectorRoute.match(method: "GET",
            path: "/injector/check?app=myapp&platform=ios&channel=staging&nativeVersion=3.2.0")
        XCTAssertEqual(route, .check(app: "myapp", platform: "ios", channel: "staging", nativeVersion: "3.2.0"))
    }

    func testCheckDefaultsNativeVersionWhenMissing() {
        let route = InjectorRoute.match(method: "GET",
            path: "/injector/check?app=myapp&platform=ios&channel=staging")
        XCTAssertEqual(route, .check(app: "myapp", platform: "ios", channel: "staging", nativeVersion: "0"))
    }

    func testCheckMissingRequiredParamIsBadRequest() {
        let route = InjectorRoute.match(method: "GET", path: "/injector/check?app=myapp")
        guard case .badRequest = route else {
            return XCTFail("Expected .badRequest, got \(route)")
        }
    }

    func testMatchesBundleDownload() {
        let route = InjectorRoute.match(method: "GET", path: "/injector/bundle/abc-123")
        XCTAssertEqual(route, .bundleDownload(releaseId: "abc-123"))
    }

    func testMatchesHealth() {
        XCTAssertEqual(InjectorRoute.match(method: "GET", path: "/health"), .health)
        XCTAssertEqual(InjectorRoute.match(method: "HEAD", path: "/health"), .health)
    }

    func testMatchesOptions() {
        XCTAssertEqual(InjectorRoute.match(method: "OPTIONS", path: "/injector/check"), .options)
    }

    func testUnknownRouteIsNotFound() {
        XCTAssertEqual(InjectorRoute.match(method: "GET", path: "/nope"), .notFound)
    }

    func testPostToCheckIsNotFound() {
        XCTAssertEqual(InjectorRoute.match(method: "POST", path: "/injector/check"), .notFound)
    }
}
