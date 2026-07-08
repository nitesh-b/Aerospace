//
//  APIClientTests.swift
//  AerospaceTests
//
//  Exercises APIClient's response mapping using a stub URLProtocol, so the
//  status/header/body/JSON-detection logic is covered without live network.
//

import XCTest
@testable import Aerospace

/// A URLProtocol that returns a canned response configured per-test.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class APIClientTests: XCTestCase {

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return APIClient(session: URLSession(configuration: config))
    }

    private func get() -> URLRequest {
        URLRequest(url: URL(string: "https://stub.local/x")!)
    }

    func testSuccessJSON() async {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.headers = ["Content-Type": "application/json"]
        StubURLProtocol.body = Data("{\"ok\":true}".utf8)

        let response = await makeClient().send(get())
        XCTAssertEqual(response.outcome, .success)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.isBodyJSON)
        XCTAssertEqual(response.bodyByteCount, 11)
        XCTAssertTrue(response.headers.contains { $0.name.lowercased() == "content-type" })
    }

    func testServerErrorIsSuccessOutcomeWithCode() async {
        StubURLProtocol.statusCode = 500
        StubURLProtocol.headers = [:]
        StubURLProtocol.body = Data("boom".utf8)

        let response = await makeClient().send(get())
        // A reachable 500 is a successful round trip, not a transport failure.
        XCTAssertEqual(response.outcome, .success)
        XCTAssertEqual(response.statusCode, 500)
        XCTAssertFalse(response.isBodyJSON)
    }

    func testJSONDetectedWithoutContentType() async {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.headers = [:]
        StubURLProtocol.body = Data("[1,2,3]".utf8)

        let response = await makeClient().send(get())
        XCTAssertTrue(response.isBodyJSON)   // sniffed by content
    }

    func testPlainTextNotJSON() async {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.headers = ["Content-Type": "text/plain"]
        StubURLProtocol.body = Data("hello world".utf8)

        let response = await makeClient().send(get())
        XCTAssertFalse(response.isBodyJSON)
        XCTAssertEqual(response.bodyText, "hello world")
    }
}
