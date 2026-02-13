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
