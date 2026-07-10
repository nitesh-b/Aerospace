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

    func isCompatible(withNativeVersion nativeVersion: String) -> Bool {
        InjectorVersion.isCompatible(reported: nativeVersion, min: minNativeVersion, max: maxNativeVersion)
    }
}
