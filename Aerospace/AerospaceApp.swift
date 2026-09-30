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
    @StateObject private var oztamStore = OztamStore()
    @StateObject private var apiStore = APITesterStore()
    @StateObject private var injectorStore = InjectorStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(oztamStore)
                .environmentObject(apiStore)
                .environmentObject(injectorStore)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    store.startServer()
                    injectorStore.startServer()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Restart Server") { store.restartServer() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
