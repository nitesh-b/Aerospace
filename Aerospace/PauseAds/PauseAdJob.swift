//
//  PauseAdJob.swift
//  Aerospace
//
//  Where a pause ad lives inside the youi.ads tree. Mirrors youi.ads
//  `setup-s` / `setup-h` (folder layout), `deploy` (deployment path and zip
//  title). All paths are relative to the destination root, `/`-separated.
//
//      ads/{sales|house}/{YYYY}/{folder}/{MM}{Mon}/pause/p-{job}/v{n}/
//          server/                     designer hand-off copy
//          metadata.json               editable metadata
//          manifests/RemoteManifest/   what the apps load
//

import Foundation

nonisolated enum PauseAdType: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sales
    case house

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sales: return "Sales"
        case .house: return "House"
        }
    }
}

nonisolated struct PauseAdJob: Hashable, Sendable {
    let adType: PauseAdType
    let year: String
    let folderName: String
    let monthFolder: String
    /// Always `p-` prefixed, e.g. `p-19583`.
    let ticket: String

    enum ValidationError: Error, Equatable, LocalizedError {
        case emptyFolderName
        case invalidFolderName
        case emptyJobCode
        case invalidJobCode

        var errorDescription: String? {
            switch self {
            case .emptyFolderName: return "Folder name is required."
            case .invalidFolderName:
                return "Folder name may only contain letters, digits, '.', '_' and '-', and must start with a letter or digit."
            case .emptyJobCode: return "Job code is required."
            case .invalidJobCode: return "Job code may only contain letters, digits, '_' and '-'."
            }
        }
    }

    // MARK: - Construction

    /// A new job dated `date` (year and month folder come from it), as
    /// `setup-s` / `setup-h` would create.
    static func make(adType: PauseAdType, folderName: String, jobCode: String,
                     date: Date = Date(), calendar: Calendar = .current) throws -> PauseAdJob {
        let folder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { throw ValidationError.emptyFolderName }
        guard folder.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw ValidationError.invalidFolderName
        }

        let ticket = normalizeTicket(jobCode)
        let code = ticket.dropFirst(ticketPrefix.count)
        guard !code.isEmpty else { throw ValidationError.emptyJobCode }
        guard code.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ValidationError.invalidJobCode
        }

        return PauseAdJob(adType: adType,
                          year: String(calendar.component(.year, from: date)),
                          folderName: folder,
                          monthFolder: monthFolder(for: date, calendar: calendar),
                          ticket: ticket)
    }

    /// Parses `ads/{type}/{year}/{folder}/{month}/pause/{ticket}[/...]`.
    /// A leading `/` and any deeper components are ignored.
    init?(relativePath: String) {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count >= 7, parts[0] == "ads", parts[5] == "pause",
              let type = PauseAdType(rawValue: parts[1]) else { return nil }
        self.init(adType: type, year: parts[2], folderName: parts[3],
                  monthFolder: parts[4], ticket: parts[6])
    }

    private init(adType: PauseAdType, year: String, folderName: String,
                 monthFolder: String, ticket: String) {
        self.adType = adType
        self.year = year
        self.folderName = folderName
        self.monthFolder = monthFolder
        self.ticket = ticket
    }

    // MARK: - Naming rules

    private static let ticketPrefix = "p-"

    /// `19583`, `p-19583` and `P-19583` all become `p-19583`. (The CLI only
    /// recognised lowercase `p-`, turning `P-19583` into `p-P-19583`.)
    static func normalizeTicket(_ jobCode: String) -> String {
        var code = jobCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.lowercased().hasPrefix(ticketPrefix) {
            code.removeFirst(ticketPrefix.count)
        }
        return ticketPrefix + code
    }

    /// Node's `toLocaleDateString('en-GB', { month: 'short' })`, which the CLI
    /// uses. Foundation's en_GB formatter says "Sep", so the table is fixed.
    private static let enGBShortMonths = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec",
    ]

    /// `MM` + en-GB short month, e.g. `09Sept`, `10Oct`.
    static func monthFolder(for date: Date, calendar: Calendar = .current) -> String {
        let month = calendar.component(.month, from: date)
        return String(format: "%02d", month) + enGBShortMonths[month - 1]
    }

    /// Lowercased brand with every run of non `[a-z0-9]` replaced by `_`.
    static func suggestedFolderName(brand: String) -> String {
        brand.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    // MARK: - Paths

    var relativePath: String {
        ["ads", adType.rawValue, year, folderName, monthFolder, "pause", ticket].joined(separator: "/")
    }

    func versionPath(_ version: Int) -> String { "\(relativePath)/v\(version)" }
    func serverPath(_ version: Int) -> String { versionPath(version) + "/server" }
    func metadataPath(_ version: Int) -> String { versionPath(version) + "/metadata.json" }
    func remoteManifestPath(_ version: Int) -> String { versionPath(version) + "/manifests/RemoteManifest" }
    func hostedMetadataPath(_ version: Int) -> String { remoteManifestPath(version) + "/metadata.json" }

    /// `deployments/` + the ads tree from `{type}` down to `v{n}`.
    func deploymentDirectory(_ version: Int) -> String {
        ["deployments", adType.rawValue, year, folderName, monthFolder, "pause", ticket, "v\(version)"]
            .joined(separator: "/")
    }

    /// CLI `deployZips` title: target up to the first `_`, with `(`/`)` and
    /// whitespace turned into `_`.
    static func deploymentTitle(target: String) -> String {
        let head = target.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        return head
            .replacingOccurrences(of: "[()]", with: "_", options: .regularExpression)
            .replacingOccurrences(of: " +", with: "_", options: .regularExpression)
            .replacingOccurrences(of: "\\s", with: "_", options: .regularExpression)
    }

    /// `{title}-dpm-{yyyy-MM-dd}.zip` inside `deploymentDirectory`.
    func deploymentZipPath(_ version: Int, target: String, date: Date = Date(),
                           calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return deploymentDirectory(version) + "/\(Self.deploymentTitle(target: target))-dpm-\(stamp).zip"
    }

    // MARK: - File system

    /// Version numbers of existing `v{n}` directories, ascending.
    func existingVersions(under root: URL, fileManager: FileManager = .default) -> [Int] {
        let jobURL = root.appendingPathComponent(relativePath, isDirectory: true)
        return Self.subdirectoryNames(of: jobURL, fileManager: fileManager)
            .compactMap { name -> Int? in
                let digits = name.dropFirst()
                guard name.hasPrefix("v"), !digits.isEmpty,
                      digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
                return Int(digits)
            }
            .sorted()
    }

    func nextVersion(under root: URL, fileManager: FileManager = .default) -> Int {
        (existingVersions(under: root, fileManager: fileManager).last ?? 0) + 1
    }

    /// Every existing job with this ticket, in any type/year/folder/month,
    /// sorted by path. The CLI only noticed duplicates in the current month.
    static func locate(ticket jobCode: String, under root: URL,
                       fileManager: FileManager = .default) -> [PauseAdJob] {
        let ticket = normalizeTicket(jobCode)
        var found: [PauseAdJob] = []
        for type in PauseAdType.allCases {
            let typeURL = root.appendingPathComponent("ads/\(type.rawValue)", isDirectory: true)
            for year in subdirectoryNames(of: typeURL, fileManager: fileManager) {
                let yearURL = typeURL.appendingPathComponent(year, isDirectory: true)
                for folder in subdirectoryNames(of: yearURL, fileManager: fileManager) {
                    let folderURL = yearURL.appendingPathComponent(folder, isDirectory: true)
                    for month in subdirectoryNames(of: folderURL, fileManager: fileManager) {
                        let ticketURL = folderURL
                            .appendingPathComponent(month, isDirectory: true)
                            .appendingPathComponent("pause/\(ticket)", isDirectory: true)
                        var isDirectory: ObjCBool = false
                        if fileManager.fileExists(atPath: ticketURL.path, isDirectory: &isDirectory),
                           isDirectory.boolValue {
                            found.append(PauseAdJob(adType: type, year: year, folderName: folder,
                                                    monthFolder: month, ticket: ticket))
                        }
                    }
                }
            }
        }
        return found.sorted { $0.relativePath < $1.relativePath }
    }

    private static func subdirectoryNames(of url: URL, fileManager: FileManager) -> [String] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
    }
}
