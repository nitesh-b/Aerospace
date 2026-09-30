//
//  OztamEvent.swift
//  Aerospace
//
//  One flattened OCS meter event row — the same unit oztail prints per line.
//  A meter event from the API carries a nested `events` array; each entry
//  becomes one `OztamEvent`, tagged with the device it was tailed from.
//

import SwiftUI

nonisolated enum OztamSeverity: String, CaseIterable, Identifiable, Codable, Sendable {
    case ok
    case warning
    case error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ok: return "OK"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    /// The single-character flag oztail prints in its ERR column.
    var flag: String {
        switch self {
        case .ok: return ""
        case .warning: return "W"
        case .error: return "Q"
        }
    }

    var systemImage: String {
        switch self {
        case .ok: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

nonisolated struct OztamEvent: Identifiable, Hashable, Sendable {
    /// Positions above this are epoch milliseconds rather than seconds into
    /// the asset — the same threshold oztail uses.
    static let minEpochTime: Double = 1e10

    let id: UUID
    /// The saved device this row was tailed from.
    let deviceID: UUID
    let deviceName: String

    /// `event.timestamp` — when the player emitted the event.
    let timestamp: Date
    /// `meterEvent.createdAt` — when the OCS recorded it. Drives the poll cursor.
    let createdAt: Date

    let vendorVersion: String
    let sessionId: String
    let publisherId: String
    let mediaId: String
    /// The event name, e.g. LOAD / BEGIN / PROGRESS / COMPLETE.
    let event: String

    let fromPosition: Double?
    let toPosition: Double?

    let severity: OztamSeverity
    /// `inputErrorStr` / `inputWarningStr` when the meter event was flagged.
    let detail: String?

    let propertiesDeviceId: String?
    let demo1: String?

    /// The whole meter event, pretty-printed, for the detail pane.
    let rawJSON: String

    // MARK: - Derived

    /// True when both positions are epoch milliseconds (live streams) rather
    /// than seconds into the asset (VOD).
    var usesEpochPositions: Bool {
        guard let from = fromPosition, let to = toPosition else { return false }
        return from > Self.minEpochTime && to > Self.minEpochTime
    }

    /// Seconds between the two positions, or nil when either is missing.
    var duration: Double? {
        guard let from = fromPosition, let to = toPosition else { return nil }
        return usesEpochPositions ? (to - from) / 1000 : (to - from)
    }

    var fromPositionText: String { Self.positionText(fromPosition, epoch: usesEpochPositions) }
    var toPositionText: String { Self.positionText(toPosition, epoch: usesEpochPositions) }

    var durationText: String {
        guard let duration else { return "" }
        return String(format: "%.1f", duration)
    }

    private static func positionText(_ value: Double?, epoch: Bool) -> String {
        guard let value else { return "" }
        return epoch ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Lowercased text a free-text filter searches over.
    var searchHaystack: String {
        [deviceName, vendorVersion, sessionId, publisherId, mediaId, event,
         detail ?? "", propertiesDeviceId ?? "", demo1 ?? "", rawJSON]
            .joined(separator: " ")
            .lowercased()
    }
}

// MARK: - Parsing

extension OztamEvent {

    /// Flattens one OCS meter event object into its individual event rows.
    /// Tolerates missing or differently-typed fields — the OCS sends positions
    /// as either numbers or strings depending on the vendor.
    static func rows(fromMeterEvent object: [String: Any], device: OztamDevice) -> [OztamEvent] {
        guard let nested = object["events"] as? [[String: Any]], !nested.isEmpty else { return [] }

        let createdAt = date(from: object["createdAt"]) ?? Date()
        let vendorVersion = (string(from: object["vendorVersion"]) ?? "").lowercased()
        let properties = object["properties"] as? [String: Any]

        let severity: OztamSeverity
        let detail: String?
        if isFlagged(object["inputErrors"]) {
            severity = .error
            detail = string(from: object["inputErrorStr"])
        } else if isFlagged(object["inputWarnings"]) {
            severity = .warning
            detail = string(from: object["inputWarningStr"])
        } else {
            severity = .ok
            detail = nil
        }

        let raw = prettyJSON(object)

        return nested.map { entry in
            OztamEvent(
                id: UUID(),
                deviceID: device.id,
                deviceName: device.displayName,
                timestamp: date(from: entry["timestamp"]) ?? createdAt,
                createdAt: createdAt,
                vendorVersion: vendorVersion,
                sessionId: string(from: object["sessionId"]) ?? "",
                publisherId: string(from: object["publisherId"]) ?? "",
                mediaId: string(from: object["mediaId"]) ?? "",
                event: string(from: entry["event"]) ?? "",
                fromPosition: number(from: entry["fromPosition"]),
                toPosition: number(from: entry["toPosition"]),
                severity: severity,
                detail: detail?.isEmpty == true ? nil : detail,
                propertiesDeviceId: string(from: properties?["deviceId"]),
                demo1: string(from: properties?["demo1"]),
                rawJSON: raw
            )
        }
    }

    /// Matches oztail's truthiness test: any non-zero count or non-empty string
    /// marks the meter event as flagged.
    private static func isFlagged(_ value: Any?) -> Bool {
        if let n = number(from: value) { return n != 0 }
        if let s = value as? String { return !s.isEmpty }
        if let b = value as? Bool { return b }
        return false
    }

    static func string(from value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func number(from value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// Parses the ISO-8601 timestamps the OCS returns, with or without
    /// fractional seconds, and tolerates epoch milliseconds.
    static func date(from value: Any?) -> Date? {
        if let text = value as? String {
            if let parsed = fractionalFormatter.date(from: text) { return parsed }
            if let parsed = plainFormatter.date(from: text) { return parsed }
            return nil
        }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > minEpochTime ? raw / 1000 : raw)
        }
        return nil
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func prettyJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: object) }
        return text
    }
}
