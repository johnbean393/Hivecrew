//
//  HivelinkApp.swift
//  Hivelink
//

import Combine
import HivecrewCore
import SwiftData
import SwiftUI

/// Owns the shared `HivelinkClusterCoordinator` and `HivelinkTaskService` so both use the same coordinator
/// and a stable `ModelContext` from the app container.
@MainActor
private final class HivelinkAppCore: ObservableObject {
    let clusterCoordinator: HivelinkClusterCoordinator
    let taskService: HivelinkTaskService

    init(modelContainer: ModelContainer) {
        let coordinator = HivelinkClusterCoordinator()
        clusterCoordinator = coordinator
        taskService = HivelinkTaskService(
            modelContext: modelContainer.mainContext,
            clusterCoordinator: coordinator
        )
    }
}

@main
struct HivelinkApp: App {
    @StateObject private var authManager = RemoteAccessAuthManager()
    @StateObject private var appCore: HivelinkAppCore

    private static let sharedModelContainer: ModelContainer = {
        let schema = Schema([TaskRecord.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        _appCore = StateObject(wrappedValue: HivelinkAppCore(modelContainer: Self.sharedModelContainer))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            .animation(.default, value: authManager.isAuthenticated)
            .environmentObject(authManager)
            .environmentObject(appCore.clusterCoordinator)
            .environmentObject(appCore.taskService)
            .task {
                authManager.loadStoredCredentials()
                if authManager.isAuthenticated {
                    await appCore.clusterCoordinator.loadCluster()
                    await appCore.taskService.bootstrap()
                }
            }
            .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
                if isAuthenticated {
                    Task {
                        await appCore.clusterCoordinator.loadCluster()
                        await appCore.taskService.bootstrap()
                    }
                } else {
                    appCore.taskService.stopReconciliation()
                    Task {
                        await appCore.clusterCoordinator.stopDiscovery()
                    }
                }
            }
        }
        .modelContainer(Self.sharedModelContainer)
    }
}
