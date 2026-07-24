//
//  OpenTab.swift
//  Aerospace
//
//  One open tab in the API tester. A tab holds a working copy of a request.
//  requestID is nil for ephemeral tabs (e.g. opened by Cmd+clicking a URL in a
//  response) that are not backed by a saved request. Response and in-flight
//  state are held in the store, keyed by tab id, not persisted here.
//

import Foundation

nonisolated struct OpenTab: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var requestID: SavedRequest.ID?
    var request: SavedRequest
    var isPreview: Bool

    init(
        id: UUID = UUID(),
        requestID: SavedRequest.ID? = nil,
        request: SavedRequest,
        isPreview: Bool = false
    ) {
        self.id = id
        self.requestID = requestID
        self.request = request
        self.isPreview = isPreview
    }
}
