import XCTest
import AppKit
@testable import Aerospace

final class JsonHighlighterTests: XCTestCase {
    func testPrettyPrintsAndSortsKeys() {
        let out = JSONHighlighter.pretty("{\"b\":1,\"a\":2}")
        XCTAssertTrue(out.contains("\"a\""))
        XCTAssertTrue(out.contains("\n"))               // pretty-printed
        XCTAssertLessThan(out.range(of: "\"a\"")!.lowerBound,
                          out.range(of: "\"b\"")!.lowerBound) // sorted keys
    }

    func testInvalidJSONReturnedVerbatim() {
        XCTAssertEqual(JSONHighlighter.pretty("not json"), "not json")
    }

    func testAttributedContainsFullText() {
        let attr = JSONHighlighter.attributed("{\"a\":1}", font: .monospacedSystemFont(ofSize: 12, weight: .regular), textColor: .textColor)
        XCTAssertTrue(attr.string.contains("\"a\""))
    }
}
