//
//  HivelinkApp.swift
//  Hivelink
//

import HivecrewCore
import SwiftData
import SwiftUI

@main
struct HivelinkApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([TaskRecord.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
