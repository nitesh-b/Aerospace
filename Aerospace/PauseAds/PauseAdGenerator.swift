//
//  PauseAdGenerator.swift
//  Aerospace
//
//  "Generate Pause Ad": youi.ads `setup-s/h` + copy into server/ + `auto` +
//  `gen` in one step, without the You.i engine.
//
//      source/ ──copy (minus noise) + youi image swaps──▶ v{n}/server/
//      metadata ──────────────────────────────────────▶ v{n}/metadata.json
//      server/ ──RemoteManifestBuilder────────────────▶ v{n}/manifests/RemoteManifest/
//      metadata normalized ───────────────────────────▶ RemoteManifest/metadata.json
//
//  The source folder is never modified. The new server/ is staged before the
//  old one is removed, so a version can be regenerated from its own server/.
//

import Foundation

nonisolated enum PauseAdGenerator {
    enum Mode: Hashable, Sendable {
        /// Fails if the version folder already exists.
        case create
        /// Replaces server/, metadata.json and manifests/RemoteManifest/.
        case overwrite
    }

    struct Request: Sendable {
        let source: URL
        let destinationRoot: URL
        let job: PauseAdJob
        let version: Int
        let mode: Mode
        /// Derived fields (possibly user-edited) + brand/campaign/industry.
        let metadata: PauseAdMetadata
        var applyImageSwaps = true
    }

    struct Result: Sendable {
        let job: PauseAdJob
        let version: Int
        let versionURL: URL
        /// Relative to the destination root; served as `/files/<path>`.
        let hostedMetadataPath: String
        let appliedSwaps: [PauseAdInspection.ImageSwap]
        let inspection: PauseAdInspection
        let manifest: RemoteManifestBuilder.Result
    }

    enum GenerateError: Error, Equatable, LocalizedError {
        case inspectionFailed([String])
        case versionExists(Int)
        case invalidVersion
        case sourceContainsDestination
        case interactiveAdUnsupported
        case invalidDuration
        case missingField(PauseAdMetadata.Field)
        case notGenerated(Int)

        var errorDescription: String? {
            switch self {
            case .inspectionFailed(let messages):
                return "The source folder has errors:\n" + messages.map { "• \($0)" }.joined(separator: "\n")
            case .versionExists(let version):
                return "v\(version) already exists. Choose overwrite or create the next version."
            case .invalidVersion:
                return "The version number must be 1 or more."
            case .sourceContainsDestination:
                return "The destination is inside the source folder. Choose a destination outside it."
            case .interactiveAdUnsupported:
                return "This is an interactive pause ad (runtime code). Generate it with the youi.ads CLI (`autoi` / `gen`), which encrypts the code into the RemoteManifest."
            case .invalidDuration:
                return "The duration must be greater than 0."
            case .missingField(.lottieTarget):
                return "The lottie target file isn't at the top of the source folder."
            case .missingField(let field):
                return "\(field.label) is required."
            case .notGenerated(let version):
                return "v\(version) hasn't been generated yet."
            }
        }
    }

    /// Never copied into server/.
    private static let skippedNames: Set<String> = ["__MACOSX", "Adobe After Effects Auto-Save"]
    private static let interactiveCodeFiles = ["code_constructor.jsx", "code_render.jsx"]

    @discardableResult
    static func generate(_ request: Request, fileManager: FileManager = .default) throws -> Result {
        let source = request.source.standardizedFileURL.resolvingSymlinksInPath()
        let root = request.destinationRoot.standardizedFileURL.resolvingSymlinksInPath()
        let job = request.job
        let version = request.version
        let versionURL = root.appendingPathComponent(job.versionPath(version), isDirectory: true)
        let serverURL = root.appendingPathComponent(job.serverPath(version), isDirectory: true)
        let metadata = request.metadata

        // Structural checks first — nothing is written until all pass.
        guard version >= 1 else { throw GenerateError.invalidVersion }
        guard !isInside(versionURL, source) else { throw GenerateError.sourceContainsDestination }

        let versionExists = fileManager.fileExists(atPath: versionURL.path)
        if versionExists, request.mode == .create { throw GenerateError.versionExists(version) }

        let hasRuntimeCode = interactiveCodeFiles.contains {
            fileManager.fileExists(atPath: versionURL.appendingPathComponent($0).path)
        }
        if hasRuntimeCode || metadata.extraFields["runtimeSourcePath"] != nil {
            throw GenerateError.interactiveAdUnsupported
        }

        let inspection = PauseAdInspector.inspect(source, fileManager: fileManager)
        guard inspection.canGenerate else {
            throw GenerateError.inspectionFailed(inspection.issues.filter { $0.severity == .error }.map(\.message))
        }

        if metadata.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GenerateError.missingField(.target)
        }
        let lottieTarget = metadata.lottieTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if lottieTarget.isEmpty || !fileManager.fileExists(atPath: source.appendingPathComponent(lottieTarget).path) {
            throw GenerateError.missingField(.lottieTarget)
        }
        guard metadata.duration > 0, metadata.duration.isFinite else { throw GenerateError.invalidDuration }

        // setup: version folder + staged server/
        try fileManager.createDirectory(at: versionURL, withIntermediateDirectories: true)
        let stagingURL = versionURL.appendingPathComponent(".server-\(UUID().uuidString)", isDirectory: true)
        var appliedSwaps: [PauseAdInspection.ImageSwap] = []
        do {
            try copyHandOff(from: source, to: stagingURL, fileManager: fileManager)
            if request.applyImageSwaps {
                for swap in inspection.swaps {
                    let youi = source.appendingPathComponent("assets/drawable/default/\(swap.name)")
                    let target = stagingURL.appendingPathComponent("images/\(swap.name)")
                    try fileManager.removeItem(at: target)
                    try fileManager.copyItem(at: youi, to: target)
                    appliedSwaps.append(swap)
                }
            }
            if fileManager.fileExists(atPath: serverURL.path) {
                try fileManager.removeItem(at: serverURL)
            }
            try fileManager.moveItem(at: stagingURL, to: serverURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        // auto: metadata.json
        try metadata.jsonData().write(
            to: root.appendingPathComponent(job.metadataPath(version)), options: .atomic)

        // gen: RemoteManifest + normalized metadata (after the manifest, as the CLI does)
        let manifest = try RemoteManifestBuilder.build(serverDirectory: serverURL, fileManager: fileManager)
        try metadata.normalizedForManifest().jsonData().write(
            to: root.appendingPathComponent(job.hostedMetadataPath(version)), options: .atomic)

        return Result(job: job, version: version, versionURL: versionURL,
                      hostedMetadataPath: job.hostedMetadataPath(version),
                      appliedSwaps: appliedSwaps, inspection: inspection, manifest: manifest)
    }

    // MARK: - Metadata only

    /// Rewrites `v{n}/metadata.json` and `RemoteManifest/metadata.json`
    /// without recopying assets — e.g. brand/campaign/industry filled in
    /// after local testing.
    static func updateMetadata(_ metadata: PauseAdMetadata, job: PauseAdJob, version: Int,
                               destinationRoot: URL, fileManager: FileManager = .default) throws {
        let root = destinationRoot.standardizedFileURL.resolvingSymlinksInPath()
        let bundle = root.appendingPathComponent(job.remoteManifestPath(version), isDirectory: true)
        guard fileManager.fileExists(atPath: bundle.appendingPathComponent("RemoteManifest.json").path) else {
            throw GenerateError.notGenerated(version)
        }
        if metadata.extraFields["runtimeSourcePath"] != nil { throw GenerateError.interactiveAdUnsupported }
        if metadata.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GenerateError.missingField(.target)
        }
        let lottieTarget = metadata.lottieTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if lottieTarget.isEmpty || !fileManager.fileExists(atPath: bundle.appendingPathComponent(lottieTarget).path) {
            throw GenerateError.missingField(.lottieTarget)
        }
        guard metadata.duration > 0, metadata.duration.isFinite else { throw GenerateError.invalidDuration }

        try metadata.jsonData().write(to: root.appendingPathComponent(job.metadataPath(version)), options: .atomic)
        try metadata.normalizedForManifest().jsonData().write(
            to: root.appendingPathComponent(job.hostedMetadataPath(version)), options: .atomic)
    }

    // MARK: - Helpers

    /// Recursive copy skipping dot-files, `__MACOSX` and AE auto-saves.
    private static func copyHandOff(from source: URL, to destination: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        for child in children {
            let name = child.lastPathComponent
            guard !name.hasPrefix("."), !skippedNames.contains(name) else { continue }
            let target = destination.appendingPathComponent(name)
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try copyHandOff(from: child, to: target, fileManager: fileManager)
            } else {
                try fileManager.copyItem(at: child, to: target)
            }
        }
    }

    /// `url` equals `ancestor` or lies beneath it.
    private static func isInside(_ url: URL, _ ancestor: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = ancestor.standardizedFileURL.path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}
