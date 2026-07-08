//
//  RequestBuilderTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class RequestBuilderTests: XCTestCase {

    private let builder = RequestBuilder()

    private func request(_ url: String, method: HTTPMethod = .get) -> SavedRequest {
        SavedRequest(method: method, urlString: url)
    }

    // MARK: - URL / scheme

    func testEmptyURLThrows() {
        XCTAssertThrowsError(try builder.makeURLRequest(from: request("   "))) {
            XCTAssertEqual($0 as? RequestBuilder.BuildError, .emptyURL)
        }
    }

    func testMissingSchemeThrows() {
        XCTAssertThrowsError(try builder.makeURLRequest(from: request("example.com/path"))) {
            XCTAssertEqual($0 as? RequestBuilder.BuildError, .missingScheme)
        }
    }

    func testValidURLAndMethod() throws {
        let req = try builder.makeURLRequest(from: request("https://example.com/x", method: .post))
        XCTAssertEqual(req.url?.absoluteString, "https://example.com/x")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.timeoutInterval, 30)
    }

    func testHTTPAndLocalhostAllowed() throws {
        let req = try builder.makeURLRequest(from: request("http://localhost:57333/log", method: .post))
        XCTAssertEqual(req.url?.scheme, "http")
        XCTAssertEqual(req.url?.host, "localhost")
    }

    // MARK: - Query params

    func testEnabledQueryParamsAppended() throws {
        var r = request("https://example.com")
        r.queryParams = [
            KeyValueItem(key: "limit", value: "100"),
            KeyValueItem(key: "page", value: "1"),
        ]
        let req = try builder.makeURLRequest(from: r)
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(Set(items.map { "\($0.name)=\($0.value ?? "")" }), ["limit=100", "page=1"])
    }

    func testDisabledAndBlankKeyParamsSkipped() throws {
        var r = request("https://example.com")
        r.queryParams = [
            KeyValueItem(key: "a", value: "1"),
            KeyValueItem(key: "b", value: "2", isEnabled: false),
            KeyValueItem(key: "", value: "3"),
        ]
        let req = try builder.makeURLRequest(from: r)
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "a")
    }

    func testPreservesExistingQueryInURL() throws {
        var r = request("https://example.com/search?q=swift")
        r.queryParams = [KeyValueItem(key: "page", value: "2")]
        let req = try builder.makeURLRequest(from: r)
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.name == "q" && $0.value == "swift" })
        XCTAssertTrue(items.contains { $0.name == "page" && $0.value == "2" })
    }

    func testDuplicateQueryKeysKept() throws {
        var r = request("https://example.com")
        r.queryParams = [KeyValueItem(key: "tag", value: "a"), KeyValueItem(key: "tag", value: "b")]
        let req = try builder.makeURLRequest(from: r)
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.filter { $0.name == "tag" }.count, 2)
    }

    func testQueryValuePercentEncoded() throws {
        var r = request("https://example.com")
        r.queryParams = [KeyValueItem(key: "q", value: "a b&c")]
        let req = try builder.makeURLRequest(from: r)
        // The raw URL must be percent-encoded exactly once.
        XCTAssertTrue(req.url!.absoluteString.contains("q=a%20b%26c"))
    }

    // MARK: - Headers

    func testEnabledHeadersAddedIncludingDuplicates() throws {
        var r = request("https://example.com")
        r.headers = [
            KeyValueItem(key: "X-A", value: "1"),
            KeyValueItem(key: "X-A", value: "2"),
            KeyValueItem(key: "X-B", value: "3", isEnabled: false),
        ]
        let req = try builder.makeURLRequest(from: r)
        // Duplicate keys are combined (comma-separated; spacing is Foundation-defined).
        let combined = req.value(forHTTPHeaderField: "X-A") ?? ""
        XCTAssertTrue(combined.contains("1") && combined.contains("2"), "got \(combined)")
        XCTAssertNil(req.value(forHTTPHeaderField: "X-B"))
    }

    // MARK: - Auth

    func testBearerInjectedWhenSet() throws {
        var r = request("https://example.com")
        r.authKind = .bearer
        r.bearerToken = "xyz"
        let req = try builder.makeURLRequest(from: r)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer xyz")
    }

    func testNoBearerWhenNoneOrEmpty() throws {
        var r = request("https://example.com")
        r.authKind = .none
        r.bearerToken = "xyz"
        XCTAssertNil(try builder.makeURLRequest(from: r).value(forHTTPHeaderField: "Authorization"))

        r.authKind = .bearer
        r.bearerToken = "   "
        XCTAssertNil(try builder.makeURLRequest(from: r).value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Body & Content-Type

    func testJSONBodyAutoContentType() throws {
        var r = request("https://example.com", method: .post)
        r.bodyKind = .json
        r.bodyText = "{\"a\":1}"
        let req = try builder.makeURLRequest(from: r)
        XCTAssertEqual(req.httpBody, Data("{\"a\":1}".utf8))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testUserContentTypeNotOverridden() throws {
        var r = request("https://example.com", method: .post)
        r.bodyKind = .json
        r.bodyText = "{}"
        r.headers = [KeyValueItem(key: "Content-Type", value: "application/vnd.api+json")]
        let req = try builder.makeURLRequest(from: r)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/vnd.api+json")
    }

    func testRawBodyNoAutoContentType() throws {
        var r = request("https://example.com", method: .post)
        r.bodyKind = .raw
        r.bodyText = "hello"
        let req = try builder.makeURLRequest(from: r)
        XCTAssertEqual(req.httpBody, Data("hello".utf8))
        XCTAssertNil(req.value(forHTTPHeaderField: "Content-Type"))
    }

    func testNoneBodyOmitsBody() throws {
        var r = request("https://example.com", method: .post)
        r.bodyKind = .none
        r.bodyText = "ignored"
        XCTAssertNil(try builder.makeURLRequest(from: r).httpBody)
    }

    func testGETBodyRetained() throws {
        var r = request("https://example.com", method: .get)
        r.bodyKind = .raw
        r.bodyText = "body"
        XCTAssertEqual(try builder.makeURLRequest(from: r).httpBody, Data("body".utf8))
    }
}
