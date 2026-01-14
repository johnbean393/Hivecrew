//
//  VMDetailView.swift
//  Hivecrew
//
//  Detail view for an ephemeral VM running a task
//

import Combine
import SwiftUI

/// Detail view for an ephemeral VM, showing display and agent controls
struct VMDetailView: View {
    let vm: VMInfo
    @EnvironmentObject var vmService: VMServiceClient
    @EnvironmentObject var taskService: TaskService
    @ObservedObject var vmRuntime = AppVMRuntime.shared
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showTracePanel = true
    
    private var isVMRunning: Bool {
        vmRuntime.getVM(id: vm.id) != nil
    }
    
    /// Get the task assigned to this VM
    private var assignedTask: TaskRecord? {
        taskService.tasks.first { $0.assignedVMId == vm.id && $0.status.isActive }
    }
    
    /// Get the state publisher for the assigned task
    private var statePublisher: AgentStatePublisher? {
        guard let task = assignedTask else { return nil }
        return taskService.statePublisher(for: task.id)
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Main content area - VM display
            VStack(spacing: 0) {
                // VM display area
                vmDisplayArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                
                // VM info bar
                VMInfoBar(vm: vm, isAgentRunning: statePublisher?.status == .running)
            }
            
            // Agent Trace Panel on the right
            if showTracePanel, let publisher = statePublisher, let task = assignedTask {
                Divider()
                
                AgentTracePanel(
                    statePublisher: publisher,
                    taskTitle: task.title,
                    taskDescription: task.taskDescription
                )
            }
        }
        .toolbar { toolbarContent }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
    
    // MARK: - Display Area
    
    @ViewBuilder
    private var vmDisplayArea: some View {
        if isVMRunning {
            VMDisplayView(vmId: vm.id, vmRuntime: vmRuntime)
        } else {
            VMPlaceholderView(
                icon: "display",
                title: "VM is starting...",
                subtitle: "Your VM will be ready shortly."
            )
        }
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Agent control buttons (pause/resume/cancel)
            agentControlButtons
            
            // Trace panel toggle
            if statePublisher != nil {
                Button(action: { showTracePanel.toggle() }) {
                    Label("Trace", systemImage: showTracePanel ? "sidebar.trailing" : "sidebar.trailing")
                }
                .help(showTracePanel ? "Hide Trace Panel" : "Show Trace Panel")
            }
        }
    }
    
    @ViewBuilder
    private var agentControlButtons: some View {
        if let task = assignedTask, let publisher = statePublisher {
            if publisher.status == .running {
                Button(action: { pauseAgent() }) {
                    Label("Pause Agent", systemImage: "pause.fill")
                }
                .help("Pause the agent to take over manually")
            } else if publisher.status == .paused {
                Button(action: { resumeAgent() }) {
                    Label("Resume Agent", systemImage: "play.fill")
                }
                .tint(.green)
                .help("Resume the agent")
            }
            
            // Cancel button for active tasks
            if task.status.isActive {
                Button(action: { cancelAgent() }) {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .tint(.red)
                .help("Cancel the task")
            }
        }
    }
    
    // MARK: - Agent Control Actions
    
    private func pauseAgent() {
        guard let task = assignedTask else { return }
        taskService.pauseTask(task)
    }
    
    private func resumeAgent() {
        guard let task = assignedTask else { return }
        taskService.resumeTask(task)
    }
    
    private func cancelAgent() {
        guard let task = assignedTask else { return }
        Task {
            await taskService.cancelTask(task)
        }
    }
}

#Preview {
    let sampleVM = VMInfo(
        id: "test-vm",
        name: "Test VM",
        status: .ready,
        createdAt: Date(),
        lastUsedAt: nil,
        bundlePath: "/tmp/test",
        configuration: VMConfiguration()
    )
    
    return VMDetailView(vm: sampleVM)
        .environmentObject(VMServiceClient.shared)
        .environmentObject(TaskService())
        .frame(width: 800, height: 600)
}
