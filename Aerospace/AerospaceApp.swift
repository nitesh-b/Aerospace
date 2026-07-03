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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
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
