//
//  AerospaceApp.swift
//  Aerospace
//
//  Entry point. Owns the shared LogStore and starts the HTTP log server
//  when the app launches. The Pause Ads tool serves its destination folder
//  through that same server (/files/*).
//

import SwiftUI

@main
struct AerospaceApp: App {
    @StateObject private var store = LogStore()
    @StateObject private var oztamStore = OztamStore()
    @StateObject private var apiStore = APITesterStore()
    @StateObject private var injectorStore = InjectorStore()
    @StateObject private var pauseAdStore = PauseAdStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(oztamStore)
                .environmentObject(apiStore)
                .environmentObject(injectorStore)
                .environmentObject(pauseAdStore)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    pauseAdStore.attach(to: store)
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
