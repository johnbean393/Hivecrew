//
//  AgentEnvironmentsView.swift
//  Hivecrew
//
//  Agent Environments tab - Live view into running tasks and their ephemeral VMs
//

import Combine
import SwiftUI
import SwiftData
import TipKit
import HivecrewShared

/// Represents an item in the environments sidebar (either a task or a developer VM)
enum EnvironmentItem: Hashable {
    case task(String)      // Task ID
    case developerVM(String) // VM ID
    
    var id: String {
        switch self {
        case .task(let taskId): return "task:\(taskId)"
        case .developerVM(let vmId): return "dev:\(vmId)"
        }
    }
}

/// Agent Environments tab - Live view into running tasks and their ephemeral VMs
struct AgentEnvironmentsView: View {
    @EnvironmentObject var vmService: VMServiceClient
    @EnvironmentObject var taskService: TaskService
    @ObservedObject private var vmRuntime = AppVMRuntime.shared
    
    @AppStorage("developerVMIds") private var developerVMIdsData: Data = Data()
    
    @Binding var selectedTaskId: String?
    @State private var selectedItem: EnvironmentItem?
    
    // Tips
    private let takeControlTip = TakeControlTip()
    
    /// Developer VM IDs stored in settings
    private var developerVMIds: Set<String> {
        guard let decoded = try? JSONDecoder().decode(Set<String>.self, from: developerVMIdsData) else {
            return []
        }
        return decoded
    }
    
    /// Running developer VMs
    private var runningDeveloperVMs: [VMInfo] {
        vmService.vms.filter { vm in
            developerVMIds.contains(vm.id) && vmRuntime.getVM(id: vm.id) != nil
        }
    }
    
    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .onChange(of: selectedItem) { _, newValue in
            // Sync with selectedTaskId for compatibility
            if case .task(let taskId) = newValue {
                selectedTaskId = taskId
            } else {
                selectedTaskId = nil
            }
        }
        .onChange(of: selectedTaskId) { _, newValue in
            // Sync from external selection
            if let taskId = newValue {
                selectedItem = .task(taskId)
            }
        }
        .onAppear {
            // Track environment viewed for tips when there are active tasks
            if !activeTasksWithVMs.isEmpty {
                TipStore.shared.donateEnvironmentViewed()
            }
        }
        .onChange(of: activeTasksWithVMs) { oldValue, newValue in
            // Track when a task becomes active
            if oldValue.isEmpty && !newValue.isEmpty {
                TipStore.shared.donateEnvironmentViewed()
            }
        }
    }
    
    // MARK: - Active Tasks
    
    /// Tasks that have an assigned VM (running or recently completed)
    private var activeTasksWithVMs: [TaskRecord] {
        taskService.tasks.filter { task in
            task.assignedVMId != nil && task.status.isActive
        }.sorted { $0.createdAt > $1.createdAt }
    }
    
    // MARK: - Sidebar
    
    private var sidebarContent: some View {
        List(selection: $selectedItem) {
            // Active agent tasks section
            if !activeTasksWithVMs.isEmpty {
                Section("Agent Tasks") {
                    taskList
                }
            }
            
            // Developer VMs section
            if !runningDeveloperVMs.isEmpty {
                Section("Developer VMs") {
                    developerVMList
                }
            }
            
            // Empty state if nothing to show
            if activeTasksWithVMs.isEmpty && runningDeveloperVMs.isEmpty {
                emptyState
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
    }
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Active Environments", systemImage: "desktopcomputer")
        } description: {
            Text("Start a task or developer VM to see it here")
        }
        .listRowBackground(Color.clear)
    }
    
    private var taskList: some View {
        ForEach(activeTasksWithVMs) { task in
            ActiveTaskRow(task: task)
                .tag(EnvironmentItem.task(task.id))
        }
    }
    
    private var developerVMList: some View {
        ForEach(runningDeveloperVMs) { vm in
            DeveloperVMRow(vm: vm)
                .tag(EnvironmentItem.developerVM(vm.id))
        }
    }
    
    // MARK: - Detail
    
    @ViewBuilder
    private var detailContent: some View {
        switch selectedItem {
        case .task(let taskId):
            if let task = activeTasksWithVMs.first(where: { $0.id == taskId }),
               let vmId = task.assignedVMId,
               let vmInfo = vmService.vms.first(where: { $0.id == vmId }) {
                VMDetailView(vm: vmInfo)
                    .popoverTip(takeControlTip, arrowEdge: .bottom)
            } else {
                emptyDetailView
            }
            
        case .developerVM(let vmId):
            if let vmInfo = vmService.vms.first(where: { $0.id == vmId }) {
                VMDetailView(vm: vmInfo)
            } else {
                emptyDetailView
            }
            
        case nil:
            // Auto-select first available item
            if let firstTask = activeTasksWithVMs.first,
               let vmId = firstTask.assignedVMId,
               let vmInfo = vmService.vms.first(where: { $0.id == vmId }) {
                VMDetailView(vm: vmInfo)
                    .onAppear { selectedItem = .task(firstTask.id) }
            } else if let firstDevVM = runningDeveloperVMs.first {
                VMDetailView(vm: firstDevVM)
                    .onAppear { selectedItem = .developerVM(firstDevVM.id) }
            } else {
                emptyDetailView
            }
        }
    }
    
    private var emptyDetailView: some View {
        ContentUnavailableView {
            Label("No Active Environments", systemImage: "desktopcomputer")
        } description: {
            Text("Running tasks and developer VMs will appear here")
        }
    }
}

// MARK: - Developer VM Row

/// Row displaying a running developer VM in the sidebar
private struct DeveloperVMRow: View {
    let vm: VMInfo
    
    var body: some View {
        HStack(spacing: 8) {
            // Status indicator (always green since we only show running VMs)
            Circle()
                .fill(.blue)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name)
                    .font(.headline)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Image(systemName: "hammer")
                        .font(.caption2)
                    Text("Developer VM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Active Task Row

/// Row displaying an active task in the sidebar
private struct ActiveTaskRow: View {
    let task: TaskRecord
    @EnvironmentObject var taskService: TaskService
    
    private var statePublisher: AgentStatePublisher? {
        taskService.statePublisher(for: task.id)
    }
    
    var body: some View {
        HStack(spacing: 8) {
            statusIndicator
            
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(task.status.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var statusIndicator: some View {
        switch task.status {
        case .running:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
        case .paused:
            Circle()
                .fill(.yellow)
                .frame(width: 8, height: 8)
        case .waitingForVM:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 8, height: 8)
        default:
            Circle()
                .fill(.gray)
                .frame(width: 8, height: 8)
        }
    }
    
    private func elapsedTime(since date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        let minutes = Int(elapsed / 60)
        let seconds = Int(elapsed.truncatingRemainder(dividingBy: 60))
        
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}

#Preview {
    @Previewable @State var selectedTaskId: String? = nil
    AgentEnvironmentsView(selectedTaskId: $selectedTaskId)
        .environmentObject(VMServiceClient.shared)
        .environmentObject(TaskService())
}
