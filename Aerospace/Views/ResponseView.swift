//
//  ResponseView.swift
//  Aerospace
//
//  Shows the outcome of the last sent request: a status pill, timing/size,
//  and a Body / Headers switcher. JSON bodies are rendered via ResponseTextView
//  using JSONHighlighter.
//

import SwiftUI

struct ResponseView: View {
    let response: APIResponse?
    let isSending: Bool

    @EnvironmentObject private var store: APITesterStore
    @State private var showFind = false

    private enum Pane: String, CaseIterable, Identifiable {
        case body = "Body"
        case headers = "Headers"
        var id: String { rawValue }
    }
    @State private var pane: Pane = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if isSending {
                ProgressView().controlSize(.small)
                Text("Sending…").foregroundStyle(.secondary)
            } else if let response {
                statusPill(response)
                if let code = response.statusCode {
                    Text(HTTPURLResponse.localizedString(forStatusCode: code).capitalized)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(response.durationText, systemImage: "clock")
                    .foregroundStyle(.secondary)
                Label(byteText(response.bodyByteCount), systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text("No response yet")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusPill(_ response: APIResponse) -> some View {
        Text(response.statusLine)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(statusColor(response), in: Capsule())
    }

    private func statusColor(_ response: APIResponse) -> Color {
        switch response.outcome {
        case .failure: return .red
        case .cancelled: return .secondary
        case .success:
            switch response.statusCode ?? 0 {
            case 200..<300: return .green
            case 300..<400: return .blue
            case 400..<500: return .orange
            default: return .red
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let response {
            switch response.outcome {
            case .failure(let detail):
                messageView(icon: "exclamationmark.triangle", tint: .red,
                            title: "Request failed", detail: detail)
            case .cancelled:
                messageView(icon: "xmark.circle", tint: .secondary,
                            title: "Request cancelled", detail: "The request was replaced or stopped.")
            case .success:
                VStack(spacing: 0) {
                    Picker("", selection: $pane) {
                        ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)
                    Divider()
                    switch pane {
                    case .body: bodyView(response)
                    case .headers: headersView(response)
                    }
                }
            }
        } else {
            ContentUnavailableView("Send a Request",
                                   systemImage: "paperplane",
                                   description: Text("The response will appear here."))
        }
    }

    @ViewBuilder
    private func bodyView(_ response: APIResponse) -> some View {
        if response.bodyText.isEmpty {
            Text("Empty body")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                // Hidden button carries the Cmd+S shortcut; active only while the
                // body pane is visible so it does not shadow a global Save.
                Button("") { showFind = true }
                    .keyboardShortcut("s", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)

                ResponseTextView(
                    text: response.bodyText,
                    isJSON: response.isBodyJSON,
                    onOpenLink: { url in store.openEphemeralGet(url: url) },
                    showFindBarSignal: $showFind
                )
            }
        }
    }

    private func headersView(_ response: APIResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(response.headers) { pair in
                    HStack(alignment: .top, spacing: 10) {
                        Text(pair.name)
                            .font(.callout.weight(.medium))
                            .frame(width: 180, alignment: .leading)
                        Text(pair.value)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
            .padding(12)
        }
    }

    private func messageView(icon: String, tint: Color, title: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon).foregroundStyle(tint)
        } description: {
            Text(detail).textSelection(.enabled)
        }
    }

    private func byteText(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }
}

#Preview {
    ResponseView(
        response: APIResponse(outcome: .success, statusCode: 200,
                              headers: [HeaderPair(name: "Content-Type", value: "application/json")],
                              bodyText: "{\"ok\":true}", bodyByteCount: 11,
                              duration: .milliseconds(245), isBodyJSON: true),
        isSending: false
    )
    .environmentObject(APITesterStore())
    .frame(width: 480, height: 360)
}
