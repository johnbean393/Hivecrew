//
//  ContentView.swift
//  Hivecrew
//
//  Created by John Bean on 1/10/26.
//

import SwiftUI
import SwiftData
import TipKit

/// Main content view with tab-based navigation
struct ContentView: View {
    @EnvironmentObject var vmService: VMServiceClient
    @EnvironmentObject var taskService: TaskService
    @State private var selectedTab: AppTab = .dashboard
    @State private var selectedTaskId: String?
    @State private var pendingQuestion: AgentQuestion?
    @State private var pendingPermissionTaskId: String?
    @State private var pendingPermission: PermissionRequest?
    
    // Tips
    private let watchAgentsWorkTip = WatchAgentsWorkTip()
    
    enum AppTab: String, CaseIterable {
        case dashboard = "Dashboard"
        case environments = "Environments"
        
        var icon: String {
            switch self {
            case .dashboard: return "square.grid.3x3.topleft.filled"
            case .environments: return "desktopcomputer"
            }
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem {
                    Label(AppTab.dashboard.rawValue, systemImage: AppTab.dashboard.icon)
                }
                .tag(AppTab.dashboard)
            
            AgentEnvironmentsView(selectedTaskId: $selectedTaskId)
                .tabItem {
                    Label(AppTab.environments.rawValue, systemImage: AppTab.environments.icon)
                }
                .tag(AppTab.environments)
                .popoverTip(watchAgentsWorkTip, arrowEdge: .top)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTask)) { notification in
            if let taskId = notification.userInfo?["taskId"] as? String {
                selectedTaskId = taskId
                selectedTab = .environments
            }
        }
        .agentQuestionSheet($pendingQuestion) { _ in
            if let questionId = pendingQuestion?.id {
                taskService.answerQuestion(questionId)
            }
        }
        .onChange(of: taskService.pendingQuestions) { oldValue, newValue in
            // Show the first pending question
            if pendingQuestion == nil, let firstQuestion = newValue.first {
                pendingQuestion = firstQuestion
                // Track agent question for tips
                TipStore.shared.donateAgentAskedQuestion()
            }
        }
        // Permission confirmation sheet
        .sheet(item: $pendingPermission) { request in
            ToolConfirmationSheet(
                toolName: request.toolName,
                details: request.details,
                onApprove: {
                    if let taskId = pendingPermissionTaskId {
                        taskService.respondToPermission(taskId: taskId, approved: true)
                    }
                    pendingPermission = nil
                    pendingPermissionTaskId = nil
                },
                onDeny: {
                    if let taskId = pendingPermissionTaskId {
                        taskService.respondToPermission(taskId: taskId, approved: false)
                    }
                    pendingPermission = nil
                    pendingPermissionTaskId = nil
                }
            )
            .interactiveDismissDisabled()
        }
        .onChange(of: taskService.pendingPermissions) { oldValue, newValue in
            // Show the first pending permission
            if pendingPermission == nil, let (taskId, request) = newValue.first {
                pendingPermissionTaskId = taskId
                pendingPermission = request
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(VMServiceClient.shared)
        .environmentObject(TaskService())
        .environmentObject(SchedulerService.shared)
        .modelContainer(for: [VMRecord.self, TaskRecord.self, ScheduledTask.self], inMemory: true)
}
