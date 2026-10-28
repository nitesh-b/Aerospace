//
//  JSONField.swift
//  Aerospace
//
//  Finds the `"key": value` member of a JSON document that a text selection
//  sits in, so a field picked in the response body can be saved as a
//  variable. Positions are UTF-16 offsets, matching NSTextView ranges.
//

import Foundation

nonisolated struct JSONField: Equatable, Sendable {
    let key: String
    /// String values unquoted and unescaped; anything else as compact JSON.
    let value: String

    /// The innermost member whose `"key": value` text contains the selection
    /// (ignoring surrounding whitespace and commas). A caret counts as a
    /// selection. Nil when the text isn't JSON or the selection isn't inside
    /// a single member.
    static func locate(in text: String, selection: NSRange) -> JSONField? {
        let units = Array(text.utf16)
        guard selection.location != NSNotFound, NSMaxRange(selection) <= units.count else { return nil }
        var scanner = Scanner(units: units)
        guard scanner.document() else { return nil }

        let target = trimmed(selection, in: units)
        let containing = scanner.members.filter {
            $0.span.location <= target.location && NSMaxRange(target) <= NSMaxRange($0.span)
        }
        guard let member = containing.min(by: { $0.span.length < $1.span.length }) else { return nil }
        return JSONField(key: member.key, value: member.value)
    }

    private static func trimmed(_ range: NSRange, in units: [UTF16.CodeUnit]) -> NSRange {
        let skip: Set<UTF16.CodeUnit> = [0x20, 0x09, 0x0A, 0x0D, 0x2C]   // space, tab, LF, CR, comma
        var start = range.location, end = NSMaxRange(range)
        while start < end, skip.contains(units[start]) { start += 1 }
        while end > start, skip.contains(units[end - 1]) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Scanning

    private struct Member {
        let key: String
        let value: String
        /// From the key's opening quote to the end of the value.
        let span: NSRange
    }

    /// A small recursive-descent pass that records every object member with
    /// its source span.
    private struct Scanner {
        let units: [UTF16.CodeUnit]
        var index = 0
        var members: [Member] = []

        init(units: [UTF16.CodeUnit]) { self.units = units }

        mutating func document() -> Bool {
            skipWhitespace()
            guard value() != nil else { return false }
            skipWhitespace()
            return index == units.count
        }

        /// Parses one value; returns its text for a variable.
        private mutating func value() -> String? {
            guard index < units.count else { return nil }
            let start = index
            switch units[index] {
            case 0x7B:  // {
                guard object() else { return nil }
            case 0x5B:  // [
                guard array() else { return nil }
            case 0x22:  // "
                return string()
            default:
                guard literal() else { return nil }
                return String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
            }
            return compact(units[start..<index])
        }

        private mutating func object() -> Bool {
            index += 1
            skipWhitespace()
            if consume(0x7D) { return true }
            while true {
                skipWhitespace()
                let keyStart = index
                guard index < units.count, units[index] == 0x22, let key = string() else { return false }
                skipWhitespace()
                guard consume(0x3A) else { return false }   // :
                skipWhitespace()
                guard let value = value() else { return false }
                members.append(Member(key: key, value: value,
                                      span: NSRange(location: keyStart, length: index - keyStart)))
                skipWhitespace()
                if consume(0x2C) { continue }
                return consume(0x7D)
            }
        }

        private mutating func array() -> Bool {
            index += 1
            skipWhitespace()
            if consume(0x5D) { return true }
            while true {
                skipWhitespace()
                guard value() != nil else { return false }
                skipWhitespace()
                if consume(0x2C) { continue }
                return consume(0x5D)
            }
        }

        /// A quoted string, unescaped. `index` is on the opening quote.
        private mutating func string() -> String? {
            let start = index
            var escaped = false
            index += 1
            while index < units.count {
                switch units[index] {
                case 0x22:
                    index += 1
                    guard escaped else {
                        return String(utf16CodeUnits: Array(units[(start + 1)..<(index - 1)]), count: index - start - 2)
                    }
                    let quoted = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
                    return try? JSONDecoder().decode(String.self, from: Data(quoted.utf8))
                case 0x5C:
                    escaped = true
                    index += 2
                default:
                    index += 1
                }
            }
            return nil
        }

        /// A number, true, false or null.
        private mutating func literal() -> Bool {
            let start = index
            while index < units.count, !Self.delimiters.contains(units[index]) { index += 1 }
            let text = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
            guard !text.isEmpty else { return false }
            return ["true", "false", "null"].contains(text) || Double(text) != nil
        }

        private static let delimiters: Set<UTF16.CodeUnit> = [0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D]

        private mutating func skipWhitespace() {
            while index < units.count, [0x20, 0x09, 0x0A, 0x0D].contains(units[index]) { index += 1 }
        }

        private mutating func consume(_ unit: UTF16.CodeUnit) -> Bool {
            guard index < units.count, units[index] == unit else { return false }
            index += 1
            return true
        }

        /// Source text with whitespace outside strings removed.
        private func compact(_ slice: ArraySlice<UTF16.CodeUnit>) -> String {
            var out: [UTF16.CodeUnit] = []
            var inString = false, escaped = false
            for unit in slice {
                if inString {
                    out.append(unit)
                    if escaped { escaped = false } else if unit == 0x5C { escaped = true } else if unit == 0x22 { inString = false }
                } else if unit == 0x22 {
                    inString = true
                    out.append(unit)
                } else if ![0x20, 0x09, 0x0A, 0x0D].contains(unit) {
                    out.append(unit)
                }
            }
            return String(utf16CodeUnits: out, count: out.count)
        }
    }
}
