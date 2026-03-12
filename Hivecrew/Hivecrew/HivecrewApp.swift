//
//  HivecrewApp.swift
//  Hivecrew
//
//  Created by John Bean on 1/10/26.
//

import Combine
import Sparkle
import SwiftUI
import SwiftData
import TipKit
import HivecrewShared
import HivecrewLLM
import HivecrewAPI
import AppKit

@main
struct HivecrewApp: App {
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            VMRecord.self,
            LLMProviderRecord.self,
            TaskRecord.self,
            AgentSessionRecord.self,
            ScheduledTask.self,
            MCPServerRecord.self,
        ])

        do {
            return try SwiftDataStoreManager.makeModelContainer(schema: schema)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    @NSApplicationDelegateAdaptor(HivecrewAppDelegate.self) var appDelegate
    @StateObject private var vmService = VMServiceClient.shared
    @StateObject private var taskService = TaskService()
    @StateObject private var schedulerService = SchedulerService.shared
    @StateObject private var terminationManager = AppTerminationManager.shared
    @StateObject private var downloadService = TemplateDownloadService.shared
    
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
    
    /// Whether to show the template update sheet
    @State private var showTemplateUpdate = false
    /// The current default template ID (for removal after update)
    @AppStorage("defaultTemplateId") private var defaultTemplateId = ""
    
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vmService)
                .environmentObject(taskService)
                .environmentObject(schedulerService)
                .onAppear {
                    self.onStartup()
                }
                // Termination confirmation sheet
                .sheet(
                    isPresented: $terminationManager.showTerminationConfirmation,
                    onDismiss: {
                        terminationManager.handleTerminationSheetDismissed()
                    }
                ) {
                    TerminationConfirmationSheet(terminationManager: terminationManager)
                        .interactiveDismissDisabled()
                }
                // Onboarding sheet
                .sheet(
                    isPresented: $showOnboarding
                ) {
                    OnboardingView(isPresented: $showOnboarding)
                        .environmentObject(vmService)
                        .modelContainer(sharedModelContainer)
                        .interactiveDismissDisabled()
                }
                // Startup queued tasks sheet
                .sheet(
                    isPresented: $showStartupSheet
                ) {
                    QueuedTasksStartupSheet(
                        isPresented: $showStartupSheet,
                        queuedTasks: startupQueuedTasks
                    )
                    .environmentObject(taskService)
                }
                // Template update sheet
                .sheet(
                    isPresented: $showTemplateUpdate
                ) {
                    if let update = downloadService.availableUpdate {
                        TemplateUpdateSheet(
                            isPresented: $showTemplateUpdate,
                            update: update,
                            currentTemplateId: defaultTemplateId.isEmpty ? nil : defaultTemplateId
                        )
                    }
                }
                // Listen for debug menu onboarding trigger
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: .showOnboardingWizard
                    )
                ) { _ in
                    showOnboarding = true
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: .checkForTemplateUpdates
                    )
                ) { _ in
                    Task {
                        await checkForTemplateUpdatesManually()
                    }
                }
                .onChange(of: showOnboarding) { _, isPresented in
                    guard !isPresented, hasCompletedOnboarding else { return }
                    if downloadService.shouldPromptForUpdate() {
                        showTemplateUpdate = true
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        .commands {
            CheckForUpdatesCommand(updater: appDelegate.updaterController.updater)
            SkillsMenuCommand()
            RetrievalIndexMenuCommand()
            DevicesMenuCommand()
            DebugMenuCommands()
        }
        
        Settings {
            SettingsView()
                .environmentObject(vmService)
                .environmentObject(taskService)
                .environmentObject(schedulerService)
                .modelContainer(sharedModelContainer)
        }
        
        Window("Skills", id: "skills-window") {
            SkillsWindow()
        }
        .defaultSize(width: 900, height: 600)

        Window("Retrieval Index", id: "retrieval-index-window") {
            RetrievalIndexWindow()
        }
        .defaultSize(width: 760, height: 560)
        
    }
    
    /// Function to run on startup
    @MainActor
    private func onStartup() {
        // Wire up the model context to services
        taskService.setModelContext(sharedModelContainer.mainContext)
        
        // Configure and start scheduler service
        schedulerService.configure(modelContext: sharedModelContainer.mainContext, taskService: taskService)
        schedulerService.start()
        
        // Configure termination manager
        terminationManager.configure(taskService: taskService)
        
        // Configure TipKit
        TipStore.shared.configure()
        
        // Configure and start API server if enabled
        APIServerManager.shared.configure(taskService: taskService, modelContext: sharedModelContainer.mainContext)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                APIServerManager.shared.startIfEnabled()
            }
        }

        // Install/start retrieval daemon LaunchAgent off the immediate launch path
        // so daemon readiness never delays first-frame responsiveness.
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            RetrievalDaemonManager.shared.startIfEnabled()
        }
        
        // Reconnect remote access tunnel after first-frame startup work.
        // This keeps keychain/process work off the immediate launch path.
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(350))
            await RemoteAccessManager.shared.reconnectIfNeeded()
        }
        
        // Configure MCP server manager (connections are established lazily)
        // Servers are connected when MCP tools are first needed to avoid startup lag
        MCPServerManager.shared.configure(modelContext: sharedModelContainer.mainContext)
        
        // Check startup tasks only once per app launch, not on window re-open.
        if !hasPerformedStartupCheck {
            hasPerformedStartupCheck = true
            
            if hasCompletedOnboarding {
                // Update tip state for onboarding completion
                TipStore.shared.onboardingCompleted()
                
                // Check for queued tasks from previous session after a brief delay to let data load.
                // Keep this on MainActor because TaskService is MainActor-isolated.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    checkForQueuedTasks()
                }
            }
            
            // Always check template updates on startup, but only prompt after onboarding is complete.
            Task {
                await checkForTemplateUpdates(allowPrompt: hasCompletedOnboarding)
            }
        }
        
        // Check if onboarding is needed
        if !hasCompletedOnboarding {
            showOnboarding = true
        }
    }
    
    /// Check for queued tasks from a previous session and show the startup sheet
    @MainActor
    private func checkForQueuedTasks() {
        let queuedTasks = taskService.queuedTasks
        if !queuedTasks.isEmpty {
            startupQueuedTasks = queuedTasks
            showStartupSheet = true
        }
    }
    
    /// Check for template updates and prompt if available
    private func checkForTemplateUpdates(allowPrompt: Bool) async {
        // Force check on startup
        await downloadService.checkForUpdates(force: true)
        
        // Show prompt if update available and not skipped
        if allowPrompt, downloadService.shouldPromptForUpdate() {
            await MainActor.run {
                showTemplateUpdate = true
            }
        }
    }
    
    /// Manually check for template updates from the app menu
    private func checkForTemplateUpdatesManually() async {
        await downloadService.checkForUpdates(force: true)
        
        if downloadService.updateAvailable, downloadService.availableUpdate != nil {
            await MainActor.run {
                showTemplateUpdate = true
            }
            return
        }
        
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "No Template Updates Found"
            alert.informativeText = "You're already on the latest compatible VM template."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
}
