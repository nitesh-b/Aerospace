//
//  JSONValue.swift
//  Aerospace
//
//  An order-preserving JSON tree for hand-maintained config files. Object
//  keys keep their file order and numbers keep their literal text, so a file
//  opened and saved without edits keeps its layout (JSONSerialization loses
//  both). Includes a small parser and an indented writer.
//

import Foundation

nonisolated enum JSONValue: Hashable, Sendable {
    case object([Member])
    case array([JSONValue])
    case string(String)
    /// The literal as written, e.g. `2500`, `0.5`, `1e3`.
    case number(String)
    case bool(Bool)
    case null

    struct Member: Hashable, Sendable {
        var key: String
        var value: JSONValue
    }

    // MARK: - Access

    var members: [Member]? {
        if case .object(let members) = self { return members }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        members?.first { $0.key == key }?.value
    }

    var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    var numberLiteral: String? {
        if case .number(let literal) = self { return literal }
        return nil
    }

    /// One short line for lists: strings unquoted, objects as their keys.
    var summary: String {
        switch self {
        case .string(let string): return string.replacingOccurrences(of: "\n", with: " ")
        case .object(let members):
            let compact = compactText
            return compact.count <= 60 ? compact : "{ " + members.map(\.key).joined(separator: ", ") + " }"
        case .array(let elements):
            let compact = compactText
            return compact.count <= 60 ? compact : "[\(elements.count) items]"
        case .number, .bool, .null: return compactText
        }
    }

    var isScalar: Bool {
        switch self {
        case .object, .array: return false
        case .string, .number, .bool, .null: return true
        }
    }

    func value(at path: [String]) -> JSONValue? {
        guard let key = path.first else { return self }
        return self[key]?.value(at: Array(path.dropFirst()))
    }

    /// Replaces (or appends) `key`, keeping its position; `nil` removes it.
    /// No-op unless this is an object.
    mutating func set(_ value: JSONValue?, forKey key: String) {
        guard var members else { return }
        if let index = members.firstIndex(where: { $0.key == key }) {
            if let value { members[index].value = value } else { members.remove(at: index) }
        } else if let value {
            members.append(Member(key: key, value: value))
        }
        self = .object(members)
    }

    /// Sets the value at `path`; intermediate objects must already exist.
    mutating func setValue(_ value: JSONValue?, at path: [String]) {
        guard let key = path.first else {
            if let value { self = value }
            return
        }
        if path.count == 1 {
            set(value, forKey: key)
        } else if var child = self[key] {
            child.setValue(value, at: Array(path.dropFirst()))
            set(child, forKey: key)
        }
    }

    /// The same shape with emptied leaves: `""`, `0`, `false`, `[]`.
    var blankCopy: JSONValue {
        switch self {
        case .object(let members): return .object(members.map { Member(key: $0.key, value: $0.value.blankCopy) })
        case .array: return .array([])
        case .string: return .string("")
        case .number: return .number("0")
        case .bool: return .bool(false)
        case .null: return .null
        }
    }

    // MARK: - Numbers

    /// Whether `text` is a JSON number literal (no surrounding whitespace).
    static func isNumberLiteral(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var parser = JSONParser(bytes: bytes)
        guard (try? parser.parseNumber()) != nil else { return false }
        return parser.index == bytes.count
    }
}

// MARK: - Parsing

nonisolated extension JSONValue {
    struct ParseError: LocalizedError, Equatable, Sendable {
        let message: String
        let line: Int
        let column: Int

        var errorDescription: String? { "\(message) (line \(line), column \(column))" }
    }

    init(parsing text: String) throws {
        try self.init(data: Data(text.utf8))
    }

    init(data: Data) throws {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var parser = JSONParser(bytes: bytes)
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == bytes.count else { throw parser.error("Unexpected content after the JSON value") }
        self = value
    }
}

