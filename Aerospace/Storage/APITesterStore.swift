//
//  APITesterStore.swift
//  Aerospace
//
//  Observable state for the API-tester tool: owns the SQLite request store,
//  publishes the saved-request list and the live edit buffer, debounces
//  auto-save, and runs (cancellable) requests through APIClient.
//

import Foundation
import Combine

@MainActor
final class APITesterStore: ObservableObject {

    @Published private(set) var requests: [SavedRequest] = []
    @Published private(set) var folders: [RequestFolder] = []
    @Published private(set) var tabs: [OpenTab] = []
    @Published var activeTabID: OpenTab.ID?
    private static let openTabsKey = "api.openTabs"
    private static let activeTabKey = "api.activeTab"
    @Published private(set) var responsesByTab: [OpenTab.ID: APIResponse] = [:]
    @Published private(set) var sendingTabs: Set<OpenTab.ID> = []

    var lastResponse: APIResponse? { activeTabID.flatMap { responsesByTab[$0] } }
    var isSending: Bool { activeTabID.map { sendingTabs.contains($0) } ?? false }

    /// Test seam.
    func debugSetResponse(_ response: APIResponse, forTab id: OpenTab.ID) {
        responsesByTab[id] = response
    }

    /// The app-wide N10 API key (HMAC secret). Backed by the Keychain, never
    /// stored in the request database and never sent as a header.
    @Published var n10APIKey: String {
        didSet { KeychainStore.save(n10APIKey, account: Self.n10KeyAccount) }
    }
    private static let n10KeyAccount = "N10_API_KEY"

    /// Global variables available to every request as `{name}` tokens in the
    /// URL, header values, query-param values, bearer token, and body.
    /// Persisted as JSON in UserDefaults — shared across all saved requests,
    /// not per-request state.
    @Published var variables: [KeyValueItem] {
        didSet { saveVariables() }
    }
    private static let variablesKey = "api.variables"

    /// Enabled, non-blank-keyed variables as a name → value dictionary, ready
    /// to hand to `RequestBuilder`. A later duplicate key wins.
    var variablesDictionary: [String: String] {
        var result: [String: String] = [:]
        for item in variables where item.isEnabled
            && !item.key.trimmingCharacters(in: .whitespaces).isEmpty {
            result[item.key] = item.value
        }
        return result
    }

    /// The request currently shown in the editor. Edits are debounced to disk.
    @Published var editing: SavedRequest {
        didSet {
            guard !isLoadingSelection else { return }
            writeEditingIntoActiveTab()
            scheduleAutoSave()
        }
    }

    /// Sidebar selection. Changing it flushes pending edits, then loads the row.
    @Published var selectedID: SavedRequest.ID? {
        didSet { if selectedID != oldValue { loadSelected() } }
    }

    private let store: SQLiteRequestStore
    private let defaults: UserDefaults
    private var autoSaveWork: DispatchWorkItem?
    private var sendTasksByTab: [OpenTab.ID: Task<Void, Never>] = [:]
    /// Suppresses auto-save while we programmatically replace `editing`.
    private var isLoadingSelection = false

    init(store: SQLiteRequestStore? = nil, defaults: UserDefaults = .standard) {
        self.store = store ?? Self.makeDefaultStore()
        self.defaults = defaults
        n10APIKey = KeychainStore.read(account: Self.n10KeyAccount) ?? ""
        variables = Self.loadVariables(from: defaults)
        let all = self.store.fetchAll()
        requests = all
        folders = self.store.fetchAllFolders()
        if let first = all.first {
            editing = first
            selectedID = first.id       // didSet does not fire during init
        } else {
            editing = SavedRequest()
            selectedID = nil
        }
        restoreTabs()
    }

    // An explicit (trivial) deinit works around a toolchain crash: without one,
    // deallocating an APITesterStore instance aborts with a malloc-corruption
    // SIGABRT inside the compiler-synthesized isolated deinit for this
    // @MainActor class (reproduces even on the pre-folders version of this
    // file, with no store methods called — see task-4-report.md for the
    // isolated repro). This keeps `APITesterStore(store:defaults:)` safe to
    // construct and let go out of scope in tests.
    deinit {}

    private static func loadVariables(from defaults: UserDefaults) -> [KeyValueItem] {
        guard let data = defaults.data(forKey: variablesKey),
              let items = try? JSONDecoder().decode([KeyValueItem].self, from: data) else {
            return []
        }
        return items
    }

