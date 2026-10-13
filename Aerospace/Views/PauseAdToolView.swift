//
//  PauseAdToolView.swift
//  Aerospace
//
//  The Pause Ads tool: the generate/deploy form beside a tabbed panel
//  (source checks, hosted ads, request log), with a status bar for the
//  Logger server that serves the ads at /files/*.
//

import SwiftUI

struct PauseAdToolView: View {
    enum Panel: String, CaseIterable, Identifiable {
        case checks = "Checks"
        case hosted = "Hosted"
        case requests = "Requests"

        var id: String { rawValue }
    }

    @EnvironmentObject private var store: PauseAdStore
    @State private var panel: Panel = .checks

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                PauseAdFormView()
                    .frame(minWidth: 380, idealWidth: 420)
                VStack(spacing: 0) {
                    Picker("Panel", selection: $panel) {
                        ForEach(Panel.allCases) { panel in
                            Text(title(for: panel)).tag(panel)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(10)
                    Divider()
                    switch panel {
                    case .checks: PauseAdInspectionView()
                    case .hosted: HostedPauseAdsView()
                    case .requests: PauseAdRequestsView()
                    }
                }
                .frame(minWidth: 420)
            }
            Divider()
            PauseAdStatusBar()
        }
        .onChange(of: store.lastGenerated?.hostedMetadataPath) { _, path in
            if path != nil { panel = .hosted }
        }
    }

    private func title(for panel: Panel) -> String {
        switch panel {
        case .checks:
            let count = store.inspection?.issues.count ?? 0
            return count > 0 ? "Checks (\(count))" : "Checks"
        case .hosted:
            return "Hosted (\(store.hostedAds.count))"
        case .requests:
            return store.fileRequests.isEmpty ? "Requests" : "Requests (\(store.fileRequests.count))"
        }
    }
}

/// Logger server state, which also gates pause ad hosting.
struct PauseAdStatusBar: View {
    @EnvironmentObject private var logStore: LogStore
    @EnvironmentObject private var store: PauseAdStore

    private var indicatorColor: Color {
        switch logStore.serverState {
        case .running: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 9, height: 9)
            if logStore.serverState.isRunning {
                Text("Serving at http://\(store.host.address()):\(String(logStore.port))/files/")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("Logger server \(logStore.serverState.description.lowercased()). Pause ads are not being served.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if store.destinationURL == nil {
                Text("No destination folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if logStore.serverState.isRunning {
                Button {
                    logStore.stopServer()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button {
                    logStore.startServer()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

#Preview {
    PauseAdToolView()
        .environmentObject(PauseAdStore())
        .environmentObject(LogStore())
        .frame(width: 1100, height: 700)
}
