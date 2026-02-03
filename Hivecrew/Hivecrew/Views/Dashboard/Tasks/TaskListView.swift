//
//  TaskListView.swift
//  Hivecrew
//
//  Searchable list of tasks with status indicators
//

import SwiftUI
import TipKit

/// List of tasks with search functionality
struct TaskListView: View {
    
    @EnvironmentObject var taskService: TaskService
    @Binding var selectedTab: TaskListTab
    @ObservedObject var schedulerService: SchedulerService
    
    @State private var searchText: String = ""
    @FocusState private var isSearching: Bool

    private let listRowHorizontalInset: CGFloat = 8
    
    // Tips
    private let reviewCompletedTasksTip = ReviewCompletedTasksTip()
    
    var searchFieldColor: Color {
        return isSearching ? .accentColor.opacity(0.8) : .secondary.opacity(0.4)
    }
    
    var filteredTasks: [TaskRecord] {
        if searchText.isEmpty {
            return taskService.tasks
        } else {
            return taskService.tasks.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.taskDescription.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with tabs and search
            header
            // Task list
            if filteredTasks.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filteredTasks, id: \.id) { task in
                        TaskRowView(task: task)
                            .listRowInsets(EdgeInsets(
                                top: 4,
                                leading: -listRowHorizontalInset,
                                bottom: 4,
                                trailing: -listRowHorizontalInset
                            ))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .padding(.bottom, 6)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .contentMargins(.horizontal, 0)
                .popoverTip(reviewCompletedTasksTip, arrowEdge: .top)
            }
        }
        .padding(.horizontal, 40)
    }
    
    var header: some View {
        HStack {
            // Tab buttons
            tabButtons
            
            Spacer()
            
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($isSearching)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 200)
            .background {
                Capsule()
                    .stroke(
                        searchFieldColor,
                        lineWidth: 1
                    )
            }
        }
    }
    
    private var tabButtons: some View {
        HStack(spacing: 16) {
            Button {
                selectedTab = .tasks
            } label: {
                Text("Tasks")
                    .font(.headline)
                    .foregroundStyle(selectedTab == .tasks ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            
            Button {
                selectedTab = .scheduled
            } label: {
                HStack(spacing: 4) {
                    Text("Scheduled")
                        .font(.headline)
                        .foregroundStyle(selectedTab == .scheduled ? .primary : .secondary)
                    
                    let count = schedulerService.enabledSchedules.count
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.3))
                            .foregroundColor(.secondary)
                            .clipShape(Capsule())
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            
            Text(searchText.isEmpty ? "No tasks yet" : "No matching tasks")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            if searchText.isEmpty {
                Text("Enter a task above to get started")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

#Preview {
    TaskListView(selectedTab: .constant(.tasks), schedulerService: SchedulerService.shared)
        .environmentObject(TaskService())
        .frame(width: 600, height: 400)
}
