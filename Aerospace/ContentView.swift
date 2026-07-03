//
//  ContentView.swift
//  Aerospace
//
//  Root view: a three-tab interface (Logs, Statistics, Settings) with a
//  persistent server-status bar along the bottom.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LogStore

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                LogsView()
                    .tabItem { Label("Logs", systemImage: "doc.text") }

                StatisticsView()
                    .tabItem { Label("Stats", systemImage: "chart.bar") }

                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }

            Divider()
            ServerStatusBar()
        }
    }
}

/// A compact status bar showing the server state, port, and total log count.
struct ServerStatusBar: View {
    @EnvironmentObject private var store: LogStore

    private var indicatorColor: Color {
        switch store.serverState {
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
            Text(store.serverState.description)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Label("\(store.totalStored)", systemImage: "tray.full")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Total logs stored")

            if store.serverState.isRunning {
                Button {
                    store.stopServer()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button {
                    store.startServer()
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
    ContentView().environmentObject(LogStore())
}
