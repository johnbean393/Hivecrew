//
//  QueuedTasksStartupSheet.swift
//  Hivecrew
//
//  Sheet shown on startup when there are queued tasks from a previous session
//

import SwiftUI

/// Sheet shown on app startup when queued tasks exist from a previous session
struct QueuedTasksStartupSheet: View {
    @EnvironmentObject var taskService: TaskService
    @Binding var isPresented: Bool
    
    /// Tasks that were queued from a previous session
    let queuedTasks: [TaskRecord]
    
    /// Selected task IDs (default to all selected)
    @State private var selectedTaskIds: Set<String>
    
    init(isPresented: Binding<Bool>, queuedTasks: [TaskRecord]) {
        self._isPresented = isPresented
        self.queuedTasks = queuedTasks
        // Default all tasks to selected
        self._selectedTaskIds = State(initialValue: Set(queuedTasks.map { $0.id }))
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)
                
                Text("Queued Tasks Found")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("The following tasks were queued from your previous session. Select which tasks you'd like to run.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            // Task list
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(queuedTasks) { task in
                        QueuedTaskRow(
                            task: task,
                            isSelected: selectedTaskIds.contains(task.id),
                            onToggle: { toggleSelection(task.id) }
                        )
                        
                        if task.id != queuedTasks.last?.id {
                            Divider()
                                .padding(.horizontal, 12)
                        }
                    }
                }
            }
            .frame(minHeight: CGFloat(min(queuedTasks.count, 1)) * 60, maxHeight: 300)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            
            // Selection info
            HStack {
                Text("\(selectedTaskIds.count) of \(queuedTasks.count) tasks selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Select All") {
                    selectAll()
                }
                .buttonStyle(.link)
                .disabled(selectedTaskIds.count == queuedTasks.count)
                
                Button("Deselect All") {
                    deselectAll()
                }
                .buttonStyle(.link)
                .disabled(selectedTaskIds.isEmpty)
            }
            
            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    cancelAllTasks()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Run") {
                    runSelectedTasks()
                }
                .disabled(selectedTaskIds.isEmpty)
                
                Button("Run All") {
                    runAllTasks()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
    
    // MARK: - Actions
    
    private func toggleSelection(_ taskId: String) {
        if selectedTaskIds.contains(taskId) {
            selectedTaskIds.remove(taskId)
        } else {
            selectedTaskIds.insert(taskId)
        }
    }
    
    private func selectAll() {
        selectedTaskIds = Set(queuedTasks.map { $0.id })
    }
    
    private func deselectAll() {
        selectedTaskIds.removeAll()
    }
    
    private func runSelectedTasks() {
        // Cancel tasks that are not selected
        let unselectedTasks = queuedTasks.filter { !selectedTaskIds.contains($0.id) }
        for task in unselectedTasks {
            Task {
                await taskService.removeFromQueue(task)
            }
        }
        
        // Start selected tasks
        let selectedTasks = queuedTasks.filter { selectedTaskIds.contains($0.id) }
        for task in selectedTasks {
            Task {
                await taskService.startTask(task)
            }
        }
        
        isPresented = false
    }
    
    private func runAllTasks() {
        // Start all tasks
        for task in queuedTasks {
            Task {
                await taskService.startTask(task)
            }
        }
        
        isPresented = false
    }
    
    private func cancelAllTasks() {
        // Remove all queued tasks
        for task in queuedTasks {
            Task {
                await taskService.removeFromQueue(task)
            }
        }
        
        isPresented = false
    }
}

// MARK: - QueuedTaskRow

private struct QueuedTaskRow: View {
    let task: TaskRecord
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Checkbox
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .blue : .secondary)
                
                // Task info
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        // Status badge
                        Text(task.status.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                        
                        // Created time
                        Text(formatDate(task.createdAt))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // Model info
                        Text("•")
                            .foregroundColor(.secondary)
                        
                        Text(task.modelId)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    QueuedTasksStartupSheet(
        isPresented: .constant(true),
        queuedTasks: []
    )
    .environmentObject(TaskService())
}
