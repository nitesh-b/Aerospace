//
//  InjectorStore.swift
//  Aerospace
//
//  The observable application state for the Injector tool: owns the SQLite
//  release-metadata store, the HTTP server, and the on-disk bundle file
//  storage. Publishing a release copies the bundle file, hashes it, and
//  inserts a metadata row. The HTTP server answers /injector/check and
//  /injector/bundle/<id> by reading straight from the (thread-safe) SQLite
//  store and disk, bypassing the main actor entirely for that hot path.
//

import Foundation
import Combine
import CryptoKit

@MainActor
final class InjectorStore: ObservableObject {

    @Published private(set) var releases: [InjectorRelease] = []
    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var publishError: String?

    @Published var port: UInt16 {
        didSet { defaults.set(Int(port), forKey: Keys.port) }
    }

    private nonisolated let store: SQLiteInjectorReleaseStore
    private nonisolated let bundlesDirectory: URL
    private let server = HTTPInjectorServer()
    private let defaults: UserDefaults

    private enum Keys {
        static let port = "injector.port"
    }

    nonisolated deinit {}

    init(store: SQLiteInjectorReleaseStore? = nil, bundlesDirectory: URL? = nil,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.port = UInt16(defaults.object(forKey: Keys.port) as? Int ?? 57334)
        self.store = store ?? Self.makeDefaultStore()
        self.bundlesDirectory = bundlesDirectory ?? Self.makeDefaultBundlesDirectory()
        try? FileManager.default.createDirectory(at: self.bundlesDirectory,
                                                 withIntermediateDirectories: true)
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

    private static func makeDefaultBundlesDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("Aerospace", isDirectory: true)
            .appendingPathComponent("InjectorBundles", isDirectory: true)
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

    /// Imports `bundleURL` into Injector's storage, tags it, and records it
    /// as a new release. Returns whether publishing succeeded; on failure,
    /// `publishError` explains why.
    @discardableResult
    func publish(bundleURL: URL, app: String, platform: String, channel: String, version: String,
                minNativeVersion: String, maxNativeVersion: String) -> Bool {
        publishError = nil

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
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destinationDir = bundlesDirectory.appendingPathComponent(id, isDirectory: true)
        let destinationFile = destinationDir.appendingPathComponent(bundleURL.lastPathComponent)

        do {
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            try data.write(to: destinationFile)
            let release = InjectorRelease(
                id: id, app: app, platform: platform, channel: channel, version: version,
                minNativeVersion: minNativeVersion, maxNativeVersion: maxNativeVersion,
                bundleHash: hash, bundlePath: destinationFile.path, createdAt: Date()
            )
            try store.insert(release)
        } catch {
            publishError = "Publish failed: \(error.localizedDescription)"
            return false
        }

        refreshReleases()
        return true
    }

    private func refreshReleases() {
        releases = store.fetchAll()
    }
}
