//
//  HTTPMethod.swift
//  Aerospace
//
//  The HTTP verbs supported by the API request tester.
//

import Foundation

nonisolated enum HTTPMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"

    var id: String { rawValue }

    /// Whether a request body is conventional for this method. Used only as a
    /// UI hint — the request builder never strips a body the user has entered.
    var allowsBody: Bool {
        switch self {
        case .post, .put, .patch: return true
        case .get, .delete: return false
        }
    }
}
