//
//  DynamicConfig.swift
//  Aerospace
//
//  The uap dynamic configuration (e.g. `dynamic_config_2026_10_23.json`):
//  top-level sections such as `tealiumEventPermissionMap` holding entries
//  whose values are either plain JSON or platform maps,
//
//      { all?: T; roku?: T; tvos?: T; androidtv?: T; firetv?: T;
//        ios?: T; androidtouch?: T; xbox?: T; vegatv?: T }
//
//  where a platform without its own value reads `all`.
//

import Foundation

nonisolated enum ConfigPlatform: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case roku
    case tvos
    case androidtv
    case firetv
    case ios
    case androidtouch
    case xbox
    case vegatv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .roku: return "Roku"
        case .tvos: return "tvOS"
        case .androidtv: return "Android TV"
        case .firetv: return "Fire TV"
        case .ios: return "iOS"
        case .androidtouch: return "Android Touch"
        case .xbox: return "Xbox"
        case .vegatv: return "Vega TV"
        }
    }

    /// Every platform except `all`.
    static let specific: [ConfigPlatform] = allCases.filter { $0 != .all }
}

nonisolated extension JSONValue {
    /// A non-empty object keyed only by platform names.
    var isPlatformMap: Bool {
        guard let members, !members.isEmpty else { return false }
        return members.allSatisfy { ConfigPlatform(rawValue: $0.key) != nil }
    }

    /// The value a platform reads from a platform map: its own, else `all`.
    func resolved(for platform: ConfigPlatform) -> JSONValue? {
        self[platform.rawValue] ?? self[ConfigPlatform.all.rawValue]
    }
}

