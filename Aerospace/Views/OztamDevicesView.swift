//
//  OztamDevicesView.swift
//  Aerospace
//
//  The Devices tab: the saved tail targets, each with a checkbox controlling
//  whether it is included when tailing starts, plus add/edit/delete.
//

import SwiftUI

struct OztamDevicesView: View {
    @EnvironmentObject private var store: OztamStore

    @State private var editorTarget: OztamDeviceEditorTarget?
    @State private var deletionTarget: OztamDevice?
    @State private var showDeleteAllConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            if store.devices.isEmpty {
                emptyState
            } else {
                deviceList
            }
            Divider()
            footer
        }
        .navigationTitle("Devices")
        .sheet(item: $editorTarget) { target in
            OztamDeviceEditor(target: target)
                .environmentObject(store)
        }
        .confirmationDialog(
            "Remove “\(deletionTarget?.displayName ?? "")”?",
            isPresented: Binding(get: { deletionTarget != nil },
                                 set: { if !$0 { deletionTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let deletionTarget { store.remove(deletionTarget) }
                deletionTarget = nil
            }
            Button("Cancel", role: .cancel) { deletionTarget = nil }
        }
        .confirmationDialog("Remove all saved devices? This cannot be undone.",
                            isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) { store.removeAllDevices() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - List

    private var deviceList: some View {
        List {
            Section {
                ForEach(store.devices) { device in
                    OztamDeviceRow(device: device) { isSelected in
                        store.setSelected(isSelected, for: device)
                    }
                    .contextMenu {
                        Button("Edit…") { editorTarget = .edit(device) }
                        Button("Remove", role: .destructive) { deletionTarget = device }
                    }
                    .onTapGesture(count: 2) { editorTarget = .edit(device) }
                }
            } header: {
                Text("Collect data from")
            } footer: {
                Text("Selected devices are polled every \(store.pollSeconds)s while tailing. Changes take effect on the next poll.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Devices", systemImage: "tv")
        } description: {
            Text("Add a tail target — an IP address, device ID, session ID or OzTAM device ID.")
        } actions: {
            Button("Add Device") { editorTarget = .create }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                editorTarget = .create
            } label: {
                Label("Add Device", systemImage: "plus")
            }

            if !store.devices.isEmpty {
                Button("Select All") { store.setAllSelected(true) }
                    .disabled(store.devices.allSatisfy(\.isSelected))
                Button("Select None") { store.setAllSelected(false) }
                    .disabled(store.devices.allSatisfy { !$0.isSelected })

                Spacer()

                Button(role: .destructive) {
                    showDeleteAllConfirm = true
                } label: {
                    Label("Remove All", systemImage: "trash")
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Row

private struct OztamDeviceRow: View {
    let device: OztamDevice
    let onSelectionChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { device.isSelected }, set: onSelectionChange))
                .labelsHidden()
                .help("Include this device when tailing")

            Image(systemName: device.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.displayName).fontWeight(.medium)
                    Text(device.kind.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                }
                HStack(spacing: 6) {
                    Text(device.trimmedValue.isEmpty ? "No identifier set" : device.trimmedValue)
                        .font(.caption.monospaced())
                        .foregroundStyle(device.isUsable ? Color.secondary : Color.red)
                    if device.kind == .ipAddress, OztamDevice.isIPAddress(device.trimmedValue) {
                        Text("md5 \(device.queryValue.prefix(12))…")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .help("Sent to OzTAM as \(device.queryValue)")
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .opacity(device.isSelected ? 1 : 0.55)
    }
}

// MARK: - Editor

enum OztamDeviceEditorTarget: Identifiable {
    case create
    case edit(OztamDevice)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let device): return device.id.uuidString
        }
    }
}

private struct OztamDeviceEditor: View {
    @EnvironmentObject private var store: OztamStore
    @Environment(\.dismiss) private var dismiss

    let target: OztamDeviceEditorTarget

    @State private var name = ""
    @State private var kind: OztamDeviceKind = .ipAddress
    @State private var value = ""
    @State private var isDetectingIP = false
    @State private var detectionError: String?

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing ? "Edit Device" : "Add Device")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            Form {
                TextField("Name", text: $name, prompt: Text("Lounge room TV"))

                Picker("Look up by", selection: $kind) {
                    ForEach(OztamDeviceKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }

                TextField(kind.title, text: $value, prompt: Text(kind.placeholder))
                    .font(.body.monospaced())

                if kind == .ipAddress {
                    HStack(spacing: 8) {
                        Button {
                            detectPublicIP()
                        } label: {
                            Label("Detect My Public IP", systemImage: "bolt")
                        }
                        .disabled(isDetectingIP)
                        if isDetectingIP {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text("IP addresses are MD5-hashed before they are sent to OzTAM, the same way oztail does it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let detectionError {
                    Text(detectionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private func load() {
        guard case .edit(let device) = target else { return }
        name = device.name
        kind = device.kind
        value = device.value
    }

    private func save() {
        switch target {
        case .create:
            store.addDevice(name: name, kind: kind, value: value)
        case .edit(let device):
            var updated = device
            updated.name = name
            updated.kind = kind
            updated.value = value
            store.update(updated)
        }
        dismiss()
    }

    /// Mirrors runoztail.sh's fallback: ask 10play for the caller's public IP.
    private func detectPublicIP() {
        isDetectingIP = true
        detectionError = nil
        Task {
            let detected = await PublicIPLookup.fetch()
            isDetectingIP = false
            if let detected {
                value = detected
            } else {
                detectionError = "Could not detect your public IP. Enter it manually."
            }
        }
    }
}

/// Resolves this machine's public IP via the same endpoint runoztail.sh uses.
nonisolated enum PublicIPLookup {
    static func fetch() async -> String? {
        guard let url = URL(string: "https://10play.com.au/whatismyip") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ip = object["ip"] as? String, !ip.isEmpty {
            return ip
        }
        // Tolerate a bare-text response.
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return OztamDevice.isIPAddress(text) ? text : nil
    }
}

#Preview {
    OztamDevicesView().environmentObject(OztamStore())
}
