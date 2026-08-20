//
//  SettingsView.swift
//  Aerospace
//
//  The Settings tab: server port, log retention / auto-purge, data export,
//  and destructive maintenance actions.
//

import SwiftUI
import UniformTypeIdentifiers
import Darwin

struct SettingsView: View {
    @EnvironmentObject private var store: LogStore

    @State private var portText = ""
    @State private var showClearConfirm = false
    @State private var exportMessage: String?
    @State private var useLANAddress = false

    var body: some View {
        Form {
            serverSection
            retentionSection
            exportSection
            dangerSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { portText = String(store.port) }
    }

    // MARK: - Server

    private var serverSection: some View {
        Section("Server") {
            HStack {
                Text("Port")
                Spacer()
                TextField("57333", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(applyPort)
                Button("Apply", action: applyPort)
                    .disabled(parsedPort == nil || parsedPort == store.port)
            }
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(store.serverState.isRunning ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(store.serverState.description).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(store.serverState.isRunning ? "Stop Server" : "Start Server") {
                    store.serverState.isRunning ? store.stopServer() : store.startServer()
                }
                Button("Restart") { store.restartServer() }
            }
            Toggle("Use LAN IP address", isOn: $useLANAddress)
            Text("Send logs with: POST http://\(displayHost):\(store.port)/log")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var displayHost: String {
        guard useLANAddress else { return "localhost" }
        return Self.lanIPAddress() ?? "localhost"
    }

    /// First non-loopback IPv4 address on an active interface (e.g. en0), for
    /// reaching this Mac's server from another device on the same network.
    private static func lanIPAddress() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                      &host, socklen_t(host.count),
                                      nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }

    private var parsedPort: UInt16? {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(value) else { return nil }
        return UInt16(value)
    }

    private func applyPort() {
        guard let port = parsedPort else {
            portText = String(store.port)
            return
        }
        store.port = port
        store.restartServer()
    }

    // MARK: - Retention

    private var retentionSection: some View {
        Section("Retention") {
            Toggle("Automatically purge old logs", isOn: $store.autoPurgeEnabled)
                .onChange(of: store.autoPurgeEnabled) { _, _ in store.purgeIfNeeded() }
            Stepper(value: $store.retentionDays, in: 1...365) {
                Text("Keep logs for \(store.retentionDays) day\(store.retentionDays == 1 ? "" : "s")")
            }
            .disabled(!store.autoPurgeEnabled)
            if store.autoPurgeEnabled {
                Button("Purge Now") { store.purgeIfNeeded(); store.refreshLogs() }
            }
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        Section("Export") {
            HStack {
                Button {
                    export(data: store.exportJSON(), suggestedName: "aerospace-logs.json", type: .json)
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                Button {
                    export(data: store.exportCSV(), suggestedName: "aerospace-logs.csv", type: .commaSeparatedText)
                } label: {
                    Label("Export CSV", systemImage: "tablecells")
                }
            }
            if let exportMessage {
                Text(exportMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func export(data: Data?, suggestedName: String, type: UTType) {
        guard let data else { exportMessage = "Nothing to export."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                exportMessage = "Exported to \(url.lastPathComponent)."
            } catch {
                exportMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Danger zone

    private var dangerSection: some View {
        Section("Maintenance") {
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("Delete All Logs", systemImage: "trash")
            }
            .confirmationDialog("Delete all stored logs? This cannot be undone.",
                                isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { store.clearAll() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

#Preview {
    SettingsView().environmentObject(LogStore())
}
