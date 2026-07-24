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
    @Published private(set) var isSending = false
    @Published private(set) var lastResponse: APIResponse?

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
        didSet { if !isLoadingSelection { scheduleAutoSave() } }
    }

    /// Sidebar selection. Changing it flushes pending edits, then loads the row.
    @Published var selectedID: SavedRequest.ID? {
        didSet { if selectedID != oldValue { loadSelected() } }
    }

    private let store: SQLiteRequestStore
    private let defaults: UserDefaults
    private var autoSaveWork: DispatchWorkItem?
    private var sendTask: Task<Void, Never>?
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

    // MARK: - Sending

    func send() {
        var request: URLRequest
        do {
            request = try RequestBuilder().makeURLRequest(from: editing, variables: variablesDictionary)
        } catch {
            lastResponse = APIResponse(
                outcome: .failure((error as? LocalizedError)?.errorDescription ?? "\(error)")
            )
            return
        }

        // N10 signing: computed over the FINAL URL at send time.
        if editing.n10SigningEnabled {
            let key = n10APIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                lastResponse = APIResponse(outcome: .failure(
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
        sendTask?.cancel()
        isSending = true
        let client = APIClient()
        sendTask = Task { [weak self] in
            let response = await client.send(request)
            guard !Task.isCancelled else { return }
            self?.lastResponse = response
            self?.isSending = false
        }
    }

    func cancelSend() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
    }
}
