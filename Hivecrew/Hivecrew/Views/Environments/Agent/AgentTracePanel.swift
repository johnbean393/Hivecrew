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
                            TraceEntryView(entry: entry, statePublisher: statePublisher)
                                .id(entry.id)
                        }
                        
                        // Streaming reasoning view (shows while reasoning is being streamed)
                        if statePublisher.isReasoningStreaming && !statePublisher.streamingReasoning.isEmpty {
                            StreamingReasoningView(reasoning: statePublisher.streamingReasoning)
                                .id("streaming-reasoning")
                        }
                    }
                    .padding()
                }
                .scrollIndicators(.never)
                .onChange(of: statePublisher.activityLog.count) { oldCount, newCount in
                    if newCount > oldCount, let lastEntry = statePublisher.activityLog.last {
                        withAnimation {
                            proxy.scrollTo(lastEntry.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: statePublisher.streamingReasoning) { _, _ in
                    // Auto-scroll to bottom while reasoning is streaming
                    if statePublisher.isReasoningStreaming {
                        withAnimation {
                            proxy.scrollTo("streaming-reasoning", anchor: .bottom)
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
        .onAppear {
            // Mark trace panel as visible so floating question window doesn't appear
            statePublisher.isTracePanelVisible = true
        }
        .onDisappear {
            // Mark trace panel as not visible so floating window can appear if needed
            statePublisher.isTracePanelVisible = false
        }
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
                Image(systemName: question.isIntervention ? "hand.raised.fill" : "questionmark.bubble.fill")
                    .foregroundStyle(question.isIntervention ? .orange : .yellow)
                Text(question.isIntervention ? "Action Required:" : "Agent is asking:")
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
                case .intervention(let request):
                    interventionInput(request)
            }
        }
        .padding()
        .background((question.isIntervention ? Color.orange : Color.yellow).opacity(0.1))
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
    
    @ViewBuilder
    private func interventionInput(_ request: AgentInterventionRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let service = request.service {
                Text("Service: \(service)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Text("Please complete the action above, then click Done")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    statePublisher.provideAnswer("cancelled")
                }
                .buttonStyle(.bordered)
                
                Button("Done") {
                    statePublisher.provideAnswer("completed")
                }
                .buttonStyle(.borderedProminent)
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
                .textSelection(.enabled)
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
    @ObservedObject var statePublisher: AgentStatePublisher
    
    @State private var isExpanded: Bool = false
    @State private var isReasoningExpanded: Bool = false
    @State private var isSubagentExpanded: Bool = false
    
    var body: some View {
        if entry.type == .subagent, let subagentId = entry.subagentId {
            SubagentBoxView(
                subagentId: subagentId,
                statePublisher: statePublisher,
                isExpanded: $isSubagentExpanded
            )
        } else {
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
                    
                    // Reasoning indicator (collapsed)
                    if let reasoning = entry.reasoning, !reasoning.isEmpty, !isExpanded {
                        HStack(spacing: 4) {
                            Image(systemName: "brain")
                                .font(.caption2)
                            Text("Reasoning available")
                                .font(.caption2)
                        }
                        .foregroundStyle(.purple.opacity(0.8))
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
                
                // Reasoning section (collapsible)
                if let reasoning = entry.reasoning, !reasoning.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isReasoningExpanded.toggle()
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "brain")
                                    .font(.caption)
                                Text("Reasoning")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Spacer()
                                Image(systemName: isReasoningExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        
                        if isReasoningExpanded {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    Text(reasoning)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    
                                    // Invisible anchor at bottom
                                    Color.clear
                                        .frame(height: 1)
                                        .id("entry-reasoning-bottom")
                                }
                                .onAppear {
                                    // Scroll to bottom when expanded
                                    proxy.scrollTo("entry-reasoning-bottom", anchor: .bottom)
                                }
                            }
                            .frame(maxHeight: 200)
                            .background(Color.purple.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.top, 4)
                }
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
        case .subagent: return "person.2.fill"
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
        case .subagent: return .indigo
        }
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.timestamp)
    }
}

// MARK: - Subagent Box View

struct SubagentBoxView: View {
    let subagentId: String
    @ObservedObject var statePublisher: AgentStatePublisher
    @Binding var isExpanded: Bool
    
    private var subagent: SubagentBoxState? {
        statePublisher.subagents.first(where: { $0.id == subagentId })
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .font(.caption)
                        .frame(width: 16)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(subagent?.goal ?? "Subagent")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(isExpanded ? nil : 2)
                        
                        Text(subagent?.currentAction ?? "Working…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            
            if isExpanded {
                SubagentExpandedProgressView(lines: subagent?.lines ?? [])
                    .padding(.horizontal, 6)
            }
        }
    }
    
    private var statusIcon: String {
        switch subagent?.status {
        case .running:
            return "sparkles"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "slash.circle.fill"
        case .none:
            return "sparkles"
        }
    }
    
    private var statusColor: Color {
        switch subagent?.status {
        case .running:
            return .indigo
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        case .none:
            return .secondary
        }
    }
}

struct SubagentExpandedProgressView: View {
    let lines: [SubagentProgressLine]
    
    private let maxHeight: CGFloat = 220
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: iconName(for: line.type))
                                    .foregroundStyle(iconColor(for: line.type))
                                    .font(.caption2)
                                    .frame(width: 14)
                                
                                Text(line.summary)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                
                                Spacer()
                            }
                            
                            if let details = line.details, !details.isEmpty {
                                Text(details)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: maxHeight)
            .onChange(of: lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
    
    private func iconName(for type: SubagentProgressLineType) -> String {
        switch type {
        case .info: return "info.circle.fill"
        case .toolCall: return "hammer.fill"
        case .toolResult: return "checkmark.circle.fill"
        case .llmResponse: return "sparkles"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    
    private func iconColor(for type: SubagentProgressLineType) -> Color {
        switch type {
        case .info: return .gray
        case .toolCall: return .orange
        case .toolResult: return .green
        case .llmResponse: return .purple
        case .error: return .red
        }
    }
}

// MARK: - Streaming Reasoning View

/// View that displays streaming reasoning as it arrives in real-time
struct StreamingReasoningView: View {
    let reasoning: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header with animated indicator
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .frame(width: 16)
                
                HStack(spacing: 4) {
                    Text("Reasoning")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.purple)
                    
                    // Animated streaming indicator
                    StreamingIndicator()
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            
            // Reasoning content with auto-scroll to bottom
            ScrollViewReader { proxy in
                ScrollView {
                    Text(reasoning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Invisible anchor at bottom for scrolling
                    Color.clear
                        .frame(height: 1)
                        .id("reasoning-bottom")
                }
                .onChange(of: reasoning) { _, _ in
                    // Auto-scroll to bottom when reasoning updates
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("reasoning-bottom", anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(Color.purple.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.leading, 24)
        }
    }
}

/// Animated dots indicator for streaming
struct StreamingIndicator: View {
    @State private var animationOffset: Int = 0
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.purple)
                    .frame(width: 4, height: 4)
                    .opacity(animationOffset == index ? 1.0 : 0.3)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: false)) {
                // Start animation timer
            }
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                animationOffset = (animationOffset + 1) % 3
            }
        }
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
