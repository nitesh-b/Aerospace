//
//  OztamSettingsView.swift
//  Aerospace
//
//  The Oztam Log Settings tab: which OCS host to tail, the credentials used to
//  reach it (password kept in the Keychain), and the poll/backlog windows that
//  correspond to oztail's --frequency and --history flags.
//

import SwiftUI

struct OztamSettingsView: View {
    @EnvironmentObject private var store: OztamStore

    @State private var showClearConfirm = false

    var body: some View {
        Form {
            environmentSection
            credentialsSection
            pollingSection
            diagnosticsSection
            maintenanceSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    // MARK: - Environment

    private var environmentSection: some View {
        Section("Environment") {
            Picker("Tail host", selection: $store.environment) {
                ForEach(OztamEnvironment.allCases) { env in
                    Text(env.title).tag(env)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: store.environment) { _, _ in
                if store.tailState.isTailing { store.restartTailing() }
            }
            Text(store.environment.hostString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Credentials

    private var credentialsSection: some View {
        Section {
            TextField("User ID", text: $store.userId, prompt: Text("broadcaster"))
            SecureField("Password", text: $store.password)
            if !store.credentials.isComplete {
                Label("Both fields are needed before tailing can start.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("OzTAM Credentials")
        } footer: {
            Text("The password is stored in your macOS Keychain, never in the app's database. Ask the team for the shared oztail account if you do not have one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Polling

    private var pollingSection: some View {
        Section {
            Stepper(value: $store.pollSeconds, in: 1...300) {
                Text("Poll every \(store.pollSeconds) second\(store.pollSeconds == 1 ? "" : "s")")
            }
            Stepper(value: $store.historyMinutes,
                    in: OztamStore.historyRange,
                    step: 10) {
                Text("Fetch \(store.historyMinutes) minute\(store.historyMinutes == 1 ? "" : "s") of backlog on start")
            }
            if store.tailState.isTailing {
                Button("Restart Tail") { store.restartTailing() }
                    .help("Apply the backlog window immediately")
            }
        } header: {
            Text("Polling")
        } footer: {
            Text("The backlog window only applies when tailing starts. OzTAM accepts up to \(OztamStore.historyRange.upperBound) minutes (7 days).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Tail state") {
                Text(store.tailState.description).foregroundStyle(.secondary)
            }
            LabeledContent("Polls completed") {
                Text("\(store.pollCount)").monospacedDigit().foregroundStyle(.secondary)
            }
            if let lastPollAt = store.lastPollAt {
                LabeledContent("Last poll") {
                    Text(lastPollAt, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if store.diagnostics.isEmpty {
                Text(store.tailState.isTailing
                     ? "Waiting for the first poll to return."
                     : "No polls yet. Start tailing to see per-device results here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.diagnostics) { diagnostic in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: diagnostic.outcome.isFailure
                                  ? "xmark.octagon" : "checkmark.circle")
                                .foregroundStyle(diagnostic.outcome.isFailure ? Color.red : Color.green)
                            Text(diagnostic.deviceName).fontWeight(.medium)
                            Spacer()
                            Text("\(diagnostic.totalRows) rows")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(diagnostic.summary)
                            .font(.caption)
                            .foregroundStyle(diagnostic.outcome.isFailure ? Color.red : Color.secondary)
                        Text("Next fromDate: \(OztamClient.cursorFormatter.string(from: diagnostic.cursor))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        if let url = diagnostic.requestURL {
                            Text(url)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Request URLs carry no credentials, so they can be pasted into curl with -u to reproduce a poll by hand.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Maintenance

    private var maintenanceSection: some View {
        Section("Maintenance") {
            LabeledContent("Collected events") {
                Text("\(store.events.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Buffer limit") {
                Text("\(store.maxEvents)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("Clear Collected Events", systemImage: "trash")
            }
            .disabled(store.events.isEmpty)
            .confirmationDialog("Clear all collected events? Saved devices are kept.",
                                isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { store.clearEvents() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

#Preview {
    OztamSettingsView().environmentObject(OztamStore())
}
