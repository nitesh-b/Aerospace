# API Tester: Folders, Tabs, Response-Body Interactions — Design

**Date:** 2026-07-24
**Status:** Approved (design)
**Author:** nitesh_b

## Summary

Extend the API Tester (a native SwiftUI macOS feature in the Aerospace app) with four
capabilities:

1. **Folder structure** — organize saved requests into arbitrarily nested folders, with
   drag-and-drop reorganization; persisted.
2. **Tabs** — open requests in tabs, using a VS Code-style single **preview** tab that
   pins on edit/double-click; open tabs persist across restarts.
3. **Cmd+click a URL in the response body** — opens a new *ephemeral* tab with a GET
   request to that URL and sends it immediately.
4. **Cmd+S find in the response body** — a native find bar with match highlighting and
   next/previous navigation, active when the response body is focused.

## Context (current implementation)

- **Stack:** native SwiftUI macOS app (`Aerospace.xcodeproj`), not Electron/React.
- **State:** `APITesterStore` (`@MainActor final class … ObservableObject`), injected as
  an `@EnvironmentObject`. Today it holds a *single* active request (`editing`), a single
  `lastResponse`, and a store-wide `isSending`.
- **Persistence:** requests in SQLite (`Storage/SQLiteRequestStore.swift`, table
  `api_requests`, JSON-encoded `query_json`/`headers_json` columns, additive column
  migrations already supported); global `variables` and the N10 key live in
  UserDefaults / Keychain.
- **Models:** `SavedRequest` (struct, `Identifiable/Codable/Hashable/Sendable`, keyed by
  `id: UUID`), `KeyValueItem`, `HTTPMethod`, `AuthKind`, `BodyKind`, `APIResponse`.
- **Views:** `APITesterView` (HSplitView: list | VSplitView[editor/response]),
  `RequestListView` (sidebar `List(selection:)` over `store.requests`),
  `RequestEditorView` (binds `$store.editing`), `ResponseView` (takes `response`/`isSending`
  params; body via `JsonViewer` for JSON, monospaced `Text` otherwise).
- **Send flow:** `RequestBuilder.makeURLRequest(from:variables:)` applies `{name}`
  substitution → optional N10 HMAC signing → `APIClient().send` in a cancellable `Task`.
- **Shortcuts:** SwiftUI-native only — app `.commands` in `AerospaceApp.swift` and
  view-level `.keyboardShortcut` (e.g. Send = Cmd+Return). No `NSEvent` monitors.

## Key architectural decision: NSTextView-backed response body

Features 3 and 4 both require capabilities plain SwiftUI `Text` does not provide well:
clickable link handling with modifier detection, and a find bar with highlighted,
navigable matches. Rather than bolt these onto `Text`, introduce a single
`ResponseTextView` (`NSViewRepresentable` wrapping `NSTextView`) that:

- Renders the response body as an `NSAttributedString`. JSON keeps its existing syntax
  highlighting: `JsonViewer`'s highlight logic is refactored to produce an
  `NSAttributedString` (or its `AttributedString` output is bridged) and reused here.
- Marks URLs as links (via `NSDataDetector` over the body text) so they are clickable.
- Handles **Cmd+click** on a link via `textView(_:clickedOnLink:at:)`, checking
  `NSEvent.modifierFlags` for `.command`; forwards the URL to the store.
- Enables the native find bar (`textView.usesFindBar = true`) and exposes a way to show
  it, bound to **Cmd+S** while the response body is first responder.
- Remains read-only and text-selectable (preserving current copy behavior).

`ResponseView` uses `ResponseTextView` for the body pane (both JSON and non-JSON). The
copy-to-pasteboard affordance from `JsonViewer` is preserved.

## Data model

### RequestFolder (new — `Models/RequestFolder.swift`)

```swift
struct RequestFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var parentID: UUID?      // nil = root
    var sortIndex: Int
    var createdAt: Date
    var updatedAt: Date
}
```

### SavedRequest (extended)

Add:
- `folderID: UUID?` — nil = root (unfiled).
- `sortIndex: Int` — order within its parent (folder or root).

Both are added with sensible defaults so decoding existing rows is safe.

### OpenTab (new — `Models/OpenTab.swift`)

```swift
struct OpenTab: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var requestID: SavedRequest.ID?   // nil = ephemeral (not backed by a saved request)
    var request: SavedRequest         // working/editing buffer for this tab
    var isPreview: Bool               // true = VS Code-style preview tab
    // response, isSending are runtime-only (see store), not persisted
}
```

Runtime-only per-tab state (`response: APIResponse?`, `isSending: Bool`, and the
in-flight send `Task`) is kept in the store keyed by tab id, not in the persisted struct.

## Persistence

