//
//  ActiveTaskRowView.swift
//  Hivecrew
//
//  Sidebar row for active agent tasks
//

import SwiftUI
import AppKit
import HivecrewCore

/// Row displaying an active task in the sidebar
struct ActiveTaskRow: View {
    let task: TaskRecord
    @EnvironmentObject var taskService: TaskService
    @EnvironmentObject var detachedTaskWindowStore: DetachedTaskWindowStore
    @Environment(\.openWindow) private var openWindow
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
                HStack(spacing: 6) {
                    if let kind = task.assignedRuntimeKind {
                        HStack(spacing: 3) {
                            Image(systemName: kind.iconName)
                                .font(.system(size: 8))
                            Text(kind.displayName)
                                .font(.caption2)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(kind.badgeColor)
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(task.isExecutingRemotely ? .blue : .secondary)
                }
                if let ownerLabel {
                    Text(ownerLabel)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                openDetachedTaskWindow()
            } label: {
                let isVM = task.assignedRuntimeKind == .isolatedVM || task.assignedVMId != nil
                Label {
                    Text(
                        detachedTaskWindowStore.isDetached(task.id)
                            ? String(localized: isVM ? "Show VM and Agent Trace Window" : "Show Agent Trace Window")
                            : String(localized: isVM ? "Open VM and Agent Trace in New Window" : "Open Agent Trace in New Window")
                    )
                } icon: {
                    Image(
                        systemName: detachedTaskWindowStore.isDetached(task.id)
                            ? "macwindow.on.rectangle"
                            : "macwindow.badge.plus"
                    )
                }
            }
        }
    }

    private var statusText: String {
        if task.isExecutingRemotely, let nodeName = task.remoteNodeDisplayName {
            switch task.remoteLeaseState {
            case .suspect:
                return String(localized: "Checking \(nodeName)")
            case .recovering:
                return String(localized: "Recovering from \(nodeName)")
            case .completedAwaitingImport:
                return String(localized: "Importing from \(nodeName)")
            default:
                break
            }
            return task.clusterExecutionState == .recoveringRemote
                ? String(localized: "Reconnecting to \(nodeName)")
                : String(localized: "Running on \(nodeName)")
        }
        if task.isInternalClusterExecution {
            return String(localized: "Serving cluster task")
        }
        return task.status.displayName
    }

    private var ownerLabel: String? {
        guard task.isInternalClusterExecution else { return nil }
        let ownerName = task.clusterOwnerNodeName
            ?? clusterStatus.displayName(forPeerId: task.clusterOwnerNodeId)
            ?? task.clusterOwnerNodeId.map { $0.count <= 8 ? $0 : String($0.prefix(8)) }
        guard let ownerName else { return String(localized: "Leased Task") }
        return String(localized: "From \(ownerName)")
    }

    @MainActor
    private func openDetachedTaskWindow() {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            try? await openWindow(
                id: DetachedTaskEnvironmentWindowScene.id,
                value: DetachedTaskEnvironmentWindowValue(taskId: task.id),
                sharingBehavior: SwiftUI.OpenWindowAction.SharingBehavior.requested
            )
        }
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
