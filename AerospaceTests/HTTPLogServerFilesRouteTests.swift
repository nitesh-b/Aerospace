//
//  HTTPLogServerFilesRouteTests.swift
//  AerospaceTests
//
//  End-to-end over loopback: the Logger server serving pause ads at /files/*.
//

import XCTest
@testable import Aerospace

final class HTTPLogServerFilesRouteTests: XCTestCase {

    private var base: URL!
    private var server: HTTPLogServer!
    private var port: UInt16 = 0
    private let resolver = PauseAdFileResolver()
    private let requests = RequestRecorder()
    private let manifest = "ads/sales/2026/brand/10Oct/pause/p-1/v1/manifests/RemoteManifest"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [PauseAdFileRequest] = []
        func append(_ r: PauseAdFileRequest) { lock.lock(); items.append(r); lock.unlock() }
        var all: [PauseAdFileRequest] { lock.lock(); defer { lock.unlock() }; return items }
    }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTTPLogServerFilesRouteTests-\(UUID().uuidString)", isDirectory: true)
        let dir = base.appendingPathComponent(manifest)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data(#"{"loop":false}"#.utf8).write(to: dir.appendingPathComponent("metadata.json"))
        try Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) }).write(to: dir.appendingPathComponent("images/bg.png"))
        resolver.setRoot(base)

        server = HTTPLogServer()
        let running = expectation(description: "server running")
        let box = PortBox()
        server.onStateChange = { state in
            if case .running(let p) = state, box.set(p) { running.fulfill() }
        }
        let recorder = requests
        server.setFileHandling(resolver: resolver, onRequest: { recorder.append($0) })
        server.start(port: 0)
        wait(for: [running], timeout: 5)
        port = box.port
        XCTAssertNotEqual(port, 0)
    }

    final class PortBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var port: UInt16 = 0
        func set(_ p: UInt16) -> Bool { lock.lock(); defer { lock.unlock() }; guard port == 0 else { return false }; port = p; return true }
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: base)
    }

    private func fetch(_ path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    // MARK: - Tests

    func testServesJSONWithHeaders() async throws {
        let (data, response) = try await fetch("/files/\(manifest)/metadata.json")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"loop":false}"#)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    func testServesBinaryIntact() async throws {
        let (data, response) = try await fetch("/files/\(manifest)/images/bg.png")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(data, try Data(contentsOf: base.appendingPathComponent("\(manifest)/images/bg.png")))
    }

    func testHeadReturnsLengthWithoutBody() async throws {
        let (data, response) = try await fetch("/files/\(manifest)/images/bg.png", method: "HEAD")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "300000")
        XCTAssertTrue(data.isEmpty)
    }

    func testMissingFileIs404AndTraversalIs403() async throws {
        let (_, missing) = try await fetch("/files/\(manifest)/nope.json")
        XCTAssertEqual(missing.statusCode, 404)
        let (_, traversal) = try await fetch("/files/ads/%2e%2e/secret.txt")
        XCTAssertEqual(traversal.statusCode, 403)
    }

    func testNoRootIs404WithExplanation() async throws {
        resolver.setRoot(nil)
        let (data, response) = try await fetch("/files/\(manifest)/metadata.json")
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("destination folder"))
    }

    func testExistingRoutesStillWork() async throws {
        let (health, healthResponse) = try await fetch("/health")
        XCTAssertEqual(healthResponse.statusCode, 200)
        XCTAssertTrue(String(decoding: health, as: UTF8.self).contains("healthy"))
        let (_, other) = try await fetch("/nope")
        XCTAssertEqual(other.statusCode, 404)
        let (_, postOnFiles) = try await fetch("/files/\(manifest)/metadata.json", method: "POST")
        XCTAssertEqual(postOnFiles.statusCode, 404, "files are read-only")
    }

    func testRequestsAreReported() async throws {
        _ = try await fetch("/files/\(manifest)/metadata.json?x=1")
        _ = try await fetch("/files/\(manifest)/nope.json")
        try await Task.sleep(nanoseconds: 200_000_000)
        let log = requests.all
        XCTAssertEqual(log.map(\.status), [200, 404])
        XCTAssertEqual(log.first?.path, "/files/\(manifest)/metadata.json?x=1")
        XCTAssertEqual(log.first?.bytes, 14)
        XCTAssertEqual(log.first?.client, "127.0.0.1")
    }

    func testDisablingFileHandling() async throws {
        server.setFileHandling(resolver: nil)
        let (_, response) = try await fetch("/files/\(manifest)/metadata.json")
        XCTAssertEqual(response.statusCode, 404)
    }
}
