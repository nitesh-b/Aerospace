//
//  DynamicConfigEditorView.swift
//  Aerospace
//
//  The Dynamic Config editor: sections, the selected section's entries with
//  a column per platform, and an inspector for the selected entries.
//

import SwiftUI
import AppKit

struct DynamicConfigEditorView: View {
    @EnvironmentObject private var store: DynamicConfigStore

    var body: some View {
        HSplitView {
            DynamicConfigSectionList()
                .frame(minWidth: 150, idealWidth: 200, maxWidth: 260, maxHeight: .infinity)
            Group {
                if let section = store.selectedSection {
                    DynamicConfigEntryTable(section: section)
                } else {
                    ContentUnavailableView("No Section Selected", systemImage: "list.bullet.rectangle")
                }
            }
            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            DynamicConfigInspector()
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
        }
    }
}

// MARK: - Sections

struct DynamicConfigSectionList: View {
    @EnvironmentObject private var store: DynamicConfigStore

    var body: some View {
        List(store.sections, selection: $store.selectedSectionKey) { section in
            VStack(alignment: .leading, spacing: 1) {
                Text(section.key)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(for: section))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help(section.key)
            .tag(section.key)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let config = store.config {
                let overrides = config.overrideCount
                Text("\(config.entryCount) entries · \(overrides) override\(overrides == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    private func subtitle(for section: DynamicConfig.Section) -> String {
        let count = section.entries.count
        var text = "\(count) entr\(count == 1 ? "y" : "ies")"
        if section.hasPlatformMaps {
            let overrides = section.overrideCount
            text += overrides == 0 ? " · per platform" : " · \(overrides) override\(overrides == 1 ? "" : "s")"
        }
        return text
    }
}

// MARK: - Entries

struct DynamicConfigEntryTable: View {
    let section: DynamicConfig.Section

    @EnvironmentObject private var store: DynamicConfigStore
    @State private var filter = ""
    @State private var overridesOnly = false
    @State private var addingEntry = false
    @State private var pendingDelete: Set<DynamicConfig.Entry.ID> = []

    /// Entries are members of the section object (not the section itself).
    private var isObjectSection: Bool { section.entries.first.map { $0.path.count == 2 } ?? true }

    private var rows: [DynamicConfig.Entry] {
        section.entries.filter { entry in
            (filter.isEmpty || entry.key.localizedCaseInsensitiveContains(filter))
                && (!overridesOnly || !entry.overrides.isEmpty)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Filter keys", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                if section.hasPlatformMaps {
                    Toggle("Overrides only", isOn: $overridesOnly)
                        .toggleStyle(.checkbox)
                }
                Spacer()
                Button {
                    addingEntry = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!isObjectSection)
                .help("Add an entry to \(section.key)")
                Button {
                    pendingDelete = store.selectedEntryIDs
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(!isObjectSection || store.selectedEntryIDs.isEmpty)
                .help("Delete the selected entries")
            }
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            Group {
                if section.hasPlatformMaps {
                    platformTable
                } else {
                    valueTable
                }
            }
            .contextMenu(forSelectionType: DynamicConfig.Entry.ID.self) { ids in
                contextMenu(for: ids)
            }
            .onDeleteCommand {
                if isObjectSection, !store.selectedEntryIDs.isEmpty { pendingDelete = store.selectedEntryIDs }
            }
        }
        .sheet(isPresented: $addingEntry) {
            DynamicConfigAddEntrySheet(section: section)
        }
        .confirmationDialog(deleteTitle, isPresented: deletePromptShown, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.removeEntries(pendingDelete)
                pendingDelete = []
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("Removes them from \(section.key). Revert discards this until you save.")
        }
    }

    private var platformTable: some View {
        Table(rows, selection: $store.selectedEntryIDs) {
            TableColumn("Key") { entry in
                keyCell(entry)
            }
            .width(min: 120, ideal: 180)
            TableColumnForEach(ConfigPlatform.allCases) { platform in
                TableColumn(platform.title) { entry in
                    DynamicConfigValueCell(entry: entry, platform: platform, isFlagSection: section.isFlagSection)
                }
                .width(min: 40, ideal: platform == .androidtv || platform == .androidtouch ? 100 : 64)
            }
        }
    }

    private var valueTable: some View {
        Table(rows, selection: $store.selectedEntryIDs) {
            TableColumn("Key") { entry in
                keyCell(entry)
            }
            .width(min: 140, ideal: 220)
            TableColumn("Value") { entry in
                Text(entry.value.summary)
                    .lineLimit(1)
                    .foregroundStyle(entry.value.isScalar ? .primary : .secondary)
                    .help(entry.value.compactText)
            }
        }
    }

    private func keyCell(_ entry: DynamicConfig.Entry) -> some View {
        Text(entry.key)
            .font(.body.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .help(entry.key)
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<DynamicConfig.Entry.ID>) -> some View {
        let entries = section.entries.filter { ids.contains($0.id) }
        if !entries.isEmpty {
            if section.hasPlatformMaps {
                Button("Clear Overrides") { store.clearOverrides(at: entries.map(\.path)) }
                    .disabled(entries.allSatisfy { $0.overrides.isEmpty })
            }
            Button(entries.count == 1 ? "Copy Key" : "Copy Keys") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entries.map(\.key).joined(separator: "\n"), forType: .string)
            }
            if isObjectSection {
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = ids }
            }
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete this entry?" : "Delete \(pendingDelete.count) entries?"
    }

    private var deletePromptShown: Binding<Bool> {
        Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
    }
}

/// One platform's value in the entries table. Values a platform inherits
/// from All are faded; overrides are tinted.
struct DynamicConfigValueCell: View {
    let entry: DynamicConfig.Entry
    let platform: ConfigPlatform
    let isFlagSection: Bool

    var body: some View {
        let cell = entry.cell(for: platform)
        if let value = cell.value {
            if isFlagSection, value == .number("1") || value == .number("0") {
                let on = value == .number("1")
                Image(systemName: on ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(on ? Color.green : Color.red)
                    .opacity(cell.isOwn ? 1 : 0.3)
                    .frame(maxWidth: .infinity)
                    .help(help(value: value, isOwn: cell.isOwn))
            } else {
                Text(value.summary)
                    .font(.body.monospaced())
                    .fontWeight(cell.isOwn && platform != .all ? .semibold : .regular)
                    .foregroundStyle(cell.isOwn ? (platform == .all ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                                     : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .help(help(value: value, isOwn: cell.isOwn))
            }
        } else {
            Text("–")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .help("\(platform.title) has no value")
        }
    }

    private func help(value: JSONValue, isOwn: Bool) -> String {
        let text = value.compactText
        if platform == .all || !entry.isPlatformMap { return "All: \(text)" }
        return isOwn ? "\(platform.title) override: \(text)" : "\(platform.title) uses All: \(text)"
    }
}

// MARK: - Add entry

struct DynamicConfigAddEntrySheet: View {
    let section: DynamicConfig.Section

    @EnvironmentObject private var store: DynamicConfigStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to \(section.key)")
                .font(.headline)
            TextField("Key", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit(add)
            Text("Starts as \(DynamicConfig.newEntryValue(in: section).compactText). Set its values in the inspector.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedKey.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func add() {
        do {
            try store.addEntry(trimmedKey)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
