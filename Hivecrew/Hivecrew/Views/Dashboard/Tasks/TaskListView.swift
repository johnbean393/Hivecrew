//
//  TaskListView.swift
//  Hivecrew
//
//  Searchable list of tasks with status indicators
//

import SwiftUI

/// List of tasks with search functionality
struct TaskListView: View {
    
    @EnvironmentObject var taskService: TaskService
    @State private var searchText: String = ""
    @FocusState private var isSearching: Bool
    
    var searchFieldColor: Color {
        return self.isSearching ? .accentColor : .secondary
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
        VStack(alignment: .leading, spacing: 12) {
            // Header with search
            header
                .padding(.horizontal, 11)
            // Task list
            if filteredTasks.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filteredTasks, id: \.id) { task in
                        TaskRowView(task: task)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.horizontal, 40)
    }
    
    var header: some View {
        HStack {
            Text("Tasks")
                .font(.headline)
                .foregroundStyle(.primary)
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
                        searchFieldColor.opacity(0.4),
                        lineWidth: 1
                    )
            }
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
    TaskListView()
        .environmentObject(TaskService())
        .frame(width: 600, height: 400)
}
