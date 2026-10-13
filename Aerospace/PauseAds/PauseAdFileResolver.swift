//
//  PauseAdFileResolver.swift
//  Aerospace
//
//  Maps `GET /files/<path>` on the Logger server to a file under the pause ad
//  destination root — the same URL shape youi.ads served, so existing
//  `pauseAdRotation` entries only need the host changed:
//
//      http://<lan-ip>:57333/files/ads/…/manifests/RemoteManifest/metadata.json
//
//  Stricter than youi.ads (which served its whole repo root to the LAN):
//  only the `ads/` subtree, no hidden files, no directory listings, no
//  `..` traversal and no symlinks escaping `ads/`.
//
//  Thread-safe: the server queue resolves while the UI changes the root.
//

import Foundation

/// One `/files/*` request as seen by the server, for the Pause Ads request log.
nonisolated struct PauseAdFileRequest: Hashable, Sendable {
    let date: Date
    let method: String
    /// As requested, including any query string.
    let path: String
    let status: Int
    let bytes: Int
    /// Remote IP of the device that asked.
    let client: String
}

nonisolated final class PauseAdFileResolver: @unchecked Sendable {
    enum Resolution: Equatable, Sendable {
        case file(URL, mimeType: String)
        case notFound
        case forbidden
        /// No destination folder has been chosen yet.
        case noRoot
    }

    static let routePrefix = "/files/"
    static let servedSubtree = "ads"

    private let lock = NSLock()
    private var _root: URL?

    var root: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _root
    }

    func setRoot(_ url: URL?) {
        lock.lock()
        _root = url?.standardizedFileURL
        lock.unlock()
    }

    // MARK: - Routing

    static func handles(requestPath: String) -> Bool {
        relativePath(fromRequestPath: requestPath) != nil
    }

    /// The still percent-encoded remainder after `/files/`, without query or
    /// fragment; nil for any other route.
    static func relativePath(fromRequestPath requestPath: String) -> String? {
        let pathOnly = requestPath.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        guard pathOnly.hasPrefix(routePrefix) else { return nil }
        return String(pathOnly.dropFirst(routePrefix.count))
    }

    func resolve(requestPath: String) -> Resolution {
        guard let encoded = Self.relativePath(fromRequestPath: requestPath) else { return .notFound }
        guard let root else { return .noRoot }

        guard let decoded = encoded.removingPercentEncoding, !decoded.contains("\0") else { return .forbidden }
        let components = decoded.split(separator: "/").map(String.init)
        if components.contains(where: { $0 == ".." || $0 == "." || $0.contains("\\") }) { return .forbidden }
        guard components.first == Self.servedSubtree,
              !components.contains(where: { $0.hasPrefix(".") }) else { return .notFound }

        let requested = components.reduce(root) { $0.appendingPathComponent($1) }
        guard FileManager.default.fileExists(atPath: requested.path) else { return .notFound }

        let resolved = requested.resolvingSymlinksInPath()
        let servedRoot = root.appendingPathComponent(Self.servedSubtree).resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(servedRoot.path + "/") else { return .forbidden }

        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return .notFound
        }
        return .file(resolved, mimeType: Self.mimeType(forExtension: resolved.pathExtension))
    }

    // MARK: - MIME

    /// youi.ads' table plus a few image types designers use.
    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "js": return "application/javascript"
        case "zip": return "application/zip"
        case "txt": return "text/plain"
        case "html": return "text/html"
        case "css": return "text/css"
        default: return "application/octet-stream"
        }
    }
}
