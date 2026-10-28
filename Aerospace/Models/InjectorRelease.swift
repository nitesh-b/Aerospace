//
//  InjectorRelease.swift
//  Aerospace
//
//  A single published Injector release: which app/platform/channel it
//  targets, which native-app-version range it's compatible with, and where
//  its bundle file lives on disk. Persisted by SQLiteInjectorReleaseStore;
//  the bundle bytes themselves are a flat file, not stored here.
//

import Foundation

struct InjectorRelease: Identifiable, Equatable, Sendable {
    let id: String
    let app: String
    let platform: String
    let channel: String
    let version: String
    let minNativeVersion: String
    let maxNativeVersion: String
    let bundleHash: String
    let bundlePath: String
    let createdAt: Date
    /// Every file in the release folder (the bundle plus any assets), as
    /// listed in the static manifest. Empty for releases published before
    /// the static OTA layout existed; those are left out of the manifest.
    var files: [InjectorReleaseFile] = []

    /// The bundle's path relative to the release folder.
    var bundleFileName: String {
        URL(fileURLWithPath: bundlePath).lastPathComponent
    }

    func isCompatible(withNativeVersion nativeVersion: String) -> Bool {
        InjectorVersion.isCompatible(reported: nativeVersion, min: minNativeVersion, max: maxNativeVersion)
    }
}

/// One file of a release, addressed relative to the release folder.
nonisolated struct InjectorReleaseFile: Codable, Equatable, Sendable {
    /// "/"-separated path relative to the release folder, e.g.
    /// "main.jsbundle" or "assets/src/images/logo.png".
    let path: String
    let sha256: String
}
