import XCTest
@testable import Aerospace

@MainActor
final class APITesterStoreFoldersTests: XCTestCase {

    private func makeStore() throws -> APITesterStore {
        let path = NSTemporaryDirectory() + "aerospace-store-\(UUID().uuidString).sqlite"
        let sqlite = try SQLiteRequestStore(path: path)
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return APITesterStore(store: sqlite, defaults: defaults)
    }

    func testNewFolderPersists() throws {
        let store = try makeStore()
        let f = store.newFolder(parentID: nil)
        XCTAssertTrue(store.folders.contains { $0.id == f.id })
    }

    func testRenameFolder() throws {
        let store = try makeStore()
        let f = store.newFolder(parentID: nil)
        store.renameFolder(id: f.id, to: "Renamed")
        XCTAssertEqual(store.folders.first { $0.id == f.id }?.name, "Renamed")
    }

    func testDeleteFolderReparentsChildrenToParent() throws {
        let store = try makeStore()
        let outer = store.newFolder(parentID: nil)
        let inner = store.newFolder(parentID: outer.id)   // outer/inner
        // A request inside `outer`.
        var req = SavedRequest(name: "R", urlString: "https://x", folderID: outer.id)
        try store.debugUpsertRequest(req)                  // test seam, see Step 3

        store.deleteFolder(id: outer.id)

        XCTAssertFalse(store.folders.contains { $0.id == outer.id })    // gone
        XCTAssertEqual(store.folders.first { $0.id == inner.id }?.parentID, nil) // reparented to root
        XCTAssertEqual(store.requests.first { $0.id == req.id }?.folderID, nil)  // request survives, at root
    }

    func testMoveRequestToFolder() throws {
        let store = try makeStore()
        let f = store.newFolder(parentID: nil)
        var req = SavedRequest(name: "R", urlString: "https://x")
        try store.debugUpsertRequest(req)
        store.move(requestID: req.id, toFolder: f.id)
        XCTAssertEqual(store.requests.first { $0.id == req.id }?.folderID, f.id)
    }

    func testMoveFolderIntoOwnDescendantIsRejected() throws {
        let store = try makeStore()
        let a = store.newFolder(parentID: nil)
        let b = store.newFolder(parentID: a.id)   // a/b
        store.move(folderID: a.id, toParent: b.id) // would create a cycle
        XCTAssertNil(store.folders.first { $0.id == a.id }?.parentID) // unchanged (still root)
    }
}
