//
//  FolderBookmarks.swift
//  Aerospace
//
//  Persistent access to user-chosen folders under the App Sandbox. A folder
//  picked in an open panel is only readable for the current launch; a
//  security-scoped bookmark (requires the
//  com.apple.security.files.bookmarks.app-scope entitlement) restores access
//  after relaunch.
//

import Foundation

nonisolated protocol FolderBookmarking: Sendable {
    func bookmark(for url: URL) throws -> Data
    /// The folder and whether the bookmark should be re-created.
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool)
    @discardableResult func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

nonisolated struct SecurityScopedBookmarks: FolderBookmarking {
    func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                          relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}
