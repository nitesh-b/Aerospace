//
//  JsonViewer.swift
//  Aerospace
//
//  Renders a JSON string as pretty-printed, lightly syntax-highlighted,
//  monospaced text with a copy button.
//

import SwiftUI
import AppKit

/// Shared JSON pretty-printing + lightweight key/value highlighting, usable
/// from both the SwiftUI JsonViewer and the AppKit-backed ResponseTextView.
enum JSONHighlighter {
    static func pretty(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: out, encoding: .utf8)
        else { return json }
        return string
    }

    static func attributed(_ json: String, font: NSFont, textColor: NSColor) -> NSAttributedString {
        let text = pretty(json)
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        let ns = text as NSString
        var searchStart = 0
        while searchStart < ns.length {
            let openRange = ns.range(of: "\"", range: NSRange(location: searchStart, length: ns.length - searchStart))
            if openRange.location == NSNotFound { break }
            let afterOpen = openRange.location + openRange.length
            let closeRange = ns.range(of: "\"", range: NSRange(location: afterOpen, length: ns.length - afterOpen))
            if closeRange.location == NSNotFound { break }
            let strRange = NSRange(location: openRange.location,
                                   length: closeRange.location + closeRange.length - openRange.location)
            // Look at the next non-whitespace char after the closing quote.
            var i = closeRange.location + closeRange.length
            while i < ns.length, let scalar = Unicode.Scalar(ns.character(at: i)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) { i += 1 }
            let isKey = i < ns.length && ns.character(at: i) == unichar(UInt8(ascii: ":"))
            result.addAttribute(.foregroundColor,
                                value: isKey ? NSColor.controlAccentColor : NSColor.systemGreen,
                                range: strRange)
            searchStart = closeRange.location + closeRange.length
        }
        return result
    }
}

struct JsonViewer: View {
    let json: String
    var title: String = "Payload"

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button {
                    copyToPasteboard()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(highlighted)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var pretty: String { JSONHighlighter.pretty(json) }

    /// Very lightweight highlighting: colour JSON keys and string values.
    private var highlighted: AttributedString {
        var result = AttributedString(pretty)
        result.foregroundColor = .primary

        // Highlight "..." runs; a run immediately followed by ':' is a key.
        let text = pretty
        var searchStart = text.startIndex
        while let open = text.range(of: "\"", range: searchStart..<text.endIndex),
              let close = text.range(of: "\"", range: open.upperBound..<text.endIndex) {
            let stringRange = open.lowerBound..<close.upperBound
            let after = close.upperBound
            let isKey = text[after...].first(where: { !$0.isWhitespace }) == ":"
            if let attrRange = Range(stringRange, in: result) {
                result[attrRange].foregroundColor = isKey ? .accentColor : .green
            }
            searchStart = close.upperBound
        }
        return result
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pretty, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

#Preview {
    JsonViewer(json: "{\"userId\":123,\"status\":\"success\",\"token\":\"xyz\"}")
        .frame(width: 400, height: 300)
}
