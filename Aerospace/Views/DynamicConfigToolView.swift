//
//  DynamicConfigToolView.swift
//  Aerospace
//
//  The Dynamic Config tool: open a dynamic config JSON, edit values for all
//  platforms or per platform (Editor), see the config as one platform reads
//  it (Preview), or edit the raw JSON (JSON). The bar along the bottom hosts
//  the config on the Logger server for devices to fetch.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DynamicConfigToolView: View {
    enum Panel: String, CaseIterable, Identifiable {
        case editor = "Editor"
        case preview = "Preview"
        case json = "JSON"

        var id: String { rawValue }
    }

    @EnvironmentObject private var store: DynamicConfigStore
    @State private var panel: Panel = .editor
    @State private var pendingOpen: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.config == nil {
                emptyState
            } else {
                Group {
                    switch panel {
                    case .editor: DynamicConfigEditorView()
                    case .preview: DynamicConfigPreviewView()
                    case .json: DynamicConfigJSONView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            DynamicConfigStatusBar()
        }
        .navigationTitle("Dynamic Config")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.pathExtension.lowercased() == "json" else { return false }
            requestOpen(url)
            return true
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: discardPromptShown,
                            titleVisibility: .visible, presenting: pendingOpen) { url in
            Button("Discard and Open", role: .destructive) { store.open(url) }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text("Your edits to \(store.fileName) haven't been saved. Opening \(url.lastPathComponent) discards them.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Panel", selection: $panel) {
                ForEach(Panel.allCases) { panel in
                    Text(panel.rawValue).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(store.config == nil)

            Spacer()

            if store.config != nil {
                fileLabel
            }

            Button(action: chooseFile) {
                Label("Open…", systemImage: "folder")
            }
            Button { store.revert() } label: {
                Label("Revert", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.canRevert)
            .help("Discard unsaved edits")
            Button(action: saveAs) {
                Label("Save As…", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(store.config == nil)
            Button {
                store.fileURL == nil ? saveAs() : store.save()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(store.config == nil || (store.fileURL != nil && !store.isDirty))
        }
        .padding(10)
    }

    private var fileLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(store.fileURL == nil ? "Not saved" : store.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .help(store.fileURL?.path(percentEncoded: false) ?? "Save to choose a file")
            if store.isDirty {
                Text("Edited")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.2), in: Capsule())
            }
            if let fileURL = store.fileURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
        .font(.callout)
        .padding(.trailing, 6)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Dynamic Config", systemImage: "slider.horizontal.3")
        } description: {
            Text("Open a dynamic config JSON such as dynamic_config_2026_10_23.json, or drop one here. Set each value for all platforms, then override it for Roku, tvOS, Android TV, Fire TV, iOS, Android Touch, Xbox or Vega TV.")
        } actions: {
            Button("Open…", action: chooseFile)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var discardPromptShown: Binding<Bool> {
        Binding(get: { pendingOpen != nil }, set: { if !$0 { pendingOpen = nil } })
    }

    private func requestOpen(_ url: URL) {
        if store.isDirty {
            pendingOpen = url
        } else {
            store.open(url)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.directoryURL = store.fileURL?.deletingLastPathComponent()
        panel.prompt = "Open"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            requestOpen(url)
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = store.suggestedFileName
        panel.directoryURL = store.fileURL?.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.save(as: url)
        }
    }
}

// MARK: - Preview

/// The config with every platform map resolved for one platform.
struct DynamicConfigPreviewView: View {
    @EnvironmentObject private var store: DynamicConfigStore
    @State private var platform: ConfigPlatform = .all

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Platform", selection: $platform) {
                    ForEach(ConfigPlatform.allCases) { platform in
                        Text(platform.title).tag(platform)
                    }
                }
                .fixedSize()
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
            Divider()
            JsonViewer(json: resolvedText, title: "As \(platform.title) reads it", reformats: false)
        }
    }

    private var resolvedText: String {
        guard let config = store.config else { return "{}" }
        return DynamicConfig.format(config.resolved(for: platform))
    }

    private var summary: String {
        guard let config = store.config else { return "" }
        guard platform != .all else { return "Platform maps show their All value." }
        let count = config.overrideCount(for: platform)
        return count == 0 ? "No \(platform.title) overrides; every value comes from All."
            : "\(count) value\(count == 1 ? "" : "s") overridden for \(platform.title); the rest come from All."
    }
}

// MARK: - JSON

/// The whole document as text. Edits apply on Apply.
struct DynamicConfigJSONView: View {
    @EnvironmentObject private var store: DynamicConfigStore
    @State private var text = ""
    @State private var error: String?

    private var documentText: String { store.config?.text ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            CodeTextEditor(text: $text)
            Divider()
            HStack(spacing: 10) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if text != documentText {
                    Text("Edited. Apply to update the config.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Discard Edits") {
                    text = documentText
                    error = nil
                }
                .disabled(text == documentText)
                Button("Apply", action: apply)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text == documentText)
            }
            .padding(10)
        }
        .onAppear { text = documentText }
        .onChange(of: documentText) { _, new in
            text = new
            error = nil
        }
    }

    private func apply() {
        do {
            try store.replace(withText: text)
            text = documentText
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Hosting bar

/// Hosting on the Logger server, the request log, and the last file action.
struct DynamicConfigStatusBar: View {
    @EnvironmentObject private var store: DynamicConfigStore
    @EnvironmentObject private var logStore: LogStore
    @State private var showingRequests = false

    private var isServing: Bool {
        store.isHosting && store.config != nil && logStore.serverState.isRunning
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isServing ? Color.green : (store.isHosting && store.config != nil ? .orange : .secondary))
                .frame(width: 9, height: 9)
            hostingText
            Spacer(minLength: 8)
            statusText
            Toggle("Host", isOn: $store.isHosting)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Serve the open config at \(DynamicConfigHost.path) on the Logger server")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    @ViewBuilder
    private var hostingText: some View {
        if !store.isHosting {
            Text("Hosting is off.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if store.config == nil {
            Text("Open a config to host it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !logStore.serverState.isRunning {
            Text(serverProblem + " The config is not being served.")
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(logStore.serverState.description)
            Button {
                logStore.startServer()
            } label: {
                Label("Start", systemImage: "play.fill")
            }
        } else {
            let url = store.hostedURL(port: logStore.port)
            Text(url)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help("Serves the config as it is in the editor, unsaved edits included")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy URL")
            Picker("Host", selection: $store.urlHost) {
                ForEach(PauseAdHost.allCases) { host in
                    Text(host == .lan ? "LAN IP (\(host.address()))" : host.label).tag(host)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Address used in the URL")
            requestsButton
        }
    }

    private var serverProblem: String {
        switch logStore.serverState {
        case .failed(let message) where message.contains("Address already in use"):
            return "Port \(String(logStore.port)) is in use by another app. Quit it or change the port in Logger › Settings."
        case .failed(let message):
            return "Logger server failed: \(message)."
        case .starting:
            return "Logger server is starting."
        case .stopped, .running:
            return "Logger server is stopped."
        }
    }

    private var requestsButton: some View {
        Button {
            showingRequests = true
        } label: {
            if let last = store.requests.first {
                Text("Fetched \(last.date.formatted(date: .omitted, time: .standard)) by \(last.client)")
                    .font(.callout)
                    .foregroundStyle(last.status == 200 ? Color.secondary : Color.red)
                    .lineLimit(1)
            } else {
                Text("Not fetched yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .help("Show requests for the hosted config")
        .popover(isPresented: $showingRequests, arrowEdge: .top) {
            DynamicConfigRequestsView()
                .frame(width: 520, height: 320)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch store.status {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(message)
        case nil:
            EmptyView()
        }
    }
}

/// Requests for the hosted config, newest first.
struct DynamicConfigRequestsView: View {
    @EnvironmentObject private var store: DynamicConfigStore

    var body: some View {
        VStack(spacing: 0) {
            if store.requests.isEmpty {
                ContentUnavailableView("No Requests Yet", systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("Point the app's dynamic config URL at the hosted URL. Requests show up here."))
            } else {
                Table(store.requests) {
                    TableColumn("Time") { request in
                        Text(request.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                    }
                    .width(70)
                    TableColumn("Status") { request in
                        Text(String(request.status))
                            .monospacedDigit()
                            .foregroundStyle(request.status == 200 ? .green : .red)
                    }
                    .width(50)
                    TableColumn("Device") { request in
                        Text(request.client).monospaced()
                    }
                    .width(120)
                    TableColumn("Request") { request in
                        Text("\(request.method) \(request.path)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(request.path)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(store.requests.count) request\(store.requests.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { store.clearRequests() }
                    .disabled(store.requests.isEmpty)
            }
            .padding(8)
        }
    }
}

#Preview {
    DynamicConfigToolView()
        .environmentObject(DynamicConfigStore())
        .environmentObject(LogStore())
        .frame(width: 1100, height: 700)
}
