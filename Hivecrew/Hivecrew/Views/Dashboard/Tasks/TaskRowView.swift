//
//  TaskRowView.swift
//  Hivecrew
//
//  Individual task row with status indicator
//

import SwiftUI
import TipKit
import Combine

/// Individual task row with status dot and title
struct TaskRowView: View {
    let task: TaskRecord
    @EnvironmentObject var taskService: TaskService
    @State private var isHovered: Bool = false
    @State private var showingTrace: Bool = false
    
    // Tips
    private let showDeliverableTip = ShowDeliverableTip()
    
    /// Whether the task is actively executing (not paused, waiting, or completed)
    var isActivelyRunning: Bool {
        task.status == .running
    }
    
    var statusColor: Color {
        switch task.status {
            case .queued, .waitingForVM, .paused:
                return .yellow
            case .running:
                return .green
            case .completed:
                // Use wasSuccessful to determine color if available
                if let success = task.wasSuccessful {
                    return success ? .green : .red
                }
                return .gray
            case .failed:
                return .red
            case .cancelled:
                return .gray
            case .timedOut, .maxIterations:
                return .orange
        }
    }
    
    /// Icon for completed task based on wasSuccessful
    var completionIcon: String? {
        guard task.status == .completed else { return nil }
        if let success = task.wasSuccessful {
            return success ? "checkmark.circle.fill" : "xmark.circle.fill"
        }
        return nil
    }
    
    var body: some View {
        Button(action: handleRowTap) {
            HStack(spacing: 12) {
                // Status indicator
                if let icon = completionIcon {
                    // Show checkmark or X for completed tasks
                    Image(systemName: icon)
                        .foregroundStyle(statusColor)
                        .font(.system(size: 14))
                        .frame(width: 14, height: 14)
                } else {
                    // Status dot for active/other tasks
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .stroke(statusColor.opacity(0.3), lineWidth: 2)
                        )
                }
                
                // Task info
                VStack(alignment: .leading, spacing: 2) {
                    // Title
                    Text(task.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    // Status text
                    HStack(spacing: 8) {
                        // Show verified status for completed tasks
                        if task.status == .completed, let success = task.wasSuccessful {
                            Text(success ? "Verified Complete" : "Incomplete")
                                .font(.caption)
                                .foregroundStyle(success ? .green : .red)
                        } else {
                            Text(task.status.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        // Show duration for completed tasks
                        if !task.status.isActive, task.completedAt != nil {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(task.durationString)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        
                        // Show elapsed time for running tasks
                        if task.status == .running, let startedAt = task.startedAt {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            ElapsedTimeView(startDate: startedAt)
                        }
                        
                        // Show deliverable count for completed tasks with outputs
                        if !task.status.isActive, let outputPaths = task.outputFilePaths, !outputPaths.isEmpty {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Button(action: { showDeliverablesInFinder() }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "doc.fill")
                                        .font(.caption2)
                                    Text("\(outputPaths.count)")
                                        .font(.caption)
                                }
                                .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("Show deliverables in Finder")
                            .popoverTip(showDeliverableTip, arrowEdge: .bottom)
                        }
                    }
                }
                
                Spacer()
                
                // Actions (shown on hover)
                if isHovered {
                    HStack(spacing: 8) {
                        // Rerun button for inactive tasks
                        if !task.status.isActive {
                            Button(action: { Task { try? await taskService.rerunTask(task) } }) {
                                Image(systemName: "arrow.counterclockwise")
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("Rerun task")
                        }
                        
                        if task.status.isActive {
                            Button(action: { Task { await taskService.cancelTask(task) } }) {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel task")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // Only show delete action for non-active tasks
            if !task.status.isActive {
                Button(role: .destructive) {
                    Task { await taskService.deleteTask(task) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showingTrace) {
            SessionTraceView(task: task)
        }
        .contextMenu {
            // View trace option
            Button {
                showingTrace = true
            } label: {
                Label("View Trace", systemImage: "list.bullet.rectangle")
            }
            
            // Rerun option for inactive tasks
            if !task.status.isActive {
                Button {
                    Task { try? await taskService.rerunTask(task) }
                } label: {
                    Label("Rerun", systemImage: "arrow.counterclockwise")
                }
            }
            
            // Show deliverables
            if let outputPaths = task.outputFilePaths, !outputPaths.isEmpty {
                Button {
                    showDeliverablesInFinder()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            
            // Cancel option for active tasks
            if task.status.isActive {
                Divider()
                Button(role: .destructive) {
                    Task { await taskService.cancelTask(task) }
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            }
            
            // Delete option for inactive tasks
            if !task.status.isActive {
                Divider()
                Button(role: .destructive) {
                    Task { await taskService.deleteTask(task) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .padding(2)
    }
    
    private func handleRowTap() {
        if isActivelyRunning {
            // Navigate to task's environment if task is actively running
            navigateToTask(task.id)
        } else {
            // Show trace for non-running tasks
            showingTrace = true
        }
    }
    
    private func navigateToTask(_ taskId: String) {
        // Navigate to the task in the Environments tab
        NotificationCenter.default.post(
            name: .navigateToTask,
            object: nil,
            userInfo: ["taskId": taskId]
        )
    }
    
    private func showDeliverablesInFinder() {
        guard let outputPaths = task.outputFilePaths, !outputPaths.isEmpty else { return }
        
        // Convert paths to URLs
        let urls = outputPaths.compactMap { URL(fileURLWithPath: $0) }
        
        // Filter to only existing files
        let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        
        if existingURLs.isEmpty {
            // If no files exist, try to open the output directory instead
            let outputDirectoryPath = UserDefaults.standard.string(forKey: "outputDirectoryPath") ?? ""
            let outputDirectory: URL
            if outputDirectoryPath.isEmpty {
                outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
            } else {
                outputDirectory = URL(fileURLWithPath: outputDirectoryPath)
            }
            NSWorkspace.shared.open(outputDirectory)
        } else {
            // Select the files in Finder
            NSWorkspace.shared.activateFileViewerSelecting(existingURLs)
        }
    }
}

/// Displays elapsed time that updates every second
struct ElapsedTimeView: View {
    let startDate: Date
    @State private var elapsed: TimeInterval = 0
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var elapsedString: String {
        let seconds = Int(elapsed)
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        } else {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
    }
    
    var body: some View {
        Text(elapsedString)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(startDate)
            }
            .onAppear {
                elapsed = Date().timeIntervalSince(startDate)
            }
    }
}

// Notification for navigation
extension Notification.Name {
    static let navigateToTask = Notification.Name("navigateToTask")
}

#Preview {
    VStack(spacing: 8) {
        TaskRowView(task: TaskRecord(
            title: "Create Paris Trip Research `docx`",
            taskDescription: "Research places to visit in Paris",
            status: .waitingForVM,
            providerId: "test",
            modelId: "gpt-5.2"
        ))
        
        TaskRowView(task: TaskRecord(
            title: "Create Paris Trip Research `docx`",
            taskDescription: "Research places to visit in Paris",
            status: .running,
            startedAt: Date().addingTimeInterval(-125),
            providerId: "test",
            modelId: "gpt-5.2"
        ))
        
        TaskRowView(task: TaskRecord(
            title: "Invent Nuclear Fusion",
            taskDescription: "Solve cold fusion",
            status: .failed,
            completedAt: Date(),
            providerId: "test",
            modelId: "gpt-5.2",
            errorMessage: "Task is impossible"
        ))
    }
    .environmentObject(TaskService())
    .padding()
    .frame(width: 500)
}
