//
//  HostedPauseAd.swift
//  Aerospace
//
//  A generated pause ad found under the destination root, and the URLs /
//  parameters.js snippet used to load it in uap.rn or youi.rn.
//

import Foundation

/// Which address the apps should use to reach this Mac.
nonisolated enum PauseAdHost: String, CaseIterable, Identifiable, Sendable {
    /// Real devices (TVs, phones) on the same network.
    case lan
    /// Apps running on this Mac (youi.rn osx, simulators).
    case localhost
    /// The Android emulator's alias for the host Mac.
    case androidEmulator

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lan: return "LAN IP"
        case .localhost: return "localhost"
        case .androidEmulator: return "Android emulator (10.0.2.2)"
        }
    }

    func address(lan: String? = LANAddress.current()) -> String {
        switch self {
        case .lan: return lan ?? "localhost"
        case .localhost: return "localhost"
        case .androidEmulator: return "10.0.2.2"
        }
    }
}

nonisolated struct HostedPauseAd: Identifiable, Hashable, Sendable {
    let job: PauseAdJob
    let version: Int
    /// The normalized metadata that is served.
    let metadata: PauseAdMetadata
    let modified: Date

    var id: String { metadataPath }

    /// Relative to the destination root.
    var metadataPath: String { job.hostedMetadataPath(version) }

    func url(host: String, port: UInt16) -> String {
        "http://\(host):\(port)/files/\(Self.encodedPath(metadataPath))"
    }

    private static func encodedPath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    /// Paste-ready lines for uap.rn / youi.rn `parameters.js`, in the format
    /// documented in youi.ads/documentation/how-to-test-pause-ads-2025.md.
    static func rotationSnippet(_ ads: [HostedPauseAd], host: String, port: UInt16) -> String {
        var lines = ["export const pauseAdHost = 'http://\(host):\(port)/';",
                     "export const pauseAdRotation = ["]
        lines += ads.map { "\t`${pauseAdHost}files/\(encodedPath($0.metadataPath))`," }
        lines += ["];", "// Also required in devMenu: useLocalPauseAds: true"]
        return lines.joined(separator: "\n")
    }

    // MARK: - Scan

    /// Every `ads/{sales|house}/*/*/*/pause/*/v{n}` with a readable
    /// `manifests/RemoteManifest/metadata.json`, newest first.
    static func scan(root: URL, fileManager: FileManager = .default) -> [HostedPauseAd] {
        var found: [HostedPauseAd] = []
        for type in PauseAdType.allCases {
            let typeURL = root.appendingPathComponent("ads/\(type.rawValue)", isDirectory: true)
            for year in subdirectories(of: typeURL, fileManager) {
                for folder in subdirectories(of: year, fileManager) {
                    for month in subdirectories(of: folder, fileManager) {
                        for ticket in subdirectories(of: month.appendingPathComponent("pause"), fileManager) {
                            let relative = ["ads", type.rawValue, year.lastPathComponent, folder.lastPathComponent,
                                            month.lastPathComponent, "pause", ticket.lastPathComponent]
                                .joined(separator: "/")
                            guard let job = PauseAdJob(relativePath: relative) else { continue }
                            for version in job.existingVersions(under: root, fileManager: fileManager) {
                                let metadataURL = root.appendingPathComponent(job.hostedMetadataPath(version))
                                guard let data = fileManager.contents(atPath: metadataURL.path),
                                      let metadata = try? PauseAdMetadata(jsonData: data) else { continue }
                                let modified = (try? metadataURL.resourceValues(forKeys: [.contentModificationDateKey])
                                    .contentModificationDate) ?? .distantPast
                                found.append(HostedPauseAd(job: job, version: version, metadata: metadata,
                                                           modified: modified))
                            }
                        }
                    }
                }
            }
        }
        return found.sorted { ($0.modified, $0.id) > ($1.modified, $1.id) }
    }

    private static func subdirectories(of url: URL, _ fileManager: FileManager) -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
