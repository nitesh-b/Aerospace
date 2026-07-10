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
        case n10 = "N10"
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
        case .n10:
            return store.editing.n10SigningEnabled ? "N10 •" : "N10"
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
        case .n10:
            n10Editor
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

    private var n10Editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Sign requests with N10 HMAC", isOn: $store.editing.n10SigningEnabled)
                .toggleStyle(.switch)

            if store.editing.n10SigningEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").font(.caption).foregroundStyle(.secondary)
                    SecureField("Hex-encoded N10 API key", text: $store.n10APIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Label("Stored in the Keychain · shared across all requests · never sent",
                          systemImage: "key.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Divider()

                Text("Device identity").font(.caption).foregroundStyle(.secondary)
                HStack {
                    labeledField("App Version", text: $store.editing.n10AppVersion)
                    labeledField("System Name", text: $store.editing.n10SystemName)
                    labeledField("System Version", text: $store.editing.n10SystemVersion)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Headers added at send time").font(.caption).foregroundStyle(.secondary)
                    headerPreview("User-Agent", userAgentPreview)
                    if isAppleTVPreview {
                        headerPreview("X-Network-Ten-App", userAgentPreview)
                    } else {
                        Text("X-Network-Ten-App: only sent when System Name is \"tvOS\"")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let signature = signatureHeaderPreview {
                        headerPreview(signature.name, signature.value)
                    } else {
                        Text("No signature header for \(store.editing.method.rawValue) requests")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            } else {
                Text("When on, a method-dependent signature (X-N10-SIG for GET, "
                     + "X-Network-Ten-Auth for POST) and the 10play identity headers "
                     + "are added automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var userAgentPreview: String {
        N10Signer().userAgent(deviceInfoPreview)
    }

    private var deviceInfoPreview: N10Signer.DeviceInfo {
        .init(appVersion: store.editing.n10AppVersion,
              systemName: store.editing.n10SystemName,
              systemVersion: store.editing.n10SystemVersion)
    }

    private var isAppleTVPreview: Bool {
        N10Signer.isAppleTV(deviceInfoPreview)
    }

    private var signatureHeaderPreview: (name: String, value: String)? {
        switch store.editing.method {
        case .get:
            return ("X-N10-SIG", "<unixSeconds>_<hmacSHA256(\"ts:finalURL\")>")
        case .post:
            return ("X-Network-Ten-Auth", "base64(\"yyyyMMddHHmmss\" UTC)")
        case .put, .patch, .delete:
            return nil
        }
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func headerPreview(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(name + ":").font(.caption2.monospaced().weight(.medium))
            Text(value).font(.caption2.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
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
