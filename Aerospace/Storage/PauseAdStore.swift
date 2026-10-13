//
//  PauseAdStore.swift
//  Aerospace
//
//  The observable state for the Pause Ads tool: the source hand-off folder,
//  the destination root (normally the youi.ads repo), the job/metadata form,
//  Generate and Deploy, the hosted-ad list and the request log of the
//  Logger server's /files/* route.
//
//  Folder access survives relaunch through security-scoped bookmarks; the
//  destination stays accessible for the app's lifetime so the server can
//  keep serving it.
//

import Foundation
import Combine

@MainActor
final class PauseAdStore: ObservableObject {

    enum Status: Equatable {
        case success(String)
        case failure(String)
    }

    /// Shown when Generate targets a job that already has versions.
    struct VersionPrompt: Identifiable, Equatable {
        let job: PauseAdJob
        let latest: Int
        var next: Int { latest + 1 }
        var id: String { "\(job.relativePath)/v\(latest)" }
    }

    enum VersionChoice {
        case overwriteLatest
        case createNext
        case cancel
    }

    static let maxFileRequests = 200

    // MARK: - Folders

    @Published private(set) var sourceURL: URL?
    @Published private(set) var destinationURL: URL?

    // MARK: - Form

    @Published var adType: PauseAdType = .sales {
        didSet { saveForm() }
    }
    /// Set through `setFolderName` for hand edits; follows the brand otherwise.
    @Published private(set) var folderName = ""
    @Published var jobCode = "" {
        didSet {
            guard jobCode != oldValue else { return }
            lookupExistingJob()
            saveForm()
        }
    }
    @Published var metadata = PauseAdMetadata() {
        didSet {
            if !folderNameEdited, existingJob == nil, metadata.adBrandName != oldValue.adBrandName {
                folderName = PauseAdJob.suggestedFolderName(brand: metadata.adBrandName)
            }
            saveForm()
        }
    }
    @Published var applyImageSwaps = true {
        didSet { saveForm() }
    }
    @Published var host: PauseAdHost = .lan {
        didSet { saveForm() }
    }

    // MARK: - Derived state

    @Published private(set) var inspection: PauseAdInspection?
    /// The job with this ticket already in the destination, if any. When set,
    /// Generate and Deploy use its location instead of a new one.
    @Published private(set) var existingJob: PauseAdJob?
    /// All locations of this ticket (normally one).
    @Published private(set) var existingJobLocations: [PauseAdJob] = []
    @Published private(set) var existingVersions: [Int] = []
    /// Raw `metadata.json` of the latest existing version.
    @Published private(set) var existingMetadata: PauseAdMetadata?
    @Published private(set) var hostedAds: [HostedPauseAd] = []
    @Published private(set) var fileRequests: [PauseAdFileRequest] = []

    // MARK: - Activity

    @Published private(set) var isWorking = false
    @Published var versionPrompt: VersionPrompt?
    @Published var status: Status?
    @Published private(set) var lastGenerated: PauseAdGenerator.Result?
    @Published private(set) var lastDeployment: PauseAdDeployer.Result?

    /// Installed on the Logger server via `attach(to:)`.
    let resolver = PauseAdFileResolver()

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let bookmarks: FolderBookmarking
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var folderNameEdited = false

    private enum Keys {
        static let sourceBookmark = "pauseAds.sourceBookmark"
        static let destinationBookmark = "pauseAds.destinationBookmark"
        static let form = "pauseAds.lastForm"
    }

    private struct SavedForm: Codable {
        var adType: String
        var folderName: String
        var folderNameEdited: Bool
        var jobCode: String
        var adBrandName: String
        var adCampaign: String
        var adIndustry: String
        var upNextModifierTime: Double
        var applyImageSwaps: Bool
        var host: String
    }

    nonisolated deinit {}

    init(defaults: UserDefaults = .standard,
         bookmarks: FolderBookmarking = SecurityScopedBookmarks(),
         now: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = .current) {
        self.defaults = defaults
        self.bookmarks = bookmarks
        self.now = now
        self.calendar = calendar

        if let data = defaults.data(forKey: Keys.form),
           let form = try? JSONDecoder().decode(SavedForm.self, from: data) {
            adType = PauseAdType(rawValue: form.adType) ?? .sales
            folderName = form.folderName
            folderNameEdited = form.folderNameEdited
            jobCode = form.jobCode
            metadata.adBrandName = form.adBrandName
            metadata.adCampaign = form.adCampaign
            metadata.adIndustry = form.adIndustry
            metadata.upNextModifierTime = form.upNextModifierTime
            applyImageSwaps = form.applyImageSwaps
            host = PauseAdHost(rawValue: form.host) ?? .lan
        }

        if let url = restoreBookmark(Keys.sourceBookmark) {
            sourceURL = url
            reinspect()
        }
        if let url = restoreBookmark(Keys.destinationBookmark) {
            destinationURL = url
            resolver.setRoot(url)
            refreshHostedAds()
            lookupExistingJob()
        }
    }

