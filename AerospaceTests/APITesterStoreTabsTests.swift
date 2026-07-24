import XCTest
@testable import Aerospace

@MainActor
final class APITesterStoreTabsTests: XCTestCase {

    private func makeStore(defaultsName: String? = nil) throws -> (APITesterStore, UserDefaults, SQLiteRequestStore) {
        let path = NSTemporaryDirectory() + "aerospace-tabs-\(UUID().uuidString).sqlite"
        let sqlite = try SQLiteRequestStore(path: path)
        let defaults = UserDefaults(suiteName: defaultsName ?? "test-\(UUID().uuidString)")!
        return (APITesterStore(store: sqlite, defaults: defaults), defaults, sqlite)
    }

    private func seed(_ store: APITesterStore, name: String) throws -> SavedRequest {
        let r = SavedRequest(name: name, urlString: "https://example.com/\(name)")
        try store.debugUpsertRequest(r)
        return r
    }

    func testOpenRequestCreatesPreviewTab() throws {
        let (store, _, _) = try makeStore()
        let r = try seed(store, name: "A")
        store.openRequest(id: r.id, pinned: false)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertTrue(store.tabs[0].isPreview)
        XCTAssertEqual(store.activeTabID, store.tabs[0].id)
    }

    func testSecondPreviewReplacesFirst() throws {
        let (store, _, _) = try makeStore()
        let a = try seed(store, name: "A")
        let b = try seed(store, name: "B")
        store.openRequest(id: a.id, pinned: false)
        store.openRequest(id: b.id, pinned: false)
        XCTAssertEqual(store.tabs.count, 1)                 // preview reused
        XCTAssertEqual(store.tabs[0].requestID, b.id)
    }

    func testPinnedTabsAccumulate() throws {
        let (store, _, _) = try makeStore()
        let a = try seed(store, name: "A")
        let b = try seed(store, name: "B")
        store.openRequest(id: a.id, pinned: true)
        store.openRequest(id: b.id, pinned: true)
        XCTAssertEqual(store.tabs.count, 2)
    }

    func testOpenAlreadyOpenRequestFocuses() throws {
        let (store, _, _) = try makeStore()
        let a = try seed(store, name: "A")
        store.openRequest(id: a.id, pinned: true)
        let firstTab = store.tabs[0].id
        store.openRequest(id: a.id, pinned: true)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.activeTabID, firstTab)
    }

    func testCloseActiveTabSelectsNeighbor() throws {
        let (store, _, _) = try makeStore()
        let a = try seed(store, name: "A")
        let b = try seed(store, name: "B")
        store.openRequest(id: a.id, pinned: true)
        store.openRequest(id: b.id, pinned: true)   // active = B
        store.closeTab(id: store.activeTabID!)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.activeTabID, store.tabs[0].id)  // fell back to A
    }

    func testTabsPersistAndRestore() throws {
        let suite = "persist-\(UUID().uuidString)"
        let path = NSTemporaryDirectory() + "aerospace-persist-\(UUID().uuidString).sqlite"
        let sqlite = try SQLiteRequestStore(path: path)
        let defaults = UserDefaults(suiteName: suite)!
        let r = SavedRequest(name: "A", urlString: "https://x")
        try sqlite.upsert(r)

        let store1 = APITesterStore(store: sqlite, defaults: defaults)
        store1.openRequest(id: r.id, pinned: true)

        // New store over the SAME sqlite + defaults → tabs restored.
        let store2 = APITesterStore(store: sqlite, defaults: defaults)
        XCTAssertEqual(store2.tabs.count, 1)
        XCTAssertEqual(store2.tabs[0].requestID, r.id)
    }

    func testOpenEphemeralGetAppendsPinnedTab() throws {
        let (store, _, _) = try makeStore()
        store.openEphemeralGet(url: URL(string: "https://example.com/thing")!)
        let tab = try XCTUnwrap(store.tabs.last)
        XCTAssertNil(tab.requestID)                 // ephemeral, not saved
        XCTAssertFalse(tab.isPreview)               // pinned
        XCTAssertEqual(tab.request.method, .get)
        XCTAssertEqual(tab.request.urlString, "https://example.com/thing")
        XCTAssertEqual(store.activeTabID, tab.id)
        XCTAssertFalse(store.requests.contains { $0.id == tab.request.id }) // not persisted to list
    }

    func testLastResponseIsPerActiveTab() throws {
        let (store, _, _) = try makeStore()
        let a = try seed(store, name: "A")
        let b = try seed(store, name: "B")
        store.openRequest(id: a.id, pinned: true)
        let tabA = store.activeTabID!
        store.openRequest(id: b.id, pinned: true)
        let tabB = store.activeTabID!

        store.debugSetResponse(APIResponse(outcome: .success, statusCode: 200), forTab: tabA)
        XCTAssertNil(store.lastResponse)            // active tab is B, still empty
        store.selectTab(id: tabA)
        XCTAssertEqual(store.lastResponse?.statusCode, 200)
        _ = tabB
    }
}
