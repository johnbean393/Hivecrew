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
import HivecrewVoice
import AppKit
import HivecrewCore

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
            NSLog("Could not create on-disk ModelContainer: \(error)")

            do {
                let fallbackConfiguration = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
                return try ModelContainer(
                    for: schema,
                    configurations: [fallbackConfiguration]
                )
            } catch {
                fatalError("Could not create fallback ModelContainer: \(error)")
            }
        }
    }()
    
    @NSApplicationDelegateAdaptor(HivecrewAppDelegate.self) var appDelegate
    @StateObject private var vmService = VMServiceClient.shared
    @StateObject private var taskService = TaskService()
    @StateObject private var schedulerService = SchedulerService.shared
    @StateObject private var terminationManager = AppTerminationManager.shared
    @StateObject private var downloadService = TemplateDownloadService.shared
    @StateObject private var voiceOrchestrator = VoiceOrchestrator()
    @StateObject private var compactCallManager = CompactCallManager()
    @StateObject private var detachedTaskWindowStore = DetachedTaskWindowStore()
    
    /// Whether to show the startup sheet for queued tasks
    @State private var showStartupSheet = false
    /// Queued tasks found at startup
    @State private var startupQueuedTasks: [TaskRecord] = []
    /// Whether the startup check has already been performed (prevents re-showing when window re-opens)
    @State private var hasPerformedStartupCheck = false
    /// Whether app-wide services have already been bootstrapped for this launch.
    @State private var hasBootstrappedServices = false
    
    /// Whether to show the onboarding wizard
    @State private var showOnboarding = false
    /// Whether onboarding has been completed
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    
    /// The template currently presented in the update sheet.
    @State private var presentedTemplateUpdate: RemoteTemplate?
    /// The current default template ID (for removal after update)
    @AppStorage("defaultTemplateId") private var defaultTemplateId = ""
    
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vmService)
                .environmentObject(taskService)
                .environmentObject(schedulerService)
                .environmentObject(voiceOrchestrator)
                .environmentObject(compactCallManager)
                .environmentObject(detachedTaskWindowStore)
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
                .sheet(item: $presentedTemplateUpdate) { update in
                    TemplateUpdateSheet(
                        update: update,
                        currentTemplateId: defaultTemplateId.isEmpty ? nil : defaultTemplateId
                    )
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
                        presentTemplateUpdateSheetIfNeeded()
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

        WindowGroup("Task Environment", id: DetachedTaskEnvironmentWindowScene.id, for: DetachedTaskEnvironmentWindowValue.self) { value in
            if let taskId = value.wrappedValue?.taskId {
                DetachedTaskEnvironmentWindow(taskId: taskId)
                    .environmentObject(vmService)
                    .environmentObject(taskService)
                    .environmentObject(detachedTaskWindowStore)
            } else {
                ContentUnavailableView {
                    Label("Task Unavailable", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                } description: {
                    Text("Select a running task from the Environments tab to open its VM and agent trace here.")
                }
            }
        }
        .defaultSize(width: 1400, height: 900)
        .restorationBehavior(.disabled)
        
    }
    
    /// Function to run on startup
    @MainActor
    private func onStartup() {
        if !hasBootstrappedServices {
            hasBootstrappedServices = true

        // Wire up the model context to services
        taskService.setModelContext(sharedModelContainer.mainContext)
        normalizeProviderSortOrdersIfNeeded(modelContext: sharedModelContainer.mainContext)
        synchronizePersistedCodexProviderNames()
        VoiceAvailability.migrateRealtime15ToRealtime2IfNeeded()
        
        // Configure and start scheduler service
        schedulerService.configure(modelContext: sharedModelContainer.mainContext, taskService: taskService)
        schedulerService.start()
        
        // Configure termination manager
        terminationManager.configure(taskService: taskService)
        AppSleepWakeMonitor.shared.configure(voiceOrchestrator: voiceOrchestrator)
        AppSleepWakeMonitor.shared.start()
        
        // Configure voice orchestrator
        voiceOrchestrator.configure(taskService: taskService, modelContext: sharedModelContainer.mainContext)
        
        // Configure compact call manager
        compactCallManager.configure(orchestrator: voiceOrchestrator, taskService: taskService)
        appDelegate.compactCallManager = compactCallManager
        
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

        // Configure App Worker (cua-driver) manager — probes binary/permissions without launching backend
        CuaDriverManager.shared.configure()
        
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
        }
        
        // Check if onboarding is needed
        if !hasCompletedOnboarding {
            showOnboarding = true
        }
    }

    @MainActor
    private func synchronizePersistedCodexProviderNames() {
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        guard let providers = try? sharedModelContainer.mainContext.fetch(descriptor) else {
            return
        }

        let changed = providers.reduce(into: false) { partialResult, provider in
            if provider.syncPersistedCodexDisplayName() {
                partialResult = true
            }
        }

        if changed {
            try? sharedModelContainer.mainContext.save()
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
                presentTemplateUpdateSheetIfNeeded()
            }
        }
    }
    
    /// Manually check for template updates from the app menu
    private func checkForTemplateUpdatesManually() async {
        await downloadService.checkForUpdates(force: true)
        
        if downloadService.updateAvailable, downloadService.availableUpdate != nil {
            await MainActor.run {
                presentTemplateUpdateSheetIfNeeded()
            }
            return
        }
        
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = String(localized: "No Template Updates Found")
            alert.informativeText = String(localized: "You're already on the latest compatible VM template.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }
    }

    @MainActor
    private func presentTemplateUpdateSheetIfNeeded() {
        guard let update = downloadService.availableUpdate else { return }
        presentedTemplateUpdate = update
    }
    
}

@MainActor
private final class AppSleepWakeMonitor {
    static let shared = AppSleepWakeMonitor()
    
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?
    private weak var voiceOrchestrator: VoiceOrchestrator?
    
    private init() {}

    func configure(voiceOrchestrator: VoiceOrchestrator) {
        self.voiceOrchestrator = voiceOrchestrator
    }
    
    func start() {
        guard willSleepObserver == nil, didWakeObserver == nil else { return }
        
        let center = NSWorkspace.shared.notificationCenter
        willSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await self.voiceOrchestrator?.handleSystemWillSleep()
                await ClusterManager.shared.handleSystemWillSleep()
                await RemoteAccessManager.shared.handleSystemWillSleep()
            }
        }
        
        didWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await RemoteAccessManager.shared.handleSystemDidWake()
                await self.voiceOrchestrator?.handleSystemDidWake()
            }
        }
    }
}
