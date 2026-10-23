//
//  DynamicConfigStore.swift
//  Aerospace
//
//  The observable state for the Dynamic Config tool: the open config file,
//  the edited document, the section / entry selection (kept here so it
//  survives switching tools), and hosting the document on the Logger server
//  at /config/dynamic_config.json.
//
//  The file is reopened after relaunch through a security-scoped bookmark.
//  Unsaved edits are kept as a draft in UserDefaults and restored with it.
//

import Foundation
import Combine

@MainActor
final class DynamicConfigStore: ObservableObject {

    enum Status: Equatable {
        case success(String)
        case failure(String)
    }

    @Published private(set) var fileURL: URL?
    @Published private(set) var config: DynamicConfig?
    @Published private(set) var isDirty = false
    @Published var status: Status?

    @Published var selectedSectionKey: String? {
        didSet { if selectedSectionKey != oldValue { selectedEntryIDs = [] } }
    }
    @Published var selectedEntryIDs: Set<DynamicConfig.Entry.ID> = []

    // MARK: Hosting

    static let maxRequests = 200

    /// Serve the document (unsaved edits included) on the Logger server.
    @Published var isHosting: Bool {
        didSet {
            defaults.set(isHosting, forKey: Keys.hosting)
            syncHost()
        }
    }
    /// The address shown in the hosted URL.
    @Published var urlHost: PauseAdHost {
        didSet { defaults.set(urlHost.rawValue, forKey: Keys.urlHost) }
    }
    /// Requests for the hosted config, newest first.
    @Published private(set) var requests: [DynamicConfigRequest] = []

    /// Installed on the Logger server via `attach(to:)`.
    let host = DynamicConfigHost()

    /// The text last read from or written to `fileURL`, as formatted by
    /// `DynamicConfig.text`.
    private var savedText: String?

    private let defaults: UserDefaults
    private let bookmarks: FolderBookmarking
    private let now: @Sendable () -> Date

    private enum Keys {
        static let fileBookmark = "dynamicConfig.fileBookmark"
        static let draft = "dynamicConfig.draft"
        static let hosting = "dynamicConfig.hosting"
        static let urlHost = "dynamicConfig.urlHost"
    }

    nonisolated deinit {}

