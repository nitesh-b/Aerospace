//
//  LogEvent.swift
//  Aerospace
//
//  The canonical, stored representation of a single log line.
//

import Foundation

nonisolated struct LogEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let category: String
    let subCategory: String
    /// The raw arg3 payload, stored as a JSON string exactly as received.
    let payload: String
    let level: LogLevel
    let sessionId: String?
    let application: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: String,
        subCategory: String,
        payload: String,
        level: LogLevel = .info,
        sessionId: String? = nil,
        application: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.subCategory = subCategory
        self.payload = payload
        self.level = level
        self.sessionId = sessionId
        self.application = application
    }

    /// A single-line, truncated preview of the payload for list rows.
    var payloadPreview: String {
        let collapsed = payload
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let squeezed = collapsed.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return squeezed.count > 140 ? String(squeezed.prefix(140)) + "…" : squeezed
    }

    /// Pretty-printed JSON for the detail viewer. Falls back to the raw
    /// string when the payload is not valid JSON.
    var prettyPayload: String {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let string = String(data: pretty, encoding: .utf8)
        else {
            return payload
        }
        return string
    }
}
