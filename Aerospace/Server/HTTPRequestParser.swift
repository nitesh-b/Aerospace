//
//  HTTPRequestParser.swift
//  Aerospace
//
//  A minimal, incremental HTTP/1.1 request parser. It accumulates bytes from
//  the socket and yields a complete request once the headers and (when
//  present) a Content-Length body have arrived.
//

import Foundation

nonisolated struct HTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    /// Header names are lowercased for case-insensitive lookup.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

nonisolated enum HTTPParseError: Error, Equatable {
    case malformedRequestLine
    case bodyTooLarge
}

/// Feed bytes with `append(_:)`; call `takeRequest()` to pull a complete
/// request when one is available. Not internally synchronized: use one per
/// connection and only from that connection's serial queue. `@unchecked
/// Sendable` reflects that single-queue confinement.
nonisolated final class HTTPRequestParser: @unchecked Sendable {
    private var buffer = Data()
    private let maxBodySize: Int

    init(maxBodySize: Int = 8 * 1024 * 1024) {
        self.maxBodySize = maxBodySize
    }

    func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns a parsed request if the buffer contains a complete one,
    /// consuming those bytes. Returns nil if more data is needed.
    /// Throws on malformed input or an over-large body.
    func takeRequest() throws -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else {
            return nil // headers not fully received yet
        }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw HTTPParseError.malformedRequestLine
        }

        var lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseError.malformedRequestLine }

        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw HTTPParseError.malformedRequestLine }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        if contentLength > maxBodySize { throw HTTPParseError.bodyTooLarge }

        let bodyStart = headerRange.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else {
            return nil // body not fully received yet
        }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)

        // Consume the parsed request from the buffer (support keep-alive).
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}
