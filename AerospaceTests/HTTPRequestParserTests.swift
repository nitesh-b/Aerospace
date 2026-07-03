//
//  HTTPRequestParserTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class HTTPRequestParserTests: XCTestCase {

    func testParsesSimplePostWithBody() throws {
        let parser = HTTPRequestParser()
        let json = "{\"arg1\":\"A\"}"
        let raw = "POST /log HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)"
        parser.append(Data(raw.utf8))

        let request = try parser.takeRequest()
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/log")
        XCTAssertEqual(request?.header("content-type"), "application/json")
        XCTAssertEqual(request?.body, Data(json.utf8))
    }

    func testReturnsNilUntilHeadersComplete() throws {
        let parser = HTTPRequestParser()
        parser.append(Data("POST /log HTTP/1.1\r\nContent-Length: 2".utf8))
        XCTAssertNil(try parser.takeRequest())
    }

    func testReturnsNilUntilBodyComplete() throws {
        let parser = HTTPRequestParser()
        parser.append(Data("POST /log HTTP/1.1\r\nContent-Length: 10\r\n\r\nab".utf8))
        XCTAssertNil(try parser.takeRequest())
    }

    func testAssemblesAcrossMultipleChunks() throws {
        let parser = HTTPRequestParser()
        parser.append(Data("POST /log HTTP/1.1\r\nContent-Length: 5\r\n".utf8))
        XCTAssertNil(try parser.takeRequest())
        parser.append(Data("\r\nhel".utf8))
        XCTAssertNil(try parser.takeRequest())
        parser.append(Data("lo".utf8))
        let request = try parser.takeRequest()
        XCTAssertEqual(request?.body, Data("hello".utf8))
    }

    func testGetWithoutBody() throws {
        let parser = HTTPRequestParser()
        parser.append(Data("GET /health HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        let request = try parser.takeRequest()
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/health")
        XCTAssertEqual(request?.body.count, 0)
    }

    func testKeepAlivePipelinedRequests() throws {
        let parser = HTTPRequestParser()
        let r1 = "GET /a HTTP/1.1\r\n\r\n"
        let r2 = "GET /b HTTP/1.1\r\n\r\n"
        parser.append(Data((r1 + r2).utf8))
        XCTAssertEqual(try parser.takeRequest()?.path, "/a")
        XCTAssertEqual(try parser.takeRequest()?.path, "/b")
        XCTAssertNil(try parser.takeRequest())
    }

    func testMalformedRequestLineThrows() {
        let parser = HTTPRequestParser()
        parser.append(Data("GARBAGE\r\n\r\n".utf8))
        XCTAssertThrowsError(try parser.takeRequest())
    }

    func testBodyTooLargeThrows() {
        let parser = HTTPRequestParser(maxBodySize: 4)
        parser.append(Data("POST /log HTTP/1.1\r\nContent-Length: 100\r\n\r\n".utf8))
        XCTAssertThrowsError(try parser.takeRequest()) {
            XCTAssertEqual($0 as? HTTPParseError, .bodyTooLarge)
        }
    }
}
