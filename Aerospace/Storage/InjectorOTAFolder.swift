//
//  InjectorOTAFolder.swift
//  Aerospace
//
//  The static OTA folder: the exact layout that gets uploaded to S3 (e.g.
//  `aws s3 sync <root> s3://<bucket>/`), and that the Injector server serves
//  locally at GET /ota/* so devices exercise the same contract they'll use
//  against the bucket:
//
//      <root>/<app>/<platform>/<channel>/manifest.json
//      <root>/<app>/<platform>/<channel>/<releaseId>/<bundle and assets>
//
//  Clients fetch the manifest, pick the newest release whose native-version
//  range covers them, then download and hash-check every file it lists.
//  No server-side logic is involved, so any static host works.
//
//  Path resolution follows PauseAdFileResolver: no hidden files, no
//  directory listings, no `..` traversal and no symlinks escaping the root.
//

import Foundation
import CryptoKit

/// The `manifest.json` written for one app + platform + channel.
nonisolated struct InjectorManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let app: String
    let platform: String
    let channel: String
    /// Newest first; clients take the first compatible entry.
    let releases: [Release]

    struct Release: Codable, Equatable, Sendable {
        let id: String
        let version: String
        let minNativeVersion: String
        let maxNativeVersion: String
        let createdAt: Date
        /// Path of the JS bundle, relative to the release folder.
        let bundle: String
        /// Every file in the release folder, bundle included.
        let files: [InjectorReleaseFile]
    }
}

nonisolated final class InjectorOTAFolder: Sendable {
    enum Resolution: Equatable, Sendable {
        case file(URL, mimeType: String)
        case notFound
        case forbidden
    }

    static let routePrefix = "/ota/"
    static let manifestFileName = "manifest.json"

    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    // MARK: - Layout

    /// Whether `value` is safe as an app, platform or channel folder name,
    /// both on disk and unencoded in a URL or S3 key.
    static func isValidPathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix(".") else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0)
        }
    }

    func channelDirectory(app: String, platform: String, channel: String) -> URL {
        root.appendingPathComponent(app, isDirectory: true)
            .appendingPathComponent(platform, isDirectory: true)
            .appendingPathComponent(channel, isDirectory: true)
    }

    func releaseDirectory(app: String, platform: String, channel: String, releaseId: String) -> URL {
        channelDirectory(app: app, platform: platform, channel: channel)
            .appendingPathComponent(releaseId, isDirectory: true)
    }

    // MARK: - Manifest

    /// The manifest for `releases` (all targeting one app + platform +
    /// channel), newest first. Releases without a file list predate the
    /// static layout and are left out.
    static func manifest(for releases: [InjectorRelease], app: String, platform: String,
                         channel: String) -> InjectorManifest {
        let entries = releases
            .filter { !$0.files.isEmpty }
            .sorted { $0.createdAt > $1.createdAt }
            .map {
                InjectorManifest.Release(
                    id: $0.id, version: $0.version, minNativeVersion: $0.minNativeVersion,
                    maxNativeVersion: $0.maxNativeVersion, createdAt: $0.createdAt,
                    bundle: $0.bundleFileName, files: $0.files)
            }
        return InjectorManifest(schemaVersion: InjectorManifest.currentSchemaVersion, app: app,
                                platform: platform, channel: channel, releases: entries)
    }

    static func encode(_ manifest: InjectorManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    func writeManifest(releases: [InjectorRelease], app: String, platform: String,
                       channel: String) throws {
        let manifest = Self.manifest(for: releases, app: app, platform: platform, channel: channel)
        let directory = channelDirectory(app: app, platform: platform, channel: channel)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(manifest).write(to: directory.appendingPathComponent(Self.manifestFileName),
                                        options: .atomic)
    }

    /// Every regular, non-hidden file under `directory`, as paths relative
    /// to it with their SHA-256, sorted by path.
    static func listFiles(in directory: URL) throws -> [InjectorReleaseFile] {
        let base = directory.resolvingSymlinksInPath().path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [InjectorReleaseFile] = []
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let fullPath = url.resolvingSymlinksInPath().path
            guard fullPath.hasPrefix(base) else { continue }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            files.append(InjectorReleaseFile(path: String(fullPath.dropFirst(base.count)),
                                             sha256: sha256Hex(data)))
        }
        return files.sorted { $0.path < $1.path }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Serving

    func resolve(requestPath: String) -> Resolution {
        let pathOnly = requestPath.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        guard pathOnly.hasPrefix(Self.routePrefix) else { return .notFound }
        let encoded = String(pathOnly.dropFirst(Self.routePrefix.count))

        guard let decoded = encoded.removingPercentEncoding, !decoded.contains("\0") else { return .forbidden }
        let components = decoded.split(separator: "/").map(String.init)
        if components.contains(where: { $0 == ".." || $0 == "." || $0.contains("\\") }) { return .forbidden }
        guard !components.isEmpty, !components.contains(where: { $0.hasPrefix(".") }) else { return .notFound }

        let requested = components.reduce(root) { $0.appendingPathComponent($1) }
        guard FileManager.default.fileExists(atPath: requested.path) else { return .notFound }

        let resolved = requested.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { return .forbidden }

        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return .notFound
        }
        return .file(resolved, mimeType: PauseAdFileResolver.mimeType(forExtension: resolved.pathExtension))
    }
}
