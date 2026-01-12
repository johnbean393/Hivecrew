//
//  DashboardView.swift
//  Hivecrew
//
//  Dashboard tab - Command center for dispatching tasks and reviewing results
//

import SwiftUI
import SwiftData

/// Dashboard tab - Command center for dispatching tasks and reviewing results
struct DashboardView: View {
    @EnvironmentObject var vmService: VMServiceClient
    @EnvironmentObject var taskService: TaskService
    
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
            }
            
            Spacer()
                .frame(height: 32)
            
            // Bottom section: Task list
            TaskListView()
            
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
        .modelContainer(for: [LLMProviderRecord.self, TaskRecord.self], inMemory: true)
}
