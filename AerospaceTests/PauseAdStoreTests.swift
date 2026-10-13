//
//  PauseAdStoreTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

/// Bookmarks as plain paths; records access calls.
final class FakeBookmarks: FolderBookmarking, @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [String] = []
    private var _stopped: [String] = []
    var started: [String] { lock.lock(); defer { lock.unlock() }; return _started }
    var stopped: [String] { lock.lock(); defer { lock.unlock() }; return _stopped }

    func bookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self), isDirectory: true), false)
    }
    func startAccessing(_ url: URL) -> Bool { lock.lock(); _started.append(url.lastPathComponent); lock.unlock(); return true }
    func stopAccessing(_ url: URL) { lock.lock(); _stopped.append(url.lastPathComponent); lock.unlock() }
}

@MainActor
final class PauseAdStoreTests: XCTestCase {

    private var base: URL!
    private var source: URL { base.appendingPathComponent("handoff", isDirectory: true) }
    private var destination: URL { base.appendingPathComponent("youi.ads", isDirectory: true) }
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let bookmarks = FakeBookmarks()
    private let prefix = "Brand-2026-PremiumPause-Ad"
    private let v1 = "ads/sales/2026/specsavers/10Oct/pause/p-19583/v1"

    private nonisolated static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }
    private nonisolated static let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9))!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PauseAdStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try write("\(prefix).aep", "aep", in: source)
        try write("data.json", #"{"fr":60,"assets":[],"markers":[{"tm":0,"cm":"Ad-In","dr":240}]}"#, in: source)
        try write("assets/layout/tv/\(prefix)_main.layout", "layout", in: source)
        try write("assets/layout/tv/\(prefix)_main.timeline.log", """
        markers {
          duration: 3.86666656
          name: "Ad-In"
        }
        """, in: source)
        suiteName = "PauseAdStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ relative: String, _ text: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func makeStore(defaults custom: UserDefaults? = nil) -> PauseAdStore {
        PauseAdStore(defaults: custom ?? defaults, bookmarks: bookmarks, now: { Self.today }, calendar: Self.calendar)
    }

    /// A store with no persisted form, as on a first launch.
    private func makeFreshStore() -> PauseAdStore {
        let name = "PauseAdStoreTests-fresh-\(UUID().uuidString)"
        let fresh = UserDefaults(suiteName: name)!
        addTeardownBlock { fresh.removePersistentDomain(forName: name) }
        return makeStore(defaults: fresh)
    }

    /// Source + destination chosen, brand fields filled, job code set.
    private func readyStore() -> PauseAdStore {
        let store = makeStore()
        store.setSource(source)
        store.setDestination(destination)
        store.metadata.adBrandName = "Specsavers"
        store.metadata.adCampaign = "278843"
        store.metadata.adIndustry = "Style and fashion"
        store.jobCode = "P-19583"
        return store
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: destination.appendingPathComponent(relative).path)
    }

    // MARK: - Source / inspection

    func testSetSourceInspectsAndFillsDerivedFieldsKeepingBrand() {
        let store = makeStore()
        store.metadata.adBrandName = "Kept"
        store.setSource(source)

        XCTAssertEqual(store.sourceURL?.lastPathComponent, "handoff")
        XCTAssertEqual(store.inspection?.canGenerate, true)
        XCTAssertEqual(store.metadata.target, "\(prefix)_main")
        XCTAssertEqual(store.metadata.lottieTarget, "data.json")
        XCTAssertEqual(store.metadata.duration, 3.86666656)
        XCTAssertEqual(store.metadata.adBrandName, "Kept")
        XCTAssertEqual(bookmarks.started, ["handoff"])
    }

    func testReplacingSourceStopsAccessToPrevious() throws {
        let store = makeStore()
        store.setSource(source)
        let other = base.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        store.setSource(other)
        XCTAssertEqual(bookmarks.stopped, ["handoff"])
        XCTAssertEqual(store.inspection?.canGenerate, false)
    }

    // MARK: - Folder name and job preview

    func testFolderNameFollowsBrandUntilEditedByHand() {
        let store = makeStore()
        store.metadata.adBrandName = "Old El Paso"
        XCTAssertEqual(store.folderName, "old_el_paso")
        store.setFolderName("oldelpaso")
        store.metadata.adBrandName = "Something Else"
        XCTAssertEqual(store.folderName, "oldelpaso")
    }

    func testJobPreview() {
        let store = readyStore()
        XCTAssertEqual(store.jobPreviewPath, "ads/sales/2026/specsavers/10Oct/pause/p-19583")
        store.jobCode = "bad code"
        XCTAssertNil(store.jobPreviewPath)
        XCTAssertNotNil(store.jobError)
    }

    // MARK: - Generate

    func testGenerateFreshJob() async throws {
        let store = readyStore()
        XCTAssertTrue(store.canGenerate)
        await store.generate()

        XCTAssertNil(store.versionPrompt)
        XCTAssertTrue(exists("\(v1)/manifests/RemoteManifest/metadata.json"))
        guard case .success = store.status else { return XCTFail("\(String(describing: store.status))") }
        XCTAssertEqual(store.existingVersions, [1])
        XCTAssertEqual(store.hostedAds.map(\.metadataPath), ["\(v1)/manifests/RemoteManifest/metadata.json"])
        XCTAssertEqual(store.lastGenerated?.version, 1)
        XCTAssertFalse(store.isWorking)
    }

    func testGenerateExistingAsksThenOverwrites() async throws {
        let store = readyStore()
        await store.generate()
        await store.generate()
        XCTAssertEqual(store.versionPrompt?.latest, 1)
        XCTAssertEqual(store.versionPrompt?.next, 2)

        store.metadata.adCampaign = "Updated"
        await store.resolveVersionPrompt(.overwriteLatest)
        XCTAssertNil(store.versionPrompt)
        XCTAssertEqual(store.existingVersions, [1])
        let raw = try PauseAdMetadata(jsonData: Data(contentsOf: destination.appendingPathComponent("\(v1)/metadata.json")))
        XCTAssertEqual(raw.adCampaign, "Updated")
    }

    func testGenerateExistingCreateNext() async {
        let store = readyStore()
        await store.generate()
        await store.generate()
        await store.resolveVersionPrompt(.createNext)
        XCTAssertEqual(store.existingVersions, [1, 2])
        XCTAssertEqual(store.hostedAds.count, 2)
    }

    func testGenerateExistingCancel() async {
        let store = readyStore()
        await store.generate()
        await store.generate()
        await store.resolveVersionPrompt(.cancel)
        XCTAssertNil(store.versionPrompt)
        XCTAssertEqual(store.existingVersions, [1])
    }

    func testGenerateWithoutDestinationFails() async {
        let store = makeStore()
        store.setSource(source)
        store.jobCode = "1"
        store.metadata.adBrandName = "B"
        XCTAssertFalse(store.canGenerate)
        await store.generate()
        guard case .failure = store.status else { return XCTFail("expected failure") }
    }

    func testGeneratorErrorsSurfaceAsStatus() async throws {
        let store = readyStore()
        try FileManager.default.removeItem(at: source.appendingPathComponent("data.json"))
        await store.generate()
        guard case .failure(let message) = store.status else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("data.json"), message)
    }

    // MARK: - Existing job lookup

    func testExistingJobInOtherMonthIsAdoptedAndFillsBlankBrandFields() async throws {
        let first = readyStore()
        await first.generate()
        // Same ticket, generated in "September" by hand-moving the folder.
        let old = destination.appendingPathComponent("ads/sales/2026/specsavers/10Oct")
        try FileManager.default.moveItem(at: old, to: destination.appendingPathComponent("ads/sales/2026/specsavers/09Sept"))

        let store = makeFreshStore()
        store.setSource(source)
        store.setDestination(destination)
        store.adType = .house
        store.jobCode = "19583"

        XCTAssertEqual(store.existingJob?.relativePath, "ads/sales/2026/specsavers/09Sept/pause/p-19583")
        XCTAssertEqual(store.jobPreviewPath, "ads/sales/2026/specsavers/09Sept/pause/p-19583")
        XCTAssertEqual(store.adType, .sales)
        XCTAssertEqual(store.folderName, "specsavers")
        XCTAssertEqual(store.metadata.adBrandName, "Specsavers")
        XCTAssertEqual(store.metadata.adIndustry, "Style and fashion")
        XCTAssertEqual(store.metadataDifferences, [])
    }

    func testExistingJobDoesNotOverwriteTypedBrand() async {
        let first = readyStore()
        await first.generate()
        let store = makeFreshStore()
        store.setDestination(destination)
        store.metadata.adBrandName = "Typed"
        store.jobCode = "19583"
        XCTAssertEqual(store.metadata.adBrandName, "Typed")
    }

    func testDifferencesAgainstExistingMetadataAreReported() async throws {
        let first = readyStore()
        first.metadata.duration = 5.5
        await first.generate()

        let store = makeStore()
        store.setDestination(destination)
        store.jobCode = "19583"
        store.setSource(source)
        XCTAssertEqual(store.metadataDifferences.map(\.field), [.duration])
    }

    // MARK: - Deploy

    func testDeployBlockedUntilGeneratedAndComplete() async {
        let store = readyStore()
        XCTAssertFalse(store.deployBlockers.isEmpty)
        await store.deploy()
        guard case .failure = store.status else { return XCTFail("expected failure") }

        store.metadata.adIndustry = ""
        await store.generate()
        XCTAssertEqual(store.deployBlockers, ["Industry"])
        await store.deploy()
        guard case .failure = store.status else { return XCTFail("expected failure") }
        XCTAssertFalse(exists("deployments"))
    }

    func testFillBrandAfterTestingThenDeploy() async throws {
        let store = readyStore()
        store.metadata.adCampaign = ""
        await store.generate()

        store.metadata.adCampaign = "Spring  Sale"
        XCTAssertEqual(store.deployBlockers, [])
        await store.deploy()

        guard case .success = store.status else { return XCTFail("\(String(describing: store.status))") }
        let zip = "deployments/sales/2026/specsavers/10Oct/pause/p-19583/v1/\(prefix)-dpm-2026-10-13.zip"
        XCTAssertTrue(exists(zip), "expected \(zip)")
        XCTAssertEqual(store.lastDeployment?.metadata.adCampaign, "spring sale")
    }

    func testDeployRefusesChangedTarget() async {
        let store = readyStore()
        await store.generate()
        store.metadata.target = "Other_main"
        await store.deploy()
        guard case .failure(let message) = store.status else { return XCTFail("expected failure") }
        XCTAssertTrue(message.lowercased().contains("regenerate"), message)
    }

    // MARK: - Hosting

    func testResolverFollowsDestination() {
        let store = makeStore()
        XCTAssertNil(store.resolver.root)
        store.setDestination(destination)
        XCTAssertEqual(store.resolver.root?.lastPathComponent, "youi.ads")
    }

    func testRotationSnippetForSelection() async {
        let store = readyStore()
        store.host = .localhost
        await store.generate()
        let snippet = store.rotationSnippet(for: Set(store.hostedAds.map(\.id)), port: 57333)
        XCTAssertTrue(snippet.contains("export const pauseAdHost = 'http://localhost:57333/';"))
        XCTAssertTrue(snippet.contains("files/\(v1)/manifests/RemoteManifest/metadata.json"))
        XCTAssertEqual(store.hostedURL(for: store.hostedAds[0], port: 57333),
                       "http://localhost:57333/files/\(v1)/manifests/RemoteManifest/metadata.json")
    }

    func testFileRequestLogIsNewestFirstAndCapped() {
        let store = makeStore()
        for i in 0..<(PauseAdStore.maxFileRequests + 5) {
            store.record(PauseAdFileRequest(date: Date(), method: "GET", path: "/files/ads/\(i)",
                                            status: 200, bytes: 1, client: "1.2.3.4"))
        }
        XCTAssertEqual(store.fileRequests.count, PauseAdStore.maxFileRequests)
        XCTAssertEqual(store.fileRequests.first?.path, "/files/ads/\(PauseAdStore.maxFileRequests + 4)")
        store.clearFileRequests()
        XCTAssertEqual(store.fileRequests, [])
    }

    // MARK: - Persistence

    func testFoldersAndFormSurviveRelaunch() {
        let first = readyStore()
        first.adType = .house
        first.setFolderName("customfolder")
        first.applyImageSwaps = false
        first.host = .androidEmulator

        let store = makeStore()
        XCTAssertEqual(store.sourceURL?.lastPathComponent, "handoff")
        XCTAssertEqual(store.destinationURL?.lastPathComponent, "youi.ads")
        XCTAssertEqual(store.resolver.root?.lastPathComponent, "youi.ads")
        XCTAssertEqual(store.adType, .house)
        XCTAssertEqual(store.folderName, "customfolder")
        XCTAssertEqual(store.jobCode, "P-19583")
        XCTAssertEqual(store.metadata.adBrandName, "Specsavers")
        XCTAssertEqual(store.metadata.target, "\(prefix)_main", "derived fields re-inspected")
        XCTAssertFalse(store.applyImageSwaps)
        XCTAssertEqual(store.host, .androidEmulator)
        store.metadata.adBrandName = "Other"
        XCTAssertEqual(store.folderName, "customfolder", "hand-edited flag persisted")
    }
}
