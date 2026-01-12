//
//  AgentTracePanel.swift
//  Hivecrew
//
//  Right-side panel showing agent trace with screenshots and reasoning
//  Inspired by Bytebot's trace display design
//

import SwiftUI
import AppKit

/// Right-side panel showing agent trace with task, screenshots, and activity
struct AgentTracePanel: View {
    @ObservedObject var statePublisher: AgentStatePublisher
    let taskTitle: String
    let taskDescription: String
    @State private var selectedEntryId: String?
    @State private var textAnswer: String = ""
    @State private var instructionText: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Task header
            taskHeader
            
            Divider()
            
            // Trace content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(statePublisher.activityLog) { entry in
                            TraceEntryView(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: statePublisher.activityLog.count) { oldCount, newCount in
                    if newCount > oldCount, let lastEntry = statePublisher.activityLog.last {
                        withAnimation {
                            proxy.scrollTo(lastEntry.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            // Pending question UI (if any)
            if let question = statePublisher.pendingQuestion {
                Divider()
                questionInputView(question)
            }
            
            // Instruction input bar (when agent is running)
            if statePublisher.status == .running || statePublisher.status == .paused {
                Divider()
                instructionInputBar
            }
            
            Divider()
            
            // Status footer
            statusFooter
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Instruction Input Bar
    
    private var instructionInputBar: some View {
        HStack(spacing: 8) {
            TextField("Add instructions...", text: $instructionText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    submitInstruction()
                }
            
            Button(action: submitInstruction) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(instructionText.isEmpty ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    private func submitInstruction() {
        let instruction = instructionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        
        // Set pending instructions on state publisher
        statePublisher.pendingInstructions = instruction
        statePublisher.logInfo("User added instruction: \(instruction)")
        
        instructionText = ""
    }
    
    // MARK: - Question Input View
    
    @ViewBuilder
    private func questionInputView(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Question header
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.yellow)
                Text("Agent is asking:")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            
            // Question text
            Text(question.question)
                .font(.body)
                .foregroundStyle(.primary)
            
            // Answer input based on question type
            switch question {
            case .text:
                textQuestionInput()
            case .multipleChoice(let mcQuestion):
                multipleChoiceInput(mcQuestion)
            }
        }
        .padding()
        .background(Color.yellow.opacity(0.1))
    }
    
    @ViewBuilder
    private func textQuestionInput() -> some View {
        HStack {
            TextField("Type your answer...", text: $textAnswer)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    submitTextAnswer()
                }
            
            Button("Send") {
                submitTextAnswer()
            }
            .buttonStyle(.borderedProminent)
            .disabled(textAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    
    private func submitTextAnswer() {
        let answer = textAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        statePublisher.provideAnswer(answer)
        textAnswer = ""
    }
    
    @ViewBuilder
    private func multipleChoiceInput(_ question: AgentMultipleChoiceQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button(action: {
                    statePublisher.provideAnswer(option)
                }) {
                    HStack {
                        Text("\(index + 1). \(option)")
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Task Header
    
    private var taskHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status badge
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(statusColor)
                
                Spacer()
                
                // Step counter
                if statePublisher.currentStep > 0 {
                    Text("Step \(statePublisher.currentStep)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(Capsule())
                }
            }
            
            // Task icon and description
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(taskTitle)
                        .font(.headline)
                        .lineLimit(2)
                    
                    if !taskDescription.isEmpty && taskDescription != taskTitle {
                        Text(taskDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        .padding()
    }
    
    // MARK: - Status Footer
    
    private var statusFooter: some View {
        HStack(spacing: 16) {
            // Token usage
            if statePublisher.totalTokens > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "textformat.123")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(formatNumber(statePublisher.totalTokens)) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Current tool indicator
            if let tool = statePublisher.currentToolCall {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                    Text(tool)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Helpers
    
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
    
    private var statusText: String {
        switch statePublisher.status {
        case .idle: return "Idle"
        case .connecting: return "Connecting..."
        case .running: return "Running"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
    
    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }
}

// MARK: - Trace Entry View

/// Individual trace entry row - matches the design from SessionTraceView
struct TraceEntryView: View {
    let entry: AgentActivityEntry
    
    @State private var isExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Main row
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.summary)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(isExpanded ? nil : 2)
                    
                    if let details = entry.details, !details.isEmpty {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                    }
                }
                
                Spacer()
                
                // Timestamp
                Text(timeString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
            
            // Expanded details view
            if isExpanded {
                if let details = entry.details, !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(.leading, 24)
                }
            }
        }
    }
    
    // MARK: - Styling
    
    private var iconName: String {
        switch entry.type {
        case .observation: return "camera.fill"
        case .toolCall: return "hammer.fill"
        case .toolResult: return "checkmark.circle.fill"
        case .llmRequest: return "arrow.up.circle.fill"
        case .llmResponse: return "sparkles"
        case .userQuestion: return "questionmark.bubble.fill"
        case .userAnswer: return "person.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
    
    private var iconColor: Color {
        switch entry.type {
        case .observation: return .cyan
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
}

// MARK: - Preview

#Preview {
    let publisher = AgentStatePublisher(taskId: "test")
    publisher.status = .running
    publisher.currentStep = 3
    publisher.promptTokens = 1250
    publisher.completionTokens = 350
    
    publisher.addActivity(AgentActivityEntry(
        type: .observation,
        summary: "Screenshot taken",
        screenshotPath: nil
    ))
    publisher.addActivity(AgentActivityEntry(
        type: .llmResponse,
        summary: "Perfect! I can see \"google.com\" has been typed in the address bar and Firefox is showing suggestions.",
        details: "I can see the first suggestion is \"www.google.com — Visit\" highlighted in blue. Now I'll press Enter to navigate to Google."
    ))
    publisher.addActivity(AgentActivityEntry(
        type: .toolCall,
        summary: "Executing: keyboard_key"
    ))
    publisher.addActivity(AgentActivityEntry(
        type: .toolResult,
        summary: "✓ keyboard_key",
        details: "Keys: Return"
    ))
    publisher.addActivity(AgentActivityEntry(
        type: .observation,
        summary: "Screenshot taken"
    ))
    publisher.addActivity(AgentActivityEntry(
        type: .llmResponse,
        summary: "Perfect! I have successfully opened Firefox and navigated to google.com. The page is now fully loaded.",
        details: "• The iconic Google logo in the center\n• The search bar below the logo\n• Various options like \"Google 搜尋\" (Google Search)"
    ))
    
    return AgentTracePanel(
        statePublisher: publisher,
        taskTitle: "Open Firefox and go to google.com",
        taskDescription: "Navigate to Google homepage using Firefox browser"
    )
    .frame(height: 600)
}
