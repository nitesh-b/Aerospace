//
//  LogLevel.swift
//  Aerospace
//
//  Severity levels a log event may carry. Derived from the payload's
//  optional `level` field; defaults to `.info` when absent or unknown.
//

import SwiftUI

nonisolated enum LogLevel: String, Codable, CaseIterable, Identifiable, Comparable {
    case debug
    case info
    case warning
    case error
    case critical

    var id: String { rawValue }

    /// Case-insensitive parse. Accepts common aliases (warn, err, fatal).
    init(parsing raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            self = .info
            return
        }
        switch raw {
        case "debug", "trace", "verbose": self = .debug
        case "info", "information", "notice": self = .info
        case "warning", "warn": self = .warning
        case "error", "err": self = .error
        case "critical", "fatal", "crit": self = .critical
        default: self = LogLevel(rawValue: raw) ?? .info
        }
    }

    /// Ordinal used for ordering and threshold comparisons.
    var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        case .critical: return 4
        }
    }

    var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    var systemImage: String {
        switch self {
        case .debug: return "ant"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .critical: return "flame"
        }
    }

    var color: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .critical: return .purple
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}
