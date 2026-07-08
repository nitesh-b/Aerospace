//
//  N10SignerTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class N10SignerTests: XCTestCase {

    private let signer = N10Signer()

    // MARK: - HMAC correctness (RFC 4231, Test Case 1)

    func testHMACMatchesRFC4231Vector() {
        // key = 0x0b × 20 bytes, data = "Hi There"
        let keyHex = String(repeating: "0b", count: 20)
        let expected = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        XCTAssertEqual(N10Signer.hmacSHA256Hex(message: "Hi There", keyHex: keyHex), expected)
    }

    func testHMACIsLowercase64HexAndDeterministic() {
        let a = N10Signer.hmacSHA256Hex(message: "1700000000:https://x/y", keyHex: "abcdef01")
        let b = N10Signer.hmacSHA256Hex(message: "1700000000:https://x/y", keyHex: "abcdef01")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testDifferentKeyOrMessageChangesSignature() {
        let base = N10Signer.hmacSHA256Hex(message: "m", keyHex: "00")
        XCTAssertNotEqual(base, N10Signer.hmacSHA256Hex(message: "m", keyHex: "01"))
        XCTAssertNotEqual(base, N10Signer.hmacSHA256Hex(message: "n", keyHex: "00"))
    }

    // MARK: - Hex decoding

    func testHexDecode() {
        XCTAssertEqual(N10Signer.hexDecode("00ff10"), Data([0x00, 0xff, 0x10]))
        XCTAssertEqual(N10Signer.hexDecode("0xAABB"), Data([0xaa, 0xbb]))
        XCTAssertEqual(N10Signer.hexDecode("aa bb"), Data([0xaa, 0xbb]))
        XCTAssertEqual(N10Signer.hexDecode(""), Data())
    }

    // MARK: - User-Agent

    func testUserAgentFormat() {
        let ua = signer.userAgent(.init(appVersion: "3.4.1", systemName: "iOS", systemVersion: "17.2"))
        XCTAssertEqual(ua, "10play/3.4.1 iOS 17.2 UAP")
    }

    // MARK: - Header assembly

    func testHeadersContainAllThreeWithMatchingUserAgent() {
        let device = N10Signer.DeviceInfo(appVersion: "1.0", systemName: "iOS", systemVersion: "17.0")
        let headers = signer.headers(finalURL: "https://api.example.com/x?a=1",
                                     apiKeyHex: "0b0b0b0b", device: device, timestamp: 1_700_000_000)
        XCTAssertEqual(headers["User-Agent"], "10play/1.0 iOS 17.0 UAP")
        XCTAssertEqual(headers["X-Network-Ten-App"], headers["User-Agent"])

        let sig = try! XCTUnwrap(headers["X-N10-SIG"])
        let parts = sig.split(separator: "_")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(String(parts[0]), "1700000000")
        XCTAssertEqual(parts[1].count, 64)
        // Matches the standalone primitive over "<ts>:<url>".
        let expected = N10Signer.hmacSHA256Hex(
            message: "1700000000:https://api.example.com/x?a=1", keyHex: "0b0b0b0b")
        XCTAssertEqual(String(parts[1]), expected)
    }

    func testSignatureHeaderValueShape() {
        let value = signer.signatureHeaderValue(timestamp: 42, url: "https://x", apiKeyHex: "ab")
        XCTAssertTrue(value.hasPrefix("42_"))
    }
}