- **Folders:** new SQLite table `api_folders` (`id`, `name`, `parent_id`, `sort_index`,
  `created_at`, `updated_at`) in `SQLiteRequestStore`, with CRUD (`upsertFolder`,
  `fetchAllFolders`, `deleteFolder`). Deleting a folder re-parents its children to the
  folder's parent (no cascading delete of requests) — requests are never destroyed by a
  folder delete.
- **Requests:** additive columns `folder_id`, `sort_index` on `api_requests` via the
  existing migration mechanism; read/written in `upsert`/`fetch`.
- **Tabs:** open tabs + active tab id persisted as JSON in UserDefaults (key
  `"api.openTabs"` / `"api.activeTab"`), matching the existing `variables` pattern.
  Ephemeral tabs persist their working `SavedRequest` buffer so they restore intact.
  On load, tabs whose `requestID` no longer exists as a saved request are dropped
  (unless ephemeral).

## Store changes (`APITesterStore`)

- New published state: `folders: [RequestFolder]`, `tabs: [OpenTab]`,
  `activeTabID: OpenTab.ID?`, plus runtime maps for per-tab response/isSending.
- `editing` becomes a binding into the active tab's `request` (a computed
  `Binding<SavedRequest>` or a forwarding `@Published` synced to the active tab), so
  `RequestEditorView` continues to bind to one request. `lastResponse`/`isSending`
  resolve to the active tab.
- **Folder ops:** `newFolder(parentID:)`, `renameFolder`, `deleteFolder`,
  `move(request:toFolder:)`, `move(folder:toParent:)`, reordering via `sortIndex`.
  A cycle guard prevents dropping a folder into its own descendant.
- **Tab ops:** `openRequest(id:)` (reuse/replace preview tab, or focus existing pinned
  tab), `pinTab`, `closeTab`, `selectTab`, `openEphemeralGet(url:)` (feature 3). Editing
  a preview tab's request flips `isPreview = false`.
- **Send:** per-tab. Each tab has its own cancellable `Task`; `send()` acts on the active
  tab; results stored in the tab's runtime slot. Auto-save (debounced 0.3s) applies to
  the active tab's request when it is backed by a saved request and non-empty.

## Views

- **`RequestListView`** → tree of folders + requests. `List` with `children:` /
  `OutlineGroup` for nesting; `.onDrag`/`.onDrop` (drop delegate) to move requests and
  folders and to reorder. Context menu: New Folder, New Request Here, Rename, Delete,
  Duplicate. Single-click opens/replaces the preview tab; double-click pins.
- **`TabBarView`** (new) → horizontal tab strip above the editor/response area. Shows
  request name + method badge, italic for preview tabs, a dirty indicator, active
  highlight, and per-tab close button. Clicking selects; middle-click / close button
  closes.
- **`APITesterView`** → add `TabBarView` at the top of the right-hand pane above the
  editor/response VSplitView.
- **`RequestEditorView`** → binds to the active tab's request (via the store's forwarding
  binding); otherwise unchanged. Editing flips a preview tab to pinned.
- **`ResponseView`** → body pane rendered by `ResponseTextView`; keeps the status/timing
  header and body/headers segmented switcher. Reads the active tab's response.
- **`ResponseTextView`** (new) → as described in the architecture section.

## Shortcuts

- **Cmd+S (response body focused):** show the find bar in `ResponseTextView`. Scoped to
  the response body being first responder so it does not collide globally. Implemented in
  the NSTextView layer (`performKeyEquivalent`/`keyDown` on a subclass, or a first-
  responder-gated command) rather than a global app command.
- **Cmd+click a link (response body):** open ephemeral GET tab + send (feature 3).
- Existing Send = Cmd+Return is unchanged and now targets the active tab.

## Error handling & edge cases

- Deleting a folder re-parents children; never deletes requests implicitly.
- Folder drag cannot create a cycle (guard against dropping into a descendant).
- Closing the active tab selects an adjacent tab; closing the last tab leaves an empty
  state (no active request) — the editor/response show an empty placeholder.
- Ephemeral tab from a bad/unparseable URL: still opens the tab, send fails through the
  normal `APIClient` `.failure` path and is shown in the response pane.
- Persisted tabs referencing deleted requests are pruned on load.
- Body larger than the existing 2 MB display cap continues to be truncated for display.

## Out of scope (YAGNI)

- Request-level (non-global) variables or environments.
- Importing/exporting collections (e.g. Postman/OpenAPI).
- Tab drag-to-reorder (tabs open/close/select only in v1).
- Opening links in an external browser on plain (non-Cmd) click.

## Suggested implementation sequencing

1. Data model + persistence (folders, request columns, tab persistence) — no UI.
2. Folder tree UI + drag-and-drop in `RequestListView`.
3. Tabs: `OpenTab`, store generalization, `TabBarView`, editor/response binding to active
   tab, per-tab send, persistence.
4. `ResponseTextView` (NSTextView) replacing body rendering, preserving JSON highlight +
   copy.
5. Cmd+click ephemeral GET tab.
6. Cmd+S find bar.
