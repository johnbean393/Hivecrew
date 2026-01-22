//
//  ScheduledTasksView.swift
//  Hivecrew
//
//  View for displaying and managing scheduled tasks
//

import SwiftUI
import SwiftData

/// View displaying the list of scheduled tasks
struct ScheduledTasksView: View {
    @Binding var selectedTab: TaskListTab
    @ObservedObject var schedulerService: SchedulerService
    
    @State private var searchText: String = ""
    @State private var showCreateSheet: Bool = false
    @State private var scheduleToEdit: ScheduledTask?
    @FocusState private var isSearching: Bool
    
    private var searchFieldColor: Color {
        isSearching ? .accentColor : .secondary
    }
    
    private var filteredSchedules: [ScheduledTask] {
        if searchText.isEmpty {
            return schedulerService.scheduledTasks
        } else {
            return schedulerService.scheduledTasks.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.taskDescription.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with tabs, search and add button
            header
                .padding(.horizontal, 11)
            
            // Schedule list
            if filteredSchedules.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filteredSchedules, id: \.id) { schedule in
                        ScheduledTaskRowView(
                            schedule: schedule,
                            onEdit: { scheduleToEdit = schedule },
                            onRunNow: { runNow(schedule) }
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 40)
        .sheet(isPresented: $showCreateSheet) {
            ScheduleCreationSheet()
        }
        .sheet(item: $scheduleToEdit) { schedule in
            ScheduleCreationSheet(editing: schedule)
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
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
                        searchFieldColor.opacity(0.4),
                        lineWidth: 1
                    )
            }
            
            // Add button (sized to match search bar height)
            Button {
                showCreateSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 21, height: 21)
                    .background(
                        Circle()
                            .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Create scheduled task")
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
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            
            Text(searchText.isEmpty ? "No scheduled tasks" : "No matching schedules")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            if searchText.isEmpty {
                Text("Schedule tasks to run at specific times")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                
                Button {
                    showCreateSheet = true
                } label: {
                    Label("Create Schedule", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    // MARK: - Actions
    
    private func runNow(_ schedule: ScheduledTask) {
        Task {
            await schedulerService.runNow(schedule)
        }
    }
}

// MARK: - Preview

#Preview {
    ScheduledTasksView(selectedTab: .constant(.scheduled), schedulerService: SchedulerService.shared)
        .modelContainer(for: ScheduledTask.self, inMemory: true)
        .frame(width: 600, height: 400)
}
