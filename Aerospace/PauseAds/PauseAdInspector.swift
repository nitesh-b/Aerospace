//
//  PauseAdInspector.swift
//  Aerospace
//
//  Reads a designer hand-off folder (AEP + lottie data.json + images/ + youi
//  assets/) without modifying it, derives the metadata youi.ads `auto` would
//  (target, lottieTarget, duration, loop), and reports problems before
//  anything is generated.
//
//  Differences from the CLI, all deliberate:
//  - Markers are parsed as blocks; the CLI substring-matched "Loop"/"Ad-In"
//    anywhere in the log, so a layer named "Loop-BG.jpg" made an ad loop.
//  - Duration falls back to the lottie `Ad-In` marker (dr / fr) when there is
//    no youi export; the CLI silently left 1.
//  - lottieTarget uses the real file name instead of hard-coding "data.json".
//

import Foundation
import ImageIO

nonisolated struct PauseAdInspection: Sendable {
    enum Severity: Hashable, Sendable { case warning, error }

    struct Issue: Hashable, Sendable {
        let severity: Severity
        let message: String
    }

    enum DurationSource: Hashable, Sendable { case timelineLog, lottieMarker, none }

    /// A youi drawable that will replace the same-named lottie image.
    struct ImageSwap: Hashable, Sendable {
        let name: String
        let lottieBytes: Int
        let youiBytes: Int
    }

    /// A derived field that differs from an existing metadata.json.
    struct Difference: Hashable, Sendable {
        let field: PauseAdMetadata.Field
        let existing: String
        let derived: String
    }

    let source: URL
    var aepFileName: String?
    var hasLottie = false
    /// Paths are relative to `source`.
    var layoutFile: String?
    var timelineLogFile: String?
    /// loop/target/lottieTarget/duration filled; brand fields left empty.
    var derived = PauseAdMetadata()
    var durationSource: DurationSource = .none
    var referencedImages: [String] = []
    var missingImages: [String] = []
    var unusedImages: [String] = []
    var swaps: [ImageSwap] = []
    /// Total of `images/` as delivered.
    var lottieImageBytes = 0
    /// Total of `images/` after swaps — what uap.rn downloads.
    var shippedImageBytes = 0
    var youiImageBytes = 0
    var issues: [Issue] = []

    init(source: URL) { self.source = source }

    var canGenerate: Bool { !issues.contains { $0.severity == .error } }

    mutating func warn(_ message: String) { issues.append(Issue(severity: .warning, message: message)) }
    mutating func fail(_ message: String) { issues.append(Issue(severity: .error, message: message)) }

    /// Derived fields (loop, target, lottieTarget, duration) that differ from
    /// `existing` — e.g. a stale metadata.json from an earlier AE export.
    func differences(from existing: PauseAdMetadata) -> [Difference] {
        var result: [Difference] = []
        if existing.loop != derived.loop {
            result.append(Difference(field: .loop, existing: "\(existing.loop)", derived: "\(derived.loop)"))
        }
        if existing.target != derived.target {
            result.append(Difference(field: .target, existing: existing.target, derived: derived.target))
        }
        if existing.lottieTarget != derived.lottieTarget {
            result.append(Difference(field: .lottieTarget, existing: existing.lottieTarget,
                                     derived: derived.lottieTarget))
        }
        if abs(existing.duration - derived.duration) > PauseAdInspector.durationTolerance {
            result.append(Difference(field: .duration, existing: "\(existing.duration)",
                                     derived: "\(derived.duration)"))
        }
        return result
    }
}

