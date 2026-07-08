//
//  KeyValueItem.swift
//  Aerospace
//
//  A single editable key/value row, shared by the headers and query-parameter
//  editors. `isEnabled` lets a row be kept but excluded from the sent request.
//

import Foundation

nonisolated struct KeyValueItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var key: String
    var value: String
    var isEnabled: Bool

    init(id: UUID = UUID(), key: String = "", value: String = "", isEnabled: Bool = true) {
        self.id = id
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
    }

    /// A copy carrying a fresh identity — used when duplicating a request so the
    /// clone's rows don't share SwiftUI `ForEach` identity with the original.
    func copyWithNewID() -> KeyValueItem {
        KeyValueItem(id: UUID(), key: key, value: value, isEnabled: isEnabled)
    }
}
