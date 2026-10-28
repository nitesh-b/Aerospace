//
//  JSONFieldTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class JSONFieldTests: XCTestCase {

    /// Laid out the way the response body shows it.
    private let body = JSONHighlighter.pretty(#"""
    {"token": "abc.def", "expires": 3600, "ok": true, "none": null,
     "user": {"id": 42, "name": "Ann \"A\" Lee", "tags": ["a", "b"]},
     "items": [{"sku": "X1"}, {"sku": "Y2"}], "url": "https://example.com/a/b", "emoji": "😀 hi"}
    """#)

    private func range(of needle: String, occurrence: Int = 0) -> NSRange {
        let ns = body as NSString
        var search = NSRange(location: 0, length: ns.length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = ns.range(of: needle, range: search)
            precondition(found.location != NSNotFound, "\(needle) not in body")
            search = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
        }
        return found
    }

    private func field(selecting needle: String, occurrence: Int = 0) -> JSONField? {
        JSONField.locate(in: body, selection: range(of: needle, occurrence: occurrence))
    }

    private func field(caretBefore needle: String) -> JSONField? {
        JSONField.locate(in: body, selection: NSRange(location: range(of: needle).location, length: 0))
    }

    func testSelectingTheValueGivesTheMember() {
        XCTAssertEqual(field(selecting: "abc.def"), JSONField(key: "token", value: "abc.def"))
    }

    func testSelectingTheKeyGivesTheMember() {
        XCTAssertEqual(field(selecting: "token"), JSONField(key: "token", value: "abc.def"))
        XCTAssertEqual(field(selecting: #""token""#), JSONField(key: "token", value: "abc.def"))
    }

    func testSelectingTheWholeLineIgnoresIndentAndComma() {
        let line = range(of: #""token" : "abc.def","#)
        let withIndent = NSRange(location: line.location - 2, length: line.length + 3)   // leading spaces, trailing newline
        XCTAssertEqual(JSONField.locate(in: body, selection: withIndent), JSONField(key: "token", value: "abc.def"))
    }

    func testCaretInsideAValue() {
        XCTAssertEqual(field(caretBefore: "def"), JSONField(key: "token", value: "abc.def"))
    }

    func testScalarsKeepTheirLiteralText() {
        XCTAssertEqual(field(selecting: "3600"), JSONField(key: "expires", value: "3600"))
        XCTAssertEqual(field(selecting: "true"), JSONField(key: "ok", value: "true"))
        XCTAssertEqual(field(selecting: "null"), JSONField(key: "none", value: "null"))
    }

    func testNestedFieldWinsOverItsParent() {
        XCTAssertEqual(field(selecting: "42"), JSONField(key: "id", value: "42"))
        XCTAssertEqual(field(selecting: "Y2"), JSONField(key: "sku", value: "Y2"))
    }

    func testStringsAreUnescaped() {
        XCTAssertEqual(field(selecting: "Lee"), JSONField(key: "name", value: #"Ann "A" Lee"#))
        XCTAssertEqual(field(selecting: "https://example.com/a/b"), JSONField(key: "url", value: "https://example.com/a/b"))
        XCTAssertEqual(field(selecting: "hi"), JSONField(key: "emoji", value: "😀 hi"))
    }

    func testContainersAreCompactJSON() {
        XCTAssertEqual(field(selecting: "tags"), JSONField(key: "tags", value: #"["a","b"]"#))
        XCTAssertEqual(field(selecting: "user"),
                       JSONField(key: "user", value: #"{"id":42,"name":"Ann \"A\" Lee","tags":["a","b"]}"#))
    }

    func testArrayElementGivesTheArrayMember() {
        XCTAssertEqual(field(selecting: #""b""#), JSONField(key: "tags", value: #"["a","b"]"#))
    }

    func testSelectionAcrossTwoFieldsGivesTheirParent() {
        let id = range(of: #""id""#), name = range(of: "Lee")
        let both = NSRange(location: id.location, length: NSMaxRange(name) - id.location)
        XCTAssertEqual(JSONField.locate(in: body, selection: both)?.key, "user")
    }

    func testNoFieldAtTheTopLevel() {
        XCTAssertNil(JSONField.locate(in: body, selection: NSRange(location: 0, length: 1)))
        XCTAssertNil(JSONField.locate(in: body, selection: NSRange(location: 0, length: (body as NSString).length)))
    }

    func testNotJSON() {
        XCTAssertNil(JSONField.locate(in: "token: abc", selection: NSRange(location: 0, length: 5)))
        XCTAssertNil(JSONField.locate(in: #"{"a": 1"#, selection: NSRange(location: 1, length: 3)))
        XCTAssertNil(JSONField.locate(in: #"{"a": tru}"#, selection: NSRange(location: 1, length: 3)))
        XCTAssertNil(JSONField.locate(in: "", selection: NSRange(location: 0, length: 0)))
    }

    func testOutOfRangeSelection() {
        XCTAssertNil(JSONField.locate(in: #"{"a": 1}"#, selection: NSRange(location: 5, length: 10)))
        XCTAssertNil(JSONField.locate(in: #"{"a": 1}"#, selection: NSRange(location: NSNotFound, length: 0)))
    }

    func testCompactBodyWithoutPrettyPrinting() {
        let text = #"{"a":{"b":[1, 2]},"c":"d"}"#
        let c = (text as NSString).range(of: "d")
        XCTAssertEqual(JSONField.locate(in: text, selection: c), JSONField(key: "c", value: "d"))
        let one = (text as NSString).range(of: "1")
        XCTAssertEqual(JSONField.locate(in: text, selection: one), JSONField(key: "b", value: "[1,2]"))
    }
}
