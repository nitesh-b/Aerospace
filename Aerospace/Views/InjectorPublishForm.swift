//
//  InjectorPublishForm.swift
//  Aerospace
//
//  The publish form: pick a built JS bundle file, tag it with its target
//  app/platform/channel/native-version range, and publish it as a new
//  release.
//

import SwiftUI
import UniformTypeIdentifiers

struct InjectorPublishForm: View {
    @EnvironmentObject private var store: InjectorStore

    @State private var bundleURL: URL?
    @State private var app = ""
    @State private var platform = "ios"
    @State private var channel = "staging"
    @State private var version = ""
    @State private var minNativeVersion = ""
    @State private var maxNativeVersion = ""

    var body: some View {
        Form {
            Section("Bundle") {
                Button {
                    chooseBundle()
                } label: {
                    Label(bundleURL?.lastPathComponent ?? "Choose Bundle File…",
                         systemImage: "doc.badge.plus")
                }
                if let bundleURL {
                    Text(bundleURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section("Target") {
                TextField("App", text: $app)
                Picker("Platform", selection: $platform) {
                    Text("iOS").tag("ios")
                    Text("Android").tag("android")
                }
                TextField("Channel", text: $channel)
                TextField("Version", text: $version)
                TextField("Min Native Version", text: $minNativeVersion)
                TextField("Max Native Version", text: $maxNativeVersion)
            }

            if let publishError = store.publishError {
                Text(publishError).font(.caption).foregroundStyle(.red)
            }

            Button("Publish") { publish() }
                .disabled(!canPublish)
        }
        .formStyle(.grouped)
        .navigationTitle("Publish")
    }

    private var canPublish: Bool {
        bundleURL != nil && !app.isEmpty && !channel.isEmpty && !version.isEmpty
            && !minNativeVersion.isEmpty && !maxNativeVersion.isEmpty
    }

    private func chooseBundle() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            bundleURL = url
        }
    }

    private func publish() {
        guard let bundleURL else { return }
        let published = store.publish(
            bundleURL: bundleURL, app: app, platform: platform, channel: channel, version: version,
            minNativeVersion: minNativeVersion, maxNativeVersion: maxNativeVersion)
        if published {
            self.bundleURL = nil
            version = ""
        }
    }
}

#Preview {
    InjectorPublishForm().environmentObject(InjectorStore())
}
