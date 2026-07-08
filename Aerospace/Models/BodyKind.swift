//
//  BodyKind.swift
//  Aerospace
//
//  How a request body should be treated. `json` enables pretty-printing and an
//  automatic Content-Type; `raw` is sent verbatim.
//

import Foundation

nonisolated enum BodyKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case raw
    case json

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .raw: return "Raw"
        case .json: return "JSON"
        }
    }
}
