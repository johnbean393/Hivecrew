//
//  ScheduledTaskRowView.swift
//  Hivecrew
//
//  Row view for displaying a scheduled task in a list
//

import SwiftUI
import TipKit
import Combine

/// Row view for a scheduled task
struct ScheduledTaskRowView: View {
    @EnvironmentObject var schedulerService: SchedulerService
    
    let schedule: ScheduledTask
    let onEdit: () -> Void
    let onRunNow: () -> Void
    
    @State private var isHovered: Bool = false
    @State private var currentDate: Date = Date()
    
    // Tips
    private let scheduleRunNowTip = ScheduleRunNowTip()
    
    // Timer that fires every second to update countdown
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    private var statusColor: Color {
        if !schedule.isEnabled {
            return .secondary
        }
        if schedule.scheduleType == .oneTime && schedule.hasExpired {
            return .orange
        }
        return .green
    }
    
    private var nextRunText: String {
        guard schedule.isEnabled else { return "Disabled" }
        
        if schedule.scheduleType == .oneTime && schedule.hasExpired {
            return "Expired"
        }
        
        guard let nextRun = schedule.nextRunAt else {
            return "Not scheduled"
        }
        
        // Calculate time remaining
        let timeInterval = nextRun.timeIntervalSince(currentDate)
        
        if timeInterval <= 0 {
            return "Running soon..."
        }
        
        // Format as human-readable countdown
        let totalSeconds = Int(timeInterval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if hours > 0 {
            return "in \(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "in \(minutes)m \(seconds)s"
        } else {
            return "in \(seconds)s"
        }
    }
    
    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(statusColor.opacity(0.3), lineWidth: 2)
                    )
                
                // Main content
                VStack(alignment: .leading, spacing: 2) {
                    // Title
                    Text(schedule.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundStyle(schedule.isEnabled ? .primary : .secondary)
                    
                    // Status line
                    HStack(spacing: 6) {
                        // Schedule type badge
                        Text(schedule.scheduleType.displayName)
                            .font(.caption)
                            .foregroundStyle(schedule.isEnabled ? Color.accentColor : Color.secondary)
                        
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        
                        // Schedule details
                        Text(schedule.scheduleDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    
                    // Next run time
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("Next: \(nextRunText)")
                            .font(.caption)
                    }
                    .foregroundStyle(.tertiary)
                }
                
                Spacer()
                
                // Actions (shown on hover)
                if isHovered {
                    HStack(spacing: 8) {
                        // Enable/Disable toggle
                        Toggle("", isOn: Binding(
                            get: { schedule.isEnabled },
                            set: { _ in toggleEnabled() }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        
                        // Run now button
                        if schedule.isEnabled {
                            Button {
                                onRunNow()
                            } label: {
                                Image(systemName: "play.fill")
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.plain)
                            .help("Run now")
                            .popoverTip(scheduleRunNowTip, arrowEdge: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Button(role: .destructive) {
                deleteSchedule()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            
            if schedule.isEnabled {
                Button {
                    onRunNow()
                } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
            }
            
            Divider()
            
            Button {
                toggleEnabled()
            } label: {
                Label(schedule.isEnabled ? "Disable" : "Enable", systemImage: schedule.isEnabled ? "pause.circle" : "play.circle")
            }
            
            Divider()
            
            Button(role: .destructive) {
                deleteSchedule()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onReceive(timer) { _ in
            currentDate = Date()
        }
    }
    
    // MARK: - Actions
    
    private func toggleEnabled() {
        do {
            try schedulerService.toggleScheduledTask(schedule)
        } catch {
            print("Failed to toggle schedule: \(error)")
        }
    }
    
    private func deleteSchedule() {
        do {
            try schedulerService.deleteScheduledTask(schedule)
        } catch {
            print("Failed to delete schedule: \(error)")
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 8) {
        ScheduledTaskRowView(
            schedule: ScheduledTask(
                title: "Daily Research Task",
                taskDescription: "Research the latest AI developments",
                providerId: "provider-1",
                modelId: "gpt-5.2",
                scheduleType: .recurring,
                recurrenceRule: .daily(at: 9, minute: 0)
            ),
            onEdit: {},
            onRunNow: {}
        )
        
        ScheduledTaskRowView(
            schedule: ScheduledTask(
                title: "Weekly Report",
                taskDescription: "Generate weekly report",
                providerId: "provider-1",
                modelId: "gpt-5.2",
                scheduleType: .recurring,
                recurrenceRule: .weekly(on: [2, 4, 6], at: 10, minute: 30)
            ),
            onEdit: {},
            onRunNow: {}
        )
    }
    .padding()
    .environmentObject(SchedulerService.shared)
}
