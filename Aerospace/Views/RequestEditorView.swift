//
//  RequestEditorView.swift
//  Aerospace
//
//  The request builder: name, method, URL, and switchable editors for query
//  parameters, headers, authentication, and body — plus the Send control.
//

import SwiftUI

struct RequestEditorView: View {
    @EnvironmentObject private var store: APITesterStore

    private enum Section: String, CaseIterable, Identifiable {
        case params = "Params"
        case headers = "Headers"
        case auth = "Auth"
        case body = "Body"
        var id: String { rawValue }
    }
    @State private var section: Section = .params

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            nameRow
            urlRow
            sectionPicker
            Divider()
            ScrollView { sectionContent.padding(.top, 4) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Top rows

    private var nameRow: some View {
        TextField("Request name", text: $store.editing.name)
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
    }

    private var urlRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: $store.editing.method) {
                ForEach(HTTPMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            TextField("https://api.example.com/path", text: $store.editing.urlString)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { store.send() }

            if store.isSending {
                Button(role: .cancel) { store.cancelSend() } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
            } else {
                Button { store.send() } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.editing.urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var sectionPicker: some View {
        Picker("", selection: $section) {
            ForEach(Section.allCases) { section in
                Text(badge(for: section)).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// Section label with a count badge for params/headers.
    private func badge(for section: Section) -> String {
        switch section {
        case .params:
            let n = store.editing.queryParams.filter { !$0.key.isEmpty }.count
            return n > 0 ? "Params (\(n))" : "Params"
        case .headers:
            let n = store.editing.headers.filter { !$0.key.isEmpty }.count
            return n > 0 ? "Headers (\(n))" : "Headers"
        case .auth:
            return store.editing.authKind == .bearer ? "Auth •" : "Auth"
        case .body:
            return store.editing.bodyKind == .none ? "Body" : "Body •"
        }
    }

    // MARK: - Section content

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .params:
            KeyValueEditor(items: $store.editing.queryParams,
                           keyPlaceholder: "Parameter", valuePlaceholder: "Value")
        case .headers:
            KeyValueEditor(items: $store.editing.headers,
                           keyPlaceholder: "Header", valuePlaceholder: "Value")
        case .auth:
            authEditor
        case .body:
            bodyEditor
        }
    }

    private var authEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Type", selection: $store.editing.authKind) {
                ForEach(AuthKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)

            if store.editing.authKind == .bearer {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Token").font(.caption).foregroundStyle(.secondary)
                    TextField("Bearer token", text: $store.editing.bearerToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("Sent as: Authorization: Bearer …")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $store.editing.bodyKind) {
                    ForEach(BodyKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if store.editing.bodyKind == .json {
                    Button("Format") { formatJSONBody() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .disabled(store.editing.bodyText.isEmpty)
                }
                Spacer()
            }

            if store.editing.bodyKind == .none {
                Text("This request has no body.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if store.editing.method == .get {
                    Label("GET requests usually have no body.", systemImage: "info.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                TextEditor(text: $store.editing.bodyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
        }
    }

    /// Pretty-print the JSON body in place, if it's valid JSON.
    private func formatJSONBody() {
        guard let data = store.editing.bodyText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8)
        else { return }
        store.editing.bodyText = string
    }
}

#Preview {
    RequestEditorView()
        .environmentObject(APITesterStore())
        .frame(width: 560, height: 480)
}
