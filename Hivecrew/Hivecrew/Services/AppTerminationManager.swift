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
    
    /// Whether AppKit is waiting for a termination reply
    private var terminationReplyPending = false
    
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
            terminationReplyPending = true
            showTerminationConfirmation = true
            return false
        }
        
        return true
    }
    
    /// Called when user confirms termination in the sheet
    func confirmTermination() async {
        terminationReplyPending = false
        showTerminationConfirmation = false
        await performGracefulShutdown()
        
        // Terminate the app
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
    
    /// Called when user cancels termination
    func cancelTermination() {
        showTerminationConfirmation = false
        guard terminationReplyPending else { return }
        terminationReplyPending = false
        NSApplication.shared.reply(toApplicationShouldTerminate: false)
    }
    
    /// Called when the confirmation sheet is dismissed without an explicit choice
    func handleTerminationSheetDismissed() {
        guard terminationReplyPending else { return }
        cancelTermination()
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
        
        // Count VMs that are running (only those tied to active tasks or developer VMs)
        let activeVMIds = Set(vmRuntime.activeVMIds())
        let taskVMIds = Set(
            taskService.tasks.compactMap { task in
                task.status.isActive ? task.assignedVMId : nil
            }
        )
        let developerVMIds = runningDeveloperVMIds()
        let relevantVMIds = activeVMIds.intersection(taskVMIds).union(developerVMIds)
        let totalRunningVMCount = relevantVMIds.count
        
        return ActiveWorkDetails(
            runningAgentCount: runningAgentCount,
            queuedTaskCount: queuedTaskCount,
            totalRunningVMCount: totalRunningVMCount,
            runningTaskTitles: runningTasks.map { $0.title },
            queuedTaskTitles: queuedTasks.map { $0.title }
        )
    }

    private func runningDeveloperVMIds() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: "developerVMIds"),
              let developerVMIds = try? JSONDecoder().decode(Set<String>.self, from: data),
              !developerVMIds.isEmpty else {
            return []
        }
        
        let activeVMIds = Set(vmRuntime.activeVMIds())
        return activeVMIds.intersection(developerVMIds)
    }
    
    // MARK: - Graceful Shutdown
    
    /// Perform graceful shutdown: stop VMs, fail agents and requeue them
    /// - Running agents: Cancel and requeue task, delete ephemeral VM
    /// - Paused agents: Keep VM and task paused (so it can be resumed on next launch)
    private func performGracefulShutdown() async {
        guard let taskService = taskService else { return }
        
        print("AppTerminationManager: Beginning graceful shutdown...")
        
        // Collect VMs that should be preserved (paused tasks)
        var preservedVMIds = Set<String>()
        
        // 1. Handle running agents (cancel, requeue, delete VM)
        // But preserve paused agents (just stop VM, keep task paused)
        let runningAgents = taskService.runningAgents
        for (taskId, agent) in runningAgents {
            if let task = taskService.tasks.first(where: { $0.id == taskId }) {
                if task.status == .paused {
                    // Paused task - preserve the VM so it can be resumed
                    print("AppTerminationManager: Preserving paused task \(taskId)")
                    if let vmId = task.assignedVMId {
                        preservedVMIds.insert(vmId)
                    }
                    // Don't cancel or requeue - just let it persist
                } else {
                    // Running task - cancel and requeue
                    print("AppTerminationManager: Cancelling agent for task \(taskId)")
                    await agent.cancel()
                    await taskService.requeueTask(task, reason: "App was closed - task requeued")
                }
            }
        }
        
        // 2. Stop all running VMs
        // VMs for paused tasks will be stopped (to save state) but NOT deleted
        let runningVMIds = vmRuntime.activeVMIds()
        for vmId in runningVMIds {
            print("AppTerminationManager: Stopping VM \(vmId)")
            do {
                try await vmRuntime.stopVM(id: vmId, force: true)
            } catch {
                print("AppTerminationManager: Failed to stop VM \(vmId): \(error)")
            }
        }
        
        // 3. Queued tasks remain queued (no action needed)
        // 4. Paused tasks remain paused with their VM preserved
        print("AppTerminationManager: Graceful shutdown complete. Preserved \(preservedVMIds.count) VM(s) for paused tasks")
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