private nonisolated struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    func error(_ message: String) -> JSONValue.ParseError {
        var line = 1
        var column = 1
        for byte in bytes[..<min(index, bytes.count)] {
            if byte == UInt8(ascii: "\n") {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                column += 1
            }
        }
        return JSONValue.ParseError(message: message, line: line, column: column)
    }

    mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    mutating func parseValue() throws -> JSONValue {
        guard let byte = current else { throw error("Unexpected end of input") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("Unexpected character '\(Character(Unicode.Scalar(byte)))'")
        }
    }

    private mutating func expect(_ literal: String) throws {
        let start = index
        for expected in literal.utf8 {
            guard current == expected else {
                index = start
                throw error("Invalid literal, expected '\(literal)'")
            }
            index += 1
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        index += 1
        skipWhitespace()
        var members: [JSONValue.Member] = []
        var keys = Set<String>()
        if current == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else { throw error("Expected a quoted key") }
            let keyStart = index
            let key = try parseString()
            guard keys.insert(key).inserted else {
                index = keyStart
                throw error("Duplicate key \"\(key)\"")
            }
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { throw error("Expected ':' after key \"\(key)\"") }
            index += 1
            skipWhitespace()
            members.append(JSONValue.Member(key: key, value: try parseValue()))
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(members)
            default: throw error("Expected ',' or '}' in object")
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        index += 1
        skipWhitespace()
        var elements: [JSONValue] = []
        if current == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(elements)
            default: throw error("Expected ',' or ']' in array")
            }
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while true {
            guard let byte = current else { throw error("Unterminated string") }
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                guard let escape = current else { throw error("Unterminated string") }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"): buffer.append(contentsOf: try parseUnicodeEscape())
                default:
                    index -= 1
                    throw error("Invalid escape '\\\(Character(Unicode.Scalar(escape)))'")
                }
            case 0x00..<0x20:
                throw error("Unescaped control character in string")
            default:
                buffer.append(byte)
                index += 1
            }
        }
    }

    /// After `\u`: four hex digits, joining a UTF-16 surrogate pair if present.
    private mutating func parseUnicodeEscape() throws -> [UInt8] {
        let high = try parseHex4()
        var scalar = Unicode.Scalar(high)
        if (0xD800..<0xDC00).contains(high),
           current == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") {
            let start = index
            index += 2
            let low = try parseHex4()
            if (0xDC00..<0xE000).contains(low) {
                scalar = Unicode.Scalar(0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(low) - 0xDC00))
            } else {
                index = start
            }
        }
        return Array(String(Character(scalar ?? "\u{FFFD}")).utf8)
    }

    private mutating func parseHex4() throws -> UInt16 {
        guard index + 4 <= bytes.count,
              let value = UInt16(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
            throw error("Invalid \\u escape")
        }
        index += 4
        return value
    }

    /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
    mutating func parseNumber() throws -> String {
        let start = index
        func isDigit(_ byte: UInt8?) -> Bool { byte.map { (0x30...0x39).contains($0) } ?? false }
        func digits() throws {
            guard isDigit(current) else { throw error("Invalid number") }
            while isDigit(current) { index += 1 }
        }
        if current == UInt8(ascii: "-") { index += 1 }
        if current == UInt8(ascii: "0") {
            index += 1
        } else {
            try digits()
        }
        if current == UInt8(ascii: ".") {
            index += 1
            try digits()
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
            try digits()
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}

// MARK: - Writing

nonisolated extension JSONValue {
    /// Indented with two spaces, ending in a newline. Containers for which
    /// `inline` returns true are written on one line (see `compactText`).
    func formatted(inline: (JSONValue) -> Bool = { _ in false }) -> String {
        var out = ""
        write(to: &out, indent: 0, inline: inline)
        out += "\n"
        return out
    }

    /// One line: `{ "all": 1, "roku": 0 }`, `[1, 2]`.
    var compactText: String {
        switch self {
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            return "{ " + members.map { "\(Self.quoted($0.key)): \($0.value.compactText)" }.joined(separator: ", ") + " }"
        case .array(let elements):
            return "[" + elements.map(\.compactText).joined(separator: ", ") + "]"
        case .string(let string): return Self.quoted(string)
        case .number(let literal): return literal
        case .bool(let bool): return bool ? "true" : "false"
        case .null: return "null"
        }
    }

    private func write(to out: inout String, indent: Int, inline: (JSONValue) -> Bool) {
        if isScalar || inline(self) {
            out += compactText
            return
        }
        let pad = String(repeating: "  ", count: indent + 1)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (offset, member) in members.enumerated() {
                out += pad + Self.quoted(member.key) + ": "
                member.value.write(to: &out, indent: indent + 1, inline: inline)
                out += offset < members.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: "  ", count: indent) + "}"
        case .array(let elements):
            guard !elements.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (offset, element) in elements.enumerated() {
                out += pad
                element.write(to: &out, indent: indent + 1, inline: inline)
                out += offset < elements.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: "  ", count: indent) + "]"
        case .string, .number, .bool, .null:
            break
        }
    }

    static func quoted(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
