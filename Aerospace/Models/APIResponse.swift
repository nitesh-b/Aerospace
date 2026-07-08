//
//  APIResponse.swift
//  Aerospace
//
//  The structured result of sending a request. A reachable server returns
//  `.success` (with a status code, even a 5xx); only transport-level problems
//  — DNS, TLS, timeout — are `.failure`.
//

import Foundation

nonisolated struct HeaderPair: Identifiable, Sendable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let value: String
}

nonisolated struct APIResponse: Identifiable, Sendable, Equatable {
    let id: UUID
    let outcome: Outcome
    /// Present only when an HTTP response was received.
    let statusCode: Int?
    let headers: [HeaderPair]
    let bodyText: String
    let bodyByteCount: Int
    let duration: Duration
    /// True when the response body is (or parses as) JSON — drives pretty-print.
    let isBodyJSON: Bool
    let finalURL: String?

    nonisolated enum Outcome: Sendable, Equatable {
        case success
        case failure(String)
        case cancelled
    }

    init(
        id: UUID = UUID(),
        outcome: Outcome,
        statusCode: Int? = nil,
        headers: [HeaderPair] = [],
        bodyText: String = "",
        bodyByteCount: Int = 0,
        duration: Duration = .zero,
        isBodyJSON: Bool = false,
        finalURL: String? = nil
    ) {
        self.id = id
        self.outcome = outcome
        self.statusCode = statusCode
        self.headers = headers
        self.bodyText = bodyText
        self.bodyByteCount = bodyByteCount
        self.duration = duration
        self.isBodyJSON = isBodyJSON
        self.finalURL = finalURL
    }

    /// "200 OK"-style label for the status pill.
    var statusLine: String {
        switch outcome {
        case .success:
            guard let statusCode else { return "—" }
            let text = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            return "\(statusCode) \(text.capitalized)"
        case .failure:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Milliseconds, rounded, for display (e.g. "245 ms").
    var durationText: String {
        let ms = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        return "\(Int(ms.rounded())) ms"
    }
}
