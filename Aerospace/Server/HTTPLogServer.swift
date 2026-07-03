//
//  HTTPLogServer.swift
//  Aerospace
//
//  A tiny HTTP server built on Apple's Network framework (no third-party
//  dependencies). It accepts POSTs to /log, parses them into LogEvents, and
//  forwards them via the `onEvent` callback. Runs entirely off the main
//  thread on its own dispatch queue.
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
        case ("GET", "/health"), ("HEAD", "/health"):
            respond(connection, status: 200, reason: "OK", json: ["status": "healthy"])
        case ("OPTIONS", _):
            respond(connection, status: 204, reason: "No Content", json: nil)
        default:
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

        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
        if close { head += "Connection: close\r\n" }
        head += "\r\n"

        var response = Data(head.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }
}
