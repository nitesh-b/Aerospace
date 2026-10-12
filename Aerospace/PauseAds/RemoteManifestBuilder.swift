//
//  RemoteManifestBuilder.swift
//  Aerospace
//
//  Swift port of the You.i engine's tools/workflow/generate_manifest.rb, so
//  pause ads no longer need a local engine install or Ruby. Given a `server/`
//  folder it:
//    1. replaces `../manifests/RemoteManifest/` with a copy of `server/`
//       (minus .log/.aep files and VCS/macOS noise), and
//    2. writes `RemoteManifest.json` — the asset catalog youi.rn downloads.
//
//  Differences from the Ruby script, all deliberate:
//  - Entries are sorted by name (Ruby used unsorted readdir order).
//  - Every dot-file is skipped (Ruby only skipped .DS_Store/.git), so
//    AppleDouble `._*` files never ship.
//  - Extension exclusion is case-insensitive (`.AEP` is excluded too).
//  - The new bundle is staged next to the old one and swapped in at the end;
//    a failed build leaves the previous bundle intact.
//

import Foundation

nonisolated enum RemoteManifestBuilder {
    struct Entry: Hashable, Sendable {
        let name: String
        /// nil for files; an array (possibly empty) for directories.
        let children: [Entry]?

        init(name: String, children: [Entry]? = nil) {
            self.name = name
            self.children = children
        }
    }

    struct Options: Sendable {
        /// Ruby `--excluded_extensions`; replaces the default when given.
        var excludedExtensions: Set<String> = [".log", ".aep"]
        /// Ruby `--excluded_names`; compared with the name minus its extension.
        var excludedNames: Set<String> = []
        /// Ruby `--file_name`.
        var fileName = "RemoteManifest"
        /// Ruby `--version`.
        var version = "1.0.0"
    }

    struct Result: Sendable {
        let bundleURL: URL
        let manifestURL: URL
        let catalog: [Entry]
        /// Copied files, excluding the manifest itself.
        let fileCount: Int
        let totalBytes: Int
    }

    enum BuildError: Error, LocalizedError {
        case serverFolderMissing(URL)

        var errorDescription: String? {
            switch self {
            case .serverFolderMissing(let url): return "Server folder not found: \(url.path)"
            }
        }
    }

    static let minimumEngineVersion = "4.6.0"
    static let maximumEngineVersion = "999.999.999"
    /// Ruby's ignore_defaults (minus `.`/`..`, which FileManager never lists).
    private static let ignoredNames: Set<String> = [".DS_Store", "__MACOSX", ".git"]

    // MARK: - Build

    @discardableResult
    static func build(serverDirectory: URL, options: Options = Options(),
                      fileManager: FileManager = .default) throws -> Result {
        let server = serverDirectory.standardizedFileURL
        guard isDirectory(server, fileManager) else { throw BuildError.serverFolderMissing(server) }

        let manifestsURL = server.deletingLastPathComponent().appendingPathComponent("manifests", isDirectory: true)
        let bundleURL = manifestsURL.appendingPathComponent(options.fileName, isDirectory: true)
        let stagingURL = manifestsURL.appendingPathComponent(".\(options.fileName)-\(UUID().uuidString)",
                                                             isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        do {
            let catalog = try catalog(of: server, options: options, fileManager: fileManager)
            var fileCount = 0
            var totalBytes = 0
            try copy(catalog, from: server, to: stagingURL, fileManager: fileManager,
                     fileCount: &fileCount, totalBytes: &totalBytes)

            let manifestName = "\(options.fileName).json"
            try manifestJSON(catalog: catalog, version: options.version)
                .write(to: stagingURL.appendingPathComponent(manifestName), options: .atomic)

            if fileManager.fileExists(atPath: bundleURL.path) {
                try fileManager.removeItem(at: bundleURL)
            }
            try fileManager.moveItem(at: stagingURL, to: bundleURL)

            return Result(bundleURL: bundleURL,
                          manifestURL: bundleURL.appendingPathComponent(manifestName),
                          catalog: catalog, fileCount: fileCount, totalBytes: totalBytes)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    // MARK: - Catalog

    /// The asset tree of `directory` after exclusions, sorted by name.
    static func catalog(of directory: URL, options: Options = Options(),
                        fileManager: FileManager = .default) throws -> [Entry] {
        let excludedExtensions = Set(options.excludedExtensions.map { $0.lowercased() })
        let children = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [])

        return try children
            .compactMap { url -> Entry? in
                let name = url.lastPathComponent
                guard !name.hasPrefix("."), !ignoredNames.contains(name) else { return nil }
                let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension.lowercased())"
                guard !excludedExtensions.contains(ext) else { return nil }
                guard !options.excludedNames.contains(url.deletingPathExtension().lastPathComponent) else { return nil }

                if isDirectory(url, fileManager) {
                    return Entry(name: name, children: try catalog(of: url, options: options, fileManager: fileManager))
                }
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                return isFile ? Entry(name: name) : nil
            }
            .sorted { $0.name < $1.name }
    }

    private static func copy(_ entries: [Entry], from source: URL, to destination: URL,
                             fileManager: FileManager, fileCount: inout Int, totalBytes: inout Int) throws {
        for entry in entries {
            let from = source.appendingPathComponent(entry.name)
            let to = destination.appendingPathComponent(entry.name)
            if let children = entry.children {
                try fileManager.createDirectory(at: to, withIntermediateDirectories: true)
                try copy(children, from: from, to: to, fileManager: fileManager,
                         fileCount: &fileCount, totalBytes: &totalBytes)
            } else {
                try fileManager.copyItem(at: from, to: to)
                fileCount += 1
                totalBytes += (try? from.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
    }

    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - JSON

    /// Same bytes as Ruby `JSON.pretty_generate(manifest_data)` + "\n".
    static func manifestJSON(catalog: [Entry], version: String = "1.0.0") -> Data {
        var out = "{\n"
        out += "  \"manifest_version\": \(quoted(version)),\n"
        out += "  \"minimum_engine_version\": \(quoted(minimumEngineVersion)),\n"
        out += "  \"maximum_engine_version\": \(quoted(maximumEngineVersion)),\n"
        out += "  \"asset_catalog\": "
        appendArray(catalog, indent: 1, to: &out)
        out += "\n}\n"
        return Data(out.utf8)
    }

    private static func appendArray(_ entries: [Entry], indent: Int, to out: inout String) {
        guard !entries.isEmpty else {
            out += "[]"
            return
        }
        let pad = String(repeating: "  ", count: indent)
        out += "[\n"
        for (index, entry) in entries.enumerated() {
            out += "\(pad)  {\n\(pad)    \"name\": \(quoted(entry.name))"
            if let children = entry.children {
                out += ",\n\(pad)    \"children\": "
                appendArray(children, indent: indent + 2, to: &out)
            }
            out += "\n\(pad)  }"
            out += index < entries.count - 1 ? ",\n" : "\n"
        }
        out += "\(pad)]"
    }

    private static func quoted(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: string,
                                                options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
