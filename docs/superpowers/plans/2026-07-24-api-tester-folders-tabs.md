# API Tester: Folders, Tabs & Response-Body Interactions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add nested folders (with drag-and-drop), VS Code-style request tabs, Cmd+click-a-URL-in-response → new GET tab, and a Cmd+S find bar in the response body to the API Tester.

**Architecture:** The response body is re-hosted in an `NSTextView` (`NSViewRepresentable`) to get native clickable links and a find bar. The single-request store (`APITesterStore`) is generalized to a folder tree plus a collection of open tabs; the editor and response bind to the *active* tab. Folders and requests gain `parentID`/`folderID` + `sortIndex` and are persisted in SQLite; open tabs persist in UserDefaults.

**Tech Stack:** SwiftUI (macOS), AppKit (`NSTextView`, `NSViewRepresentable`), SQLite3 C API, XCTest. Xcode 26.1.1, `Aerospace` scheme.

## Global Constraints

- **No pbxproj edits for new files.** The project uses `PBXFileSystemSynchronizedRootGroup`; new `.swift` files placed in the existing `Aerospace/` subfolders are compiled automatically. Do not hand-edit `project.pbxproj`.
- **Model types are `nonisolated struct`s** conforming to `Identifiable, Codable, Hashable, Sendable` with a memberwise `init` providing defaults (match `SavedRequest`).
- **`APITesterStore` is `@MainActor final class … ObservableObject`.** All new mutating store methods run on the main actor.
- **SQLite migrations are additive only:** add columns/tables via `ALTER TABLE ... ADD COLUMN` / `CREATE TABLE IF NOT EXISTS` in the existing `migrate()`/`createSchema()` flow; each `ALTER` runs through `sqlite3_exec` and ignores the harmless "duplicate column" error. Existing rows must decode with sensible defaults.
- **Decoding old data must not break:** new `SavedRequest` fields default to `folderID: nil`, `sortIndex: 0`.
- **Persistence keys (UserDefaults):** tabs under `"api.openTabs"`, active tab under `"api.activeTab"` (mirror the existing `"api.variables"` pattern in `APITesterStore`).
- **Build command:** `xcodebuild build -scheme Aerospace -destination 'platform=macOS' -quiet`
- **Unit-test command (single class):** `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/<ClassName> -quiet`
- **Commit after every task** with a `feat:`/`test:`-prefixed message.
- SwiftUI **views and the `NSViewRepresentable` are verified by build + manual smoke test**, not XCTest (there is no view-test harness in this repo). All store/model/persistence logic is covered by XCTest first (TDD).

---

## File Structure

**Create:**
- `Aerospace/Models/RequestFolder.swift` — folder node (`id`, `name`, `parentID`, `sortIndex`, timestamps).
- `Aerospace/Models/OpenTab.swift` — one open editor tab (persisted shape).
- `Aerospace/Views/TabBarView.swift` — horizontal tab strip.
- `Aerospace/Views/ResponseTextView.swift` — `NSViewRepresentable` wrapping `NSTextView` for the response body (links + find bar).
- `AerospaceTests/RequestFolderTests.swift`, `AerospaceTests/OpenTabTests.swift`, `AerospaceTests/APITesterStoreFoldersTests.swift`, `AerospaceTests/APITesterStoreTabsTests.swift` — new test files.

**Modify:**
- `Aerospace/Models/SavedRequest.swift` — add `folderID`, `sortIndex`.
- `Aerospace/Storage/SQLiteRequestStore.swift` — `api_folders` table, folder CRUD, request folder/sort columns.
- `Aerospace/Storage/APITesterStore.swift` — folder + tab state and operations, per-tab send, ephemeral GET, persistence.
- `Aerospace/Views/RequestListView.swift` — folder tree, drag & drop, context menu, tab-opening.
- `Aerospace/Views/APITesterView.swift` — mount `TabBarView`; response reads active tab.
- `Aerospace/Views/ResponseView.swift` — body pane uses `ResponseTextView`; surface link-tap + find.
- `Aerospace/Views/JsonViewer.swift` — expose highlight logic as a reusable `NSAttributedString` builder.
- `AerospaceTests/SQLiteRequestStoreTests.swift` — extend for folder columns.

---

## Task 1: `SavedRequest` gains `folderID` + `sortIndex`

**Files:**
- Modify: `Aerospace/Models/SavedRequest.swift`
- Test: `AerospaceTests/SQLiteRequestStoreTests.swift` (extends `SavedRequestCodableTests`)

**Interfaces:**
- Produces: `SavedRequest.folderID: UUID?` (default `nil`), `SavedRequest.sortIndex: Int` (default `0`); both carried through the memberwise `init` and `duplicated(now:)`.

- [ ] **Step 1: Write the failing test** — append to `AerospaceTests/SQLiteRequestStoreTests.swift` inside `SavedRequestCodableTests`:

```swift
    func testFolderFieldsRoundTripAndDefault() throws {
        // Default values when omitted.
        let plain = SavedRequest(name: "X")
        XCTAssertNil(plain.folderID)
        XCTAssertEqual(plain.sortIndex, 0)

        // Explicit values survive a Codable round-trip.
        let folder = UUID()
        let original = SavedRequest(name: "Y", folderID: folder, sortIndex: 7)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedRequest.self, from: data)
        XCTAssertEqual(decoded.folderID, folder)
        XCTAssertEqual(decoded.sortIndex, 7)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/SavedRequestCodableTests -quiet`
Expected: FAIL — compile error, `SavedRequest` has no `folderID`/`sortIndex` parameter.

- [ ] **Step 3: Add the fields** — in `Aerospace/Models/SavedRequest.swift`:

Add stored properties after `var bodyText: String` (line 20):

```swift
    /// Folder this request lives in. nil = root (unfiled).
    var folderID: UUID?
    /// Order within the parent folder (or root). Lower sorts first.
    var sortIndex: Int
```

Add init parameters (before `createdAt` in the parameter list) with defaults:

```swift
        folderID: UUID? = nil,
        sortIndex: Int = 0,
```

Add assignments in the init body (before `self.createdAt = createdAt`):

```swift
        self.folderID = folderID
        self.sortIndex = sortIndex
```

In `duplicated(now:)`, carry them through (add before `createdAt: now`):

```swift
            folderID: folderID,
            sortIndex: sortIndex,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/SavedRequestCodableTests -quiet`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Aerospace/Models/SavedRequest.swift AerospaceTests/SQLiteRequestStoreTests.swift
git commit -m "feat: add folderID and sortIndex to SavedRequest"
```

---

## Task 2: `RequestFolder` model

**Files:**
- Create: `Aerospace/Models/RequestFolder.swift`
- Test: `AerospaceTests/RequestFolderTests.swift`

**Interfaces:**
- Produces: `struct RequestFolder: Identifiable, Codable, Hashable, Sendable` with `id: UUID`, `var name: String`, `var parentID: UUID?`, `var sortIndex: Int`, `let createdAt: Date`, `var updatedAt: Date`, and a memberwise `init` with defaults (`name: "New Folder"`, `parentID: nil`, `sortIndex: 0`).

- [ ] **Step 1: Write the failing test** — create `AerospaceTests/RequestFolderTests.swift`:

```swift
import XCTest
@testable import Aerospace

