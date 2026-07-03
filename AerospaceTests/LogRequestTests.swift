//
//  LogRequestTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class LogRequestTests: XCTestCase {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    func testParsesObjectPayload() throws {
        let event = try LogRequest.makeEvent(from: body("""
        {"arg1":"Authentication","arg2":"Login","arg3":{"userId":123,"status":"success"}}
        """))
        XCTAssertEqual(event.category, "Authentication")
        XCTAssertEqual(event.subCategory, "Login")
        // Re-serialized with sorted keys.
        XCTAssertEqual(event.payload, "{\"status\":\"success\",\"userId\":123}")
        XCTAssertEqual(event.level, .info)
    }

    func testExtractsLevelFromPayload() throws {
        let event = try LogRequest.makeEvent(from: body("""
        {"arg1":"API","arg2":"Error","arg3":{"level":"error","code":500}}
        """))
        XCTAssertEqual(event.level, .error)
    }

    func testExtractsSessionAndApplication() throws {
        let event = try LogRequest.makeEvent(from: body("""
        {"arg1":"API","arg2":"Request","arg3":{"sessionId":"abc123","application":"DesktopClient"}}
        """))
        XCTAssertEqual(event.sessionId, "abc123")
        XCTAssertEqual(event.application, "DesktopClient")
    }

    func testStringPayloadPreserved() throws {
        let event = try LogRequest.makeEvent(from: body("""
        {"arg1":"Cat","arg2":"Sub","arg3":"just a string"}
        """))
        XCTAssertEqual(event.payload, "just a string")
    }

    func testMissingArg3BecomesEmptyObject() throws {
        let event = try LogRequest.makeEvent(from: body("""
        {"arg1":"Cat","arg2":"Sub"}
        """))
        XCTAssertEqual(event.payload, "{}")
    }

    func testTopLevelLevelFallback() throws {
        let event = try LogRequest.makeEvent(from: body("""
        {"arg1":"Cat","arg2":"Sub","arg3":"x","level":"warning"}
        """))
        XCTAssertEqual(event.level, .warning)
    }

    func testMissingCategoryThrows() {
        XCTAssertThrowsError(try LogRequest.makeEvent(from: body("""
        {"arg2":"Sub","arg3":{}}
        """))) { XCTAssertEqual($0 as? LogRequestError, .missingCategory) }
    }

    func testMissingSubCategoryThrows() {
        XCTAssertThrowsError(try LogRequest.makeEvent(from: body("""
        {"arg1":"Cat","arg3":{}}
        """))) { XCTAssertEqual($0 as? LogRequestError, .missingSubCategory) }
    }

    func testEmptyBodyThrows() {
        XCTAssertThrowsError(try LogRequest.makeEvent(from: Data())) {
            XCTAssertEqual($0 as? LogRequestError, .emptyBody)
        }
    }

    func testNonJSONThrows() {
        XCTAssertThrowsError(try LogRequest.makeEvent(from: body("not json"))) {
            XCTAssertEqual($0 as? LogRequestError, .notJSONObject)
        }
    }

    func testNumericArgsCoerced() throws {
        let event = try LogRequest.makeEvent(from: body("""
        {"arg1":42,"arg2":7,"arg3":{}}
        """))
        XCTAssertEqual(event.category, "42")
        XCTAssertEqual(event.subCategory, "7")
    }
}

final class LogLevelTests: XCTestCase {
    func testAliases() {
        XCTAssertEqual(LogLevel(parsing: "WARN"), .warning)
        XCTAssertEqual(LogLevel(parsing: "err"), .error)
        XCTAssertEqual(LogLevel(parsing: "fatal"), .critical)
        XCTAssertEqual(LogLevel(parsing: "trace"), .debug)
        XCTAssertEqual(LogLevel(parsing: nil), .info)
        XCTAssertEqual(LogLevel(parsing: ""), .info)
        XCTAssertEqual(LogLevel(parsing: "nonsense"), .info)
    }

    func testOrdering() {
        XCTAssertTrue(LogLevel.debug < LogLevel.critical)
        XCTAssertTrue(LogLevel.error >= LogLevel.error)
        XCTAssertTrue(LogLevel.warning < LogLevel.error)
    }
}
