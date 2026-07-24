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

    func testNewRequestReusesSinglePreviewTab() throws {
        let (store, _, _) = try makeStore()
        let a = try seed(store, name: "A")
        store.openRequest(id: a.id, pinned: false)   // opens a preview tab for A
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertTrue(store.tabs[0].isPreview)

        store.newRequest()

        XCTAssertEqual(store.tabs.filter { $0.isPreview }.count, 1)
        XCTAssertEqual(store.tabs.count, 1)          // reused, not appended
        let activeTab = try XCTUnwrap(store.tabs.first { $0.id == store.activeTabID })
        XCTAssertTrue(activeTab.isPreview)
        XCTAssertNotEqual(activeTab.requestID, a.id) // now the fresh blank request
    }

    func testNewRequestInFolderOpensPinnedTabWithFolder() throws {
        let (store, _, _) = try makeStore()
        let folderID = UUID()

        store.newRequest(inFolder: folderID)

        let tab = try XCTUnwrap(store.tabs.last)
        XCTAssertEqual(store.activeTabID, tab.id)
        XCTAssertFalse(tab.isPreview)                 // pinned
        XCTAssertEqual(tab.request.folderID, folderID)
    }

    func testDeleteClosesOpenTabAndDoesNotResurrect() throws {
        let (store, _, _) = try makeStore()
        let a = try seed(store, name: "A")
        store.openRequest(id: a.id, pinned: true)
        XCTAssertTrue(store.tabs.contains { $0.requestID == a.id })

        store.delete(id: a.id)

        // No tab should still reference the deleted request.
        XCTAssertFalse(store.tabs.contains { $0.requestID == a.id })
        // The row itself is gone from the list.
        XCTAssertFalse(store.requests.contains { $0.id == a.id })
        // A's tab was the only one open, so we should have fallen back to the
        // empty state — editing must no longer reference A's id, otherwise a
        // later autosave could write A's row straight back into the store.
        XCTAssertNil(store.activeTabID)
        XCTAssertNotEqual(store.editing.id, a.id)

        // Simulate the user typing into the (now-reset) editing buffer, then
        // force the debounced autosave to run early via a public flush path
        // (flushPendingSave() itself is private, but every public entry
        // point — here newRequest() — flushes pending work first).
        store.editing.urlString = "https://example.com/after-delete"
        store.newRequest()

        XCTAssertFalse(store.requests.contains { $0.id == a.id },
                        "the deleted request must not be resurrected by a later autosave")
    }

    func testDuplicateOpensCopyAsActiveTab() throws {
        let (store, _, _) = try makeStore()
        let a = try seed(store, name: "A")
        store.openRequest(id: a.id, pinned: true)
        let originalTabID = store.activeTabID

        store.duplicate(id: a.id)

        let activeTab = try XCTUnwrap(store.tabs.first { $0.id == store.activeTabID })
        XCTAssertNotEqual(activeTab.requestID, a.id)     // the copy, not the original
        XCTAssertFalse(activeTab.isPreview)              // pinned
        XCTAssertNotEqual(store.activeTabID, originalTabID)
        XCTAssertEqual(store.requests.count, 2)
    }

    func testOpenEphemeralGetInheritsOriginatingFolder() throws {
        let (store, _, _) = try makeStore()
        let folder = store.newFolder(parentID: nil)
        var inFolder = SavedRequest(name: "InFolder", urlString: "https://example.com/f")
        inFolder.folderID = folder.id
        try store.debugUpsertRequest(inFolder)
        store.openRequest(id: inFolder.id, pinned: true)   // active request lives in `folder`

        store.openEphemeralGet(url: URL(string: "https://example.com/link")!)

        let tab = try XCTUnwrap(store.tabs.first { $0.id == store.activeTabID })
        XCTAssertNil(tab.requestID)                        // still ephemeral
        XCTAssertEqual(tab.request.folderID, folder.id)    // inherited the originating folder
    }

    func testSaveActiveTabFilesEphemeralIntoOriginatingFolder() throws {
        let (store, _, _) = try makeStore()
        let folder = store.newFolder(parentID: nil)
        var inFolder = SavedRequest(name: "InFolder", urlString: "https://example.com/f")
        inFolder.folderID = folder.id
        try store.debugUpsertRequest(inFolder)
        store.openRequest(id: inFolder.id, pinned: true)
        store.openEphemeralGet(url: URL(string: "https://example.com/link")!)
        let ephemeralRequestID = store.editing.id

        store.saveActiveTab()

        // The active tab is now saved-backed and pinned.
        let tab = try XCTUnwrap(store.tabs.first { $0.id == store.activeTabID })
        XCTAssertEqual(tab.requestID, ephemeralRequestID)
        XCTAssertFalse(tab.isPreview)
        // The request is persisted in the list, filed in the originating folder.
        let saved = try XCTUnwrap(store.requests.first { $0.id == ephemeralRequestID })
        XCTAssertEqual(saved.folderID, folder.id)
    }
}
