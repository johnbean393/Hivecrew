//
//  HivelinkApp.swift
//  Hivelink
//

import BackgroundTasks
import Combine
import CoreSpotlight
import HivecrewCore
import SwiftData
import SwiftUI
import UIKit

// MARK: - App Delegate (APNs token forwarding)

final class HivelinkAppDelegate: NSObject, UIApplicationDelegate {
    weak var notificationManager: NotificationManager?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            notificationManager?.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            notificationManager?.didFailToRegisterForRemoteNotifications(error: error)
        }
    }
}

// MARK: - App Core

/// Owns the shared `HivelinkClusterCoordinator`, `RemoteTaskIndex`, `PeerConnectionManager`, and `HivelinkTaskService`
/// so remote dispatch and real-time monitoring share the same index and coordinator.
@MainActor
private final class HivelinkAppCore: ObservableObject {
    static let backgroundTaskIdentifier = "com.pattonium.Hivelink.refresh"

    let clusterCoordinator: HivelinkClusterCoordinator
    let remoteTaskIndex: RemoteTaskIndex
    let peerConnectionManager: PeerConnectionManager
    let taskService: HivelinkTaskService
    let voiceOrchestrator: HivelinkVoiceOrchestrator
    let notificationManager: NotificationManager
    let incomingCallManager: IncomingCallManager

    @Published var selectedTab: Int = 0

    init(modelContainer: ModelContainer) {
        IncomingCallManager.registerPreferenceDefaults()
        let coordinator = HivelinkClusterCoordinator()
        let index = RemoteTaskIndex()
        let notifManager = NotificationManager()

        clusterCoordinator = coordinator
        remoteTaskIndex = index
        notificationManager = notifManager

        let pcm = PeerConnectionManager(
            remoteTaskIndex: index,
            clusterCoordinator: coordinator
        )
        pcm.notificationManager = notifManager
        peerConnectionManager = pcm

        let service = HivelinkTaskService(
            modelContext: modelContainer.mainContext,
            clusterCoordinator: coordinator,
            remoteTaskIndex: index
        )
        service.peerConnectionManager = pcm
        service.notificationManager = notifManager
        taskService = service

        let orchestrator = HivelinkVoiceOrchestrator()
        orchestrator.configure(taskService: service)
        voiceOrchestrator = orchestrator

        let callManager = IncomingCallManager(callKitProvider: orchestrator.callKitProvider)
        callManager.configure(
            orchestrator: orchestrator,
            notificationManager: notifManager,
            callKitProvider: orchestrator.callKitProvider
        )
        orchestrator.configure(incomingCallManager: callManager)
        service.incomingCallManager = callManager
        pcm.incomingCallManager = callManager
        incomingCallManager = callManager

        let deps = AppDependencyManager.shared
        deps.taskService = service
        deps.voiceOrchestrator = orchestrator
        deps.setSelectedTab = { [weak self] tab in self?.selectedTab = tab }
    }

    // MARK: - Background Refresh

    func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: DispatchQueue.main
        ) { [weak self] task in
            guard let bgTask = task as? BGAppRefreshTask else { return }
            Task { @MainActor [weak self] in
                await self?.handleBackgroundRefresh(bgTask)
            }
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) async {
        scheduleBackgroundRefresh()

        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.taskService.stopReconciliation()
            }
        }

        await clusterCoordinator.loadCluster()
        await incomingCallManager.syncStoredPushTokensToServer(
            apnsTokenString: notificationManager.registeredAPNSTokenString
        )
        await taskService.reconcileAndRefresh()
        taskService.indexAllTasksInSpotlight()

        task.setTaskCompleted(success: true)
    }
}

@main
struct HivelinkApp: App {
    @UIApplicationDelegateAdaptor(HivelinkAppDelegate.self) private var appDelegate
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
        let core = HivelinkAppCore(modelContainer: Self.sharedModelContainer)
        core.registerBackgroundRefresh()
        _appCore = StateObject(wrappedValue: core)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    ContentView(tabSelection: Binding(
                        get: { appCore.selectedTab },
                        set: { appCore.selectedTab = $0 }
                    ))
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
            .environmentObject(appCore.notificationManager)
            .environmentObject(appCore.incomingCallManager)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                VoIPDiagnosticsLog.log("[HivelinkApp] UIApplication.didBecomeActive")
                appCore.notificationManager.removeAllTaskNotifications()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                VoIPDiagnosticsLog.log("[HivelinkApp] UIApplication.willResignActive")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                VoIPDiagnosticsLog.log("[HivelinkApp] UIApplication.didEnterBackground")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                VoIPDiagnosticsLog.log("[HivelinkApp] UIApplication.willEnterForeground")
            }
            .task {
                appDelegate.notificationManager = appCore.notificationManager
                await appCore.notificationManager.requestPermissions()

                authManager.loadStoredCredentials()
                if authManager.isAuthenticated {
                    await appCore.clusterCoordinator.loadCluster()
                    await appCore.incomingCallManager.syncStoredPushTokensToServer(
                        apnsTokenString: appCore.notificationManager.registeredAPNSTokenString
                    )
                    await appCore.taskService.bootstrap()
                    appCore.scheduleBackgroundRefresh()
                }
            }
            .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
                if isAuthenticated {
                    Task {
                        await appCore.clusterCoordinator.loadCluster()
                        await appCore.incomingCallManager.syncStoredPushTokensToServer(
                            apnsTokenString: appCore.notificationManager.registeredAPNSTokenString
                        )
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
            .onChange(of: appCore.notificationManager.pendingDeepLink) { _, deepLink in
                guard let deepLink else { return }
                switch deepLink {
                case .task(let id):
                    appCore.selectedTab = 0
                    appCore.notificationManager.removeNotifications(forTaskId: id)
                case .cluster:
                    appCore.selectedTab = 2
                }
                appCore.notificationManager.pendingDeepLink = nil
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let taskId = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                appCore.notificationManager.pendingDeepLink = .task(id: taskId)
            }
        }
        .modelContainer(Self.sharedModelContainer)
    }
}
