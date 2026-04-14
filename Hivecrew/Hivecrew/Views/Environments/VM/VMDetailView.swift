//
//  VMDetailView.swift
//  Hivecrew
//
//  Detail view for an ephemeral VM running a task
//

import Combine
import SwiftUI
import HivecrewCore

/// Detail view for an ephemeral VM, showing display and agent controls
struct VMDetailView: View {
    let vm: VMInfo
    @Binding var showTracePanel: Bool
    @EnvironmentObject var vmService: VMServiceClient
    @EnvironmentObject var taskService: TaskService
    @ObservedObject var vmRuntime = AppVMRuntime.shared
    
    private var isVMRunning: Bool {
        vmRuntime.getVM(id: vm.id) != nil
    }
    
    /// Get the task assigned to this VM
    private var assignedTask: TaskRecord? {
        taskService.tasks.first { task in
            task.assignedVMId == vm.id && taskService.isTaskEffectivelyActive(task)
        }
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
    
    return VMDetailView(vm: sampleVM, showTracePanel: .constant(true))
        .environmentObject(VMServiceClient.shared)
        .environmentObject(TaskService())
        .frame(width: 800, height: 600)
}