    // MARK: - Server

    /// Serve the destination at `/files/*` on the Logger server.
    func attach(to logStore: LogStore) {
        logStore.setFileHandling(resolver: resolver) { [weak self] request in
            Task { @MainActor [weak self] in self?.record(request) }
        }
    }

    func record(_ request: PauseAdFileRequest) {
        fileRequests.insert(request, at: 0)
        if fileRequests.count > Self.maxFileRequests {
            fileRequests.removeLast(fileRequests.count - Self.maxFileRequests)
        }
    }

    func clearFileRequests() {
        fileRequests.removeAll()
    }

    // MARK: - Folders

    func setSource(_ url: URL) {
        replaceAccess(old: sourceURL, new: url, key: Keys.sourceBookmark)
        sourceURL = url
        reinspect()
    }

    func setDestination(_ url: URL) {
        replaceAccess(old: destinationURL, new: url, key: Keys.destinationBookmark)
        destinationURL = url
        resolver.setRoot(url)
        refreshHostedAds()
        lookupExistingJob()
    }

    /// Re-reads the source and replaces the derived fields (target,
    /// lottieTarget, duration, loop). Brand fields are kept.
    func reinspect() {
        guard let sourceURL else { return }
        let result = PauseAdInspector.inspect(sourceURL)
        inspection = result
        metadata.loop = result.derived.loop
        metadata.target = result.derived.target
        metadata.lottieTarget = result.derived.lottieTarget
        metadata.duration = result.derived.duration
    }

    func setFolderName(_ name: String) {
        folderNameEdited = true
        folderName = name
        saveForm()
    }

    func refreshHostedAds() {
        guard let destinationURL else {
            hostedAds = []
            return
        }
        hostedAds = HostedPauseAd.scan(root: destinationURL)
    }

    // MARK: - Job

    /// Where Generate will write: the existing job for this ticket, else a
    /// new one dated today.
    func currentJob() throws -> PauseAdJob {
        if let existingJob { return existingJob }
        return try PauseAdJob.make(adType: adType, folderName: folderName, jobCode: jobCode,
                                   date: now(), calendar: calendar)
    }

    var jobPreviewPath: String? { (try? currentJob())?.relativePath }

