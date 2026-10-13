//
//  PauseAdDeployer.swift
//  Aerospace
//
//  youi.ads `deploy` without 7z: zips `v{n}/manifests/RemoteManifest/` into
//  `deployments/{type}/…/v{n}/{title}-dpm-{yyyy-MM-dd}.zip` with a single
//  `RemoteManifest/` root entry, as the 7z zips handed to the deployers have.
//
//  Differences from the CLI, all deliberate:
//  - Only the target zip is written; the CLI ran `rm -rf deployments` first,
//    deleting every previous deployment zip.
//  - Refuses incomplete metadata and a RemoteManifest that is older than an
//    edited `v{n}/metadata.json`.
//  - The zip's entry list is read back and rejected if anything other than
//    `RemoteManifest/…` files (e.g. `__MACOSX`, `._*`) got in.
//

import Foundation

nonisolated enum PauseAdDeployer {
    struct Request: Sendable {
        let destinationRoot: URL
        let job: PauseAdJob
        let version: Int
        var date = Date()
        var calendar = Calendar.current
    }

    struct Result: Sendable {
        let zipURL: URL
        /// Relative to the destination root.
        let relativePath: String
        /// File entries (no directory entries), sorted.
        let entries: [String]
        let bytes: Int
        /// The normalized metadata that ships.
        let metadata: PauseAdMetadata
    }

    enum DeployError: Error, Equatable, LocalizedError {
        case notGenerated
        case manifestOutOfDate
        case metadataIncomplete([PauseAdMetadata.Field])
        case bundleIncomplete(String)
        case unexpectedZipEntries([String])
        case notAZip
        case archiveFailed(String)

        var errorDescription: String? {
            switch self {
            case .notGenerated:
                return "This version hasn't been generated yet. Run Generate Pause Ad first."
            case .manifestOutOfDate:
                return "metadata.json was changed after the RemoteManifest was generated. Save the metadata or regenerate before deploying."
            case .metadataIncomplete(let fields):
                return "Fill in before deploying: " + fields.map(\.label).joined(separator: ", ") + "."
            case .bundleIncomplete(let file):
                return "The RemoteManifest is missing \(file). Regenerate the ad."
            case .unexpectedZipEntries(let entries):
                return "The zip contained unexpected entries: " + entries.joined(separator: ", ")
            case .notAZip:
                return "The file isn't a readable zip archive."
            case .archiveFailed(let message):
                return "Couldn't create the zip: \(message)"
            }
        }
    }

    static let rootEntry = "RemoteManifest"

    static func deploy(_ request: Request, fileManager: FileManager = .default) throws -> Result {
        let root = request.destinationRoot.standardizedFileURL.resolvingSymlinksInPath()
        let job = request.job
        let version = request.version
        let bundle = root.appendingPathComponent(job.remoteManifestPath(version), isDirectory: true)

        // 1. Generated?
        guard fileManager.fileExists(atPath: bundle.appendingPathComponent("RemoteManifest.json").path),
              let hostedData = fileManager.contents(atPath: root.appendingPathComponent(job.hostedMetadataPath(version)).path),
              let hosted = try? PauseAdMetadata(jsonData: hostedData),
              let rawData = fileManager.contents(atPath: root.appendingPathComponent(job.metadataPath(version)).path),
              let raw = try? PauseAdMetadata(jsonData: rawData) else {
            throw DeployError.notGenerated
        }

        // 2. Up to date, complete, consistent.
        guard raw.normalizedForManifest() == hosted else { throw DeployError.manifestOutOfDate }
        let missing = hosted.missingDeployFields
        guard missing.isEmpty else { throw DeployError.metadataIncomplete(missing) }
        guard fileManager.fileExists(atPath: bundle.appendingPathComponent(hosted.lottieTarget).path) else {
            throw DeployError.bundleIncomplete(hosted.lottieTarget)
        }

        // 3. Zip next to the destination, verify, swap in.
        let relativePath = job.deploymentZipPath(version, target: hosted.target,
                                                 date: request.date, calendar: request.calendar)
        let zipURL = root.appendingPathComponent(relativePath)
        let directory = zipURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stagingURL = directory.appendingPathComponent(".\(UUID().uuidString).zip")

        do {
            try archive(bundle, to: stagingURL, fileManager: fileManager)
            let entries = try zipEntries(of: stagingURL)
            let unexpected = unexpectedEntries(in: entries)
            guard unexpected.isEmpty else { throw DeployError.unexpectedZipEntries(unexpected) }

            if fileManager.fileExists(atPath: zipURL.path) {
                try fileManager.removeItem(at: zipURL)
            }
            try fileManager.moveItem(at: stagingURL, to: zipURL)

            let bytes = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Result(zipURL: zipURL, relativePath: relativePath,
                          entries: entries.filter { !$0.hasSuffix("/") }.sorted(),
                          bytes: bytes, metadata: hosted)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Zips `directory` with its own name as the root entry, via the system
    /// archiver (`NSFileCoordinator` `.forUploading`).
    private static func archive(_ directory: URL, to destination: URL, fileManager: FileManager) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading,
                                       error: &coordinatorError) { temporaryZip in
            do {
                try fileManager.copyItem(at: temporaryZip, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError {
            throw DeployError.archiveFailed(error.localizedDescription)
        }
    }

    /// Entries outside `RemoteManifest/`, macOS metadata (`__MACOSX`) or dot-files.
    static func unexpectedEntries(in entries: [String]) -> [String] {
        entries.filter { entry in
            let components = entry.split(separator: "/")
            return components.first.map(String.init) != rootEntry
                || components.contains { $0 == "__MACOSX" || $0.hasPrefix(".") }
        }
    }

    // MARK: - Zip reading

    /// Entry names from a zip's central directory (no ZIP64 — pause ads are
    /// far below 4 GB / 65 535 entries).
    static func zipEntries(of url: URL) throws -> [String] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let eocdSignature: UInt32 = 0x0605_4b50
        let centralSignature: UInt32 = 0x0201_4b50
        guard data.count >= 22 else { throw DeployError.notAZip }

        // End of central directory: last 22 bytes + up to 64 KB comment.
        var eocd: Int?
        var index = data.count - 22
        let lowest = max(0, data.count - 22 - 0xFFFF)
        while index >= lowest {
            if data.uint32(at: index) == eocdSignature { eocd = index; break }
            index -= 1
        }
        guard let eocd else { throw DeployError.notAZip }

        let count = Int(data.uint16(at: eocd + 10))
        var offset = Int(data.uint32(at: eocd + 16))
        var names: [String] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.uint32(at: offset) == centralSignature else {
                throw DeployError.notAZip
            }
            let nameLength = Int(data.uint16(at: offset + 28))
            let extraLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            guard offset + 46 + nameLength <= data.count else { throw DeployError.notAZip }
            let start = data.startIndex + offset + 46
            names.append(String(decoding: data[start..<start + nameLength], as: UTF8.self))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return names
    }
}

private extension Data {
    nonisolated func uint16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    nonisolated func uint32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
