//
//  RequestFolder.swift
//  Aerospace
//
//  A folder node in the API-tester request tree. Folders nest via parentID
//  (nil = root) and order among siblings via sortIndex.
//

import Foundation

nonisolated struct RequestFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var sortIndex: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "New Folder",
        parentID: UUID? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