    var jobError: String? {
        do {
            _ = try currentJob()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Derived fields of the inspection that differ from the existing metadata.
    var metadataDifferences: [PauseAdInspection.Difference] {
        guard let inspection, let existingMetadata else { return [] }
        return inspection.differences(from: existingMetadata)
    }

    private func lookupExistingJob() {
        guard let destinationURL,
              !jobCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearExistingJob()
            return
        }
        let locations = PauseAdJob.locate(ticket: jobCode, under: destinationURL)
        guard !locations.isEmpty else {
            clearExistingJob()
            return
        }
        // Several locations is unusual (copied by hand); use the latest edited.
        let job = locations.max { latestModification($0, destinationURL) < latestModification($1, destinationURL) }!
        existingJobLocations = locations
        existingJob = job
        existingVersions = job.existingVersions(under: destinationURL)
        existingMetadata = existingVersions.last.flatMap { version in
            FileManager.default.contents(atPath: destinationURL.appendingPathComponent(job.metadataPath(version)).path)
                .flatMap { try? PauseAdMetadata(jsonData: $0) }
        }

        adType = job.adType
        folderName = job.folderName
        if let existing = existingMetadata {
            if metadata.adBrandName.isEmpty { metadata.adBrandName = existing.adBrandName }
            if metadata.adCampaign.isEmpty { metadata.adCampaign = existing.adCampaign }
            if metadata.adIndustry.isEmpty { metadata.adIndustry = existing.adIndustry }
            metadata.extraFields = existing.extraFields
        }
    }

    private func clearExistingJob() {
        existingJob = nil
        existingJobLocations = []
        existingVersions = []
        existingMetadata = nil
        metadata.extraFields = [:]
        if !folderNameEdited {
            folderName = PauseAdJob.suggestedFolderName(brand: metadata.adBrandName)
        }
    }

    private func latestModification(_ job: PauseAdJob, _ root: URL) -> Date {
        job.existingVersions(under: root).compactMap { version in
            try? root.appendingPathComponent(job.metadataPath(version))
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max() ?? .distantPast
    }

    // MARK: - Generate

    var canGenerate: Bool {
        sourceURL != nil && destinationURL != nil && inspection?.canGenerate == true
            && jobError == nil && !isWorking
    }

    /// Generates a fresh job straight away; for an existing one, sets
    /// `versionPrompt` and waits for `resolveVersionPrompt`.
    func generate() async {
        guard let destinationURL, sourceURL != nil else {
            status = .failure("Choose a source and a destination folder first.")
            return
        }
        let job: PauseAdJob
        do {
            job = try currentJob()
        } catch {
            status = .failure(error.localizedDescription)
            return
        }
        if let latest = job.existingVersions(under: destinationURL).last {
            versionPrompt = VersionPrompt(job: job, latest: latest)
            return
        }
        await runGenerate(job: job, version: 1, mode: .create)
    }

    func resolveVersionPrompt(_ choice: VersionChoice) async {
        guard let prompt = versionPrompt else { return }
        versionPrompt = nil
        switch choice {
        case .overwriteLatest: await runGenerate(job: prompt.job, version: prompt.latest, mode: .overwrite)
        case .createNext: await runGenerate(job: prompt.job, version: prompt.next, mode: .create)
        case .cancel: break
        }
    }

    private func runGenerate(job: PauseAdJob, version: Int, mode: PauseAdGenerator.Mode) async {
        guard let sourceURL, let destinationURL else { return }
        let request = PauseAdGenerator.Request(source: sourceURL, destinationRoot: destinationURL, job: job,
                                               version: version, mode: mode, metadata: metadata,
                                               applyImageSwaps: applyImageSwaps)
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await Task.detached { try PauseAdGenerator.generate(request) }.value
            lastGenerated = result
            let swaps = result.appliedSwaps.count
            status = .success("Generated v\(version) at \(job.versionPath(version))"
                              + (swaps > 0 ? " (\(swaps) youi image\(swaps == 1 ? "" : "s") swapped in)" : ""))
        } catch {
            status = .failure(error.localizedDescription)
        }
        refreshHostedAds()
        lookupExistingJob()
        if let inspection = lastGenerated?.inspection { self.inspection = inspection }
    }

    // MARK: - Deploy

    /// Why Deploy is unavailable; empty when it can run.
    var deployBlockers: [String] {
        var blockers: [String] = []
        if existingVersions.isEmpty { blockers.append("Generate the pause ad first") }
        blockers += metadata.normalizedForManifest().missingDeployFields.map(\.label)
        return blockers
    }

    /// Saves the form's metadata into the latest version, then zips it.
    func deploy() async {
        guard let destinationURL, let job = existingJob, let version = existingVersions.last else {
            status = .failure("Generate the pause ad before deploying.")
            return
        }
        let missing = metadata.normalizedForManifest().missingDeployFields
        guard missing.isEmpty else {
            status = .failure("Fill in before deploying: " + missing.map(\.label).joined(separator: ", ") + ".")
            return
        }
        let generated = FileManager.default
            .contents(atPath: destinationURL.appendingPathComponent(job.hostedMetadataPath(version)).path)
            .flatMap { try? PauseAdMetadata(jsonData: $0) }
        if let generated, generated.target != metadata.target || generated.lottieTarget != metadata.lottieTarget {
            status = .failure("The target or lottie file changed since v\(version) was generated. Regenerate before deploying.")
            return
        }

        let metadata = self.metadata
        let request = PauseAdDeployer.Request(destinationRoot: destinationURL, job: job, version: version,
                                              date: now(), calendar: calendar)
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await Task.detached {
                try PauseAdGenerator.updateMetadata(metadata, job: job, version: version,
                                                    destinationRoot: destinationURL)
                return try PauseAdDeployer.deploy(request)
            }.value
            lastDeployment = result
            status = .success("Deployed v\(version): \(result.relativePath)")
        } catch {
            status = .failure(error.localizedDescription)
        }
        refreshHostedAds()
        lookupExistingJob()
    }

    // MARK: - URLs

    func hostedURL(for ad: HostedPauseAd, port: UInt16) -> String {
        ad.url(host: host.address(), port: port)
    }

    func rotationSnippet(for ids: Set<String>, port: UInt16) -> String {
        HostedPauseAd.rotationSnippet(hostedAds.filter { ids.contains($0.id) }, host: host.address(), port: port)
    }

    // MARK: - Persistence

    private func saveForm() {
        let form = SavedForm(adType: adType.rawValue, folderName: folderName, folderNameEdited: folderNameEdited,
                             jobCode: jobCode, adBrandName: metadata.adBrandName, adCampaign: metadata.adCampaign,
                             adIndustry: metadata.adIndustry, upNextModifierTime: metadata.upNextModifierTime,
                             applyImageSwaps: applyImageSwaps, host: host.rawValue)
        if let data = try? JSONEncoder().encode(form) {
            defaults.set(data, forKey: Keys.form)
        }
    }

    private func replaceAccess(old: URL?, new: URL, key: String) {
        if let old, old != new { bookmarks.stopAccessing(old) }
        if old != new { bookmarks.startAccessing(new) }
        if let data = try? bookmarks.bookmark(for: new) {
            defaults.set(data, forKey: key)
        }
    }

    private func restoreBookmark(_ key: String) -> URL? {
        guard let data = defaults.data(forKey: key),
              let resolved = try? bookmarks.resolve(data) else { return nil }
        let url = resolved.url
        bookmarks.startAccessing(url)
        if resolved.isStale, let fresh = try? bookmarks.bookmark(for: url) {
            defaults.set(fresh, forKey: key)
        }
        return url
    }
}
