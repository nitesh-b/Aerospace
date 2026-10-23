//
//  JSONValueTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class JSONValueTests: XCTestCase {

    func testKeepsKeyOrderAndNumberLiterals() throws {
        let value = try JSONValue(parsing: #"{"zeta": 1.50, "alpha": 2500, "mid": -1e3}"#)
        XCTAssertEqual(value.members?.map(\.key), ["zeta", "alpha", "mid"])
        XCTAssertEqual(value["zeta"], .number("1.50"))
        XCTAssertEqual(value["mid"], .number("-1e3"))
    }

    func testParsesAllValueKinds() throws {
        let value = try JSONValue(parsing: #" {"s": "x", "n": 0, "t": true, "f": false, "z": null, "a": [1, {}], "o": {}} "#)
        XCTAssertEqual(value, .object([
            .init(key: "s", value: .string("x")),
            .init(key: "n", value: .number("0")),
            .init(key: "t", value: .bool(true)),
            .init(key: "f", value: .bool(false)),
            .init(key: "z", value: .null),
            .init(key: "a", value: .array([.number("1"), .object([])])),
            .init(key: "o", value: .object([])),
        ]))
    }

    func testStringEscapesRoundTrip() throws {
        let value = try JSONValue(parsing: #"["a\"b\\c\/d", "line\nnext\ttab", "é 😀", "\u0001"]"#)
        XCTAssertEqual(value, .array([
            .string("a\"b\\c/d"), .string("line\nnext\ttab"), .string("é 😀"), .string("\u{01}"),
        ]))
        XCTAssertEqual(value.compactText, #"["a\"b\\c/d", "line\nnext\ttab", "é 😀", "\u0001"]"#)
        XCTAssertEqual(try JSONValue(parsing: value.compactText), value)
    }

    func testURLsAreWrittenWithoutEscapedSlashes() {
        XCTAssertEqual(JSONValue.string("https://10.com.au/a").compactText, #""https://10.com.au/a""#)
    }

    func testFormattedIndentsWithTwoSpaces() {
        let value = JSONValue.object([
            .init(key: "a", value: .object([.init(key: "b", value: .array([.number("1"), .number("2")]))])),
            .init(key: "e", value: .array([])),
        ])
        XCTAssertEqual(value.formatted(), """
        {
          "a": {
            "b": [
              1,
              2
            ]
          },
          "e": []
        }

        """)
        XCTAssertEqual(value.formatted { $0 == .array([.number("1"), .number("2")]) }, """
        {
          "a": {
            "b": [1, 2]
          },
          "e": []
        }

        """)
    }

    func testRejectsDuplicateKeysWithPosition() {
        XCTAssertThrowsError(try JSONValue(parsing: "{\n  \"a\": 1,\n  \"a\": 2\n}")) { error in
            XCTAssertEqual(error as? JSONValue.ParseError,
                           JSONValue.ParseError(message: "Duplicate key \"a\"", line: 3, column: 3))
        }
    }

    func testRejectsInvalidJSON() {
        for text in ["", "{", #"{"a": 1,}"#, "[1 2]", "01", "1.", "tru", #"{"a" 1}"#, "{} {}", "\"\n\"", "'a'"] {
            XCTAssertThrowsError(try JSONValue(parsing: text), text)
        }
    }

    func testSkipsByteOrderMark() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"a": 1}"#.utf8)
        XCTAssertEqual(try JSONValue(data: data)["a"], .number("1"))
    }

    func testNumberLiterals() {
        for valid in ["0", "-0", "10", "2500", "0.5", "-1.25", "1e3", "1E+3", "2.5e-10"] {
            XCTAssertTrue(JSONValue.isNumberLiteral(valid), valid)
        }
        for invalid in ["", "-", "01", "1.", ".5", "+1", "1e", "1 ", "0x10", "NaN", "1,000"] {
            XCTAssertFalse(JSONValue.isNumberLiteral(invalid), invalid)
        }
    }

    func testSetKeepsPositionAndAppendsNewKeys() throws {
        var value = try JSONValue(parsing: #"{"a": 1, "b": 2, "c": 3}"#)
        value.set(.number("20"), forKey: "b")
        value.set(.number("4"), forKey: "d")
        value.set(nil, forKey: "a")
        XCTAssertEqual(value.compactText, #"{ "b": 20, "c": 3, "d": 4 }"#)
    }

    func testSetValueAtPath() throws {
        var value = try JSONValue(parsing: #"{"s": {"x": {"all": 1}}}"#)
        value.setValue(.number("0"), at: ["s", "x", "roku"])
        value.setValue(.number("9"), at: ["missing", "x"])
        XCTAssertEqual(value.compactText, #"{ "s": { "x": { "all": 1, "roku": 0 } } }"#)
        value.setValue(nil, at: ["s", "x"])
        XCTAssertEqual(value.compactText, #"{ "s": {} }"#)
    }

    func testBlankCopyKeepsShape() throws {
        let value = try JSONValue(parsing: #"{"title": "Oops", "code": 5, "on": true, "list": [1]}"#)
        XCTAssertEqual(value.blankCopy.compactText, #"{ "title": "", "code": 0, "on": false, "list": [] }"#)
    }
}
