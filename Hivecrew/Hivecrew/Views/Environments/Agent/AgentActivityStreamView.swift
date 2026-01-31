//
//  AgentActivityStreamView.swift
//  Hivecrew
//
//  Real-time activity log for agent execution
//

import SwiftUI

/// Real-time log of agent steps
struct AgentActivityStreamView: View {
    @ObservedObject var statePublisher: AgentStatePublisher
    @State private var selectedEntryId: String?
    @State private var isPlanProgressExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Activity")
                    .font(.headline)
                
                Spacer()
                
                // Status indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statePublisher.status.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // Step counter
                Text("Step \(statePublisher.currentStep)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Plan Progress (if task has a plan)
            if let planProgress = statePublisher.planProgress {
                PlanProgressSection(
                    planState: planProgress,
                    isExpanded: $isPlanProgressExpanded
                )
                
                Divider()
            }
            
            // Activity log
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(statePublisher.activityLog) { entry in
                            ActivityEntryRow(entry: entry, isSelected: selectedEntryId == entry.id)
                                .id(entry.id)
                                .onTapGesture {
                                    selectedEntryId = selectedEntryId == entry.id ? nil : entry.id
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: statePublisher.activityLog.count) { oldCount, newCount in
                    if newCount > oldCount, let lastEntry = statePublisher.activityLog.last {
                        withAnimation {
                            proxy.scrollTo(lastEntry.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var statusColor: Color {
        switch statePublisher.status {
        case .idle: return .gray
        case .connecting: return .yellow
        case .running: return .green
        case .paused: return .yellow
        case .completed: return .blue
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

/// Individual activity entry row
struct ActivityEntryRow: View {
    let entry: AgentActivityEntry
    let isSelected: Bool
    
    private var iconName: String {
        switch entry.type {
        case .observation: return "camera"
        case .toolCall: return "hammer"
        case .toolResult: return "checkmark.circle"
        case .llmRequest: return "arrow.up.circle"
        case .llmResponse: return "arrow.down.circle"
        case .userQuestion: return "questionmark.circle"
        case .userAnswer: return "person.circle"
        case .error: return "exclamationmark.triangle"
        case .info: return "info.circle"
        }
    }
    
    private var iconColor: Color {
        switch entry.type {
        case .observation: return .blue
        case .toolCall: return .orange
        case .toolResult: return .green
        case .llmRequest: return .purple
        case .llmResponse: return .purple
        case .userQuestion: return .yellow
        case .userAnswer: return .cyan
        case .error: return .red
        case .info: return .gray
        }
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.timestamp)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Main row
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.caption)
                    .frame(width: 16)
                
                Text(timeString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 60, alignment: .leading)
                
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(isSelected ? nil : 1)
                
                Spacer()
            }
            
            // Expanded details
            if isSelected, let details = entry.details {
                Text(details)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 84)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Plan Progress Section

/// Collapsible section showing plan progress
struct PlanProgressSection: View {
    let planState: PlanState
    @Binding var isExpanded: Bool
    
    private var completionPercentage: Int {
        Int(planState.completionPercentage * 100)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (always visible)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    
                    Image(systemName: "list.bullet.clipboard")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    
                    Text("Plan Progress")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    // Completion badge
                    Text("\(planState.completedCount)/\(planState.items.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.15))
                        )
                    
                    // Progress bar
                    ProgressView(value: planState.completionPercentage)
                        .frame(width: 50)
                    
                    Text("\(completionPercentage)%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            
            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(planState.items) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: itemIcon(for: item))
                                .font(.caption2)
                                .foregroundStyle(itemColor(for: item))
                                .frame(width: 12)
                            
                            Text(item.content)
                                .font(.caption2)
                                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                                .strikethrough(item.isCompleted)
                                .lineLimit(2)
                            
                            Spacer()
                            
                            if item.addedDuringExecution {
                                Text("added")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    
                    // Deviations
                    if !planState.deviations.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                        
                        Text("Deviations: \(planState.deviations.count)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
    
    private func itemIcon(for item: PlanTodoItem) -> String {
        if item.isCompleted {
            return "checkmark.circle.fill"
        } else if item.wasSkipped {
            return "arrow.right.circle"
        } else {
            return "circle"
        }
    }
    
    private func itemColor(for item: PlanTodoItem) -> Color {
        if item.isCompleted {
            return .green
        } else if item.wasSkipped {
            return .orange
        } else {
            return .secondary
        }
    }
}

#Preview {
    let publisher = AgentStatePublisher(taskId: "test")
    publisher.status = .running
    publisher.currentStep = 5
    publisher.addActivity(AgentActivityEntry(type: .observation, summary: "Captured screenshot"))
    publisher.addActivity(AgentActivityEntry(type: .llmRequest, summary: "Sending request to LLM"))
    publisher.addActivity(AgentActivityEntry(type: .llmResponse, summary: "LLM requested 2 tool calls", details: "Tokens: +150 prompt, +45 completion"))
    publisher.addActivity(AgentActivityEntry(type: .toolCall, summary: "Executing: mouse_click"))
    publisher.addActivity(AgentActivityEntry(type: .toolResult, summary: "✓ mouse_click", details: "Clicked at (500, 300)\n(45ms)"))
    publisher.addActivity(AgentActivityEntry(type: .error, summary: "Error: Connection timeout"))
    
    // Add sample plan progress
    publisher.planProgress = PlanState(items: [
        PlanTodoItem(content: "Research AI trends", isCompleted: true),
        PlanTodoItem(content: "Create presentation outline", isCompleted: true),
        PlanTodoItem(content: "Design slides", isCompleted: false),
        PlanTodoItem(content: "Export to outbox", isCompleted: false)
    ])
    
    return AgentActivityStreamView(statePublisher: publisher)
        .frame(width: 400, height: 400)
}
