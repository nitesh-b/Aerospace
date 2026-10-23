//
//  DynamicConfigHost.swift
//  Aerospace
//
//  Hosts the open dynamic config on the Logger server at a fixed URL, so
//  devices can be pointed at this Mac instead of the CDN:
//
//      http://<lan-ip>:57333/config/dynamic_config.json
//
//  Serves the document as it is in the editor, unsaved edits included.
//  Thread-safe: the server queue reads while the UI edits.
//

import Foundation

/// One request for the hosted config, for the Dynamic Config request log.
nonisolated struct DynamicConfigRequest: Identifiable, Hashable, Sendable {
    let id = UUID()
    let date: Date
    let method: String
    /// As requested, including any query string.
    let path: String
    let status: Int
    let bytes: Int
    /// Remote IP of the device that asked.
    let client: String
}

nonisolated final class DynamicConfigHost: @unchecked Sendable {
    enum Response: Equatable, Sendable {
        case config(Data)
        /// Hosting is switched off in the Dynamic Config tool.
        case disabled
        /// No config is open.
        case noConfig
    }

    static let path = "/config/dynamic_config.json"

    private let lock = NSLock()
    private var document: Data?
    private var isEnabled = false

    static func handles(requestPath: String) -> Bool {
        let pathOnly = requestPath.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        return pathOnly == path
    }

    static func url(host: String, port: UInt16) -> String {
        "http://\(host):\(port)\(path)"
    }

    func update(document: Data?, isEnabled: Bool) {
        lock.lock()
        self.document = document
        self.isEnabled = isEnabled
        lock.unlock()
    }

    func response() -> Response {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled else { return .disabled }
        guard let document else { return .noConfig }
        return .config(document)
    }
}
