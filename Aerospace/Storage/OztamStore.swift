//
//  OztamStore.swift
//  Aerospace
//
//  The observable application state for the Oztam Log tool: owns the saved
//  device list (SQLite), the tail loop that polls the OzTAM Collection Service
//  for every selected device concurrently, the merged in-memory event buffer,
//  and the display filters. Credentials live in the Keychain; the rest of the
//  settings live in UserDefaults.
//

import Foundation
import Combine

nonisolated enum OztamTailState: Equatable, Sendable {
    case idle
    case tailing
    case failed(String)

    var isTailing: Bool { self == .tailing }

    var description: String {
        switch self {
        case .idle: return "Not tailing"
        case .tailing: return "Tailing"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

@MainActor
final class OztamStore: ObservableObject {

    // MARK: - Published UI state

    @Published private(set) var devices: [OztamDevice] = []
    /// Merged events across all tailed devices, newest first.
    @Published private(set) var events: [OztamEvent] = []
    @Published private(set) var tailState: OztamTailState = .idle
    @Published private(set) var lastError: String?
    /// Event names seen so far this session, for the event-type filter.
    @Published private(set) var knownEventTypes: [String] = []

    // MARK: - Diagnostics

    /// Polls completed since tailing started.
    @Published private(set) var pollCount = 0
    @Published private(set) var lastPollAt: Date?
    /// Per-device result of the most recent poll, so an empty list is never
    /// ambiguous. Ordered to match `devices`.
    @Published private(set) var diagnostics: [OztamPollDiagnostic] = []

    // MARK: - Filters

    /// Severities to show. Empty means nothing matches.
    @Published var severityFilter: Set<OztamSeverity> = Set(OztamSeverity.allCases)
    /// Event names to show. Empty means no event-type restriction.
    @Published var eventTypeFilter: Set<String> = []
    @Published var searchText: String = ""
    /// Restricts the list to one device. nil means all tailed devices.
    @Published var deviceFilter: UUID?

    // MARK: - Persisted settings

    @Published var environment: OztamEnvironment {
        didSet { defaults.set(environment.rawValue, forKey: Keys.environment) }
    }
    @Published var userId: String {
        didSet { defaults.set(userId, forKey: Keys.userId) }
    }
    @Published var password: String {
        didSet { KeychainStore.save(password, account: Keys.passwordAccount) }
    }
    /// Seconds between polls, matching oztail's `--frequency`.
    @Published var pollSeconds: Int {
        didSet { defaults.set(pollSeconds, forKey: Keys.pollSeconds) }
    }
    /// Minutes of backlog fetched when tailing starts, matching `--history`.
    @Published var historyMinutes: Int {
        didSet { defaults.set(historyMinutes, forKey: Keys.historyMinutes) }
    }

    /// Upper bound on the in-memory event buffer.
    let maxEvents = 5_000
    /// The bounds oztail enforces on `--history`.
    static let historyRange = 0...10_080

    // MARK: - Dependencies

    private let store: SQLiteOztamDeviceStore
    private let client: OztamClient
    private let defaults: UserDefaults
    private var tailTask: Task<Void, Never>?
    /// Per-device `fromDate` cursor, advanced as events arrive.
    private var cursors: [UUID: Date] = [:]

    private enum Keys {
        static let environment = "oztam.environment"
        static let userId = "oztam.userId"
        static let pollSeconds = "oztam.pollSeconds"
        static let historyMinutes = "oztam.historyMinutes"
        static let passwordAccount = "oztam.password"
    }

    /// Isolated deinit on a @MainActor class trips the concurrency runtime;
    /// declaring it nonisolated keeps teardown on the releasing thread.
    nonisolated deinit {}

    // MARK: - Init

    init(store: SQLiteOztamDeviceStore? = nil,
         client: OztamClient = OztamClient(),
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.client = client
        self.environment = OztamEnvironment(
            rawValue: defaults.string(forKey: Keys.environment) ?? ""
        ) ?? .staging
        self.userId = defaults.string(forKey: Keys.userId) ?? ""
        self.password = KeychainStore.read(account: Keys.passwordAccount) ?? ""
        self.pollSeconds = defaults.object(forKey: Keys.pollSeconds) as? Int ?? 5
        self.historyMinutes = defaults.object(forKey: Keys.historyMinutes) as? Int ?? 100
        self.store = store ?? Self.makeDefaultStore()
        refreshDevices()
    }

    private static func makeDefaultStore() -> SQLiteOztamDeviceStore {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Aerospace", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("oztam.sqlite").path
        do {
            return try SQLiteOztamDeviceStore(path: path)
        } catch {
            // Fall back to a temporary database so the tool still runs.
            let tmp = fm.temporaryDirectory.appendingPathComponent("aerospace-oztam.sqlite").path
            return (try? SQLiteOztamDeviceStore(path: tmp))
                ?? (try! SQLiteOztamDeviceStore(path: ":memory:"))
        }
    }

    // MARK: - Devices

    var selectedDevices: [OztamDevice] {
        devices.filter { $0.isSelected && $0.isUsable }
    }

    var credentials: OztamCredentials {
        OztamCredentials(userId: userId.trimmingCharacters(in: .whitespaces), password: password)
    }

    @discardableResult
    func addDevice(name: String, kind: OztamDeviceKind, value: String) -> OztamDevice {
        let device = OztamDevice(name: name, kind: kind, value: value)
        try? store.upsert(device)
        refreshDevices()
        return device
    }

    func update(_ device: OztamDevice) {
        try? store.upsert(device)
        refreshDevices()
    }

    func remove(_ device: OztamDevice) {
        try? store.delete(id: device.id)
        cursors[device.id] = nil
        if deviceFilter == device.id { deviceFilter = nil }
        refreshDevices()
    }

    func setSelected(_ isSelected: Bool, for device: OztamDevice) {
        var updated = device
        updated.isSelected = isSelected
        update(updated)
    }

    func setAllSelected(_ isSelected: Bool) {
        for device in devices where device.isSelected != isSelected {
            var updated = device
            updated.isSelected = isSelected
            try? store.upsert(updated)
        }
        refreshDevices()
    }

    func removeAllDevices() {
        stopTailing()
        store.deleteAll()
        cursors = [:]
        deviceFilter = nil
        refreshDevices()
    }

    private func refreshDevices() {
        devices = store.fetchAll()
    }

    // MARK: - Tailing

    /// Why tailing cannot start right now, or nil when it can.
    var tailBlocker: String? {
        if !credentials.isComplete { return "Add your OzTAM user ID and password in Settings." }
        if selectedDevices.isEmpty { return "Select at least one device to collect data from." }
        return nil
    }

    /// Starts tailing only when it can actually run, leaving `tailState`
    /// untouched otherwise. Used when the tool appears, so a configured setup
    /// begins collecting without the user hunting for the Start button, while
    /// an unconfigured one does not flash an error.
    func startTailingIfPossible() {
        guard tailTask == nil, tailBlocker == nil else { return }
        startTailing()
    }

    func startTailing() {
        guard tailTask == nil else { return }
        if let blocker = tailBlocker {
            tailState = .failed(blocker)
            lastError = blocker
            return
        }

        let start = Date().addingTimeInterval(-Double(historyMinutes) * 60)
        cursors = selectedDevices.reduce(into: [:]) { $0[$1.id] = start }
        tailState = .tailing
        lastError = nil
        pollCount = 0
        lastPollAt = nil
        diagnostics = []
        tailTask = Task { [weak self] in await self?.runTailLoop() }
    }

    func stopTailing() {
        tailTask?.cancel()
        tailTask = nil
        if tailState.isTailing { tailState = .idle }
    }

    func restartTailing() {
        stopTailing()
        startTailing()
    }

    private func runTailLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            let interval = max(1, pollSeconds)
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                break
            }
        }
        if tailState.isTailing { tailState = .idle }
        tailTask = nil
    }

    /// One poll across every currently selected device, run concurrently.
    /// Devices selected mid-tail join with a fresh backlog window.
    private func pollOnce() async {
        let targets = selectedDevices
        guard !targets.isEmpty else {
            let blocker = "Select at least one device to collect data from."
            tailState = .failed(blocker)
            lastError = blocker
            return
        }

        let credentials = self.credentials
        let host = environment.host
        let fallbackCursor = Date().addingTimeInterval(-Double(historyMinutes) * 60)
        let client = self.client

        var requests: [(device: OztamDevice, from: Date)] = []
        for device in targets {
            let from = cursors[device.id] ?? fallbackCursor
            cursors[device.id] = from
            requests.append((device, from))
        }

        let outcomes = await withTaskGroup(
            of: (UUID, Result<OztamFetchResult, Error>).self
        ) { group -> [(UUID, Result<OztamFetchResult, Error>)] in
            for request in requests {
                group.addTask {
                    do {
                        let result = try await client.fetchEvents(
                            host: host,
                            device: request.device,
                            fromDate: request.from,
                            credentials: credentials
                        )
                        return (request.device.id, .success(result))
                    } catch {
                        return (request.device.id, .failure(error))
                    }
                }
            }
            var collected: [(UUID, Result<OztamFetchResult, Error>)] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        guard !Task.isCancelled else { return }

        var batch: [OztamEvent] = []
        var failures: [String] = []
        let now = Date()
        for (deviceID, outcome) in outcomes {
            guard let device = targets.first(where: { $0.id == deviceID }) else { continue }
            let priorRows = diagnostics.first { $0.deviceID == deviceID }?.totalRows ?? 0
            let requestedFrom = requests.first { $0.device.id == deviceID }?.from

            switch outcome {
            case .success(let result):
                batch.append(contentsOf: result.events)
                // Mirror oztail: resume one second past the newest record so
                // the same events are not replayed on the next poll.
                if let latest = result.latestCreatedAt {
                    cursors[deviceID] = latest.addingTimeInterval(1)
                }
                record(device: device,
                       outcome: .answered(meterEvents: result.meterEventCount,
                                          rows: result.events.count),
                       totalRows: priorRows + result.events.count,
                       requestedFrom: requestedFrom, at: now)
            case .failure(let error):
                if error is CancellationError { continue }
                failures.append("\(device.displayName): \(error.localizedDescription)")
                record(device: device,
                       outcome: .failed(error.localizedDescription),
                       totalRows: priorRows,
                       requestedFrom: requestedFrom, at: now)
            }
        }

        ingest(batch)
        pollCount += 1
        lastPollAt = now

        if failures.isEmpty {
            lastError = nil
            if !tailState.isTailing && tailTask != nil { tailState = .tailing }
        } else {
            lastError = failures.joined(separator: "\n")
            // A total failure stops the tail; a partial one keeps going.
            if batch.isEmpty && failures.count == outcomes.count {
                tailState = .failed(failures[0])
            }
        }
    }

    /// Stores (or replaces) the diagnostic row for one device.
    private func record(device: OztamDevice,
                        outcome: OztamPollDiagnostic.Outcome,
                        totalRows: Int,
                        requestedFrom: Date?,
                        at timestamp: Date) {
        let nextCursor = cursors[device.id] ?? requestedFrom ?? timestamp
        let url = requestedFrom.flatMap {
            try? OztamClient.makeURL(host: environment.host, device: device, fromDate: $0)
        }
        let entry = OztamPollDiagnostic(
            deviceID: device.id,
            deviceName: device.displayName,
            outcome: outcome,
            polledAt: timestamp,
            totalRows: totalRows,
            cursor: nextCursor,
            requestURL: url?.absoluteString
        )
        if let index = diagnostics.firstIndex(where: { $0.deviceID == device.id }) {
            diagnostics[index] = entry
        } else {
            diagnostics.append(entry)
        }
    }

    private func ingest(_ batch: [OztamEvent]) {
        guard !batch.isEmpty else { return }
        let ordered = batch.sorted { $0.timestamp > $1.timestamp }
        events.insert(contentsOf: ordered, at: 0)
        if events.count > maxEvents { events.removeLast(events.count - maxEvents) }

        let newTypes = Set(batch.map(\.event)).subtracting(knownEventTypes).filter { !$0.isEmpty }
        if !newTypes.isEmpty {
            knownEventTypes = Set(knownEventTypes).union(newTypes).sorted()
        }
    }

    func clearEvents() {
        events = []
        knownEventTypes = []
        eventTypeFilter = []
    }

    // MARK: - Filtering

    /// `events` narrowed by the severity, event-type, device and text filters.
    var filteredEvents: [OztamEvent] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return events.filter {
            Self.matches($0, severities: severityFilter, eventTypes: eventTypeFilter,
                         device: deviceFilter, needle: needle)
        }
    }

    /// Whether one event survives the display filters. An empty `eventTypes`
    /// means no event-type restriction; a nil `device` means all devices;
    /// `needle` must already be trimmed and lowercased.
    nonisolated static func matches(
        _ event: OztamEvent,
        severities: Set<OztamSeverity>,
        eventTypes: Set<String>,
        device: UUID?,
        needle: String
    ) -> Bool {
        guard severities.contains(event.severity) else { return false }
        if !eventTypes.isEmpty && !eventTypes.contains(event.event) { return false }
        if let device, event.deviceID != device { return false }
        if !needle.isEmpty && !event.searchHaystack.contains(needle) { return false }
        return true
    }

    var hasActiveFilters: Bool {
        severityFilter != Set(OztamSeverity.allCases)
            || !eventTypeFilter.isEmpty
            || deviceFilter != nil
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func resetFilters() {
        severityFilter = Set(OztamSeverity.allCases)
        eventTypeFilter = []
        deviceFilter = nil
        searchText = ""
    }

    func toggle(_ severity: OztamSeverity) {
        if severityFilter.contains(severity) {
            severityFilter.remove(severity)
        } else {
            severityFilter.insert(severity)
        }
    }

    func toggleEventType(_ type: String) {
        if eventTypeFilter.contains(type) {
            eventTypeFilter.remove(type)
        } else {
            eventTypeFilter.insert(type)
        }
    }
}
