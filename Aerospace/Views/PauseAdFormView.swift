//
//  PauseAdFormView.swift
//  Aerospace
//
//  The Pause Ads form: source and destination folders, job (type, folder,
//  job code), metadata, and the Generate / Deploy actions.
//

import SwiftUI
import AppKit

struct PauseAdFormView: View {
    @EnvironmentObject private var store: PauseAdStore

    var body: some View {
        Form {
            foldersSection
            jobSection
            metadataSection
            derivedSection
            actionsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Pause Ads")
        .confirmationDialog(versionPromptTitle, isPresented: versionPromptShown, titleVisibility: .visible,
                            presenting: store.versionPrompt) { prompt in
            Button("Overwrite v\(prompt.latest)", role: .destructive) {
                Task { await store.resolveVersionPrompt(.overwriteLatest, prompt: prompt) }
            }
            Button("Create v\(prompt.next)") {
                Task { await store.resolveVersionPrompt(.createNext, prompt: prompt) }
            }
            Button("Cancel", role: .cancel) {
                Task { await store.resolveVersionPrompt(.cancel, prompt: prompt) }
            }
        } message: { prompt in
            Text("\(prompt.job.relativePath) already has v\(prompt.latest). Overwriting replaces its server/, metadata.json and RemoteManifest.")
        }
    }

    // MARK: - Folders

    private var foldersSection: some View {
        Section {
            folderRow(title: "Source", systemImage: "tray.and.arrow.down",
                      url: store.sourceURL, placeholder: "Designer hand-off folder (AEP, data.json, images/, assets/)",
                      choose: { chooseFolder(prompt: "Choose Source", canCreate: false, apply: store.setSource) })
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, url.hasDirectoryPath else { return false }
                    store.setSource(url)
                    return true
                }
            folderRow(title: "Destination", systemImage: "externaldrive",
                      url: store.destinationURL, placeholder: "youi.ads repository (or any folder)",
                      choose: { chooseFolder(prompt: "Choose Destination", canCreate: true, apply: store.setDestination) })
        } header: {
            Text("Folders")
        } footer: {
            if store.sourceURL != nil {
                Button("Re-check Source") { store.reinspect() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func folderRow(title: String, systemImage: String, url: URL?, placeholder: String,
                           choose: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(url?.lastPathComponent ?? "Not chosen")
                        .foregroundStyle(url == nil ? .secondary : .primary)
                    Text(url?.path ?? placeholder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url?.path ?? placeholder)
                }
                Button("Choose…", action: choose)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func chooseFolder(prompt: String, canCreate: Bool, apply: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            apply(url)
        }
    }

    // MARK: - Job

    private var folderNameBinding: Binding<String> {
        Binding(get: { store.folderName }, set: { store.setFolderName($0) })
    }

    private var jobSection: some View {
        Section {
            Picker("Type", selection: $store.adType) {
                ForEach(PauseAdType.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(store.existingJob != nil)
            TextField("Folder name", text: folderNameBinding, prompt: Text("e.g. specsavers"))
                .disabled(store.existingJob != nil)
            TextField("Job code", text: $store.jobCode, prompt: Text("e.g. P-19583"))
        } header: {
            Text("Job")
        } footer: {
            jobFooter
        }
    }

    @ViewBuilder
    private var jobFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let path = store.jobPreviewPath {
                Text(path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else if let error = store.jobError, !store.jobCode.isEmpty || !store.folderName.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if store.existingJob != nil {
                Label("Existing job: " + store.existingVersions.map { "v\($0)" }.joined(separator: ", ")
                      + ". Type and folder come from its location.", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if store.existingJobLocations.count > 1 {
                Label("This job code exists in \(store.existingJobLocations.count) places; using the most recently edited.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        Section {
            TextField("Brand name", text: $store.metadata.adBrandName, prompt: Text("Required to deploy"))
            TextField("Campaign", text: $store.metadata.adCampaign, prompt: Text("Required to deploy"))
            TextField("Industry", text: $store.metadata.adIndustry, prompt: Text("Required to deploy"))
            TextField("Up-next modifier time", value: $store.metadata.upNextModifierTime,
                      format: .number.precision(.fractionLength(0...3)))
        } header: {
            Text("Metadata")
        } footer: {
            let normalized = store.metadata.normalizedForManifest()
            if !store.metadata.adBrandName.isEmpty || !store.metadata.adCampaign.isEmpty || !store.metadata.adIndustry.isEmpty {
                Text("Shipped as: \(normalized.adBrandName) · \(normalized.adCampaign) · \(normalized.adIndustry)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var derivedSection: some View {
        Section {
            TextField("Target", text: $store.metadata.target)
            TextField("Lottie target", text: $store.metadata.lottieTarget)
            TextField("Duration (s)", value: $store.metadata.duration,
                      format: .number.precision(.fractionLength(0...8)))
            Toggle("Loop", isOn: $store.metadata.loop)
            Toggle("Swap in smaller youi images", isOn: $store.applyImageSwaps)
        } header: {
            Text("From the AE export")
        } footer: {
            differencesFooter
        }
    }

    @ViewBuilder
    private var differencesFooter: some View {
        let differences = store.metadataDifferences
        if !differences.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label("Differs from the existing metadata.json:", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                ForEach(differences, id: \.self) { difference in
                    Text("\(difference.field.label): \(difference.existing) → \(difference.derived)")
                        .font(.caption.monospaced())
                }
            }
            .font(.caption)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            HStack {
                Button("Generate Pause Ad", systemImage: "wand.and.stars") {
                    Task { await store.generate() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.canGenerate)

                Button("Deploy", systemImage: "shippingbox.and.arrow.backward") {
                    Task { await store.deploy() }
                }
                .disabled(!store.deployBlockers.isEmpty || store.isWorking)
                .help(store.deployBlockers.isEmpty ? "Zip the RemoteManifest into deployments/"
                      : "Needs: " + store.deployBlockers.joined(separator: ", "))

                if store.isWorking {
                    ProgressView().controlSize(.small)
                }
            }

            if !store.deployBlockers.isEmpty, store.existingJob != nil {
                Text("Deploy needs: " + store.deployBlockers.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            statusView

            if let deployment = store.lastDeployment {
                HStack {
                    Text(deployment.zipURL.lastPathComponent)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([deployment.zipURL])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch store.status {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .textSelection(.enabled)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .textSelection(.enabled)
        case nil:
            EmptyView()
        }
    }

    // MARK: - Version prompt

    private var versionPromptShown: Binding<Bool> {
        Binding(get: { store.versionPrompt != nil },
                set: { shown in if !shown { store.versionPrompt = nil } })
    }

    private var versionPromptTitle: String {
        guard let prompt = store.versionPrompt else { return "" }
        return "\(prompt.job.ticket) already exists"
    }
}

#Preview {
    PauseAdFormView()
        .environmentObject(PauseAdStore())
        .frame(width: 440, height: 800)
}
