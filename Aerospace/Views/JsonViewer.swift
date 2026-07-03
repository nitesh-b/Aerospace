//
//  JsonViewer.swift
//  Aerospace
//
//  Renders a JSON string as pretty-printed, lightly syntax-highlighted,
//  monospaced text with a copy button.
//

import SwiftUI

struct JsonViewer: View {
    let json: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Payload")
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

    private var pretty: String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: out, encoding: .utf8)
        else { return json }
        return string
    }

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
