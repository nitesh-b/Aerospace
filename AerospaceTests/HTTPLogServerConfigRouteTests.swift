//
//  HTTPLogServerConfigRouteTests.swift
//  AerospaceTests
//
//  End-to-end over loopback: the Logger server hosting the dynamic config at
//  /config/dynamic_config.json.
//

import XCTest
@testable import Aerospace

final class HTTPLogServerConfigRouteTests: XCTestCase {

    private var server: HTTPLogServer!
    private var port: UInt16 = 0
    private let host = DynamicConfigHost()
    private let requests = RequestRecorder()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [DynamicConfigRequest] = []
        func append(_ r: DynamicConfigRequest) { lock.lock(); items.append(r); lock.unlock() }
        var all: [DynamicConfigRequest] { lock.lock(); defer { lock.unlock() }; return items }
    }

    override func setUpWithError() throws {
        server = HTTPLogServer()
        let running = expectation(description: "server running")
        let box = HTTPLogServerFilesRouteTests.PortBox()
        server.onStateChange = { state in
            if case .running(let p) = state, box.set(p) { running.fulfill() }
        }
        let recorder = requests
        server.setConfigHandling(host: host, onRequest: { recorder.append($0) })
        server.start(port: 0)
        wait(for: [running], timeout: 5)
        port = box.port
        XCTAssertNotEqual(port, 0)
    }

    override func tearDownWithError() throws {
        server.stop()
    }

    private func fetch(_ path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    func testServesTheDocument() async throws {
        host.update(document: Data(sampleDynamicConfig.utf8), isEnabled: true)
        let (data, response) = try await fetch("/config/dynamic_config.json")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), sampleDynamicConfig)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
    }

    func testIgnoresQueryString() async throws {
        host.update(document: Data(#"{"a": 1}"#.utf8), isEnabled: true)
        let (_, response) = try await fetch("/config/dynamic_config.json?platform=roku&t=1")
        XCTAssertEqual(response.statusCode, 200)
    }

    func testServesTheLatestDocument() async throws {
        host.update(document: Data(#"{"a": 1}"#.utf8), isEnabled: true)
        _ = try await fetch("/config/dynamic_config.json")
        host.update(document: Data(#"{"a": 2}"#.utf8), isEnabled: true)
        let (data, _) = try await fetch("/config/dynamic_config.json")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a": 2}"#)
    }

    func testHeadSendsNoBody() async throws {
        host.update(document: Data(sampleDynamicConfig.utf8), isEnabled: true)
        let (data, response) = try await fetch("/config/dynamic_config.json", method: "HEAD")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), String(sampleDynamicConfig.utf8.count))
    }

    func testHostingOffIsNotFound() async throws {
        host.update(document: Data(sampleDynamicConfig.utf8), isEnabled: false)
        let (data, response) = try await fetch("/config/dynamic_config.json")
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("turned off"))
    }

    func testNoConfigIsNotFound() async throws {
        host.update(document: nil, isEnabled: true)
        let (data, response) = try await fetch("/config/dynamic_config.json")
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("No dynamic config"))
    }

    func testOtherConfigPathsAreNotRouted() async throws {
        host.update(document: Data(sampleDynamicConfig.utf8), isEnabled: true)
        let (_, response) = try await fetch("/config/other.json")
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertTrue(requests.all.isEmpty)
    }

    func testRecordsRequests() async throws {
        host.update(document: Data(#"{"a": 1}"#.utf8), isEnabled: true)
        _ = try await fetch("/config/dynamic_config.json?x=1")
        host.update(document: Data(#"{"a": 1}"#.utf8), isEnabled: false)
        _ = try await fetch("/config/dynamic_config.json")

        let recorded = requests.all
        XCTAssertEqual(recorded.map(\.status), [200, 404])
        XCTAssertEqual(recorded.map(\.bytes), [8, 0])
        XCTAssertEqual(recorded.first?.path, "/config/dynamic_config.json?x=1")
        XCTAssertEqual(recorded.first?.method, "GET")
        XCTAssertEqual(recorded.first?.client, "127.0.0.1")
    }

    func testPathMatching() {
        XCTAssertTrue(DynamicConfigHost.handles(requestPath: "/config/dynamic_config.json"))
        XCTAssertTrue(DynamicConfigHost.handles(requestPath: "/config/dynamic_config.json?platform=roku"))
        XCTAssertFalse(DynamicConfigHost.handles(requestPath: "/config/dynamic_config.json/x"))
        XCTAssertFalse(DynamicConfigHost.handles(requestPath: "/config/"))
        XCTAssertFalse(DynamicConfigHost.handles(requestPath: "/files/config/dynamic_config.json"))
        XCTAssertEqual(DynamicConfigHost.url(host: "192.168.1.5", port: 57333),
                       "http://192.168.1.5:57333/config/dynamic_config.json")
    }
}
