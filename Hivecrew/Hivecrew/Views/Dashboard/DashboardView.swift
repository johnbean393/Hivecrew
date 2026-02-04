//
//  DashboardView.swift
//  Hivecrew
//
//  Dashboard tab - Command center for dispatching tasks and reviewing results
//

import SwiftUI
import SwiftData
import TipKit

/// Tab selection for the task list section
enum TaskListTab: String, CaseIterable {
    case tasks = "Tasks"
    case scheduled = "Scheduled"
}

/// Dashboard tab - Command center for dispatching tasks and reviewing results
struct DashboardView: View {
    @EnvironmentObject var vmService: VMServiceClient
    @EnvironmentObject var taskService: TaskService
    @EnvironmentObject var schedulerService: SchedulerService
    
    @State private var selectedTab: TaskListTab = .tasks
    
    // Tips
    private let createFirstTaskTip = CreateFirstTaskTip()
    
    var body: some View {
        VStack(spacing: 0) {
            // Top section: Hero + Input
            VStack(spacing: 24) {
                Spacer()
                    .frame(height: 40)
                
                // Hero prompt
                Text("What would you like me to do?")
                    .font(.title)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                
                // Task input area
                TaskInputView()
                    .popoverTip(createFirstTaskTip, arrowEdge: .bottom)
            }
            .padding(.bottom, 24)
            .layoutPriority(1) // Prevent compression when agent preview is shown

            AgentPreviewStripView()
                .padding(.bottom, 20)
            
            // Bottom section: Task list or Scheduled tasks
            if selectedTab == .tasks {
                TaskListView(selectedTab: $selectedTab, schedulerService: schedulerService)
            } else {
                ScheduledTasksView(selectedTab: $selectedTab, schedulerService: schedulerService)
                    .onAppear {
                        TipStore.shared.donateScheduledTabViewed()
                    }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#Preview {
    DashboardView()
        .environmentObject(VMServiceClient.shared)
        .environmentObject(TaskService())
        .environmentObject(SchedulerService.shared)
        .modelContainer(for: [LLMProviderRecord.self, TaskRecord.self, ScheduledTask.self], inMemory: true)
}
