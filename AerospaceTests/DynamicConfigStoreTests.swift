//
//  DynamicConfigStoreTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

/// Bookmarks for files as plain paths.
private final class FakeFileBookmarks: FolderBookmarking, @unchecked Sendable {
    func bookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), false)
    }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}

@MainActor
final class DynamicConfigStoreTests: XCTestCase {

    private var base: URL!
    private var file: URL { base.appendingPathComponent("dynamic_config_2026_10_23.json") }
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let bookmarks = FakeFileBookmarks()
    private let appLaunch = ["tealiumEventPermissionMap", "app_launch"]

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicConfigStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data(sampleDynamicConfig.utf8).write(to: file)
        suiteName = "DynamicConfigStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> DynamicConfigStore {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        return DynamicConfigStore(defaults: defaults, bookmarks: bookmarks, now: { date })
    }

    private func fileText() throws -> String { try String(contentsOf: file, encoding: .utf8) }

    func testStartsEmpty() {
        let store = makeStore()
        XCTAssertNil(store.config)
        XCTAssertNil(store.fileURL)
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.suggestedFileName, "dynamic_config_2026_03_07.json")
    }

    func testOpenSelectsFirstSection() {
        let store = makeStore()
        store.open(file)
        XCTAssertEqual(store.fileURL, file)
        XCTAssertEqual(store.sections.count, 6)
        XCTAssertEqual(store.selectedSectionKey, "tealiumEventPermissionMap")
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.status, .success("Opened dynamic_config_2026_10_23.json"))
        XCTAssertEqual(store.suggestedFileName, "dynamic_config_2026_10_23.json")
    }

    func testOpenInvalidFileKeepsCurrentConfig() throws {
        let store = makeStore()
        store.open(file)
        let broken = base.appendingPathComponent("broken.json")
        try Data(#"{"a": }"#.utf8).write(to: broken)
        store.open(broken)
        XCTAssertEqual(store.fileURL, file)
        XCTAssertEqual(store.sections.count, 6)
        guard case .failure(let message) = store.status else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.hasPrefix("Couldn't open broken.json"), message)
    }

    func testEditMarksDirtyAndSaveWritesTheFile() throws {
        let store = makeStore()
        store.open(file)
        store.setPlatformValue(.number("0"), for: .roku, at: [appLaunch])
        XCTAssertTrue(store.isDirty)

        store.save()
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.status, .success("Saved dynamic_config_2026_10_23.json"))
        XCTAssertTrue(try fileText().contains(#""app_launch": { "all": 1, "roku": 0 },"#))
    }

    func testUndoingAnEditByHandIsNotDirty() {
        let store = makeStore()
        store.open(file)
        store.setPlatformValue(.number("0"), for: .roku, at: [appLaunch])
        store.setPlatformValue(nil, for: .roku, at: [appLaunch])
        XCTAssertFalse(store.isDirty)
    }

    func testRevertDiscardsEdits() {
        let store = makeStore()
        store.open(file)
        store.setPlatformValue(.number("0"), for: .roku, at: [appLaunch])
        XCTAssertTrue(store.canRevert)
        store.revert()
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.config?.overrideCount, 0)
    }

    func testRelaunchReopensTheFile() {
        makeStore().open(file)
        let store = makeStore()
        XCTAssertEqual(store.fileURL, file)
        XCTAssertEqual(store.sections.count, 6)
        XCTAssertEqual(store.selectedSectionKey, "tealiumEventPermissionMap")
        XCTAssertFalse(store.isDirty)
    }

    func testRelaunchRestoresUnsavedEdits() throws {
        let first = makeStore()
        first.open(file)
        first.setPlatformValue(.number("0"), for: .roku, at: [appLaunch])

        let store = makeStore()
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.config?.overrideCount(for: .roku), 1)
        XCTAssertEqual(try fileText(), sampleDynamicConfig)

        store.revert()
        XCTAssertEqual(makeStore().config?.overrideCount, 0)
    }

    func testSaveAsSwitchesFile() throws {
        let store = makeStore()
        store.open(file)
        store.setPlatformValue(.number("5"), for: .xbox, at: [["bvodConstants", "retryLimit"]])
        let copy = base.appendingPathComponent("copy.json")
        store.save(as: copy)

        XCTAssertEqual(store.fileURL, copy)
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(try fileText(), sampleDynamicConfig)
        XCTAssertTrue(try String(contentsOf: copy, encoding: .utf8).contains(#""retryLimit": { "all": 1, "xbox": 5 }"#))
        XCTAssertEqual(makeStore().fileURL, copy)
    }

    func testSaveWithoutFileAsksForSaveAs() throws {
        let store = makeStore()
        try store.replace(withText: #"{"s": {"x": {"all": 1}}}"#)
        XCTAssertTrue(store.isDirty)
        XCTAssertFalse(store.canRevert)
        store.save()
        XCTAssertEqual(store.status, .failure("Choose where to save with Save As."))
    }

    func testSelectingASectionClearsEntrySelection() {
        let store = makeStore()
        store.open(file)
        store.selectedEntryIDs = [DynamicConfig.Entry.id(for: appLaunch)]
        XCTAssertEqual(store.selectedEntries.map(\.key), ["app_launch"])
        store.selectedSectionKey = "bvodConstants"
        XCTAssertTrue(store.selectedEntryIDs.isEmpty)
    }

    func testAddEntrySelectsIt() throws {
        let store = makeStore()
        store.open(file)
        try store.addEntry("video_start")
        XCTAssertEqual(store.selectedEntries.map(\.path), [["tealiumEventPermissionMap", "video_start"]])
        XCTAssertTrue(store.isDirty)
    }

    func testRemoveEntriesPrunesSelection() {
        let store = makeStore()
        store.open(file)
        let ids: Set = [DynamicConfig.Entry.id(for: appLaunch),
                        DynamicConfig.Entry.id(for: ["tealiumEventPermissionMap", "ad_start"])]
        store.selectedEntryIDs = ids
        store.removeEntries(ids)
        XCTAssertEqual(store.selectedSection?.entries.map(\.key), ["home_screen"])
        XCTAssertTrue(store.selectedEntryIDs.isEmpty)
    }

    func testBulkPlatformValue() {
        let store = makeStore()
        store.open(file)
        let paths = store.selectedSection!.entries.map(\.path)
        store.setPlatformValue(.number("0"), for: .vegatv, at: paths)
        XCTAssertEqual(store.config?.overrideCount(for: .vegatv), 3)
        store.clearOverrides(at: paths)
        XCTAssertFalse(store.isDirty)
    }

    // MARK: - Hosting

    private func hostedText(_ store: DynamicConfigStore) -> String? {
        guard case .config(let data) = store.host.response() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func testHostsNothingUntilAConfigIsOpen() {
        let store = makeStore()
        XCTAssertTrue(store.isHosting)
        XCTAssertEqual(store.host.response(), .noConfig)
        store.open(file)
        XCTAssertEqual(hostedText(store), sampleDynamicConfig)
    }

    func testHostsUnsavedEdits() throws {
        let store = makeStore()
        store.open(file)
        store.setPlatformValue(.number("0"), for: .roku, at: [appLaunch])
        XCTAssertTrue(try XCTUnwrap(hostedText(store)).contains(#""app_launch": { "all": 1, "roku": 0 },"#))
        store.revert()
        XCTAssertEqual(hostedText(store), sampleDynamicConfig)
    }

    func testHostingCanBeTurnedOffAndStaysOff() {
        let store = makeStore()
        store.open(file)
        store.isHosting = false
        XCTAssertEqual(store.host.response(), .disabled)

        let relaunched = makeStore()
        XCTAssertFalse(relaunched.isHosting)
        XCTAssertEqual(relaunched.host.response(), .disabled)
        relaunched.isHosting = true
        XCTAssertEqual(hostedText(relaunched), sampleDynamicConfig)
    }

    func testHostedURLUsesTheChosenAddress() {
        let store = makeStore()
        store.urlHost = .androidEmulator
        XCTAssertEqual(store.hostedURL(port: 57333), "http://10.0.2.2:57333/config/dynamic_config.json")
        XCTAssertEqual(makeStore().urlHost, .androidEmulator)
        store.urlHost = .localhost
        XCTAssertEqual(store.hostedURL(port: 8080), "http://localhost:8080/config/dynamic_config.json")
    }

    func testRequestLogIsNewestFirstAndCapped() {
        let store = makeStore()
        for index in 0..<(DynamicConfigStore.maxRequests + 5) {
            store.record(DynamicConfigRequest(date: Date(timeIntervalSince1970: TimeInterval(index)), method: "GET",
                                              path: DynamicConfigHost.path, status: 200, bytes: 1, client: "10.0.0.\(index % 255)"))
        }
        XCTAssertEqual(store.requests.count, DynamicConfigStore.maxRequests)
        XCTAssertEqual(store.requests.first?.date, Date(timeIntervalSince1970: TimeInterval(DynamicConfigStore.maxRequests + 4)))
        store.clearRequests()
        XCTAssertTrue(store.requests.isEmpty)
    }

    func testReplaceWithInvalidTextThrowsAndKeepsConfig() {
        let store = makeStore()
        store.open(file)
        XCTAssertThrowsError(try store.replace(withText: "{"))
        XCTAssertEqual(store.sections.count, 6)
        XCTAssertFalse(store.isDirty)
    }
}
