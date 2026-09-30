//
//  OztamClientTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class OztamClientTests: XCTestCase {

    private let credentials = OztamCredentials(userId: "broadcaster", password: "secret")

    private func queryItems(_ request: URLRequest) -> [String: String] {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }

    func testRequestTargetsTheIPAddressEndpointWithHashedAddress() throws {
        let device = OztamDevice(name: "TV", kind: .ipAddress, value: "192.168.0.1")
        let request = try OztamClient.makeRequest(host: OztamEnvironment.staging.host,
                                                  device: device,
                                                  fromDate: Date(),
                                                  credentials: credentials)
        XCTAssertEqual(request.url?.path, "/api/events/ipaddress")
        XCTAssertEqual(request.url?.host, "stail.oztam.com.au")
        XCTAssertEqual(queryItems(request)["remoteAddress"], "f0fdb4c3f58e3e3f8e77162d893d3055")
    }

    func testRequestTargetsTheSessionEndpoint() throws {
        let device = OztamDevice(name: "Repro", kind: .sessionId, value: "sess-9")
        let request = try OztamClient.makeRequest(host: OztamEnvironment.production.host,
                                                  device: device,
                                                  fromDate: Date(),
                                                  credentials: credentials)
        XCTAssertEqual(request.url?.path, "/api/events/sessions")
        XCTAssertEqual(request.url?.host, "tail.oztam.com.au")
        XCTAssertEqual(queryItems(request)["sessionId"], "sess-9")
    }

    func testRequestTargetsTheOzTAMDeviceEndpoint() throws {
        let device = OztamDevice(name: "Meter", kind: .oztamDeviceId, value: "oz-1")
        let request = try OztamClient.makeRequest(host: OztamEnvironment.staging.host,
                                                  device: device,
                                                  fromDate: Date(),
                                                  credentials: credentials)
        XCTAssertEqual(request.url?.path, "/api/events/oztamdevices")
        XCTAssertEqual(queryItems(request)["deviceId"], "oz-1")
    }

    func testRequestCarriesBasicAuthHeader() throws {
        let device = OztamDevice(name: "Box", kind: .deviceId, value: "abc")
        let request = try OztamClient.makeRequest(host: OztamEnvironment.staging.host,
                                                  device: device,
                                                  fromDate: Date(),
                                                  credentials: credentials)
        let expected = "Basic " + Data("broadcaster:secret".utf8).base64EncodedString()
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expected)
    }

    func testRequestCarriesFromDateCursor() throws {
        let device = OztamDevice(name: "Box", kind: .deviceId, value: "abc")
        let cursor = Date(timeIntervalSince1970: 1_759_200_000)
        let request = try OztamClient.makeRequest(host: OztamEnvironment.staging.host,
                                                  device: device,
                                                  fromDate: cursor,
                                                  credentials: credentials)
        XCTAssertEqual(queryItems(request)["fromDate"],
                       OztamClient.cursorFormatter.string(from: cursor))
    }

    func testQueryEncodingMatchesEncodeURIComponent() {
        // The exact output of JavaScript's encodeURIComponent, which superagent
        // (and therefore oztail) applies to every query value.
        XCTAssertEqual(OztamClient.encodeQueryComponent("2026-09-30T13:05:00+10:00"),
                       "2026-09-30T13%3A05%3A00%2B10%3A00")
        XCTAssertEqual(OztamClient.encodeQueryComponent("a b&c=d"), "a%20b%26c%3Dd")
        XCTAssertEqual(OztamClient.encodeQueryComponent("-_.!~*'()"), "-_.!~*'()")
        XCTAssertEqual(OztamClient.encodeQueryComponent("abc123"), "abc123")
    }

    func testFromDateEscapesThePlusInTheTimezoneOffset() throws {
        // A raw `+` would be decoded server-side as a space, corrupting the
        // offset and making OzTAM return no events.
        let device = OztamDevice(name: "Box", kind: .deviceId, value: "abc")
        let url = try OztamClient.makeURL(host: OztamEnvironment.staging.host,
                                          device: device,
                                          fromDate: Date())
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedQuery)
        XCTAssertFalse(query.contains("+"), "raw + in query: \(query)")
        XCTAssertFalse(query.contains(":"), "raw : in query: \(query)")
    }

    func testFromDateStillDecodesBackToTheOriginalStamp() throws {
        let device = OztamDevice(name: "Box", kind: .deviceId, value: "abc")
        let cursor = Date(timeIntervalSince1970: 1_759_200_000)
        let url = try OztamClient.makeURL(host: OztamEnvironment.staging.host,
                                          device: device, fromDate: cursor)
        XCTAssertEqual(queryItems(URLRequest(url: url))["fromDate"],
                       OztamClient.cursorFormatter.string(from: cursor))
    }

    func testDeviceIdentifiersWithSpecialCharactersAreEscaped() throws {
        let device = OztamDevice(name: "Odd", kind: .deviceId, value: "a b&c=d")
        let url = try OztamClient.makeURL(host: OztamEnvironment.staging.host,
                                          device: device, fromDate: Date())
        XCTAssertEqual(queryItems(URLRequest(url: url))["deviceId"], "a b&c=d")
    }

    func testCursorFormatIsLocalISO8601WithoutFractionalSeconds() {
        let text = OztamClient.cursorFormatter.string(from: Date(timeIntervalSince1970: 1_759_200_000))
        // e.g. 2026-09-30T12:00:00+10:00 — same shape as moment().format().
        XCTAssertFalse(text.contains("."))
        XCTAssertTrue(text.contains("T"))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: text))
    }

    func testMakeURLCarriesNoCredentials() throws {
        let device = OztamDevice(name: "Box", kind: .deviceId, value: "abc")
        let url = try OztamClient.makeURL(host: OztamEnvironment.staging.host,
                                          device: device,
                                          fromDate: Date())
        let text = url.absoluteString
        XCTAssertFalse(text.contains("broadcaster"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
    }

    func testMakeURLMatchesTheURLTheRequestUses() throws {
        let device = OztamDevice(name: "Box", kind: .deviceId, value: "abc")
        let cursor = Date(timeIntervalSince1970: 1_759_200_000)
        let url = try OztamClient.makeURL(host: OztamEnvironment.staging.host,
                                          device: device, fromDate: cursor)
        let request = try OztamClient.makeRequest(host: OztamEnvironment.staging.host,
                                                  device: device, fromDate: cursor,
                                                  credentials: credentials)
        XCTAssertEqual(request.url, url)
    }

    func testRequestForDeviceWithoutIdentifierThrows() {
        let device = OztamDevice(name: "Empty", kind: .deviceId, value: "   ")
        XCTAssertThrowsError(try OztamClient.makeRequest(host: OztamEnvironment.staging.host,
                                                         device: device,
                                                         fromDate: Date(),
                                                         credentials: credentials)) { error in
            XCTAssertEqual(error as? OztamClientError, .invalidURL)
        }
    }
}
