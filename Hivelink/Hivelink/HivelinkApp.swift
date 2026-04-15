//
//  HivelinkApp.swift
//  Hivelink
//

import Combine
import HivecrewCore
import SwiftData
import SwiftUI

/// Owns the shared `HivelinkClusterCoordinator`, `RemoteTaskIndex`, `PeerConnectionManager`, and `HivelinkTaskService`
/// so remote dispatch and real-time monitoring share the same index and coordinator.
@MainActor
private final class HivelinkAppCore: ObservableObject {
    let clusterCoordinator: HivelinkClusterCoordinator
    let remoteTaskIndex: RemoteTaskIndex
    let peerConnectionManager: PeerConnectionManager
    let taskService: HivelinkTaskService
    let voiceOrchestrator: HivelinkVoiceOrchestrator

    init(modelContainer: ModelContainer) {
        let coordinator = HivelinkClusterCoordinator()
        let index = RemoteTaskIndex()
        clusterCoordinator = coordinator
        remoteTaskIndex = index
        peerConnectionManager = PeerConnectionManager(
            remoteTaskIndex: index,
            clusterCoordinator: coordinator
        )
        let service = HivelinkTaskService(
            modelContext: modelContainer.mainContext,
            clusterCoordinator: coordinator,
            remoteTaskIndex: index
        )
        service.peerConnectionManager = peerConnectionManager
        taskService = service

        let orchestrator = HivelinkVoiceOrchestrator()
        orchestrator.configure(taskService: service)
        voiceOrchestrator = orchestrator
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
            .environmentObject(appCore.peerConnectionManager)
            .environmentObject(appCore.taskService)
            .environmentObject(appCore.taskService.artifactImportCoordinator)
            .environmentObject(appCore.voiceOrchestrator)
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
                    appCore.peerConnectionManager.stopAll()
                    Task {
                        await appCore.clusterCoordinator.stopDiscovery()
                    }
                }
            }
        }
        .modelContainer(Self.sharedModelContainer)
    }
}
