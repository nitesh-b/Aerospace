//
//  DynamicConfigInspector.swift
//  Aerospace
//
//  Edits the selected Dynamic Config entries: one entry's value per
//  platform, or a platform's value across several entries at once.
//

import SwiftUI

struct DynamicConfigInspector: View {
    @EnvironmentObject private var store: DynamicConfigStore

    var body: some View {
        let entries = store.selectedEntries
        if let section = store.selectedSection, !entries.isEmpty {
            if entries.count == 1 {
                DynamicConfigEntryInspector(entry: entries[0], section: section)
                    .id(entries[0].id)
            } else {
                DynamicConfigBulkInspector(entries: entries, section: section)
            }
        } else {
            ContentUnavailableView("No Entry Selected", systemImage: "slider.horizontal.3",
                                   description: Text("Select an entry to set its value for all platforms or override it for one."))
        }
    }
}

// MARK: - One entry

struct DynamicConfigEntryInspector: View {
    let entry: DynamicConfig.Entry
    let section: DynamicConfig.Section

    @EnvironmentObject private var store: DynamicConfigStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Key") {
                    Text(entry.key)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Path") {
                    Text(entry.path.joined(separator: "."))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if entry.isPlatformMap {
                Section {
                    ForEach(ConfigPlatform.allCases) { platform in
                        platformRow(platform)
                    }
                } header: {
                    Text("Platforms")
                } footer: {
                    Text("A platform without its own value uses All.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Clear Overrides") { store.clearOverrides(at: [entry.path]) }
                        .disabled(entry.overrides.isEmpty || entry.value[ConfigPlatform.all.rawValue] == nil)
                }
            } else {
                plainValueSection
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func platformRow(_ platform: ConfigPlatform) -> some View {
        let own = entry.value[platform.rawValue]
        LabeledContent {
            HStack(spacing: 6) {
                if let own {
                    DynamicConfigValueEditor(value: own, style: style(for: own)) { value in
                        store.setPlatformValue(value, for: platform, at: [entry.path])
                    }
                    Button {
                        store.setPlatformValue(nil, for: platform, at: [entry.path])
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled((entry.value.members?.count ?? 0) <= 1)
                    .help(platform == .all ? "Remove the All value" : "Remove the \(platform.title) override")
                } else {
                    Text(inheritedText(for: platform))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Button(platform == .all ? "Set" : "Override") {
                        let start = entry.value.resolved(for: platform) ?? entry.referenceValue.blankCopy
                        store.setPlatformValue(start, for: platform, at: [entry.path])
                    }
                    .controlSize(.small)
                }
            }
        } label: {
            Text(platform.title)
                .fontWeight(platform == .all ? .semibold : .regular)
        }
    }

    private func inheritedText(for platform: ConfigPlatform) -> String {
        guard platform != .all, let all = entry.value[ConfigPlatform.all.rawValue] else { return "Not set" }
        return "Uses All (\(display(all)))"
    }

    @ViewBuilder
    private var plainValueSection: some View {
        let value = entry.value
        if let members = value.members, !members.isEmpty, members.allSatisfy(\.value.isScalar) {
            Section("Value") {
                ForEach(members, id: \.key) { member in
                    LabeledContent(member.key) {
                        DynamicConfigValueEditor(value: member.value, style: style(for: member.value)) { newValue in
                            var updated = value
                            updated.set(newValue, forKey: member.key)
                            store.setValue(updated, at: entry.path)
                        }
                    }
                }
            }
        } else {
            Section("Value") {
                DynamicConfigValueEditor(value: value, style: style(for: value)) { newValue in
                    store.setValue(newValue, at: entry.path)
                }
            }
        }
    }

    private func style(for value: JSONValue) -> DynamicConfig.ValueStyle {
        DynamicConfig.style(for: value, inFlagSection: section.isFlagSection)
    }

    private func display(_ value: JSONValue) -> String {
        guard style(for: value) == .flag else { return value.summary }
        return value == .number("1") ? "on" : "off"
    }
}

// MARK: - Several entries

struct DynamicConfigBulkInspector: View {
    let entries: [DynamicConfig.Entry]
    let section: DynamicConfig.Section

    @EnvironmentObject private var store: DynamicConfigStore

    private var platformEntries: [DynamicConfig.Entry] { entries.filter(\.isPlatformMap) }

    var body: some View {
        Form {
            Section {
                Text("\(entries.count) entries selected")
                    .font(.headline)
                Text(entries.map(\.key).joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if !platformEntries.isEmpty {
                Section {
                    ForEach(ConfigPlatform.allCases) { platform in
                        platformRow(platform)
                    }
                } header: {
                    Text("Set for all selected")
                } footer: {
                    Text(section.isFlagSection
                         ? "On and Off give the platform its own value. Use All removes it so the platform reads All."
                         : "Use All removes the platform's own value so it reads All.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Clear Overrides") { store.clearOverrides(at: platformEntries.map(\.path)) }
                        .disabled(platformEntries.allSatisfy { $0.overrides.isEmpty })
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func platformRow(_ platform: ConfigPlatform) -> some View {
        let paths = platformEntries.map(\.path)
        let ownCount = platformEntries.filter { $0.value[platform.rawValue] != nil }.count
        LabeledContent {
            HStack(spacing: 8) {
                Text(summary(for: platform, ownCount: ownCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Menu("Set") {
                    if section.isFlagSection {
                        Button("On") { store.setPlatformValue(.number("1"), for: platform, at: paths) }
                        Button("Off") { store.setPlatformValue(.number("0"), for: platform, at: paths) }
                    }
                    if platform != .all {
                        if section.isFlagSection { Divider() }
                        Button("Use All") { store.setPlatformValue(nil, for: platform, at: paths) }
                            .disabled(ownCount == 0)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(platform == .all && !section.isFlagSection)
            }
        } label: {
            Text(platform.title)
                .fontWeight(platform == .all ? .semibold : .regular)
        }
    }

    private func summary(for platform: ConfigPlatform, ownCount: Int) -> String {
        if section.isFlagSection {
            let values = platformEntries.compactMap { $0.value.resolved(for: platform) }
            let on = values.filter { $0 == .number("1") }.count
            let off = values.filter { $0 == .number("0") }.count
            return "\(on) on · \(off) off"
        }
        return platform == .all ? "\(ownCount) set" : "\(ownCount) overridden"
    }
}

// MARK: - Value editors

/// Edits one JSON value in the style its section uses.
struct DynamicConfigValueEditor: View {
    let value: JSONValue
    let style: DynamicConfig.ValueStyle
    let onChange: (JSONValue) -> Void

    var body: some View {
        switch style {
        case .flag:
            Toggle("On", isOn: Binding(get: { value == .number("1") },
                                       set: { onChange(.number($0 ? "1" : "0")) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        case .bool:
            Toggle("Enabled", isOn: Binding(get: { value == .bool(true) }, set: { onChange(.bool($0)) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        case .number:
            NumberLiteralField(literal: value.numberLiteral ?? "") { onChange(.number($0)) }
        case .string:
            TextField("Value", text: Binding(get: { value.stringValue ?? "" }, set: { onChange(.string($0)) }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .lineLimit(1...8)
        case .json:
            JSONLiteralEditor(value: value, onCommit: onChange)
        }
    }
}

/// A number field that only commits valid JSON number literals.
private struct NumberLiteralField: View {
    let literal: String
    let onCommit: (String) -> Void

    @State private var text: String

    init(literal: String, onCommit: @escaping (String) -> Void) {
        self.literal = literal
        self.onCommit = onCommit
        _text = State(initialValue: literal)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    private var isValid: Bool { JSONValue.isNumberLiteral(trimmed) }

    var body: some View {
        TextField("Number", text: $text)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .font(.body.monospaced())
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 140)
            .overlay {
                if !isValid {
                    RoundedRectangle(cornerRadius: 5).stroke(.red)
                }
            }
            .help(isValid ? "" : "Not a valid number")
            .onChange(of: text) {
                if isValid, trimmed != literal { onCommit(trimmed) }
            }
            .onChange(of: literal) { _, new in
                if trimmed != new { text = new }
            }
    }
}

/// Objects, arrays and null as JSON text, applied on Apply.
private struct JSONLiteralEditor: View {
    let value: JSONValue
    let onCommit: (JSONValue) -> Void

    @State private var text: String
    @State private var error: String?

    init(value: JSONValue, onCommit: @escaping (JSONValue) -> Void) {
        self.value = value
        self.onCommit = onCommit
        _text = State(initialValue: Self.text(for: value))
    }

    private static func text(for value: JSONValue) -> String {
        DynamicConfig.format(value).trimmingCharacters(in: .newlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodeTextEditor(text: $text)
                .frame(minHeight: 100, idealHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Apply") {
                    do {
                        onCommit(try JSONValue(parsing: text))
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(text == Self.text(for: value))
            }
        }
        .onChange(of: value) { _, new in
            text = Self.text(for: new)
            error = nil
        }
    }
}
