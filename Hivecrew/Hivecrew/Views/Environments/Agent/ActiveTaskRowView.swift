//
//  ActiveTaskRowView.swift
//  Hivecrew
//
//  Sidebar row for active agent tasks
//

import SwiftUI

/// Row displaying an active task in the sidebar
struct ActiveTaskRow: View {
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
}