    init(defaults: UserDefaults = .standard,
         bookmarks: FolderBookmarking = SecurityScopedBookmarks(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.bookmarks = bookmarks
        self.now = now
        isHosting = defaults.object(forKey: Keys.hosting) as? Bool ?? true
        urlHost = defaults.string(forKey: Keys.urlHost).flatMap(PauseAdHost.init(rawValue:)) ?? .lan

        if let url = restoreBookmark() {
            fileURL = url
            if let data = FileManager.default.contents(atPath: url.path),
               let config = try? DynamicConfig(data: data) {
                self.config = config
                savedText = config.text
            }
        }
        if let draft = defaults.string(forKey: Keys.draft), let config = try? DynamicConfig(text: draft) {
            self.config = config
        }
        documentChanged()
        selectedSectionKey = config?.sections.first?.key
    }

    // MARK: - Derived

    var sections: [DynamicConfig.Section] { config?.sections ?? [] }

    var selectedSection: DynamicConfig.Section? {
        guard let selectedSectionKey else { return nil }
        return config?.section(selectedSectionKey)
    }

    /// Selected entries of the selected section, in section order.
    var selectedEntries: [DynamicConfig.Entry] {
        selectedSection?.entries.filter { selectedEntryIDs.contains($0.id) } ?? []
    }

    var fileName: String { fileURL?.lastPathComponent ?? "Untitled" }

    /// `dynamic_config_2026_10_23.json` for today, unless a file is open.
    var suggestedFileName: String {
        if let fileURL { return fileURL.lastPathComponent }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now())
        return String(format: "dynamic_config_%04d_%02d_%02d.json", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - File

    /// Opens `url`, discarding unsaved edits.
    func open(_ url: URL) {
        let accessing = bookmarks.startAccessing(url)
        let loaded: DynamicConfig
        do {
            loaded = try DynamicConfig(data: Data(contentsOf: url))
        } catch {
            if accessing { bookmarks.stopAccessing(url) }
            status = .failure("Couldn't open \(url.lastPathComponent): \(error.localizedDescription)")
            return
        }
        if let old = fileURL, old != url { bookmarks.stopAccessing(old) }
        if let data = try? bookmarks.bookmark(for: url) { defaults.set(data, forKey: Keys.fileBookmark) }
        fileURL = url
        config = loaded
        savedText = loaded.text
        selectedSectionKey = loaded.sections.first?.key
        documentChanged()
        status = .success("Opened \(url.lastPathComponent)")
    }

    func save() {
        guard let fileURL else {
            status = .failure("Choose where to save with Save As.")
            return
        }
        write(to: fileURL)
    }

    /// Writes to `url` and makes it the open file.
    func save(as url: URL) {
        guard url != fileURL else {
            write(to: url)
            return
        }
        let accessing = bookmarks.startAccessing(url)
        guard write(to: url) else {
            if accessing { bookmarks.stopAccessing(url) }
            return
        }
        if let old = fileURL { bookmarks.stopAccessing(old) }
        if let data = try? bookmarks.bookmark(for: url) { defaults.set(data, forKey: Keys.fileBookmark) }
        fileURL = url
    }

    var canRevert: Bool { isDirty && savedText != nil }

    /// Discards unsaved edits.
    func revert() {
        guard let savedText, let saved = try? DynamicConfig(text: savedText) else { return }
        config = saved
        if selectedSection == nil { selectedSectionKey = saved.sections.first?.key }
        pruneSelection()
        documentChanged()
        status = nil
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        guard let config else { return false }
        let text = config.text
        do {
            // Not atomic: the sandbox grants access to the file, not its folder.
            try Data(text.utf8).write(to: url)
        } catch {
            status = .failure("Couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        savedText = text
        documentChanged()
        status = .success("Saved \(url.lastPathComponent)")
        return true
    }

    // MARK: - Hosting

    /// Serves the document at `/config/dynamic_config.json` on the Logger server.
    func attach(to logStore: LogStore) {
        logStore.setConfigHandling(host: host) { [weak self] request in
            Task { @MainActor [weak self] in self?.record(request) }
        }
    }

    func record(_ request: DynamicConfigRequest) {
        requests.insert(request, at: 0)
        if requests.count > Self.maxRequests {
            requests.removeLast(requests.count - Self.maxRequests)
        }
    }

    func clearRequests() {
        requests.removeAll()
    }

    func hostedURL(port: UInt16) -> String {
        DynamicConfigHost.url(host: urlHost.address(), port: port)
    }

    // MARK: - Editing

    func setValue(_ value: JSONValue, at path: [String]) {
        mutate { $0.setValue(value, at: path) }
    }

    func setPlatformValue(_ value: JSONValue?, for platform: ConfigPlatform, at paths: [[String]]) {
        mutate { config in
            for path in paths { config.setPlatformValue(value, for: platform, at: path) }
        }
    }

    func clearOverrides(at paths: [[String]]) {
        mutate { config in
            for path in paths { config.clearOverrides(at: path) }
        }
    }

    /// Adds an entry to the selected section and selects it.
    func addEntry(_ key: String) throws {
        guard var config, let section = selectedSection else { return }
        try config.addEntry(key, value: DynamicConfig.newEntryValue(in: section), toSection: section.key)
        self.config = config
        documentChanged()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedEntryIDs = [DynamicConfig.Entry.id(for: [section.key, trimmed])]
    }

    func removeEntries(_ ids: Set<DynamicConfig.Entry.ID>) {
        let paths = (selectedSection?.entries ?? []).filter { ids.contains($0.id) }.map(\.path)
        mutate { config in
            for path in paths { config.removeEntry(at: path) }
        }
        pruneSelection()
    }

    /// Replaces the whole document from the JSON panel.
    func replace(withText text: String) throws {
        let replacement = try DynamicConfig(text: text)
        config = replacement
        if selectedSection == nil { selectedSectionKey = replacement.sections.first?.key }
        pruneSelection()
        documentChanged()
    }

    private func mutate(_ body: (inout DynamicConfig) -> Void) {
        guard var config else { return }
        body(&config)
        guard config != self.config else { return }
        self.config = config
        documentChanged()
    }

    private func pruneSelection() {
        let ids = Set(selectedSection?.entries.map(\.id) ?? [])
        selectedEntryIDs.formIntersection(ids)
    }

    /// Updates the dirty flag, the draft and the hosted document.
    private func documentChanged() {
        let text = config?.text
        isDirty = text != nil && text != savedText
        if isDirty, let text {
            defaults.set(text, forKey: Keys.draft)
        } else {
            defaults.removeObject(forKey: Keys.draft)
        }
        syncHost(text)
    }

    private func syncHost(_ text: String? = nil) {
        host.update(document: (text ?? config?.text).map { Data($0.utf8) }, isEnabled: isHosting)
    }

    private func restoreBookmark() -> URL? {
        guard let data = defaults.data(forKey: Keys.fileBookmark),
              let resolved = try? bookmarks.resolve(data) else { return nil }
        let url = resolved.url
        bookmarks.startAccessing(url)
        if resolved.isStale, let fresh = try? bookmarks.bookmark(for: url) {
            defaults.set(fresh, forKey: Keys.fileBookmark)
        }
        return url
    }
}