    private func saveVariables() {
        guard let data = try? JSONEncoder().encode(variables) else { return }
        defaults.set(data, forKey: Self.variablesKey)
    }

    private static func makeDefaultStore() -> SQLiteRequestStore {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Aerospace", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("requests.sqlite").path
        do {
            return try SQLiteRequestStore(path: path)
        } catch {
            let tmp = fm.temporaryDirectory.appendingPathComponent("aerospace-requests.sqlite").path
            return (try? SQLiteRequestStore(path: tmp)) ?? (try! SQLiteRequestStore(path: ":memory:"))
        }
    }

    // MARK: - Selection & editing

    private func loadSelected() {
        flushPendingSave()
        guard let selectedID, let match = requests.first(where: { $0.id == selectedID }) else {
            return
        }
        isLoadingSelection = true
        editing = match
        isLoadingSelection = false
    }

    func newRequest() {
        flushPendingSave()
        isLoadingSelection = true
        editing = SavedRequest()
        isLoadingSelection = false
        selectedID = nil            // lazily inserted on first meaningful edit
        // Reuse an existing preview tab, else append — mirrors openRequest's
        // preview-reuse so at most one tab is ever marked `isPreview`.
        if let idx = tabs.firstIndex(where: { $0.isPreview }) {
            tabs[idx] = OpenTab(id: tabs[idx].id, requestID: editing.id, request: editing, isPreview: true)
            activeTabID = tabs[idx].id
        } else {
            let tab = OpenTab(requestID: editing.id, request: editing, isPreview: true)
            tabs.append(tab)
            activeTabID = tab.id
        }
        persistTabs()
    }

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

    func duplicate(id: SavedRequest.ID) {
        flushPendingSave()
        guard let original = store.fetch(id: id) else { return }
        let copy = original.duplicated()
        try? store.upsert(copy)
        refreshList()
        selectedID = copy.id        // triggers loadSelected → loads the copy
    }

    func delete(id: SavedRequest.ID) {
        store.delete(id: id)
        if selectedID == id {
            autoSaveWork?.cancel(); autoSaveWork = nil   // don't resurrect the deleted row
        }
        refreshList()
        if selectedID == id {
            selectedID = requests.first?.id
            if selectedID == nil {          // list now empty → blank template
                isLoadingSelection = true
                editing = SavedRequest()
                isLoadingSelection = false
            }
        }
    }

    // MARK: - Auto-save

    private func scheduleAutoSave() {
        autoSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performAutoSave() }
        autoSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func flushPendingSave() {
        guard let work = autoSaveWork else { return }
        work.cancel()
        autoSaveWork = nil
        performAutoSave()
    }

    private func performAutoSave() {
        autoSaveWork = nil
        // Ephemeral (unsaved) active tab: never auto-persist to the request list.
        if let activeTabID, let tab = tabs.first(where: { $0.id == activeTabID }), tab.requestID == nil {
            return
        }
        let alreadyPersisted = requests.contains { $0.id == editing.id }
        guard alreadyPersisted || !editing.isEffectivelyEmpty else { return }

        var snapshot = editing
        snapshot.updatedAt = Date()          // don't mutate `editing` (would re-trigger)
        try? store.upsert(snapshot)
        refreshList()
        if selectedID == nil { selectedID = snapshot.id }
    }

    /// Re-read the list from disk (kept in updated_at DESC order).
    private func refreshList() {
        requests = store.fetchAll()
    }

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
        sendTasksByTab[id]?.cancel()
        sendTasksByTab[id] = nil
        responsesByTab[id] = nil
        sendingTabs.remove(id)
        if wasActive {
            let neighbor = tabs[safe: idx] ?? tabs[safe: idx - 1] ?? tabs.last
            activeTabID = neighbor?.id
            loadActiveTabIntoEditing()
        }
        persistTabs()
    }

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

    private func writeEditingIntoActiveTab() {
        guard let activeTabID, let idx = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        tabs[idx].request = editing
        // A meaningful edit pins a preview tab (VS Code behavior).
        if tabs[idx].isPreview && !editing.isEffectivelyEmpty {
            tabs[idx].isPreview = false
        }
        persistTabs()
    }

    // MARK: - Sending

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

        // N10 signing: computed over the FINAL URL at send time.
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

        flushPendingSave()      // persist before sending
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
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