final class RequestFolderTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let folder = RequestFolder()
        XCTAssertEqual(folder.name, "New Folder")
        XCTAssertNil(folder.parentID)
        XCTAssertEqual(folder.sortIndex, 0)

        let parent = UUID()
        let original = RequestFolder(name: "Auth", parentID: parent, sortIndex: 3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RequestFolder.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.parentID, parent)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/RequestFolderTests -quiet`
Expected: FAIL — `RequestFolder` type not found.

- [ ] **Step 3: Create the model** — `Aerospace/Models/RequestFolder.swift`:

```swift
//
//  RequestFolder.swift
//  Aerospace
//
//  A folder node in the API-tester request tree. Folders nest via parentID
//  (nil = root) and order among siblings via sortIndex.
//

import Foundation

nonisolated struct RequestFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var sortIndex: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "New Folder",
        parentID: UUID? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/RequestFolderTests -quiet`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Aerospace/Models/RequestFolder.swift AerospaceTests/RequestFolderTests.swift
git commit -m "feat: add RequestFolder model"
```

---

## Task 3: SQLite persistence for folders + request folder/sort columns

**Files:**
- Modify: `Aerospace/Storage/SQLiteRequestStore.swift`
- Test: `AerospaceTests/SQLiteRequestStoreTests.swift`

