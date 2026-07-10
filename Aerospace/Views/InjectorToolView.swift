//
//  InjectorToolView.swift
//  Aerospace
//
//  The Injector tool: a publish form beside the release history, with a
//  persistent server-status bar along the bottom. Presented in the detail
//  area of the top-level tool navigator.
//

import SwiftUI

struct InjectorToolView: View {
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                InjectorPublishForm()
                    .frame(minWidth: 300, idealWidth: 340)
                InjectorReleaseListView()
                    .frame(minWidth: 400)
            }
            Divider()
            InjectorStatusBar()
        }
    }
}

/// A compact status bar showing the server state, port, and release count.
struct InjectorStatusBar: View {
    @EnvironmentObject private var store: InjectorStore

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

            Label("\(store.releases.count)", systemImage: "shippingbox")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Total releases published")

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
    InjectorToolView().environmentObject(InjectorStore())
}
