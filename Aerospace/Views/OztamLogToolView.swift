//
//  OztamLogToolView.swift
//  Aerospace
//
//  The Oztam Log tool: a three-tab interface (Events, Devices, Settings) with
//  a persistent tail-status bar along the bottom. Presented in the detail area
//  of the top-level tool navigator.
//

import SwiftUI

struct OztamLogToolView: View {
    @EnvironmentObject private var store: OztamStore

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                OztamEventsView()
                    .tabItem { Label("Events", systemImage: "waveform.path.ecg") }

                OztamDevicesView()
                    .tabItem { Label("Devices", systemImage: "tv") }

                OztamSettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }

            Divider()
            OztamStatusBar()
        }
        .onAppear { store.startTailingIfPossible() }
    }
}

/// A compact status bar showing the tail state, environment, selected device
/// count, and the start/stop control.
struct OztamStatusBar: View {
    @EnvironmentObject private var store: OztamStore

    private var indicatorColor: Color {
        switch store.tailState {
        case .tailing: return .green
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private var pollHelp: String {
        guard let lastPollAt = store.lastPollAt else { return "No polls yet" }
        let elapsed = Int(Date().timeIntervalSince(lastPollAt))
        return "\(store.pollCount) polls · last \(elapsed)s ago"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 9, height: 9)
            Text(store.tailState.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(store.lastError ?? store.tailState.description)

            Text(store.environment.title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .help(store.environment.hostString)

            Spacer()

            Label("\(store.selectedDevices.count)", systemImage: "tv")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Devices selected for collection")

            Label("\(store.events.count)", systemImage: "tray.full")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Events collected this session")

            if store.pollCount > 0 {
                Label("\(store.pollCount)", systemImage: "arrow.clockwise")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(pollHelp)
            }

            if store.tailState.isTailing {
                Button {
                    store.stopTailing()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button {
                    store.startTailing()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(store.tailBlocker != nil)
                .help(store.tailBlocker ?? "Start tailing the selected devices")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

/// A selectable pill used by the Oztam Log filter bar.
struct OztamFilterChip: View {
    let title: String
    let isOn: Bool
    var systemImage: String?
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption2)
                }
                Text(title).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isOn ? tint : Color(nsColor: .controlBackgroundColor), in: Capsule())
            .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    OztamLogToolView().environmentObject(OztamStore())
}
