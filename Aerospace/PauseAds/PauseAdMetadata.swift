//
//  PauseAdMetadata.swift
//  Aerospace
//
//  The pause ad `metadata.json` read by uap.rn / youi.rn. Mirrors
//  youi.ads/templates/metadata_standard_template.json: keys are written in
//  template order, and keys this tool doesn't model (e.g. `adType`,
//  `runtimeSourcePath`) are carried through untouched, as youi.ads `gen` does.
//

import Foundation

nonisolated struct PauseAdMetadata: Hashable, Sendable {
    var loop: Bool
    /// youi layout target, e.g. `Specsavers-2026-PremiumPause-Ad-25_main`.
    var target: String
    /// Lottie file name relative to metadata.json, normally `data.json`.
    var lottieTarget: String
    /// Seconds; the `Ad-In` marker duration.
    var duration: Double
    var adBrandName: String
    var adCampaign: String
    var adIndustry: String
    var upNextModifierTime: Double
    /// Unmodelled top-level keys → their serialized JSON value.
    var extraFields: [String: String]

    init(
        loop: Bool = false,
        target: String = "",
        lottieTarget: String = "",
        duration: Double = 1,
        adBrandName: String = "",
        adCampaign: String = "",
        adIndustry: String = "",
        upNextModifierTime: Double = 0,
        extraFields: [String: String] = [:]
    ) {
        self.loop = loop
        self.target = target
        self.lottieTarget = lottieTarget
        self.duration = duration
        self.adBrandName = adBrandName
        self.adCampaign = adCampaign
        self.adIndustry = adIndustry
        self.upNextModifierTime = upNextModifierTime
        self.extraFields = extraFields
    }

    // MARK: - Deploy validation

    enum Field: String, CaseIterable, Sendable {
        case loop, target, lottieTarget, duration, adBrandName, adCampaign, adIndustry

        var label: String {
            switch self {
            case .loop: return "Loop"
            case .target: return "Target"
            case .lottieTarget: return "Lottie target"
            case .duration: return "Duration"
            case .adBrandName: return "Brand name"
            case .adCampaign: return "Campaign"
            case .adIndustry: return "Industry"
            }
        }
    }

    /// Fields that must be filled before a deployment zip is produced, in
    /// display order (user-entered first, then derived).
    var missingDeployFields: [Field] {
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var missing: [Field] = []
        if blank(adBrandName) { missing.append(.adBrandName) }
        if blank(adCampaign) { missing.append(.adCampaign) }
        if blank(adIndustry) { missing.append(.adIndustry) }
        if blank(target) { missing.append(.target) }
        if blank(lottieTarget) { missing.append(.lottieTarget) }
        if !(duration > 0) { missing.append(.duration) }
        return missing
    }

    var isDeployable: Bool { missingDeployFields.isEmpty }

    // MARK: - Manifest normalization

    /// youi.ads `generateManifest` rule for brand/campaign/industry:
    /// lowercase, strip every `&` and `-`, collapse runs of 2+ spaces to one.
    static func normalizeForManifest(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "[&-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
    }

    /// The copy written to `manifests/RemoteManifest/metadata.json`.
    func normalizedForManifest() -> PauseAdMetadata {
        var copy = self
        copy.adBrandName = Self.normalizeForManifest(adBrandName)
        copy.adCampaign = Self.normalizeForManifest(adCampaign)
        copy.adIndustry = Self.normalizeForManifest(adIndustry)
        return copy
    }

    // MARK: - JSON

    enum DecodeError: Error, LocalizedError {
        case notAnObject

        var errorDescription: String? { "metadata.json is not a JSON object" }
    }

    init(jsonData: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw DecodeError.notAnObject
        }
        let defaults = PauseAdMetadata()
        self.init(
            loop: object["loop"] as? Bool ?? defaults.loop,
            target: object["target"] as? String ?? defaults.target,
            lottieTarget: object["lottieTarget"] as? String ?? defaults.lottieTarget,
            duration: object["duration"] as? Double ?? defaults.duration,
            adBrandName: object["adBrandName"] as? String ?? defaults.adBrandName,
            adCampaign: object["adCampaign"] as? String ?? defaults.adCampaign,
            adIndustry: object["adIndustry"] as? String ?? defaults.adIndustry,
            upNextModifierTime: object["upNextModifierTime"] as? Double ?? defaults.upNextModifierTime
        )
        for (key, value) in object where !Self.knownKeys.contains(key) {
            extraFields[key] = try Self.fragment(value)
        }
    }

    private static let knownKeys: Set<String> = [
        "loop", "target", "lottieTarget", "duration", "adBrandName",
        "adCampaign", "adIndustry", "upNextModifierTime",
    ]

    /// Tab-indented JSON with keys in template order, extras appended sorted.
    func jsonData() throws -> Data {
        var pairs: [(String, String)] = [
            ("loop", try Self.fragment(loop)),
            ("target", try Self.fragment(target)),
            ("lottieTarget", try Self.fragment(lottieTarget)),
            ("duration", try Self.fragment(duration)),
            ("adBrandName", try Self.fragment(adBrandName)),
            ("adCampaign", try Self.fragment(adCampaign)),
            ("adIndustry", try Self.fragment(adIndustry)),
            ("upNextModifierTime", try Self.fragment(upNextModifierTime)),
        ]
        for key in extraFields.keys.sorted() {
            pairs.append((key, extraFields[key]!))
        }
        let body = try pairs
            .map { "\t\(try Self.fragment($0.0)): \($0.1)" }
            .joined(separator: ",\n")
        return Data("{\n\(body)\n}\n".utf8)
    }

    private static func fragment(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
