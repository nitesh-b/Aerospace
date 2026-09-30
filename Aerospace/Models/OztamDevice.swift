//
//  OztamDevice.swift
//  Aerospace
//
//  A saved tail target. Each device names one of the four lookups oztail
//  supports (lib/by-address.js, by-device.js, by-session.js,
//  by-oztam-device.js) and carries the identifier to search for.
//

import Foundation
import CryptoKit

nonisolated enum OztamDeviceKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case ipAddress
    case deviceId
    case sessionId
    case oztamDeviceId

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ipAddress: return "IP Address"
        case .deviceId: return "Device ID"
        case .sessionId: return "Session ID"
        case .oztamDeviceId: return "OzTAM Device ID"
        }
    }

    /// The OCS path this lookup posts to.
    var endpointPath: String {
        switch self {
        case .ipAddress: return "/api/events/ipaddress"
        case .deviceId: return "/api/events/devices"
        case .sessionId: return "/api/events/sessions"
        case .oztamDeviceId: return "/api/events/oztamdevices"
        }
    }

    /// The query parameter name carrying the identifier.
    var queryName: String {
        switch self {
        case .ipAddress: return "remoteAddress"
        case .deviceId, .oztamDeviceId: return "deviceId"
        case .sessionId: return "sessionId"
        }
    }

    var systemImage: String {
        switch self {
        case .ipAddress: return "network"
        case .deviceId: return "tv"
        case .sessionId: return "person.badge.key"
        case .oztamDeviceId: return "antenna.radiowaves.left.and.right"
        }
    }

    var placeholder: String {
        switch self {
        case .ipAddress: return "101.111.12.1"
        case .deviceId: return "device identifier"
        case .sessionId: return "session identifier"
        case .oztamDeviceId: return "OzTAM device identifier"
        }
    }
}

nonisolated struct OztamDevice: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var kind: OztamDeviceKind
    /// The identifier as typed by the user (never hashed on the way in, so it
    /// stays editable and recognisable).
    var value: String
    /// Whether this device is included when tailing starts.
    var isSelected: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        kind: OztamDeviceKind,
        value: String,
        isSelected: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.value = value
        self.isSelected = isSelected
        self.createdAt = createdAt
    }

    var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The value actually sent to the OCS. IP addresses are MD5-hashed exactly
    /// as `TailByAddress` does; anything else goes over as typed (so a
    /// pre-hashed address pasted in still works).
    var queryValue: String {
        let raw = trimmedValue
        guard kind == .ipAddress, Self.isIPAddress(raw) else { return raw }
        return Insecure.MD5.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Mirrors oztail's `isIPAddress`: four dot-separated components, empties
    /// included, so the hashing decision matches the CLI exactly.
    static func isIPAddress(_ address: String) -> Bool {
        address.components(separatedBy: ".").count == 4
    }

    /// A device is only usable as a tail target once it has an identifier.
    var isUsable: Bool { !trimmedValue.isEmpty }

    /// Falls back to the identifier when the user left the name blank.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? trimmedValue : trimmed
    }
}