nonisolated enum PauseAdInspector {
    struct Marker: Hashable, Sendable {
        let name: String
        /// Seconds.
        let duration: Double
    }

    static let warnImageBytes = 3_000_000
    static let maxImageBytes = 5_000_000
    /// Exports from the same AEP agree to float32 precision.
    static let durationTolerance = 0.02

    /// Folders the CLI never descended into, plus macOS archive noise.
    private static let skippedDirectories: Set<String> = [
        "manifests", "Adobe After Effects Auto-Save", "tv-rklow", "__MACOSX",
    ]

    // MARK: - Inspect

    static func inspect(_ source: URL, fileManager: FileManager = .default) -> PauseAdInspection {
        var result = PauseAdInspection(source: source)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            result.fail("Source folder not found: \(source.path)")
            return result
        }

        let rootFiles = visibleChildren(of: source, fileManager: fileManager).filter { !isDirectoryURL($0) }

        // AEP — not used by the apps, but kept so the ad can be re-exported.
        let aeps = rootFiles
            .map(\.lastPathComponent)
            .filter { $0.lowercased().hasSuffix(".aep") && !$0.lowercased().contains("auto-save") }
            .sorted()
        result.aepFileName = aeps.first
        if aeps.isEmpty {
            result.warn("No .aep file in the source folder. The apps don't need it, but the ad can't be re-exported later.")
        } else if aeps.count > 1 {
            result.warn("Multiple .aep files; using \(aeps[0]).")
        }

        // Lottie
        var lottie: [String: Any]?
        if let dataJSON = rootFiles.first(where: { $0.lastPathComponent.lowercased() == "data.json" }) {
            if let data = try? Data(contentsOf: dataJSON),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                lottie = object
                result.hasLottie = true
                result.derived.lottieTarget = dataJSON.lastPathComponent
            } else {
                result.fail("\(dataJSON.lastPathComponent) is not valid JSON. Re-render it from Bodymovin.")
            }
        } else if let nested = nestedHandOff(in: source, fileManager: fileManager) {
            result.fail("The hand-off is inside the subfolder '\(nested)'. Select that folder as the source instead.")
        } else {
            result.fail("No data.json (lottie export) at the top of the source folder. uap.rn can't show the ad without it.")
        }

        // Target from the youi main layout, else the AEP prefix.
        let aepPrefix = aeps.first.map { String($0.dropLast(".aep".count)) }
        let layouts = files(under: source, fileManager: fileManager)
            .filter { $0.hasSuffix("_main.layout") || $0.hasSuffix("_Main.layout") }
            .sorted { lhs, rhs in
                // The youi exporter's default device folder first.
                let lhsTV = lhs.hasPrefix("assets/layout/tv/"), rhsTV = rhs.hasPrefix("assets/layout/tv/")
                return lhsTV != rhsTV ? lhsTV : lhs < rhs
            }
        // Several main layouts (e.g. X_main and X-v2_main): prefer the one named after the AEP.
        let aepLayout = aepPrefix.flatMap { prefix in
            layouts.first { ["\(prefix)_main.layout", "\(prefix)_Main.layout"].contains(($0 as NSString).lastPathComponent) }
        }
        if let layout = aepLayout ?? layouts.first {
            result.layoutFile = layout
            result.derived.target = String((layout as NSString).lastPathComponent.dropLast(".layout".count))
            if Set(layouts.map { ($0 as NSString).lastPathComponent }).count > 1 {
                result.warn("Multiple main layouts; using \(layout).")
            }
        } else if let aepPrefix {
            result.derived.target = aepPrefix
            result.warn("No youi export (*_main.layout). Target falls back to the AEP name, and youi.rn won't render this ad.")
        } else {
            result.fail("Can't determine the target: no *_main.layout and no .aep file.")
        }

        // Markers
        var timelineMarkerList: [Marker] = []
        if let layout = result.layoutFile {
            let log = (layout as NSString).deletingLastPathComponent
                + "/\(result.derived.target).timeline.log"
            if let text = try? String(contentsOf: source.appendingPathComponent(log), encoding: .utf8) {
                result.timelineLogFile = log
                timelineMarkerList = timelineMarkers(in: text)
            } else {
                result.warn("No \(result.derived.target).timeline.log next to the layout; the duration comes from the lottie export.")
            }
        }
        let lottieMarkerList = lottie.map(lottieMarkers(in:)) ?? []

        let timelineAdIn = timelineMarkerList.first { isNamed($0, "Ad-In") }
        let lottieAdIn = lottieMarkerList.first { isNamed($0, "Ad-In") }
        if let timelineAdIn {
            result.derived.duration = timelineAdIn.duration
            result.durationSource = .timelineLog
        } else if let lottieAdIn {
            result.derived.duration = lottieAdIn.duration
            result.durationSource = .lottieMarker
        } else {
            result.warn("No Ad-In marker in either export, so the duration defaults to 1s. Set it by hand or ask the designer to add the marker.")
        }
        if let timelineAdIn, let lottieAdIn,
           abs(timelineAdIn.duration - lottieAdIn.duration) > durationTolerance {
            result.warn("The youi and lottie exports disagree on the Ad-In duration (\(timelineAdIn.duration)s vs \(lottieAdIn.duration)s). They are probably from different AEP revisions; re-export both.")
        }
        result.derived.loop = (timelineMarkerList + lottieMarkerList).contains { isNamed($0, "Loop") }

        // Images
        if let lottie {
            inspectImages(lottie: lottie, into: &result, fileManager: fileManager)
        }
        result.youiImageBytes = files(under: source.appendingPathComponent("assets/drawable"),
                                      fileManager: fileManager)
            .reduce(0) { $0 + fileSize(source.appendingPathComponent("assets/drawable/\($1)")) }

        return result
    }

    private static func inspectImages(lottie: [String: Any], into result: inout PauseAdInspection,
                                      fileManager: FileManager) {
        let source = result.source
        let assets = lottie["assets"] as? [[String: Any]] ?? []
        let referenced = Set(assets.compactMap { asset -> String? in
            guard asset["layers"] == nil, let p = asset["p"] as? String, !p.isEmpty,
                  (asset["e"] as? NSNumber)?.intValue != 1, !p.hasPrefix("data:") else { return nil }
            let u = (asset["u"] as? String) ?? ""
            let path = u + p
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        })
        result.referencedImages = referenced.sorted()
        result.missingImages = result.referencedImages.filter {
            !fileManager.fileExists(atPath: source.appendingPathComponent($0).path)
        }
        if !result.missingImages.isEmpty {
            result.fail("data.json references \(result.missingImages.count) missing image(s): \(result.missingImages.joined(separator: ", ")).")
        }

        let imageFiles = files(under: source.appendingPathComponent("images"), fileManager: fileManager)
            .map { "images/\($0)" }
        result.unusedImages = imageFiles.filter { !referenced.contains($0) }.sorted()
        if !result.unusedImages.isEmpty {
            result.warn("\(result.unusedImages.count) image(s) in images/ are not referenced by data.json and will still be shipped: \(result.unusedImages.joined(separator: ", ")).")
        }

        var dimensionMismatches: [String] = []
        for path in imageFiles {
            let lottieURL = source.appendingPathComponent(path)
            let lottieBytes = fileSize(lottieURL)
            result.lottieImageBytes += lottieBytes
            result.shippedImageBytes += lottieBytes

            let name = (path as NSString).lastPathComponent
            guard path == "images/\(name)" else { continue } // only top-level images have youi twins
            let youiURL = source.appendingPathComponent("assets/drawable/default/\(name)")
            guard fileManager.fileExists(atPath: youiURL.path) else { continue }
            let youiBytes = fileSize(youiURL)
            guard youiBytes < lottieBytes else { continue }
            guard let lottieSize = pixelSize(lottieURL), let youiSize = pixelSize(youiURL),
                  lottieSize == youiSize else {
                dimensionMismatches.append(name)
                continue
            }
            result.swaps.append(PauseAdInspection.ImageSwap(name: name, lottieBytes: lottieBytes, youiBytes: youiBytes))
            result.shippedImageBytes += youiBytes - lottieBytes
        }
        result.swaps.sort { $0.name < $1.name }
        if !dimensionMismatches.isEmpty {
            result.warn("Smaller youi image(s) not swapped because the pixel dimensions differ or can't be read: \(dimensionMismatches.sorted().joined(separator: ", ")).")
        }

        let shipped = formatBytes(result.shippedImageBytes)
        if result.shippedImageBytes > maxImageBytes {
            result.warn("The lottie images total \(shipped) after swaps, over the 5 MB limit. Expect slow loading on low-end TVs; ask the designer to compress them.")
        } else if result.shippedImageBytes > warnImageBytes {
            result.warn("The lottie images total \(shipped) after swaps, over the recommended 3 MB.")
        }
    }

    // MARK: - Markers

    /// Top-level `markers { … }` blocks of a youi `*.timeline.log`.
    static func timelineMarkers(in text: String) -> [Marker] {
        var markers: [Marker] = []
        var depth = 0
        var inMarker = false
        var name: String?
        var duration: Double?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if depth == 0, line == "markers {" {
                inMarker = true
                name = nil
                duration = nil
            } else if inMarker, depth == 1 {
                if line.hasPrefix("duration:") {
                    duration = Double(line.dropFirst("duration:".count).trimmingCharacters(in: .whitespaces))
                } else if line.hasPrefix("name:") {
                    name = line.dropFirst("name:".count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }

            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if inMarker, depth <= 0 {
                if let name, let duration { markers.append(Marker(name: name, duration: duration)) }
                inMarker = false
                depth = 0
            }
        }
        return markers
    }

    /// Bodymovin `markers` (`cm` name, `dr` frames) converted to seconds.
    /// Newer Bodymovin versions may JSON-encode `cm` as `{"name": …}`.
    static func lottieMarkers(in lottie: [String: Any]) -> [Marker] {
        guard let fr = (lottie["fr"] as? NSNumber)?.doubleValue, fr > 0,
              let markers = lottie["markers"] as? [[String: Any]] else { return [] }
        return markers.compactMap { marker in
            guard var name = (marker["cm"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let frames = (marker["dr"] as? NSNumber)?.doubleValue else { return nil }
            if name.hasPrefix("{"),
               let object = try? JSONSerialization.jsonObject(with: Data(name.utf8)) as? [String: Any],
               let encoded = object["name"] as? String {
                name = encoded
            }
            return Marker(name: name, duration: (frames / fr * 1e8).rounded() / 1e8)
        }
    }

    private static func isNamed(_ marker: Marker, _ name: String) -> Bool {
        marker.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
    }

    // MARK: - File helpers

    private static func visibleChildren(of url: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles])) ?? []
    }

    private static func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Visible files under `url`, as paths relative to it, skipping
    /// `skippedDirectories`.
    private static func files(under url: URL, fileManager: FileManager) -> [String] {
        var result: [String] = []
        func walk(_ directory: URL, prefix: String) {
            for child in visibleChildren(of: directory, fileManager: fileManager) {
                let name = child.lastPathComponent
                if isDirectoryURL(child) {
                    if !skippedDirectories.contains(name) { walk(child, prefix: prefix + name + "/") }
                } else {
                    result.append(prefix + name)
                }
            }
        }
        walk(url, prefix: "")
        return result.sorted()
    }

    /// A single visible subfolder that itself looks like the hand-off.
    private static func nestedHandOff(in source: URL, fileManager: FileManager) -> String? {
        let folders = visibleChildren(of: source, fileManager: fileManager)
            .filter { isDirectoryURL($0) && !skippedDirectories.contains($0.lastPathComponent) }
        guard folders.count == 1, let folder = folders.first else { return nil }
        let names = visibleChildren(of: folder, fileManager: fileManager).map { $0.lastPathComponent.lowercased() }
        return names.contains("data.json") || names.contains(where: { $0.hasSuffix(".aep") })
            ? folder.lastPathComponent : nil
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
