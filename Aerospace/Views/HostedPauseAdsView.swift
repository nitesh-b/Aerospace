//
//  HostedPauseAdsView.swift
//  Aerospace
//
//  The Hosted panel (every generated ad under the destination, with copyable
//  metadata URLs and a parameters.js pauseAdRotation snippet for the
//  selection) and the Requests panel (what devices fetched from /files/*).
//

import SwiftUI
import AppKit

struct HostedPauseAdsView: View {
    @EnvironmentObject private var store: PauseAdStore
    @EnvironmentObject private var logStore: LogStore
    @State private var selection = Set<String>()
    @State private var filter = ""

    private var filteredAds: [HostedPauseAd] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.hostedAds }
        return store.hostedAds.filter {
            $0.metadataPath.lowercased().contains(query)
                || $0.metadata.adBrandName.lowercased().contains(query)
                || $0.metadata.adCampaign.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Host", selection: $store.host) {
                    ForEach(PauseAdHost.allCases) { host in
                        Text(host == .lan ? "LAN IP (\(host.address()))" : host.label).tag(host)
                    }
                }
                .frame(maxWidth: 300)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button {
                    store.refreshHostedAds()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan the destination folder")
                .accessibilityLabel("Rescan")
            }
            .padding(10)
            Divider()

            if store.hostedAds.isEmpty {
                ContentUnavailableView("No Hosted Pause Ads", systemImage: "play.rectangle",
                                       description: Text(store.destinationURL == nil
                                                         ? "Choose a destination folder."
                                                         : "Generated pause ads in the destination appear here."))
            } else {
                List(filteredAds, selection: $selection) { ad in
                    row(ad).tag(ad.id)
                        .contextMenu { menu(for: ad) }
                }
            }

            Divider()
            snippetBar
        }
    }

    // MARK: - Rows

    private func row(_ ad: HostedPauseAd) -> some View {
        let url = store.hostedURL(for: ad, port: logStore.port)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(ad.metadata.adBrandName.isEmpty ? ad.job.folderName : ad.metadata.adBrandName)
                    .font(.headline)
                Text(ad.metadata.adCampaign)
                    .foregroundStyle(.secondary)
                Spacer()
                if ad.id == store.lastGenerated?.hostedMetadataPath {
                    Text("Just generated")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.2), in: Capsule())
                }
                Text(ad.modified, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    copy(url)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy metadata URL")
                .accessibilityLabel("Copy metadata URL")
            }
            Text("\(ad.job.adType.label) · \(ad.job.year) · \(ad.job.monthFolder) · \(ad.job.ticket) · v\(ad.version) · \(ad.metadata.duration.formatted())s\(ad.metadata.loop ? " · loop" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(url)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func menu(for ad: HostedPauseAd) -> some View {
        Button("Copy Metadata URL") { copy(store.hostedURL(for: ad, port: logStore.port)) }
        Button("Copy pauseAdRotation for This Ad") {
            copy(store.rotationSnippet(for: [ad.id], port: logStore.port))
        }
        if let root = store.destinationURL {
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(ad.metadataPath)])
            }
        }
    }

    // MARK: - Snippet

    private var snippetBar: some View {
        HStack {
            Text(selection.isEmpty
                 ? "Select ads (⌘-click for several) to build a pauseAdRotation."
                 : "\(selection.count) selected · rotates in list order")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy pauseAdRotation") {
                copy(store.rotationSnippet(for: selection, port: logStore.port))
            }
            .disabled(selection.isEmpty)
        }
        .padding(10)
        .background(.bar)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Every /files/* request the Logger server answered, newest first.
struct PauseAdRequestsView: View {
    @EnvironmentObject private var store: PauseAdStore

    var body: some View {
        VStack(spacing: 0) {
            if store.fileRequests.isEmpty {
                ContentUnavailableView("No Requests Yet", systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("Requests from uap.rn / youi.rn for hosted pause ads show up here. A 404 usually means the URL in parameters.js is wrong."))
            } else {
                Table(store.fileRequests) {
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
                    .width(110)
                    TableColumn("Path") { request in
                        Text(request.path.replacingOccurrences(of: "/files/", with: "", options: .anchored))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(request.path)
                    }
                    TableColumn("Size") { request in
                        Text(request.bytes > 0 ? PauseAdInspector.formatBytes(request.bytes) : "–")
                            .monospacedDigit()
                    }
                    .width(70)
                }
            }
            Divider()
            HStack {
                let failures = store.fileRequests.filter { $0.status != 200 }.count
                Text(failures > 0 ? "\(failures) failed request\(failures == 1 ? "" : "s")" : "All requests succeeded")
                    .font(.caption)
                    .foregroundStyle(failures > 0 ? .red : .secondary)
                Spacer()
                Button("Clear") { store.clearFileRequests() }
                    .disabled(store.fileRequests.isEmpty)
            }
            .padding(10)
            .background(.bar)
        }
    }
}

extension PauseAdFileRequest: Identifiable {
    var id: String { "\(date.timeIntervalSinceReferenceDate)-\(path)-\(client)" }
}
