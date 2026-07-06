//
//  LogsView.swift
//  Aerospace
//
//  The Logs tab: category sidebar, a filtered/searchable log list, and a
//  detail pane with the pretty-printed JSON payload.
//

import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var store: LogStore

    @State private var selectedCategory: String?          // nil == All
    @State private var selectedSubCategory: String?       // nil == All
    @State private var minLevel: LogLevel?
    @State private var searchText = ""
    @State private var selectedLogID: LogEvent.ID?

    var body: some View {
        NavigationSplitView {
            categorySidebar
        } content: {
            logList
        } detail: {
            detailPane
        }
        .onChange(of: selectedCategory) { _, _ in
            selectedSubCategory = nil
            updateQuery()
        }
        .onChange(of: selectedSubCategory) { _, _ in updateQuery() }
        .onChange(of: minLevel) { _, _ in updateQuery() }
        .onChange(of: searchText) { _, _ in updateQuery() }
    }

    // MARK: - Sidebar

    private var categorySidebar: some View {
        List(selection: $selectedCategory) {
            Section("Categories") {
                Label("All Categories", systemImage: "square.stack.3d.up")
                    .tag(String?.none)
                ForEach(store.categories, id: \.self) { category in
                    Label(category, systemImage: "folder")
                        .tag(String?.some(category))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Aerospace")
        .frame(minWidth: 190)
    }

    // MARK: - Log list

    private var subCategories: [String] {
        guard let selectedCategory else { return [] }
        return store.subCategories(for: selectedCategory)
    }

    private var logList: some View {
        VStack(spacing: 0) {
            if selectedCategory != nil && !subCategories.isEmpty {
                subCategoryPicker
                Divider()
            }
            if store.logs.isEmpty {
                emptyState
            } else {
                List(store.logs, selection: $selectedLogID) { event in
                    LogRow(event: event).tag(event.id)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 340)
        .navigationTitle(selectedCategory ?? "All Categories")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search payloads")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Level", selection: $minLevel) {
                    Text("All Levels").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases) { level in
                        Text("≥ \(level.label)").tag(LogLevel?.some(level))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var subCategoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(title: "All", isOn: selectedSubCategory == nil) {
                    selectedSubCategory = nil
                }
                ForEach(subCategories, id: \.self) { sub in
                    FilterChip(title: sub, isOn: selectedSubCategory == sub) {
                        selectedSubCategory = (selectedSubCategory == sub) ? nil : sub
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Logs", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(store.serverState.isRunning
                 ? "Waiting for events. POST to /log to see logs here."
                 : "The server is not running. Start it from the status bar.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail

    private var detailPane: some View {
        Group {
            if let selectedLogID, let event = store.logs.first(where: { $0.id == selectedLogID }) {
                LogDetailView(event: event)
            } else {
                ContentUnavailableView("Select a Log",
                                       systemImage: "sidebar.right",
                                       description: Text("Choose an event to inspect its payload."))
            }
        }
        .frame(minWidth: 320)
    }

    // MARK: - Query wiring

    private func updateQuery() {
        var q = LogQuery()
        q.category = selectedCategory
        q.subCategory = selectedSubCategory
        q.minLevel = minLevel
        q.searchText = searchText.isEmpty ? nil : searchText
        store.query = q
    }
}

// MARK: - Row

private struct LogRow: View {
    let event: LogEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.level.systemImage)
                .foregroundStyle(event.level.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.category).fontWeight(.semibold)
                    Text("›").foregroundStyle(.tertiary)
                    Text(event.subCategory).foregroundStyle(.secondary)
                    if let component = event.component {
                        Label(component, systemImage: "macwindow")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    }
                    Spacer()
                    Text(event.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(event.payloadPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail view

private struct LogDetailView: View {
    let event: LogEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(event.level.label, systemImage: event.level.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(event.level.color)
                    Spacer()
                    Text(event.timestamp, format: .dateTime.year().month().day()
                        .hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("\(event.category)  ›  \(event.subCategory)")
                    .font(.title3.weight(.semibold))

                HStack(spacing: 16) {
                    if let component = event.component {
                        metaField("Component", component, systemImage: "macwindow")
                    }
                    if let app = event.application {
                        metaField("App", app, systemImage: "app.badge")
                    }
                    if let session = event.sessionId {
                        metaField("Session", session, systemImage: "person.badge.key")
                    }
                }
                metaField("ID", event.id.uuidString, systemImage: "number")
            }
            .padding(16)

            Divider()
            JsonViewer(json: event.payload)
        }
    }

    private func metaField(_ label: String, _ value: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).foregroundStyle(.tertiary)
            Text(label + ":").foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.caption)
    }
}

// MARK: - Filter chip

private struct FilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isOn ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                            in: Capsule())
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
