//
//  AerospaceApp.swift
//  Aerospace
//
//  Created by Nitesh Banskota on 3/7/2026.
//

import SwiftUI
import CoreData

@main
struct AerospaceApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