**Interfaces:**
- Consumes: `RequestFolder` (Task 2), `SavedRequest.folderID`/`.sortIndex` (Task 1).
- Produces on `SQLiteRequestStore`:
  - `func upsertFolder(_ folder: RequestFolder) throws`
  - `func fetchAllFolders() -> [RequestFolder]` (ordered `sort_index ASC, name ASC`)
  - `@discardableResult func deleteFolder(id: UUID) -> Int` (deletes only the folder row; re-parenting of children is the store-layer's job in Task 4)
  - `upsert`/`fetch`/`fetchAll` now persist and read `folder_id` (TEXT, nullable) and `sort_index` (INTEGER).

- [ ] **Step 1: Write the failing tests** — add a new class to `AerospaceTests/SQLiteRequestStoreTests.swift`:

```swift
final class SQLiteFolderStoreTests: XCTestCase {

    private func makeStore() throws -> SQLiteRequestStore {
        let path = NSTemporaryDirectory() + "aerospace-fold-\(UUID().uuidString).sqlite"
        return try SQLiteRequestStore(path: path)
    }

    func testFolderInsertFetchDelete() throws {
        let store = try makeStore()
        XCTAssertTrue(store.fetchAllFolders().isEmpty)
        let f = RequestFolder(name: "Auth", sortIndex: 1)
        try store.upsertFolder(f)
        XCTAssertEqual(store.fetchAllFolders().map(\.name), ["Auth"])
        XCTAssertEqual(store.deleteFolder(id: f.id), 1)
        XCTAssertTrue(store.fetchAllFolders().isEmpty)
    }

    func testFoldersOrderedBySortIndex() throws {
        let store = try makeStore()
        try store.upsertFolder(RequestFolder(name: "B", sortIndex: 2))
        try store.upsertFolder(RequestFolder(name: "A", sortIndex: 1))
        XCTAssertEqual(store.fetchAllFolders().map(\.name), ["A", "B"])
    }

    func testRequestFolderAndSortPersist() throws {
        let store = try makeStore()
        let folderID = UUID()
        var r = SavedRequest(name: "R", urlString: "https://x")
        r.folderID = folderID
        r.sortIndex = 5
        try store.upsert(r)
        let fetched = try XCTUnwrap(store.fetch(id: r.id))
        XCTAssertEqual(fetched.folderID, folderID)
        XCTAssertEqual(fetched.sortIndex, 5)
    }

    func testRootRequestHasNilFolder() throws {
        let store = try makeStore()
        let r = SavedRequest(name: "Root", urlString: "https://x")
        try store.upsert(r)
        XCTAssertNil(try XCTUnwrap(store.fetch(id: r.id)).folderID)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/SQLiteFolderStoreTests -quiet`
Expected: FAIL — `upsertFolder`/`fetchAllFolders`/`deleteFolder` not found.

- [ ] **Step 3a: Add schema + migrations** — in `SQLiteRequestStore.createSchema()`, after the `idx_api_requests_updated` index line, add:

```swift
        try exec("""
        CREATE TABLE IF NOT EXISTS api_folders (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            parent_id TEXT,
            sort_index INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
```

In `migrate()`, add two entries to the `additions` array:

```swift
            "ALTER TABLE api_requests ADD COLUMN folder_id TEXT;",
            "ALTER TABLE api_requests ADD COLUMN sort_index INTEGER NOT NULL DEFAULT 0;",
```

- [ ] **Step 3b: Persist request folder/sort in `upsert`** — extend the `INSERT OR REPLACE` in `upsert(_:)`:

Change the column list and placeholders to include `folder_id, sort_index` (add before `created_at, updated_at` / their `?`s), then bind after the existing `updated_at` bind (index 16). New indices 17, 18:

```swift
                // ...existing binds 1...16...
                bindText(stmt, 17, request.folderID?.uuidString)   // nil-safe → NULL
                sqlite3_bind_int(stmt, 18, Int32(request.sortIndex))
```

The full SQL becomes:

```swift
                let sql = """
                INSERT OR REPLACE INTO api_requests
                (id, name, method, url, query_json, headers_json, auth_kind,
                 bearer_token, body_kind, body_text, n10_enabled, n10_app_version,
                 n10_system_name, n10_system_version, created_at, updated_at,
                 folder_id, sort_index)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
```

Keep binds 15/16 (`created_at`/`updated_at`) exactly as they are; add 17/18 after them.

- [ ] **Step 3c: Read the columns in `row(from:)`** — extend `Self.columns` to append `, folder_id, sort_index`, then in `row(from:)` read them (indices 16, 17) and pass into `SavedRequest`:

```swift
        let folderID = UUID(uuidString: columnText(stmt, 16) ?? "")   // nil for NULL/blank
        let sortIndex = Int(sqlite3_column_int(stmt, 17))
        return SavedRequest(
            id: id, name: name, method: method, urlString: url,
            queryParams: query, headers: headers, authKind: auth, bearerToken: bearer,
            bodyKind: bodyKind, bodyText: bodyText,
            n10SigningEnabled: n10Enabled, n10AppVersion: n10AppVersion,
            n10SystemName: n10SystemName, n10SystemVersion: n10SystemVersion,
            folderID: folderID, sortIndex: sortIndex,
            createdAt: createdAt, updatedAt: updatedAt
        )
```

(`UUID(uuidString:)` returns `nil` when the column is NULL/empty, which is exactly the root case.)

- [ ] **Step 3d: Add folder CRUD** — add a new `// MARK: - Folders` section in `SQLiteRequestStore`:

```swift
    // MARK: - Folders

    func upsertFolder(_ folder: RequestFolder) throws {
        try queue.sync {
            let sql = """
            INSERT OR REPLACE INTO api_folders
            (id, name, parent_id, sort_index, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, folder.id.uuidString)
            bindText(stmt, 2, folder.name)
            bindText(stmt, 3, folder.parentID?.uuidString)
            sqlite3_bind_int(stmt, 4, Int32(folder.sortIndex))
            sqlite3_bind_double(stmt, 5, folder.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 6, folder.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteError.step(lastMessage()) }
        }
    }

    func fetchAllFolders() -> [RequestFolder] {
        (try? queue.sync {
            let stmt = try prepare("""
            SELECT id, name, parent_id, sort_index, created_at, updated_at
            FROM api_folders ORDER BY sort_index ASC, name ASC;
            """)
            defer { sqlite3_finalize(stmt) }
            var results: [RequestFolder] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(RequestFolder(
                    id: UUID(uuidString: columnText(stmt, 0) ?? "") ?? UUID(),
                    name: columnText(stmt, 1) ?? "Folder",
                    parentID: UUID(uuidString: columnText(stmt, 2) ?? ""),
                    sortIndex: Int(sqlite3_column_int(stmt, 3)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                ))
            }
            return results
        }) ?? []
    }

    @discardableResult
    func deleteFolder(id: UUID) -> Int {
        (try? queue.sync {
            let stmt = try prepare("DELETE FROM api_folders WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteError.step(lastMessage()) }
            return Int(sqlite3_changes(db))
        }) ?? 0
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/SQLiteFolderStoreTests -only-testing:AerospaceTests/SQLiteRequestStoreTests -quiet`
Expected: PASS (both new folder tests and the existing request-store tests still green — migrations are additive).

- [ ] **Step 5: Commit**

```bash
git add Aerospace/Storage/SQLiteRequestStore.swift AerospaceTests/SQLiteRequestStoreTests.swift
git commit -m "feat: persist folders and request folder/sort columns in SQLite"
```

---

## Task 4: Store folder state & operations (with re-parenting delete + cycle guard)

**Files:**
- Modify: `Aerospace/Storage/APITesterStore.swift`
- Test: `AerospaceTests/APITesterStoreFoldersTests.swift`

**Interfaces:**
- Consumes: `SQLiteRequestStore` folder CRUD (Task 3).
- Produces on `APITesterStore`:
  - `@Published private(set) var folders: [RequestFolder]`
  - `func newFolder(parentID: UUID?) -> RequestFolder` (persists, refreshes, returns it)
  - `func renameFolder(id: UUID, to name: String)`
  - `func deleteFolder(id: UUID)` — re-parents child folders and requests to the deleted folder's `parentID`, then deletes the folder row. Never deletes requests.
  - `func move(requestID: SavedRequest.ID, toFolder folderID: UUID?)`
  - `func move(folderID: UUID, toParent parentID: UUID?)` — no-op if it would create a cycle (target is the folder itself or one of its descendants).
  - `func isDescendant(_ candidate: UUID, of folderID: UUID) -> Bool` (helper for the cycle guard; internal but tested).
- The `init` must now also load folders: add `folders = self.store.fetchAllFolders()` after `requests = all`.

- [ ] **Step 1: Write the failing tests** — create `AerospaceTests/APITesterStoreFoldersTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/APITesterStoreFoldersTests -quiet`
Expected: FAIL — `folders`, `newFolder`, `debugUpsertRequest`, etc. not found.

- [ ] **Step 3: Implement** — in `APITesterStore.swift`:

Add published state after `@Published private(set) var requests` (line 16):

```swift
    @Published private(set) var folders: [RequestFolder] = []
```

In `init`, after `requests = all` (line 70), add:

```swift
        folders = self.store.fetchAllFolders()
```

Add a `// MARK: - Folders` section (near the end, before `// MARK: - Sending`):

```swift
    // MARK: - Folders

    /// Test seam: persist a request directly (production code paths use tabs/auto-save).
    func debugUpsertRequest(_ request: SavedRequest) throws {
        try store.upsert(request)
        refreshList()
    }

    @discardableResult
    func newFolder(parentID: UUID?) -> RequestFolder {
        let siblings = folders.filter { $0.parentID == parentID }
        let nextIndex = (siblings.map(\.sortIndex).max() ?? -1) + 1
        let folder = RequestFolder(parentID: parentID, sortIndex: nextIndex)
        try? store.upsertFolder(folder)
        refreshFolders()
        return folder
    }

    func renameFolder(id: UUID, to name: String) {
        guard var folder = folders.first(where: { $0.id == id }) else { return }
        folder.name = name
        folder.updatedAt = Date()
        try? store.upsertFolder(folder)
        refreshFolders()
    }

    func deleteFolder(id: UUID) {
        guard let target = folders.first(where: { $0.id == id }) else { return }
        // Re-parent child folders.
        for var child in folders where child.parentID == id {
            child.parentID = target.parentID
            child.updatedAt = Date()
            try? store.upsertFolder(child)
        }
        // Re-parent child requests.
        for var req in requests where req.folderID == id {
            req.folderID = target.parentID
            req.updatedAt = Date()
            try? store.upsert(req)
        }
        store.deleteFolder(id: id)
        refreshFolders()
        refreshList()
    }

    func move(requestID: SavedRequest.ID, toFolder folderID: UUID?) {
        guard var req = requests.first(where: { $0.id == requestID }) else { return }
        req.folderID = folderID
        req.updatedAt = Date()
        try? store.upsert(req)
        refreshList()
    }

    func move(folderID: UUID, toParent parentID: UUID?) {
        guard var folder = folders.first(where: { $0.id == folderID }) else { return }
        if let parentID, parentID == folderID || isDescendant(parentID, of: folderID) {
            return  // cycle guard
        }
        folder.parentID = parentID
        folder.updatedAt = Date()
        try? store.upsertFolder(folder)
        refreshFolders()
    }

    /// True if `candidate` is `folderID` itself or nested anywhere beneath it.
    func isDescendant(_ candidate: UUID, of folderID: UUID) -> Bool {
        var current: UUID? = candidate
        while let id = current {
            if id == folderID { return true }
            current = folders.first(where: { $0.id == id })?.parentID
        }
        return false
    }

    private func refreshFolders() {
        folders = store.fetchAllFolders()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/APITesterStoreFoldersTests -quiet`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Aerospace/Storage/APITesterStore.swift AerospaceTests/APITesterStoreFoldersTests.swift
git commit -m "feat: folder state and operations in APITesterStore"
```

---

## Task 5: `OpenTab` model

**Files:**
- Create: `Aerospace/Models/OpenTab.swift`
- Test: `AerospaceTests/OpenTabTests.swift`

**Interfaces:**
- Consumes: `SavedRequest`.
- Produces: `struct OpenTab: Identifiable, Codable, Hashable, Sendable` with `let id: UUID`, `var requestID: SavedRequest.ID?` (nil = ephemeral), `var request: SavedRequest`, `var isPreview: Bool`; memberwise `init` with `id = UUID()`, `requestID = nil`, `isPreview = false`. Runtime-only response/isSending are held in the store, not here.

- [ ] **Step 1: Write the failing test** — create `AerospaceTests/OpenTabTests.swift`:

```swift
import XCTest
@testable import Aerospace

final class OpenTabTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let req = SavedRequest(name: "R", urlString: "https://x")
        let tab = OpenTab(requestID: req.id, request: req)
        XCTAssertEqual(tab.requestID, req.id)
        XCTAssertFalse(tab.isPreview)

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(OpenTab.self, from: data)
        XCTAssertEqual(decoded, tab)
    }

    func testEphemeralTabHasNilRequestID() throws {
        let tab = OpenTab(request: SavedRequest(name: "E", urlString: "https://y"))
        XCTAssertNil(tab.requestID)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/OpenTabTests -quiet`
Expected: FAIL — `OpenTab` not found.

- [ ] **Step 3: Create the model** — `Aerospace/Models/OpenTab.swift`:

```swift
//
//  OpenTab.swift
//  Aerospace
//
//  One open tab in the API tester. A tab holds a working copy of a request.
//  requestID is nil for ephemeral tabs (e.g. opened by Cmd+clicking a URL in a
//  response) that are not backed by a saved request. Response and in-flight
//  state are held in the store, keyed by tab id, not persisted here.
//

import Foundation

nonisolated struct OpenTab: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var requestID: SavedRequest.ID?
    var request: SavedRequest
    var isPreview: Bool

    init(
        id: UUID = UUID(),
        requestID: SavedRequest.ID? = nil,
        request: SavedRequest,
        isPreview: Bool = false
    ) {
        self.id = id
        self.requestID = requestID
        self.request = request
        self.isPreview = isPreview
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/OpenTabTests -quiet`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Aerospace/Models/OpenTab.swift AerospaceTests/OpenTabTests.swift
git commit -m "feat: add OpenTab model"
```

---

## Task 6: Store tabs — open/preview/pin/close/select + persistence

**Files:**
- Modify: `Aerospace/Storage/APITesterStore.swift`
- Test: `AerospaceTests/APITesterStoreTabsTests.swift`

**Interfaces:**
- Consumes: `OpenTab` (Task 5), existing `editing`/auto-save.
- Produces on `APITesterStore`:
  - `@Published private(set) var tabs: [OpenTab]`
  - `@Published var activeTabID: OpenTab.ID?`
  - `func openRequest(id: SavedRequest.ID, pinned: Bool)` — if a tab for this request is already open, focus it; else if a preview tab exists, replace its contents (preview unless `pinned`); else append a new tab.
  - `func pinActiveTab()` — set active tab `isPreview = false`.
  - `func closeTab(id: OpenTab.ID)` — remove; if it was active, select an adjacent tab.
  - `func selectTab(id: OpenTab.ID)` — set `activeTabID`, load its request into `editing`.
  - Auto-save writes back into the active tab's `request` and, when the edit is meaningful, flips the preview tab to pinned.
- Persistence: tabs + `activeTabID` saved to UserDefaults under `"api.openTabs"`/`"api.activeTab"`; restored in `init`, pruning saved-backed tabs whose request no longer exists.

**Design note — keeping `editing` working:** `editing` stays the editor's binding target. On any edit, `editing.didSet` writes the buffer back into `tabs[active]` and schedules auto-save. `selectTab`/`openRequest`/`newRequest` set `editing` under the existing `isLoadingSelection` guard so the write-back doesn't recurse.

- [ ] **Step 1: Write the failing tests** — create `AerospaceTests/APITesterStoreTabsTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/APITesterStoreTabsTests -quiet`
Expected: FAIL — `tabs`, `openRequest`, etc. not found.

- [ ] **Step 3a: Add tab state** — in `APITesterStore.swift`, after the `folders` published property:

```swift
    @Published private(set) var tabs: [OpenTab] = []
    @Published var activeTabID: OpenTab.ID?
    private static let openTabsKey = "api.openTabs"
    private static let activeTabKey = "api.activeTab"
```

- [ ] **Step 3b: Restore tabs in `init`** — after `folders = self.store.fetchAllFolders()`, add:

```swift
        restoreTabs()
```

Add the restore + persist helpers (new `// MARK: - Tabs` section):

```swift
    // MARK: - Tabs

    private func restoreTabs() {
        guard let data = defaults.data(forKey: Self.openTabsKey),
              let saved = try? JSONDecoder().decode([OpenTab].self, from: data) else { return }
        let liveIDs = Set(requests.map(\.id))
        // Keep ephemeral tabs; keep saved-backed tabs only if the request still exists.
        tabs = saved.filter { $0.requestID == nil || liveIDs.contains($0.requestID!) }
        if let raw = defaults.string(forKey: Self.activeTabKey),
           let id = UUID(uuidString: raw), tabs.contains(where: { $0.id == id }) {
            activeTabID = id
        } else {
            activeTabID = tabs.first?.id
        }
        loadActiveTabIntoEditing()
    }

    private func persistTabs() {
        if let data = try? JSONEncoder().encode(tabs) {
            defaults.set(data, forKey: Self.openTabsKey)
        }
        defaults.set(activeTabID?.uuidString, forKey: Self.activeTabKey)
    }

    private func loadActiveTabIntoEditing() {
        guard let activeTabID, let tab = tabs.first(where: { $0.id == activeTabID }) else { return }
        isLoadingSelection = true
        editing = tab.request
        selectedID = tab.requestID
        isLoadingSelection = false
    }

    func openRequest(id: SavedRequest.ID, pinned: Bool) {
        flushPendingSave()
        guard let request = requests.first(where: { $0.id == id }) ?? store.fetch(id: id) else { return }
        // Already open? Focus it.
        if let existing = tabs.first(where: { $0.requestID == id }) {
            if pinned, let idx = tabs.firstIndex(where: { $0.id == existing.id }) {
                tabs[idx].isPreview = false
            }
            selectTab(id: existing.id)
            return
        }
        // Reuse an existing preview tab, else append.
        if let idx = tabs.firstIndex(where: { $0.isPreview }) {
            tabs[idx] = OpenTab(id: tabs[idx].id, requestID: id, request: request, isPreview: !pinned)
            selectTab(id: tabs[idx].id)
        } else {
            let tab = OpenTab(requestID: id, request: request, isPreview: !pinned)
            tabs.append(tab)
            selectTab(id: tab.id)
        }
        persistTabs()
    }

    func selectTab(id: OpenTab.ID) {
        flushPendingSave()
        activeTabID = id
        loadActiveTabIntoEditing()
        persistTabs()
    }

    func pinActiveTab() {
        guard let activeTabID, let idx = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        tabs[idx].isPreview = false
        persistTabs()
    }

    func closeTab(id: OpenTab.ID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeTabID == id
        tabs.remove(at: idx)
        if wasActive {
            let neighbor = tabs[safe: idx] ?? tabs[safe: idx - 1] ?? tabs.last
            activeTabID = neighbor?.id
            loadActiveTabIntoEditing()
        }
        persistTabs()
    }
```

- [ ] **Step 3c: Write edits back into the active tab** — change `editing`'s `didSet` (currently line 48-50) to:

```swift
    @Published var editing: SavedRequest {
        didSet {
            guard !isLoadingSelection else { return }
            writeEditingIntoActiveTab()
            scheduleAutoSave()
        }
    }
```

Add the write-back helper in the Tabs section:

```swift
    private func writeEditingIntoActiveTab() {
        guard let activeTabID, let idx = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        tabs[idx].request = editing
        // A meaningful edit pins a preview tab (VS Code behavior).
        if tabs[idx].isPreview && !editing.isEffectivelyEmpty {
            tabs[idx].isPreview = false
        }
        persistTabs()
    }
```

- [ ] **Step 3d: Add the `Array` safe-subscript helper** — at the bottom of `APITesterStore.swift` (file scope, outside the class):

```swift
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/APITesterStoreTabsTests -quiet`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Aerospace/Storage/APITesterStore.swift AerospaceTests/APITesterStoreTabsTests.swift
git commit -m "feat: tab open/preview/pin/close/select with persistence"
```

---

## Task 7: Per-tab response/sending + ephemeral GET tab

**Files:**
- Modify: `Aerospace/Storage/APITesterStore.swift`
- Test: `AerospaceTests/APITesterStoreTabsTests.swift`

**Interfaces:**
- Consumes: tab state (Task 6), existing `send()`/`APIResponse`/`RequestBuilder`.
- Produces on `APITesterStore`:
  - `@Published private(set) var responsesByTab: [OpenTab.ID: APIResponse]`
  - `@Published private(set) var sendingTabs: Set<OpenTab.ID>`
  - `var lastResponse: APIResponse?` becomes a computed property returning `activeTabID.flatMap { responsesByTab[$0] }`.
  - `var isSending: Bool` becomes computed: `activeTabID.map { sendingTabs.contains($0) } ?? false`.
  - `func openEphemeralGet(url: URL)` — appends a **new pinned** ephemeral tab (GET, url), selects it, and calls `send()`.
  - `send()` records result/inflight state under the active tab id; each tab keeps its own `Task` in a `sendTasksByTab` map.

- [ ] **Step 1: Write the failing tests** — add to `APITesterStoreTabsTests`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/APITesterStoreTabsTests -quiet`
Expected: FAIL — `openEphemeralGet`, `debugSetResponse`, per-tab `lastResponse` not present.

- [ ] **Step 3a: Replace single-response state with per-tab maps** — in `APITesterStore.swift`:

Remove the old stored properties:

```swift
    @Published private(set) var isSending = false
    @Published private(set) var lastResponse: APIResponse?
```

Replace with:

```swift
    @Published private(set) var responsesByTab: [OpenTab.ID: APIResponse] = [:]
    @Published private(set) var sendingTabs: Set<OpenTab.ID> = []

    var lastResponse: APIResponse? { activeTabID.flatMap { responsesByTab[$0] } }
    var isSending: Bool { activeTabID.map { sendingTabs.contains($0) } ?? false }

    /// Test seam.
    func debugSetResponse(_ response: APIResponse, forTab id: OpenTab.ID) {
        responsesByTab[id] = response
    }
```

Replace the single `private var sendTask: Task<Void, Never>?` with:

```swift
    private var sendTasksByTab: [OpenTab.ID: Task<Void, Never>] = [:]
```

- [ ] **Step 3b: Make `send()` per-tab** — rewrite the body of `send()` so it targets the active tab. Replace all `lastResponse = X` / `isSending` / `sendTask` references:

```swift
    func send() {
        guard let tabID = activeTabID else { return }
        var request: URLRequest
        do {
            request = try RequestBuilder().makeURLRequest(from: editing, variables: variablesDictionary)
        } catch {
            responsesByTab[tabID] = APIResponse(
                outcome: .failure((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            return
        }

        if editing.n10SigningEnabled {
            let key = n10APIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                responsesByTab[tabID] = APIResponse(outcome: .failure(
                    "N10 signing is on but no API key is set. Add it in the N10 section."))
                return
            }
            let device = N10Signer.DeviceInfo(
                appVersion: editing.n10AppVersion,
                systemName: editing.n10SystemName,
                systemVersion: editing.n10SystemVersion)
            let timestamp = Int(Date().timeIntervalSince1970)
            let signed = N10Signer().headers(
                method: editing.method, finalURL: request.url?.absoluteString ?? "",
                apiKeyHex: key, device: device, timestamp: timestamp)
            for (name, value) in signed {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        flushPendingSave()
        sendTasksByTab[tabID]?.cancel()
        sendingTabs.insert(tabID)
        let client = APIClient()
        sendTasksByTab[tabID] = Task { [weak self] in
            let response = await client.send(request)
            guard !Task.isCancelled else { return }
            self?.responsesByTab[tabID] = response
            self?.sendingTabs.remove(tabID)
        }
    }

    func cancelSend() {
        guard let tabID = activeTabID else { return }
        sendTasksByTab[tabID]?.cancel()
        sendTasksByTab[tabID] = nil
        sendingTabs.remove(tabID)
    }
```

- [ ] **Step 3c: Add `openEphemeralGet`** — in the Tabs section:

```swift
    func openEphemeralGet(url: URL) {
        flushPendingSave()
        let request = SavedRequest(name: url.host ?? "Request", method: .get,
                                   urlString: url.absoluteString)
        let tab = OpenTab(requestID: nil, request: request, isPreview: false)
        tabs.append(tab)
        activeTabID = tab.id
        isLoadingSelection = true
        editing = request
        selectedID = nil
        isLoadingSelection = false
        persistTabs()
        send()
    }
```

- [ ] **Step 3d: Clean up closing/auto-save for per-tab responses** — in `closeTab`, after `tabs.remove(at: idx)` add:

```swift
        sendTasksByTab[id]?.cancel()
        sendTasksByTab[id] = nil
        responsesByTab[id] = nil
        sendingTabs.remove(id)
```

Auto-save must only persist tabs backed by a saved request. In `performAutoSave()`, guard ephemeral tabs — place the guard **immediately after** the existing `autoSaveWork = nil` line (clearing the work item first, so an early return never leaves a stale, already-executed work item that a later `flushPendingSave()` would resurrect against a different active tab):

```swift
        autoSaveWork = nil
        // Ephemeral (unsaved) active tab: never auto-persist to the request list.
        if let activeTabID, let tab = tabs.first(where: { $0.id == activeTabID }), tab.requestID == nil {
            return
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/APITesterStoreTabsTests -quiet`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Aerospace/Storage/APITesterStore.swift AerospaceTests/APITesterStoreTabsTests.swift
git commit -m "feat: per-tab response/sending state and ephemeral GET tab"
```

---

## Task 8: Reusable JSON highlighter (`NSAttributedString`)

**Files:**
- Modify: `Aerospace/Views/JsonViewer.swift`
- Test: `AerospaceTests/JsonHighlighterTests.swift` (create)

**Interfaces:**
- Produces: `enum JSONHighlighter { static func pretty(_ json: String) -> String; static func attributed(_ json: String, font: NSFont, textColor: NSColor) -> NSAttributedString }`. `JsonViewer` is refactored to build its `AttributedString` from the same pretty-printing logic (no behavior change for the existing SwiftUI viewer).

- [ ] **Step 1: Write the failing test** — create `AerospaceTests/JsonHighlighterTests.swift`:

```swift
import XCTest
import AppKit
@testable import Aerospace

final class JsonHighlighterTests: XCTestCase {
    func testPrettyPrintsAndSortsKeys() {
        let out = JSONHighlighter.pretty("{\"b\":1,\"a\":2}")
        XCTAssertTrue(out.contains("\"a\""))
        XCTAssertTrue(out.contains("\n"))               // pretty-printed
        XCTAssertLessThan(out.range(of: "\"a\"")!.lowerBound,
                          out.range(of: "\"b\"")!.lowerBound) // sorted keys
    }

    func testInvalidJSONReturnedVerbatim() {
        XCTAssertEqual(JSONHighlighter.pretty("not json"), "not json")
    }

    func testAttributedContainsFullText() {
        let attr = JSONHighlighter.attributed("{\"a\":1}", font: .monospacedSystemFont(ofSize: 12, weight: .regular), textColor: .textColor)
        XCTAssertTrue(attr.string.contains("\"a\""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/JsonHighlighterTests -quiet`
Expected: FAIL — `JSONHighlighter` not found.

- [ ] **Step 3a: Add `JSONHighlighter`** — at the top of `Aerospace/Views/JsonViewer.swift`, after the imports add `import AppKit` and:

```swift
/// Shared JSON pretty-printing + lightweight key/value highlighting, usable
/// from both the SwiftUI JsonViewer and the AppKit-backed ResponseTextView.
enum JSONHighlighter {
    static func pretty(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: out, encoding: .utf8)
        else { return json }
        return string
    }

    static func attributed(_ json: String, font: NSFont, textColor: NSColor) -> NSAttributedString {
        let text = pretty(json)
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        let ns = text as NSString
        var searchStart = 0
        while searchStart < ns.length {
            let openRange = ns.range(of: "\"", range: NSRange(location: searchStart, length: ns.length - searchStart))
            if openRange.location == NSNotFound { break }
            let afterOpen = openRange.location + openRange.length
            let closeRange = ns.range(of: "\"", range: NSRange(location: afterOpen, length: ns.length - afterOpen))
            if closeRange.location == NSNotFound { break }
            let strRange = NSRange(location: openRange.location,
                                   length: closeRange.location + closeRange.length - openRange.location)
            // Look at the next non-whitespace char after the closing quote.
            var i = closeRange.location + closeRange.length
            while i < ns.length, let scalar = Unicode.Scalar(ns.character(at: i)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) { i += 1 }
            let isKey = i < ns.length && ns.character(at: i) == unichar(UInt8(ascii: ":"))
            result.addAttribute(.foregroundColor,
                                value: isKey ? NSColor.controlAccentColor : NSColor.systemGreen,
                                range: strRange)
            searchStart = closeRange.location + closeRange.length
        }
        return result
    }
}
```

- [ ] **Step 3b: Refactor `JsonViewer` to reuse `pretty`** — replace the `private var pretty: String { ... }` computed body with:

```swift
    private var pretty: String { JSONHighlighter.pretty(json) }
```

(The existing `highlighted: AttributedString` and `copyToPasteboard()` continue to use `pretty`; no other change.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/JsonHighlighterTests -quiet`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Aerospace/Views/JsonViewer.swift AerospaceTests/JsonHighlighterTests.swift
git commit -m "feat: extract reusable JSONHighlighter for AppKit response view"
```

---

## Task 9: `ResponseTextView` (NSTextView) — links + find bar

**Files:**
- Create: `Aerospace/Views/ResponseTextView.swift`
- Verify: build + manual smoke test (no XCTest — this is an `NSViewRepresentable`).

**Interfaces:**
- Consumes: `JSONHighlighter` (Task 8).
- Produces: `struct ResponseTextView: NSViewRepresentable` with:
  - `init(text: String, isJSON: Bool, onOpenLink: @escaping (URL) -> Void)`
  - a bound trigger `@Binding var showFindBarSignal: Bool` — when the parent flips it true, the view shows the find bar and resets it to false.
  - Read-only, selectable, monospaced. Detects URLs via `NSDataDetector`, styles them as links. On **Cmd+click** of a link, calls `onOpenLink(url)` and returns `false` from `clickedOnLink` to suppress the default open. `usesFindBar = true`, `isIncrementalSearchingEnabled = true`.

- [ ] **Step 1: Create the view** — `Aerospace/Views/ResponseTextView.swift`:

```swift
//
//  ResponseTextView.swift
//  Aerospace
//
//  AppKit-backed response body: read-only, selectable, monospaced text with
//  clickable links (Cmd+click opens a new GET tab) and a native find bar
//  (shown on demand via showFindBarSignal, bound to Cmd+S in ResponseView).
//

import SwiftUI
import AppKit

struct ResponseTextView: NSViewRepresentable {
    let text: String
    let isJSON: Bool
    var onOpenLink: (URL) -> Void
    @Binding var showFindBarSignal: Bool

    func makeCoordinator() -> Coordinator { Coordinator(onOpenLink: onOpenLink) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticLinkDetectionEnabled = false   // we set links ourselves
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        scroll.hasHorizontalScroller = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                        height: CGFloat.greatestFiniteMagnitude)
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        guard let textView = scroll.documentView as? NSTextView else { return }

        if context.coordinator.renderedText != text || context.coordinator.renderedJSON != isJSON {
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let attributed: NSAttributedString = isJSON
                ? JSONHighlighter.attributed(text, font: font, textColor: .textColor)
                : NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
            let mutable = NSMutableAttributedString(attributedString: attributed)
            addLinks(to: mutable)
            textView.textStorage?.setAttributedString(mutable)
            context.coordinator.renderedText = text
            context.coordinator.renderedJSON = isJSON
        }

        if showFindBarSignal {
            // Show the find bar and focus it.
            textView.window?.makeFirstResponder(textView)
            textView.performFindPanelAction(makeFindAction())
            DispatchQueue.main.async { self.showFindBarSignal = false }
        }
    }

    /// A menu-item stand-in whose tag = NSTextFinder.Action.showFindInterface.
    private func makeFindAction() -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        return item
    }

    private func addLinks(to string: NSMutableAttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let full = NSRange(location: 0, length: string.length)
        detector.enumerateMatches(in: string.string, options: [], range: full) { match, _, _ in
            if let match, let url = match.url {
                string.addAttribute(.link, value: url, range: match.range)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenLink: (URL) -> Void
        weak var textView: NSTextView?
        var renderedText: String?
        var renderedJSON: Bool?

        init(onOpenLink: @escaping (URL) -> Void) { self.onOpenLink = onOpenLink }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard NSEvent.modifierFlags.contains(.command) else { return false } // only Cmd+click acts
            let url: URL?
            if let u = link as? URL { url = u }
            else if let s = link as? String { url = URL(string: s) }
            else { url = nil }
            if let url { onOpenLink(url) }
            return true   // we handled it; don't let AppKit open it in a browser
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme Aerospace -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Aerospace/Views/ResponseTextView.swift
git commit -m "feat: NSTextView-backed response body with links and find bar"
```

---

## Task 10: Wire `ResponseView` to `ResponseTextView` (body render + Cmd+S + link tap)

**Files:**
- Modify: `Aerospace/Views/ResponseView.swift`
- Verify: build + manual smoke test.

**Interfaces:**
- Consumes: `ResponseTextView` (Task 9), `APITesterStore.openEphemeralGet` (Task 7).
- Produces: `ResponseView` gains `@EnvironmentObject store` and renders both JSON and plain bodies through `ResponseTextView`; a `.keyboardShortcut("s", modifiers: .command)` (on a hidden button gated to the body pane) flips a `@State showFind` signal; link taps call `store.openEphemeralGet(url:)`.

- [ ] **Step 1: Update `ResponseView`** — make these edits:

Add near the top of the struct:

```swift
    @EnvironmentObject private var store: APITesterStore
    @State private var showFind = false
```

Replace `bodyView(_:)` with a version that always uses `ResponseTextView` and adds the Cmd+S trigger:

```swift
    @ViewBuilder
    private func bodyView(_ response: APIResponse) -> some View {
        if response.bodyText.isEmpty {
            Text("Empty body")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                // Hidden button carries the Cmd+S shortcut; active only while the
                // body pane is visible so it does not shadow a global Save.
                Button("") { showFind = true }
                    .keyboardShortcut("s", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)

                ResponseTextView(
                    text: response.bodyText,
                    isJSON: response.isBodyJSON,
                    onOpenLink: { url in store.openEphemeralGet(url: url) },
                    showFindBarSignal: $showFind
                )
            }
        }
    }
```

Note: the `Picker`/`headersView` for the Headers pane are unchanged. When the user switches to the Headers pane the hidden button unmounts, so Cmd+S is scoped to the Body pane.

- [ ] **Step 2: Update the `#Preview`** — the preview constructs `ResponseView(...)` directly; add the environment object so it still renders:

```swift
#Preview {
    ResponseView(
        response: APIResponse(outcome: .success, statusCode: 200,
                              headers: [HeaderPair(name: "Content-Type", value: "application/json")],
                              bodyText: "{\"ok\":true}", bodyByteCount: 11,
                              duration: .milliseconds(245), isBodyJSON: true),
        isSending: false
    )
    .environmentObject(APITesterStore())
    .frame(width: 480, height: 360)
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -scheme Aerospace -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Aerospace/Views/ResponseView.swift
git commit -m "feat: render response body via ResponseTextView with Cmd+S find and link tap"
```

---

## Task 11: `TabBarView` + mount in `APITesterView`

**Files:**
- Create: `Aerospace/Views/TabBarView.swift`
- Modify: `Aerospace/Views/APITesterView.swift`
- Verify: build + manual smoke test.

**Interfaces:**
- Consumes: `APITesterStore.tabs`/`activeTabID`/`selectTab`/`closeTab` (Task 6).
- Produces: `struct TabBarView: View` reading `@EnvironmentObject store`; a horizontal `ScrollView` of tab chips (method badge + name, italic when `isPreview`, close button). `APITesterView` places it above the editor/response `VSplitView` and its `ResponseView` reads `store.lastResponse`/`store.isSending` (now computed per active tab).

- [ ] **Step 1: Create `TabBarView`** — `Aerospace/Views/TabBarView.swift`:

```swift
//
//  TabBarView.swift
//  Aerospace
//
//  Horizontal strip of open request tabs. Single-click selects; the close
//  button removes. Preview (unpinned) tabs render in italic.
//

import SwiftUI

struct TabBarView: View {
    @EnvironmentObject private var store: APITesterStore

    var body: some View {
        if store.tabs.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(store.tabs) { tab in
                        chip(tab)
                        Divider().frame(height: 18)
                    }
                }
            }
            .frame(height: 32)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func chip(_ tab: OpenTab) -> some View {
        let isActive = tab.id == store.activeTabID
        return HStack(spacing: 6) {
            Text(tab.request.method.rawValue)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(methodColor(tab.request.method))
            Text(tab.request.name.isEmpty ? "Untitled" : tab.request.name)
                .font(.callout)
                .italic(tab.isPreview)
                .lineLimit(1)
            Button {
                store.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(isActive ? Color(nsColor: .selectedControlColor) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { store.selectTab(id: tab.id) }
    }

    private func methodColor(_ method: HTTPMethod) -> Color {
        switch method {
        case .get: return .green
        case .post: return .blue
        case .put, .patch: return .orange
        case .delete: return .red
        }
    }
}

#Preview {
    TabBarView()
        .environmentObject(APITesterStore())
        .frame(width: 600)
}
```

- [ ] **Step 2: Mount it in `APITesterView`** — replace the `VSplitView` block:

```swift
            VStack(spacing: 0) {
                TabBarView()
                Divider()
                VSplitView {
                    RequestEditorView()
                        .frame(minWidth: 420, minHeight: 220)
                    ResponseView(response: store.lastResponse, isSending: store.isSending)
                        .frame(minWidth: 420, minHeight: 180)
                }
            }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -scheme Aerospace -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Aerospace/Views/TabBarView.swift Aerospace/Views/APITesterView.swift
git commit -m "feat: tab bar above editor/response panes"
```

---

## Task 12: Folder tree + drag-and-drop in `RequestListView`

**Files:**
- Modify: `Aerospace/Views/RequestListView.swift`
- Verify: build + manual smoke test.

**Interfaces:**
- Consumes: `APITesterStore` folders/requests/move/newFolder/renameFolder/deleteFolder (Tasks 4, 6), `openRequest` (Task 6).
- Produces: a `List` rendering a nested tree. Folders are `DisclosureGroup`s (recursive), requests are rows. Single-click a request → `store.openRequest(id:, pinned: false)`; double-click → `pinned: true`. Drag a request (`.onDrag` providing its id string) onto a folder (or the root drop zone) → `store.move(requestID:toFolder:)`. Context menus for New Folder / New Request / Rename / Delete / Duplicate.

**Design note:** Requests are dragged via an `NSItemProvider` carrying the request UUID string (UTType `.text`). Folder drop targets use `.onDrop(of: [.text])`. Folder-into-folder dragging is supported the same way with a `folder:` id prefix to disambiguate (`"req:<uuid>"` vs `"fld:<uuid>"`).

- [ ] **Step 1: Rewrite `RequestListView`** — replace the file body with a recursive tree:

```swift
//
//  RequestListView.swift
//  Aerospace
//
//  The saved-request sidebar for the API tester: a nested folder tree with
//  drag-and-drop, opening requests into tabs.
//

import SwiftUI
import UniformTypeIdentifiers

struct RequestListView: View {
    @EnvironmentObject private var store: APITesterStore
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .frame(minWidth: 210)
    }

    private var header: some View {
        HStack {
            Text("Requests").font(.headline)
            Spacer()
            Button { _ = store.newFolder(parentID: nil) } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless).help("New folder")
            Button { store.newRequest() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless).help("New request")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private var list: some View {
        if store.requests.isEmpty && store.folders.isEmpty {
            ContentUnavailableView("No Saved Requests", systemImage: "tray",
                                   description: Text("Tap + to create one."))
        } else {
            List {
                // Root drop target: dropping here moves items to root (nil folder).
                ForEach(childFolders(of: nil)) { folder in
                    folderNode(folder)
                }
                ForEach(rootRequests()) { request in
                    requestRow(request)
                }
            }
            .listStyle(.sidebar)
            .onDrop(of: [.text], isTargeted: nil) { providers in
                handleDrop(providers, intoFolder: nil)
            }
        }
    }

    // MARK: - Tree helpers

    private func childFolders(of parent: UUID?) -> [RequestFolder] {
        store.folders.filter { $0.parentID == parent }
            .sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
    }

    private func requests(in folder: UUID?) -> [SavedRequest] {
        store.requests.filter { $0.folderID == folder }
            .sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
    }

    private func rootRequests() -> [SavedRequest] { requests(in: nil) }

    // MARK: - Nodes

    @ViewBuilder
    private func folderNode(_ folder: RequestFolder) -> some View {
        DisclosureGroup {
            ForEach(childFolders(of: folder.id)) { folderNode($0) }
            ForEach(requests(in: folder.id)) { requestRow($0) }
        } label: {
            folderLabel(folder)
        }
    }

    private func folderLabel(_ folder: RequestFolder) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            if renaming == folder.id {
                TextField("Name", text: $renameText, onCommit: {
                    store.renameFolder(id: folder.id, to: renameText)
                    renaming = nil
                })
            } else {
                Text(folder.name).lineLimit(1)
            }
        }
        .contextMenu {
            Button("New Folder") { _ = store.newFolder(parentID: folder.id) }
            Button("New Request Here") { store.newRequest(inFolder: folder.id) }
            Button("Rename") { renameText = folder.name; renaming = folder.id }
            Button("Delete", role: .destructive) { store.deleteFolder(id: folder.id) }
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers, intoFolder: folder.id)
        }
    }

    private func requestRow(_ request: SavedRequest) -> some View {
        HStack(spacing: 8) {
            Text(request.method.rawValue)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(methodColor(request.method))
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.name.isEmpty ? "Untitled" : request.name).lineLimit(1)
                if !request.urlString.isEmpty {
                    Text(request.urlString).font(.caption2)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.openRequest(id: request.id, pinned: true) }
        .onTapGesture(count: 1) { store.openRequest(id: request.id, pinned: false) }
        .onDrag { NSItemProvider(object: "req:\(request.id.uuidString)" as NSString) }
        .contextMenu {
            Button("Duplicate") { store.duplicate(id: request.id) }
            Button("Delete", role: .destructive) { store.delete(id: request.id) }
        }
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider], intoFolder folderID: UUID?) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String else { return }
                DispatchQueue.main.async {
                    if string.hasPrefix("req:"),
                       let id = UUID(uuidString: String(string.dropFirst(4))) {
                        store.move(requestID: id, toFolder: folderID)
                    } else if string.hasPrefix("fld:"),
                              let id = UUID(uuidString: String(string.dropFirst(4))) {
                        store.move(folderID: id, toParent: folderID)
                    }
                }
            }
        }
        return true
    }

    private func methodColor(_ method: HTTPMethod) -> Color {
        switch method {
        case .get: return .green
        case .post: return .blue
        case .put, .patch: return .orange
        case .delete: return .red
        }
    }
}

#Preview {
    RequestListView()
        .environmentObject(APITesterStore())
        .frame(width: 240, height: 400)
}
```

- [ ] **Step 2: Add the `newRequest(inFolder:)` overload the menu calls** — in `APITesterStore.swift`, alongside `newRequest()`:

```swift
    func newRequest(inFolder folderID: UUID?) {
        flushPendingSave()
        isLoadingSelection = true
        var fresh = SavedRequest()
        fresh.folderID = folderID
        editing = fresh
        selectedID = nil
        isLoadingSelection = false
        // Open it as a pinned tab so the user can start editing immediately.
        let tab = OpenTab(requestID: fresh.id, request: fresh, isPreview: false)
        tabs.append(tab)
        activeTabID = tab.id
        persistTabs()
    }
```

Also update the existing `newRequest()` to open a preview tab for the blank request so it appears in the tab bar (append after setting `editing`):

```swift
        let tab = OpenTab(requestID: editing.id, request: editing, isPreview: true)
        tabs.append(tab)
        activeTabID = tab.id
        persistTabs()
```

Add these tab lines just before `newRequest()`'s closing brace (after `selectedID = nil`).

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -scheme Aerospace -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Full unit-test regression**

Run: `xcodebuild test -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests -quiet`
Expected: PASS (all AerospaceTests green).

- [ ] **Step 5: Commit**

```bash
git add Aerospace/Views/RequestListView.swift Aerospace/Storage/APITesterStore.swift
git commit -m "feat: nested folder tree with drag-and-drop in request sidebar"
```

---

## Task 13: Manual verification pass

**Files:** none (manual).

- [ ] **Step 1: Launch the app**

Run: `xcodebuild build -scheme Aerospace -destination 'platform=macOS' -quiet && open $(xcodebuild -scheme Aerospace -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')`

- [ ] **Step 2: Verify each feature** (check every box after confirming):
  - [ ] Create a folder, create a subfolder inside it, create a request inside the subfolder.
  - [ ] Drag a request from root into a folder; it moves. Drag a folder into another folder; it nests. Dragging a folder into its own descendant does nothing.
  - [ ] Delete a folder that contains a request + subfolder → folder disappears, the request and subfolder reappear at the parent level (nothing destroyed).
  - [ ] Single-click a request → opens an italic preview tab; single-click another → the preview tab is reused. Double-click (or edit) pins the tab. Multiple pinned tabs coexist; each shows its own response.
  - [ ] Send in one tab, switch tabs → each tab shows its own last response and its own sending spinner.
  - [ ] In a JSON response containing a URL, Cmd+click the URL → a new pinned tab opens with a GET to that URL and fires immediately.
  - [ ] With the response Body pane focused, press Cmd+S → the find bar appears; typing highlights matches; Return / Shift+Return jump next/prev.
  - [ ] Quit and relaunch → folder tree and open tabs (including the active tab) are restored.

- [ ] **Step 3: Commit any fixes found during manual testing**, then finish.

---

## Self-Review

**Spec coverage:**
- Folders (nested + drag&drop, persisted): Tasks 1–4, 12. ✓
- Tabs (preview/pin, persisted): Tasks 5, 6, 11. ✓
- Cmd+click URL → ephemeral GET tab: Tasks 7, 9, 10. ✓
- Cmd+S find bar (highlight + next/prev): Tasks 9, 10. ✓ (native NSTextView find bar provides next/prev + counter.)
- NSTextView-backed body preserving JSON highlight + copy: Tasks 8, 9, 10. ✓
- Delete folder re-parents children; cycle guard: Task 4. ✓
- Persisted tabs referencing deleted requests pruned on load: Task 6 (`restoreTabs`). ✓
- Per-tab send state: Task 7. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type consistency:** `openRequest(id:pinned:)`, `selectTab(id:)`, `closeTab(id:)`, `move(requestID:toFolder:)`, `move(folderID:toParent:)`, `newFolder(parentID:)`, `openEphemeralGet(url:)`, `debugUpsertRequest`, `debugSetResponse(_:forTab:)`, `JSONHighlighter.pretty/attributed`, `ResponseTextView(text:isJSON:onOpenLink:showFindBarSignal:)` are used consistently across defining and consuming tasks. `lastResponse`/`isSending` converted from stored to computed in Task 7 (APITesterView in Task 11 reads them unchanged). ✓