nonisolated struct DynamicConfig: Hashable, Sendable {

    enum ConfigError: LocalizedError, Equatable {
        case rootNotObject
        case emptyKey
        case duplicateKey(String)

        var errorDescription: String? {
            switch self {
            case .rootNotObject: return "The dynamic config must be a JSON object."
            case .emptyKey: return "Enter a key."
            case .duplicateKey(let key): return "\"\(key)\" already exists."
            }
        }
    }

    /// How an entry's values are edited.
    enum ValueStyle: Hashable, Sendable {
        /// `0` / `1` numbers, as in the permission maps.
        case flag
        case bool
        case number
        case string
        /// Objects, arrays and null.
        case json
    }

    /// A top-level key.
    struct Section: Identifiable, Hashable, Sendable {
        let key: String
        let entries: [Entry]
        /// Every leaf value in the section is `0` or `1`.
        let isFlagSection: Bool

        var id: String { key }
        var hasPlatformMaps: Bool { entries.contains(where: \.isPlatformMap) }
        var overrideCount: Int { entries.reduce(0) { $0 + $1.overrides.count } }
    }

    /// An editable value: a member of a section object, or the section
    /// itself when its value isn't an object of entries.
    struct Entry: Identifiable, Hashable, Sendable {
        let path: [String]
        let value: JSONValue

        var id: String { Self.id(for: path) }
        var key: String { path.last ?? "" }
        var isPlatformMap: Bool { value.isPlatformMap }

        static func id(for path: [String]) -> String { path.joined(separator: "\u{1F}") }

        /// Platforms other than `all` with their own value.
        var overrides: [ConfigPlatform] {
            guard isPlatformMap else { return [] }
            return ConfigPlatform.specific.filter { value[$0.rawValue] != nil }
        }

        /// What `platform` reads, and whether the value is its own. A plain
        /// value counts as `all`'s own.
        func cell(for platform: ConfigPlatform) -> (value: JSONValue?, isOwn: Bool) {
            guard isPlatformMap else { return (value, platform == .all) }
            if let own = value[platform.rawValue] { return (own, true) }
            return (value[ConfigPlatform.all.rawValue], false)
        }

        /// The value that sets an entry's style: `all`, else the first defined.
        var referenceValue: JSONValue {
            guard isPlatformMap, let members = value.members else { return value }
            return value[ConfigPlatform.all.rawValue] ?? members[0].value
        }
    }

    private(set) var root: JSONValue

    init(root: JSONValue) throws {
        guard root.members != nil else { throw ConfigError.rootNotObject }
        self.root = root
    }

    init(text: String) throws {
        try self.init(root: JSONValue(parsing: text))
    }

    init(data: Data) throws {
        try self.init(root: JSONValue(data: data))
    }

    // MARK: - Text

    /// The file layout: platform maps of scalars and short arrays of scalars
    /// on one line, e.g. `"app_launch": { "all": 1 }`.
    var text: String { Self.format(root) }

    static func format(_ value: JSONValue) -> String {
        value.formatted { value in
            switch value {
            case .object(let members):
                return value.isPlatformMap && members.allSatisfy(\.value.isScalar) && value.compactText.count <= 120
            case .array(let elements):
                return elements.allSatisfy(\.isScalar) && value.compactText.count <= 100
            default:
                return false
            }
        }
    }

    // MARK: - Structure

    var sections: [Section] {
        (root.members ?? []).map { member in
            let entries: [Entry]
            if let children = member.value.members, !member.value.isPlatformMap {
                entries = children.map { Entry(path: [member.key, $0.key], value: $0.value) }
            } else {
                entries = [Entry(path: [member.key], value: member.value)]
            }
            return Section(key: member.key, entries: entries, isFlagSection: Self.isFlagSection(entries))
        }
    }

    func section(_ key: String) -> Section? {
        sections.first { $0.key == key }
    }

    func entry(at path: [String]) -> Entry? {
        root.value(at: path).map { Entry(path: path, value: $0) }
    }

    var entryCount: Int { sections.reduce(0) { $0 + $1.entries.count } }
    var overrideCount: Int { sections.reduce(0) { $0 + $1.overrideCount } }

    /// Entries where `platform` has a value of its own.
    func overrideCount(for platform: ConfigPlatform) -> Int {
        sections.reduce(0) { total, section in
            total + section.entries.filter { $0.overrides.contains(platform) }.count
        }
    }

    static func style(for value: JSONValue, inFlagSection isFlagSection: Bool) -> ValueStyle {
        switch value {
        case .number(let literal): return isFlagSection && (literal == "0" || literal == "1") ? .flag : .number
        case .bool: return .bool
        case .string: return .string
        case .object, .array, .null: return .json
        }
    }

    private static func isFlagSection(_ entries: [Entry]) -> Bool {
        guard entries.count >= 2 else { return false }
        let leaves = entries.flatMap { entry in
            entry.isPlatformMap ? (entry.value.members ?? []).map(\.value) : [entry.value]
        }
        return leaves.allSatisfy { $0 == .number("0") || $0 == .number("1") }
    }

    // MARK: - Editing

    mutating func setValue(_ value: JSONValue, at path: [String]) {
        root.setValue(value, at: path)
    }

    /// Sets or removes (`nil`) one platform's value, keeping platforms in
    /// `ConfigPlatform` order. The last remaining value can't be removed.
    mutating func setPlatformValue(_ value: JSONValue?, for platform: ConfigPlatform, at path: [String]) {
        guard let map = root.value(at: path), map.isPlatformMap, var members = map.members else { return }
        if let index = members.firstIndex(where: { $0.key == platform.rawValue }) {
            if let value {
                members[index].value = value
            } else if members.count > 1 {
                members.remove(at: index)
            }
        } else if let value {
            let order = ConfigPlatform.allCases.firstIndex(of: platform)!
            let insertAt = members.firstIndex { member in
                ConfigPlatform.allCases.firstIndex(of: ConfigPlatform(rawValue: member.key)!)! > order
            } ?? members.endIndex
            members.insert(JSONValue.Member(key: platform.rawValue, value: value), at: insertAt)
        }
        root.setValue(.object(members), at: path)
    }

    /// Removes every platform's own value, keeping `all`.
    mutating func clearOverrides(at path: [String]) {
        guard let map = root.value(at: path), map.isPlatformMap, map[ConfigPlatform.all.rawValue] != nil else { return }
        for platform in ConfigPlatform.specific {
            setPlatformValue(nil, for: platform, at: path)
        }
    }

    /// Appends `key` to an object section.
    mutating func addEntry(_ key: String, value: JSONValue, toSection sectionKey: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ConfigError.emptyKey }
        guard let section = root[sectionKey], section.members != nil, !section.isPlatformMap else { return }
        guard section[key] == nil else { throw ConfigError.duplicateKey(key) }
        root.setValue(value, at: [sectionKey, key])
    }

    mutating func removeEntry(at path: [String]) {
        root.setValue(nil, at: path)
    }

    /// The value for a new entry in `section`, shaped like its first entry:
    /// `{ "all": 1 }` in a permission map.
    static func newEntryValue(in section: Section) -> JSONValue {
        guard let first = section.entries.first else { return .string("") }
        let reference = first.referenceValue
        let blank = section.isFlagSection ? JSONValue.number("1") : reference.blankCopy
        return first.isPlatformMap ? .object([JSONValue.Member(key: ConfigPlatform.all.rawValue, value: blank)]) : blank
    }

    // MARK: - Resolution

    /// The config as `platform` reads it: every platform map replaced by its
    /// value for that platform (dropped when it has none).
    func resolved(for platform: ConfigPlatform) -> JSONValue {
        Self.resolve(root, for: platform) ?? .object([])
    }

    private static func resolve(_ value: JSONValue, for platform: ConfigPlatform) -> JSONValue? {
        if value.isPlatformMap { return value.resolved(for: platform) }
        switch value {
        case .object(let members):
            return .object(members.compactMap { member in
                resolve(member.value, for: platform).map { JSONValue.Member(key: member.key, value: $0) }
            })
        case .array(let elements):
            return .array(elements.compactMap { resolve($0, for: platform) })
        case .string, .number, .bool, .null:
            return value
        }
    }
}
