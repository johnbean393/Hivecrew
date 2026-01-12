//
//  AppTerminationManager.swift
//  Hivecrew
//
//  Manages app termination confirmation and graceful shutdown
//

import Foundation
import AppKit
import Combine

/// Manages app termination, checking for active work and confirming with user
@MainActor
class AppTerminationManager: ObservableObject {
    static let shared = AppTerminationManager()
    
    // MARK: - Published State
    
    /// Whether we should show the termination confirmation sheet
    @Published var showTerminationConfirmation = false
    
    /// Active work details for the confirmation dialog
    @Published private(set) var activeWorkDetails = ActiveWorkDetails()
    
    // MARK: - Dependencies
    
    private weak var taskService: TaskService?
    private var vmRuntime: AppVMRuntime { AppVMRuntime.shared }
    
    private init() {}
    
    // MARK: - Configuration
    
    /// Configure the manager with required dependencies
    func configure(taskService: TaskService) {
        self.taskService = taskService
    }
    
    // MARK: - Termination Handling
    
    /// Check if app can terminate safely. Returns true if no confirmation needed.
    /// If confirmation is needed, shows the confirmation sheet and returns false.
    func shouldTerminate() -> Bool {
        let details = checkActiveWork()
        
        if details.hasActiveWork {
            activeWorkDetails = details
            showTerminationConfirmation = true
            return false
        }
        
        return true
    }
    
    /// Called when user confirms termination in the sheet
    func confirmTermination() async {
        await performGracefulShutdown()
        
        // Terminate the app
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
    
    /// Called when user cancels termination
    func cancelTermination() {
        showTerminationConfirmation = false
        NSApplication.shared.reply(toApplicationShouldTerminate: false)
    }
    
    // MARK: - Work Detection
    
    /// Check for any active work that needs confirmation before termination
    private func checkActiveWork() -> ActiveWorkDetails {
        guard let taskService = taskService else {
            return ActiveWorkDetails()
        }
        
        // Count running agents
        let runningAgentCount = taskService.runningAgents.count
        let runningTasks = taskService.tasks.filter { $0.status == .running }
        
        // Count queued tasks
        let queuedTasks = taskService.tasks.filter { $0.status == .queued || $0.status == .waitingForVM }
        let queuedTaskCount = queuedTasks.count
        
        // Count VMs that are running
        let runningVMs = vmRuntime.runningVMs
        let totalRunningVMCount = runningVMs.count
        
        return ActiveWorkDetails(
            runningAgentCount: runningAgentCount,
            queuedTaskCount: queuedTaskCount,
            totalRunningVMCount: totalRunningVMCount,
            runningTaskTitles: runningTasks.map { $0.title },
            queuedTaskTitles: queuedTasks.map { $0.title }
        )
    }
    
    // MARK: - Graceful Shutdown
    
    /// Perform graceful shutdown: stop VMs, fail agents and requeue them
    private func performGracefulShutdown() async {
        guard let taskService = taskService else { return }
        
        print("AppTerminationManager: Beginning graceful shutdown...")
        
        // 1. Cancel and requeue running agents
        let runningAgents = taskService.runningAgents
        for (taskId, agent) in runningAgents {
            print("AppTerminationManager: Cancelling agent for task \(taskId)")
            await agent.cancel()
            
            // Find and requeue the task
            if let task = taskService.tasks.first(where: { $0.id == taskId }) {
                await taskService.requeueTask(task, reason: "App was closed - task requeued")
            }
        }
        
        // 2. Stop all running VMs
        let runningVMIds = Array(vmRuntime.runningVMs.keys)
        for vmId in runningVMIds {
            print("AppTerminationManager: Stopping VM \(vmId)")
            do {
                try await vmRuntime.stopVM(id: vmId, force: true)
            } catch {
                print("AppTerminationManager: Failed to stop VM \(vmId): \(error)")
            }
        }
        
        // 3. Queued tasks remain queued (no action needed)
        print("AppTerminationManager: Graceful shutdown complete")
    }
}

// MARK: - Active Work Details

/// Details about active work in the app
struct ActiveWorkDetails {
    var runningAgentCount: Int = 0
    var queuedTaskCount: Int = 0
    var totalRunningVMCount: Int = 0
    var runningTaskTitles: [String] = []
    var queuedTaskTitles: [String] = []
    
    var hasActiveWork: Bool {
        runningAgentCount > 0 || queuedTaskCount > 0 || totalRunningVMCount > 0
    }
}

// MARK: - NSApplicationDelegate Extension

/// App delegate for handling termination
class HivecrewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            if AppTerminationManager.shared.shouldTerminate() {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            // If false, the manager will show confirmation sheet and call reply later
        }
        
        // Return .terminateLater to defer the decision
        return .terminateLater
    }
}
