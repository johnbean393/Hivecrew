//
//  ActiveTaskRowView.swift
//  Hivecrew
//
//  Sidebar row for active agent tasks
//

import SwiftUI
import HivecrewCore

/// Row displaying an active task in the sidebar
struct ActiveTaskRow: View {
    let task: TaskRecord
    @EnvironmentObject var taskService: TaskService
    @ObservedObject private var clusterStatus = ClusterStatus.shared
    
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
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(task.isExecutingRemotely ? .blue : .secondary)
                if let ownerLabel {
                    Text(ownerLabel)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if task.isExecutingRemotely, let nodeName = task.remoteNodeDisplayName {
            switch task.remoteLeaseState {
            case .suspect:
                return "Checking \(nodeName)"
            case .recovering:
                return "Recovering from \(nodeName)"
            case .completedAwaitingImport:
                return "Importing from \(nodeName)"
            default:
                break
            }
            return task.clusterExecutionState == .recoveringRemote
                ? "Reconnecting to \(nodeName)"
                : "Running on \(nodeName)"
        }
        if task.isInternalClusterExecution {
            return "Serving cluster task"
        }
        return task.status.displayName
    }

    private var ownerLabel: String? {
        guard task.isInternalClusterExecution else { return nil }
        let ownerName = clusterStatus.displayName(forPeerId: task.clusterOwnerNodeId)
            ?? task.clusterOwnerNodeId.map { $0.count <= 8 ? $0 : String($0.prefix(8)) }
        guard let ownerName else { return "Leased Task" }
        return "From \(ownerName)"
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
