//
//  HivecrewApp.swift
//  Hivecrew
//
//  Created by John Bean on 1/10/26.
//

import SwiftUI
import SwiftData
import HivecrewShared
import HivecrewLLM
import AppKit
import UserNotifications

@main
struct HivecrewApp: App {
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            VMRecord.self,
            LLMProviderRecord.self,
            TaskRecord.self,
            AgentSessionRecord.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    @NSApplicationDelegateAdaptor(HivecrewAppDelegate.self) var appDelegate
    @StateObject private var vmService = VMServiceClient.shared
    @StateObject private var taskService = TaskService()
    @StateObject private var terminationManager = AppTerminationManager.shared
    
    /// Whether to show the startup sheet for queued tasks
    @State private var showStartupSheet = false
    
    /// Queued tasks found at startup
    @State private var startupQueuedTasks: [TaskRecord] = []
    
    /// Whether the startup check has already been performed (prevents re-showing when window re-opens)
    @State private var hasPerformedStartupCheck = false
    
    /// Whether to show the onboarding wizard
    @State private var showOnboarding = false
    
    /// Whether onboarding has been completed
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vmService)
                .environmentObject(taskService)
                .onAppear {
                    // Wire up the model context to services
                    taskService.setModelContext(sharedModelContainer.mainContext)
                    
                    // Configure termination manager
                    terminationManager.configure(taskService: taskService)
                    
                    // Request notification permissions for agent questions
                    requestNotificationPermissions()
                    
                    // Check if onboarding is needed
                    if !hasCompletedOnboarding {
                        showOnboarding = true
                    } else if !hasPerformedStartupCheck {
                        // Check for queued tasks from previous session (after a brief delay to let data load)
                        // Only do this once per app launch, not on window re-open
                        hasPerformedStartupCheck = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            checkForQueuedTasks()
                        }
                    }
                }
                // Termination confirmation sheet
                .sheet(isPresented: $terminationManager.showTerminationConfirmation) {
                    TerminationConfirmationSheet(terminationManager: terminationManager)
                }
                // Startup queued tasks sheet
                .sheet(isPresented: $showStartupSheet) {
                    QueuedTasksStartupSheet(
                        isPresented: $showStartupSheet,
                        queuedTasks: startupQueuedTasks
                    )
                    .environmentObject(taskService)
                }
                // Onboarding sheet
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                        .environmentObject(vmService)
                        .modelContainer(sharedModelContainer)
                        .interactiveDismissDisabled()
                }
                // Listen for debug menu onboarding trigger
                .onReceive(NotificationCenter.default.publisher(for: .showOnboardingWizard)) { _ in
                    showOnboarding = true
                }
        }
        .modelContainer(sharedModelContainer)
        .commands {
            DebugMenuCommands()
        }
        
#if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(vmService)
                .environmentObject(taskService)
                .modelContainer(sharedModelContainer)
        }
#endif
    }
    
    /// Check for queued tasks from a previous session and show the startup sheet
    private func checkForQueuedTasks() {
        let queuedTasks = taskService.queuedTasks
        if !queuedTasks.isEmpty {
            startupQueuedTasks = queuedTasks
            showStartupSheet = true
        }
    }
    
    /// Request notification permissions for agent question alerts
    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            } else if granted {
                print("Notification permissions granted")
            } else {
                print("Notification permissions denied")
            }
        }
    }
}
