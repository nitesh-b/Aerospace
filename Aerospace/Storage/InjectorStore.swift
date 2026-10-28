//
//  InjectorStore.swift
//  Aerospace
//
//  The observable application state for the Injector tool: owns the SQLite
//  release-metadata store, the HTTP server, and the static OTA folder.
//  Publishing a release copies the bundle (and optional assets) into the
//  OTA folder, hashes every file, inserts a metadata row and rewrites that
//  channel's manifest.json. The HTTP server answers /ota/*, /injector/check
//  and /injector/bundle/<id> straight from the (thread-safe) SQLite store
//  and disk, bypassing the main actor entirely for that hot path.
//

import Foundation
import Combine

@MainActor
final class InjectorStore: ObservableObject {

    @Published private(set) var releases: [InjectorRelease] = []
    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var publishError: String?

    @Published var port: UInt16 {
        didSet { defaults.set(Int(port), forKey: Keys.port) }
    }

    private nonisolated let store: SQLiteInjectorReleaseStore
    /// The folder to upload to S3; also served locally at /ota/*.
    nonisolated let otaFolder: InjectorOTAFolder
    private let server = HTTPInjectorServer()
    private let defaults: UserDefaults

    private enum Keys {
        static let port = "injector.port"
    }

    nonisolated deinit {}

    init(store: SQLiteInjectorReleaseStore? = nil, otaDirectory: URL? = nil,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.port = UInt16(defaults.object(forKey: Keys.port) as? Int ?? 57334)
        self.store = store ?? Self.makeDefaultStore()
        self.otaFolder = InjectorOTAFolder(root: otaDirectory ?? Self.makeDefaultOTADirectory())
        try? FileManager.default.createDirectory(at: otaFolder.root, withIntermediateDirectories: true)
        wireServer()
        refreshReleases()
    }

    private static func makeDefaultStore() -> SQLiteInjectorReleaseStore {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Aerospace", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("injector.sqlite").path
        do {
            return try SQLiteInjectorReleaseStore(path: path)
        } catch {
            let tmp = fm.temporaryDirectory.appendingPathComponent("aerospace-injector.sqlite").path
            return (try? SQLiteInjectorReleaseStore(path: tmp))
                ?? (try! SQLiteInjectorReleaseStore(path: ":memory:"))
        }
    }

    private static func makeDefaultOTADirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("Aerospace", isDirectory: true)
            .appendingPathComponent("InjectorOTA", isDirectory: true)
    }

    // MARK: - Server control

    private func wireServer() {
        server.onCheck = { [store] app, platform, channel, nativeVersion in
            guard let release = store.latestCompatibleRelease(
                app: app, platform: platform, channel: channel, nativeVersion: nativeVersion
            ) else { return nil }
            return InjectorCheckResult(id: release.id, version: release.version,
                                       bundleHash: release.bundleHash)
        }
        server.onBundleRequest = { [store] releaseId in
            guard let release = store.release(id: releaseId) else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: release.bundlePath))
        }
        server.onOTAFileRequest = { [otaFolder] requestPath in
            otaFolder.resolve(requestPath: requestPath)
        }
        server.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in self?.serverState = state }
        }
    }

    func startServer() {
        server.start(port: port)
    }

    func stopServer() {
        server.stop()
    }

    func restartServer() {
        server.stop()
        server.start(port: port)
    }

    // MARK: - Publishing

    /// Imports `bundleURL` (plus the contents of `assetsURL`, the bundler's
    /// `--assets-dest` folder, if given) into the OTA folder, tags it,
    /// records it as a new release and rewrites the channel's manifest.
    /// Returns whether publishing succeeded; on failure, `publishError`
    /// explains why.
    @discardableResult
    func publish(bundleURL: URL, assetsURL: URL? = nil, app: String, platform: String, channel: String,
                 version: String, minNativeVersion: String, maxNativeVersion: String) -> Bool {
        publishError = nil

        guard [app, platform, channel].allSatisfy(InjectorOTAFolder.isValidPathComponent) else {
            publishError = "App, platform and channel may only contain letters, digits, \".\", \"-\" and \"_\"."
            return false
        }

        guard InjectorVersion.isOrdered(minNativeVersion, lessOrEqualTo: maxNativeVersion) else {
            publishError = "Minimum native version must not exceed maximum native version."
            return false
        }

        let data: Data
        do {
            data = try Data(contentsOf: bundleURL)
        } catch {
            publishError = "Could not read bundle file: \(error.localizedDescription)"
            return false
        }

        let id = UUID().uuidString
        let hash = InjectorOTAFolder.sha256Hex(data)
        let destinationDir = otaFolder.releaseDirectory(app: app, platform: platform, channel: channel,
                                                        releaseId: id)
        let destinationFile = destinationDir.appendingPathComponent(bundleURL.lastPathComponent)

        do {
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            if let assetsURL {
                try copyContents(of: assetsURL, to: destinationDir, skipping: bundleURL.lastPathComponent)
            }
            try data.write(to: destinationFile)
            let release = InjectorRelease(
                id: id, app: app, platform: platform, channel: channel, version: version,
                minNativeVersion: minNativeVersion, maxNativeVersion: maxNativeVersion,
                bundleHash: hash, bundlePath: destinationFile.path, createdAt: Date(),
                files: try InjectorOTAFolder.listFiles(in: destinationDir)
            )
            try store.insert(release)
        } catch {
            try? FileManager.default.removeItem(at: destinationDir)
            publishError = "Publish failed: \(error.localizedDescription)"
            return false
        }

        refreshReleases()
        do {
            try otaFolder.writeManifest(
                releases: store.releases(app: app, platform: platform, channel: channel),
                app: app, platform: platform, channel: channel)
        } catch {
            publishError = "Published, but writing manifest.json failed: \(error.localizedDescription)"
            return false
        }
        return true
    }

    /// Copies every non-hidden file under `source` into `destination`,
    /// keeping relative paths. A top-level file named `skipping` (the bundle
    /// itself, when the bundler wrote it into the assets folder) is ignored.
    private func copyContents(of source: URL, to destination: URL, skipping: String) throws {
        let fm = FileManager.default
        let base = source.resolvingSymlinksInPath().path + "/"
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let fullPath = url.resolvingSymlinksInPath().path
            guard fullPath.hasPrefix(base) else { continue }
            let relativePath = String(fullPath.dropFirst(base.count))
            guard relativePath != skipping else { continue }
            let target = destination.appendingPathComponent(relativePath)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: target)
        }
    }

    private func refreshReleases() {
        releases = store.fetchAll()
    }
}
