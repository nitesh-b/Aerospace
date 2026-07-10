//
//  HTTPInjectorServer.swift
//  Aerospace
//
//  A tiny HTTP server built on Apple's Network framework (no third-party
//  dependencies), serving Injector's release-check and bundle-download
//  routes. Structurally mirrors HTTPLogServer but is a separate listener on
//  its own port, kept independent so Logger's server is untouched.
//

import Foundation
import Network

/// The result of matching an incoming request to an Injector route. Pure
/// and network-free so routing logic can be unit tested directly.
nonisolated enum InjectorRoute: Equatable {
    case check(app: String, platform: String, channel: String, nativeVersion: String)
    case bundleDownload(releaseId: String)
    case health
    case options
    case badRequest(String)
    case notFound

    private static let bundlePrefix = "/injector/bundle/"

    static func match(method: String, path: String) -> InjectorRoute {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path

        switch (method, pathOnly) {
        case ("GET", "/injector/check"):
            let query = queryParameters(from: path)
            guard let app = query["app"], let platform = query["platform"],
                  let channel = query["channel"] else {
                return .badRequest("Missing required query parameter: app, platform, or channel")
            }
            return .check(app: app, platform: platform, channel: channel,
                         nativeVersion: query["nativeVersion"] ?? "0")
        case ("GET", let p) where p.hasPrefix(bundlePrefix):
            return .bundleDownload(releaseId: String(p.dropFirst(bundlePrefix.count)))
        case ("GET", "/health"), ("HEAD", "/health"):
            return .health
        case ("OPTIONS", _):
            return .options
        default:
            return .notFound
        }
    }

    private static func queryParameters(from pathAndQuery: String) -> [String: String] {
        guard let components = URLComponents(string: pathAndQuery) else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value
        }
        return result
    }
}

/// What `HTTPInjectorServer.onCheck` returns for a matching release. The
/// download URL is assembled by the server itself (it alone knows its bound
/// port), not by the caller.
nonisolated struct InjectorCheckResult: Equatable, Sendable {
    let id: String
    let version: String
    let bundleHash: String
}

nonisolated final class HTTPInjectorServer: @unchecked Sendable {
    /// Called on the server's queue to answer a `/injector/check` request.
    /// Return nil if no release matches.
    var onCheck: (@Sendable (_ app: String, _ platform: String, _ channel: String,
                            _ nativeVersion: String) -> InjectorCheckResult?)?
    /// Called on the server's queue to answer a `/injector/bundle/<id>`
    /// request. Return nil if no bundle exists for that release id.
    var onBundleRequest: (@Sendable (_ releaseId: String) -> Data?)?
    /// Called on the server's queue whenever the listener state changes.
    var onStateChange: (@Sendable (ServerState) -> Void)?

    private let queue = DispatchQueue(label: "com.networkten.aerospace.injectorserver")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private static let maxBodySize = 1024

    // MARK: - Lifecycle

    func start(port: UInt16) {
        queue.async { [self] in
            stopLocked()
            emit(.starting)

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                emit(.failed("Invalid port \(port)"))
                return
            }

            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            let newListener: NWListener
            do {
                newListener = try NWListener(using: params, on: nwPort)
            } catch {
                emit(.failed(error.localizedDescription))
                return
            }

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let boundPort = self.listener?.port?.rawValue ?? port
                    self.emit(.running(port: boundPort))
                case .failed(let error):
                    self.emit(.failed(error.localizedDescription))
                    self.stop()
                case .cancelled:
                    self.emit(.stopped)
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }

            listener = newListener
            newListener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in stopLocked() }
    }

    private func stopLocked() {
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func emit(_ state: ServerState) {
        onStateChange?(state)
    }

    // MARK: - Connections

    private func handle(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        let parser = HTTPRequestParser(maxBodySize: Self.maxBodySize)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connections[key] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, parser: parser, key: key)
    }

    private func receive(on connection: NWConnection, parser: HTTPRequestParser,
                         key: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                parser.append(data)
                self.drain(connection, parser: parser, key: key)
            }

            if isComplete || error != nil {
                connection.cancel()
                self.queue.async { self.connections[key] = nil }
                return
            }
            self.receive(on: connection, parser: parser, key: key)
        }
    }

    private func drain(_ connection: NWConnection, parser: HTTPRequestParser,
                       key: ObjectIdentifier) {
        while true {
            let request: HTTPRequest?
            do {
                request = try parser.takeRequest()
            } catch {
                respond(connection, status: 400, reason: "Bad Request",
                        json: ["error": "\(error)"], close: true)
                return
            }
            guard let request else { return }
            route(request, on: connection)
        }
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        switch InjectorRoute.match(method: request.method, path: request.path) {
        case .check(let app, let platform, let channel, let nativeVersion):
            guard let result = onCheck?(app, platform, channel, nativeVersion) else {
                respond(connection, status: 204, reason: "No Content", json: nil)
                return
            }
            respond(connection, status: 200, reason: "OK", json: [
                "id": result.id,
                "version": result.version,
                "bundleHash": result.bundleHash,
                "downloadUrl": "/injector/bundle/\(result.id)",
            ])
        case .bundleDownload(let releaseId):
            guard let data = onBundleRequest?(releaseId) else {
                respond(connection, status: 404, reason: "Not Found",
                        json: ["error": "No bundle for release \(releaseId)"])
                return
            }
            respondBinary(connection, status: 200, reason: "OK", data: data)
        case .health:
            respond(connection, status: 200, reason: "OK", json: ["status": "healthy"])
        case .options:
            respond(connection, status: 204, reason: "No Content", json: nil)
        case .badRequest(let message):
            respond(connection, status: 400, reason: "Bad Request", json: ["error": message])
        case .notFound:
            respond(connection, status: 404, reason: "Not Found",
                    json: ["error": "No route for \(request.method) \(request.path)"])
        }
    }

    // MARK: - Responses

    private func respond(_ connection: NWConnection, status: Int, reason: String,
                         json: [String: String]?, close: Bool = false) {
        var body = Data()
        if let json,
           let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            body = data
        }
        sendResponse(connection, status: status, reason: reason, contentType: "application/json",
                    body: body, close: close)
    }

    private func respondBinary(_ connection: NWConnection, status: Int, reason: String, data: Data) {
        sendResponse(connection, status: status, reason: reason,
                    contentType: "application/octet-stream", body: data, close: false)
    }

    private func sendResponse(_ connection: NWConnection, status: Int, reason: String,
                              contentType: String, body: Data, close: Bool) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
        if close { head += "Connection: close\r\n" }
        head += "\r\n"

        var response = Data(head.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }
}
