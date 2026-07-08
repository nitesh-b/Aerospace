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
    @Published private(set) var isSending = false
    @Published private(set) var lastResponse: APIResponse?

    /// The request currently shown in the editor. Edits are debounced to disk.
    @Published var editing: SavedRequest {
        didSet { if !isLoadingSelection { scheduleAutoSave() } }
    }

    /// Sidebar selection. Changing it flushes pending edits, then loads the row.
    @Published var selectedID: SavedRequest.ID? {
        didSet { if selectedID != oldValue { loadSelected() } }
    }

    private let store: SQLiteRequestStore
    private var autoSaveWork: DispatchWorkItem?
    private var sendTask: Task<Void, Never>?
    /// Suppresses auto-save while we programmatically replace `editing`.
    private var isLoadingSelection = false

    init(store: SQLiteRequestStore? = nil) {
        self.store = store ?? Self.makeDefaultStore()
        let all = self.store.fetchAll()
        requests = all
        if let first = all.first {
            editing = first
            selectedID = first.id       // didSet does not fire during init
        } else {
            editing = SavedRequest()
            selectedID = nil
        }
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

    // MARK: - Sending

    func send() {
        let request: URLRequest
        do {
            request = try RequestBuilder().makeURLRequest(from: editing)
        } catch {
            lastResponse = APIResponse(
                outcome: .failure((error as? LocalizedError)?.errorDescription ?? "\(error)")
            )
            return
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
