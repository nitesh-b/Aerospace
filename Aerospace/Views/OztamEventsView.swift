//
//  OztamEventsView.swift
//  Aerospace
//
//  The Events tab: a filter bar, the merged event stream across every tailed
//  device (newest first, laid out in the same columns oztail prints), and a
//  detail pane with the full meter-event JSON.
//

import SwiftUI

struct OztamEventsView: View {
    @EnvironmentObject private var store: OztamStore

    @State private var selectedEventID: OztamEvent.ID?

    private var visibleEvents: [OztamEvent] { store.filteredEvents }

    var body: some View {
        NavigationSplitView {
            eventList
        } detail: {
            detailPane
        }
    }

    // MARK: - List

    private var eventList: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if let error = store.lastError {
                errorBanner(error)
                Divider()
            }
            if visibleEvents.isEmpty {
                emptyState
            } else {
                List(visibleEvents, selection: $selectedEventID) { event in
                    OztamEventRow(event: event).tag(event.id)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 460)
        .navigationTitle("Oztam Log")
        .navigationSplitViewColumnWidth(min: 460, ideal: 720)
        .searchable(text: $store.searchText, placement: .toolbar,
                    prompt: "Search session, media, publisher, errors, payload")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text("\(visibleEvents.count) of \(store.events.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Events matching the current filters")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    store.clearEvents()
                    selectedEventID = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(store.events.isEmpty)
                .help("Clear the collected events")
            }
        }
    }

    // MARK: - Filters

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(OztamSeverity.allCases) { severity in
                    OztamFilterChip(
                        title: severity.label,
                        isOn: store.severityFilter.contains(severity),
                        systemImage: severity.systemImage,
                        tint: severity.color
                    ) {
                        store.toggle(severity)
                    }
                }

                Divider().frame(height: 18)

                devicePicker
                eventTypePicker

                if store.hasActiveFilters {
                    Button("Reset") { store.resetFilters() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var devicePicker: some View {
        Picker("Device", selection: $store.deviceFilter) {
            Text("All Devices").tag(UUID?.none)
            ForEach(store.devices) { device in
                Text(device.displayName).tag(UUID?.some(device.id))
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 200)
    }

    private var eventTypePicker: some View {
        Menu {
            if store.knownEventTypes.isEmpty {
                Text("No event types seen yet")
            } else {
                Button("All Event Types") { store.eventTypeFilter = [] }
                Divider()
                ForEach(store.knownEventTypes, id: \.self) { type in
                    Toggle(type, isOn: Binding(
                        get: { store.eventTypeFilter.contains(type) },
                        set: { _ in store.toggleEventType(type) }
                    ))
                }
            }
        } label: {
            Label(eventTypeLabel, systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var eventTypeLabel: String {
        switch store.eventTypeFilter.count {
        case 0: return "All Event Types"
        case 1: return store.eventTypeFilter.first ?? "1 Event Type"
        default: return "\(store.eventTypeFilter.count) Event Types"
        }
    }

    // MARK: - Banners & empty state

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Events", systemImage: "waveform.path.ecg")
        } description: {
            if store.events.isEmpty {
                Text(emptyReason)
            } else {
                Text("No collected events match the current filters.")
            }
        } actions: {
            if !store.events.isEmpty && store.hasActiveFilters {
                Button("Reset Filters") { store.resetFilters() }
            }
            if store.events.isEmpty && !store.tailState.isTailing {
                Button("Start Tailing") { store.startTailing() }
                    .disabled(store.tailBlocker != nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Spells out why the list is empty, so a silent tail is never mistaken for
    /// a broken one.
    private var emptyReason: String {
        if let blocker = store.tailBlocker { return blocker }
        guard store.tailState.isTailing else {
            return "Not tailing yet. Press Start to poll the \(store.selectedDevices.count) selected device\(store.selectedDevices.count == 1 ? "" : "s")."
        }
        guard store.pollCount > 0 else {
            return "Tailing \(store.selectedDevices.count) device\(store.selectedDevices.count == 1 ? "" : "s"). Waiting for the first poll to return."
        }
        let plural = store.pollCount == 1 ? "poll" : "polls"
        return "\(store.pollCount) \(plural) completed, no events returned yet. OzTAM only records meter events while a device is playing video. See Settings › Diagnostics for the per-device result."
    }

    // MARK: - Detail

    private var detailPane: some View {
        Group {
            if let selectedEventID,
               let event = store.events.first(where: { $0.id == selectedEventID }) {
                OztamEventDetailView(event: event)
            } else {
                ContentUnavailableView("Select an Event",
                                       systemImage: "sidebar.right",
                                       description: Text("Choose a row to inspect the full meter event."))
            }
        }
        .frame(minWidth: 340)
    }
}

// MARK: - Row

private struct OztamEventRow: View {
    let event: OztamEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.severity.systemImage)
                .foregroundStyle(event.severity.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(event.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(event.event.isEmpty ? "—" : event.event)
                        .font(.caption.weight(.semibold).monospaced())
                    Text(event.deviceName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    if !event.vendorVersion.isEmpty {
                        Text(event.vendorVersion)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    positions
                }
                HStack(spacing: 8) {
                    if !event.mediaId.isEmpty {
                        field("media", event.mediaId)
                    }
                    if !event.publisherId.isEmpty {
                        field("publisher", event.publisherId)
                    }
                    if !event.sessionId.isEmpty {
                        field("session", event.sessionId)
                    }
                }
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(event.severity.color)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var positions: some View {
        HStack(spacing: 6) {
            Text(event.fromPositionText)
            Text("→").foregroundStyle(.tertiary)
            Text(event.toPositionText)
            if !event.durationText.isEmpty {
                Text("(\(event.durationText)s)").foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label + ":").foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption2)
    }
}

// MARK: - Detail view

private struct OztamEventDetailView: View {
    let event: OztamEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(event.severity.label, systemImage: event.severity.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(event.severity.color)
                    Spacer()
                    Text(event.timestamp, format: .dateTime.year().month().day()
                        .hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(event.event.isEmpty ? "—" : event.event)
                    .font(.title3.weight(.semibold).monospaced())

                if let detail = event.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(event.severity.color)
                        .textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    metaRow("Device", event.deviceName, systemImage: "tv")
                    metaRow("User agent", event.vendorVersion, systemImage: "app.badge")
                    metaRow("Session", event.sessionId, systemImage: "person.badge.key")
                    metaRow("Publisher", event.publisherId, systemImage: "building.2")
                    metaRow("Media", event.mediaId, systemImage: "film")
                    metaRow("Positions",
                            positionSummary,
                            systemImage: event.usesEpochPositions ? "clock" : "timeline.selection")
                    if let deviceId = event.propertiesDeviceId {
                        metaRow("properties.deviceId", deviceId, systemImage: "number")
                    }
                    if let demo1 = event.demo1 {
                        metaRow("properties.demo1", demo1, systemImage: "person.2")
                    }
                    metaRow("Recorded by OCS",
                            Self.absoluteFormatter.string(from: event.createdAt),
                            systemImage: "tray.and.arrow.down")
                }
            }
            .padding(16)

            Divider()
            JsonViewer(json: event.rawJSON)
        }
    }

    private var positionSummary: String {
        let unit = event.usesEpochPositions ? "epoch ms" : "seconds"
        let from = event.fromPositionText.isEmpty ? "—" : event.fromPositionText
        let to = event.toPositionText.isEmpty ? "—" : event.toPositionText
        let duration = event.durationText.isEmpty ? "" : "  ·  \(event.durationText)s"
        return "\(from) → \(to)  (\(unit))\(duration)"
    }

    @ViewBuilder
    private func metaRow(_ label: String, _ value: String, systemImage: String) -> some View {
        if !value.isEmpty {
            GridRow {
                HStack(spacing: 5) {
                    Image(systemName: systemImage).foregroundStyle(.tertiary)
                    Text(label + ":").foregroundStyle(.secondary)
                }
                Text(value).textSelection(.enabled)
            }
            .font(.caption)
        }
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

#Preview {
    OztamEventsView().environmentObject(OztamStore())
}
