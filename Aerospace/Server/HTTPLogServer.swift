//
//  HTTPLogServer.swift
//  Aerospace
//
//  A tiny HTTP server built on Apple's Network framework (no third-party
//  dependencies). It accepts POSTs to /log, parses them into LogEvents, and
//  forwards them via the `onEvent` callback. It also serves generated pause
//  ads at GET/HEAD /files/* (see PauseAdFileResolver) and the open dynamic
//  config at GET/HEAD /config/dynamic_config.json (see DynamicConfigHost).
//  Runs entirely off the main thread on its own dispatch queue.
//

import Foundation
import Network

nonisolated enum ServerState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running(let port): return "Listening on port \(port)"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

nonisolated final class HTTPLogServer: @unchecked Sendable {
    /// Called on the server's queue for every successfully parsed log event.
    var onEvent: (@Sendable (LogEvent) -> Void)?
    /// Called on the server's queue whenever the listener state changes.
    var onStateChange: (@Sendable (ServerState) -> Void)?

    private let queue = DispatchQueue(label: "com.networkten.aerospace.httpserver")
    /// Confined to `queue`; install with `setFileHandling`.
    private var fileResolver: PauseAdFileResolver?
    private var onFileRequest: (@Sendable (PauseAdFileRequest) -> Void)?
    /// Confined to `queue`; install with `setConfigHandling`.
    private var configHost: DynamicConfigHost?
    private var onConfigRequest: (@Sendable (DynamicConfigRequest) -> Void)?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private static let maxBodySize = 8 * 1024 * 1024

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

    /// Enables `/files/*`. `onRequest` is called on the server's queue for
    /// every file request, served or not. Pass nil to disable.
    func setFileHandling(resolver: PauseAdFileResolver?,
                         onRequest: (@Sendable (PauseAdFileRequest) -> Void)? = nil) {
        queue.async { [self] in
            fileResolver = resolver
            onFileRequest = onRequest
        }
    }

    /// Enables `/config/dynamic_config.json`. `onRequest` is called on the
    /// server's queue for every request, served or not. Pass nil to disable.
    func setConfigHandling(host: DynamicConfigHost?,
                           onRequest: (@Sendable (DynamicConfigRequest) -> Void)? = nil) {
        queue.async { [self] in
            configHost = host
            onConfigRequest = onRequest
        }
    }

    /// Must be called on `queue`.
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
            // Keep reading on the same (keep-alive) connection.
            self.receive(on: connection, parser: parser, key: key)
        }
    }

    /// Pull and respond to every complete request currently in the buffer.
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
            guard let request else { return } // need more data
            route(request, on: connection)
        }
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path.split(separator: "?").first.map(String.init) ?? request.path) {
        case ("POST", "/log"):
            do {
                let event = try LogRequest.makeEvent(from: request.body)
                onEvent?(event)
                respond(connection, status: 200, reason: "OK",
                        json: ["status": "ok", "id": event.id.uuidString])
            } catch {
                respond(connection, status: 400, reason: "Bad Request",
                        json: ["error": (error as? LogRequestError)?.localizedDescription ?? "\(error)"])
            }
        case (let method, let path) where (method == "GET" || method == "HEAD")
                                          && PauseAdFileResolver.handles(requestPath: path):
            serveFile(request, on: connection)
        case (let method, let path) where (method == "GET" || method == "HEAD")
                                          && DynamicConfigHost.handles(requestPath: path):
            serveConfig(request, on: connection)
        case ("GET", "/health"), ("HEAD", "/health"):
            respond(connection, status: 200, reason: "OK", json: ["status": "healthy"])
        case ("OPTIONS", _):
            respond(connection, status: 204, reason: "No Content", json: nil)
        default:
            respond(connection, status: 404, reason: "Not Found",
                    json: ["error": "No route for \(request.method) \(request.path)"])
        }
    }

    // MARK: - Files

    private func serveFile(_ request: HTTPRequest, on connection: NWConnection) {
        let isHead = request.method == "HEAD"
        var status = 404
        var bytes = 0

        switch fileResolver?.resolve(requestPath: request.path) ?? .noRoot {
        case .file(let url, let mimeType):
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                status = 200
                bytes = data.count
                respond(connection, status: 200, reason: "OK", contentType: mimeType,
                        body: data, includeBody: !isHead,
                        extraHeaders: ["Cache-Control": "no-store"])
            } else {
                status = 500
                respond(connection, status: 500, reason: "Internal Server Error",
                        json: ["error": "Could not read \(url.lastPathComponent)"])
            }
        case .notFound:
            respond(connection, status: 404, reason: "Not Found", json: ["error": "Not found"])
        case .forbidden:
            status = 403
            respond(connection, status: 403, reason: "Forbidden", json: ["error": "Forbidden"])
        case .noRoot:
            respond(connection, status: 404, reason: "Not Found",
                    json: ["error": "No pause ad destination folder is configured in Aerospace"])
        }

        onFileRequest?(PauseAdFileRequest(date: Date(), method: request.method, path: request.path,
                                          status: status, bytes: bytes,
                                          client: Self.clientDescription(connection.endpoint)))
    }

    // MARK: - Dynamic config

    private func serveConfig(_ request: HTTPRequest, on connection: NWConnection) {
        var status = 404
        var bytes = 0

        switch configHost?.response() ?? .noConfig {
        case .config(let data):
            status = 200
            bytes = data.count
            respond(connection, status: 200, reason: "OK", contentType: "application/json; charset=utf-8",
                    body: data, includeBody: request.method != "HEAD",
                    extraHeaders: ["Cache-Control": "no-store"])
        case .disabled:
            respond(connection, status: 404, reason: "Not Found",
                    json: ["error": "Dynamic config hosting is turned off in Aerospace"])
        case .noConfig:
            respond(connection, status: 404, reason: "Not Found",
                    json: ["error": "No dynamic config is open in Aerospace"])
        }

        onConfigRequest?(DynamicConfigRequest(date: Date(), method: request.method, path: request.path,
                                              status: status, bytes: bytes,
                                              client: Self.clientDescription(connection.endpoint)))
    }

    private static func clientDescription(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            return "\(host)".components(separatedBy: "%").first ?? "\(host)"
        }
        return "\(endpoint)"
    }

    // MARK: - Responses

    private func respond(_ connection: NWConnection, status: Int, reason: String,
                         json: [String: String]?, close: Bool = false) {
        var body = Data()
        if let json,
           let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            body = data
        }
        respond(connection, status: status, reason: reason, contentType: "application/json",
                body: body, close: close)
    }

    private func respond(_ connection: NWConnection, status: Int, reason: String,
                         contentType: String, body: Data, includeBody: Bool = true,
                         extraHeaders: [String: String] = [:], close: Bool = false) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Access-Control-Allow-Methods: POST, GET, HEAD, OPTIONS\r\n"
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        if close { head += "Connection: close\r\n" }
        head += "\r\n"

        var response = Data(head.utf8)
        if includeBody { response.append(body) }

        connection.send(content: response, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }
}
