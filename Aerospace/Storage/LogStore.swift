//
//  LogStore.swift
//  Aerospace
//
//  The observable application state: owns the SQLite store and the HTTP
//  server, publishes the filtered log list, category list, statistics, and
//  server state, and mediates settings + retention.
//

import Foundation
import Combine

@MainActor
final class LogStore: ObservableObject {

    // MARK: - Published UI state

    @Published private(set) var logs: [LogEvent] = []
    @Published private(set) var categories: [String] = []
    @Published private(set) var statistics: LogStatistics = .empty
    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var totalStored: Int = 0

    /// The active filter for the Logs tab. Setting it re-queries immediately.
    @Published var query: LogQuery = .recent {
        didSet { if query != oldValue { refreshLogs() } }
    }

    // MARK: - Persisted settings

    @Published var port: UInt16 {
        didSet { defaults.set(Int(port), forKey: Keys.port) }
    }
    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Keys.retentionDays) }
    }
    @Published var autoPurgeEnabled: Bool {
        didSet { defaults.set(autoPurgeEnabled, forKey: Keys.autoPurge) }
    }
    /// Upper bound on rows fetched into the Logs tab at once.
    let displayLimit = 5_000
    /// Upper bound on rows sampled for the Statistics tab.
    let statisticsLimit = 20_000

    // MARK: - Dependencies

    private let store: SQLiteLogStore
    private let server = HTTPLogServer()
    private let defaults: UserDefaults
    private var derivedRefresh: DispatchWorkItem?

    private enum Keys {
        static let port = "server.port"
        static let retentionDays = "retention.days"
        static let autoPurge = "retention.autoPurge"
    }

    // MARK: - Init

    init(store: SQLiteLogStore? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.port = UInt16(defaults.object(forKey: Keys.port) as? Int ?? 8080)
        self.retentionDays = defaults.object(forKey: Keys.retentionDays) as? Int ?? 7
        self.autoPurgeEnabled = defaults.object(forKey: Keys.autoPurge) as? Bool ?? false

        if let store {
            self.store = store
        } else {
            self.store = Self.makeDefaultStore()
        }

        wireServer()
        purgeIfNeeded()
        refreshLogs()
        scheduleDerivedRefresh()
    }

    /// Open the on-disk database in Application Support/Aerospace.
    private static func makeDefaultStore() -> SQLiteLogStore {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Aerospace", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("logs.sqlite").path
        do {
            return try SQLiteLogStore(path: path)
        } catch {
            // Fall back to a temporary database so the app still runs.
            let tmp = fm.temporaryDirectory.appendingPathComponent("aerospace-logs.sqlite").path
            return (try? SQLiteLogStore(path: tmp)) ?? (try! SQLiteLogStore(path: ":memory:"))
        }
    }

    // MARK: - Server control

    private func wireServer() {
        server.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.ingest(event) }
        }
        server.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in self?.serverState = state }
        }
    }

    func startServer() {
        server.start(port: port)
    }

    func stopServer() {
        server.stop()
    }

    func restartServer() {
        server.stop()
        server.start(port: port)
    }

    // MARK: - Ingestion

    private func ingest(_ event: LogEvent) {
        try? store.insert(event)
        totalStored += 1
        if matches(event, query) {
            logs.insert(event, at: 0)
            if logs.count > displayLimit { logs.removeLast() }
        }
        if !categories.contains(event.category) {
            categories = store.categories()
        }
        scheduleDerivedRefresh()
    }

    private func matches(_ event: LogEvent, _ query: LogQuery) -> Bool {
        if let category = query.category, event.category != category { return false }
        if let sub = query.subCategory, event.subCategory != sub { return false }
        if let minLevel = query.minLevel, event.level < minLevel { return false }
        if let search = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !search.isEmpty {
            let haystack = "\(event.category) \(event.subCategory) \(event.payload)".lowercased()
            if !haystack.contains(search.lowercased()) { return false }
        }
        return true
    }

    // MARK: - Refresh

    /// Re-query the visible log list and category list from the database.
    func refreshLogs() {
        var q = query
        q.limit = displayLimit
        logs = store.fetch(q)
        categories = store.categories()
        totalStored = store.count()
    }

    /// Recompute statistics from a sample of stored logs. Debounced so bursts
    /// of ingestion don't thrash the CPU.
    private func scheduleDerivedRefresh() {
        derivedRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let sample = self.store.fetch(LogQuery(limit: self.statisticsLimit))
            self.statistics = LogStatistics.compute(from: sample)
            self.totalStored = self.store.count()
        }
        derivedRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func subCategories(for category: String) -> [String] {
        let events = store.fetch(LogQuery(category: category, limit: statisticsLimit))
        let unique = Set(events.map(\.subCategory))
        return unique.sorted()
    }

    // MARK: - Retention & maintenance

    func purgeIfNeeded() {
        guard autoPurgeEnabled, retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        store.deleteOlderThan(cutoff)
    }

    func clearAll() {
        store.deleteAll()
        logs = []
        categories = []
        totalStored = 0
        statistics = .empty
    }

    // MARK: - Export

    func exportJSON() -> Data? {
        let events = store.fetch(LogQuery(limit: statisticsLimit))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(events)
    }

    func exportCSV() -> Data {
        var rows = ["id,timestamp,category,subcategory,level,session_id,application,payload"]
        let formatter = ISO8601DateFormatter()
        let events = store.fetch(LogQuery(limit: statisticsLimit))
        for e in events {
            let fields = [
                e.id.uuidString,
                formatter.string(from: e.timestamp),
                e.category,
                e.subCategory,
                e.level.rawValue,
                e.sessionId ?? "",
                e.application ?? "",
                e.payload,
            ].map(Self.csvEscape)
            rows.append(fields.joined(separator: ","))
        }
        return Data(rows.joined(separator: "\n").utf8)
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
