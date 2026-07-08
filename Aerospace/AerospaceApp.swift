//
//  AerospaceApp.swift
//  Aerospace
//
//  Entry point. Owns the shared LogStore and starts the HTTP log server
//  when the app launches.
//

import SwiftUI

@main
struct AerospaceApp: App {
    @StateObject private var store = LogStore()
    @StateObject private var apiStore = APITesterStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(apiStore)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear { store.startServer() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Restart Server") { store.restartServer() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
