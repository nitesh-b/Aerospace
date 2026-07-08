//
//  AuthKind.swift
//  Aerospace
//
//  Authentication strategies for a saved request. Bearer-token is the only
//  active method today; the enum leaves room for Basic / API-key / OAuth.
//

import Foundation

nonisolated enum AuthKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case bearer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "No Auth"
        case .bearer: return "Bearer Token"
        }
    }
}
