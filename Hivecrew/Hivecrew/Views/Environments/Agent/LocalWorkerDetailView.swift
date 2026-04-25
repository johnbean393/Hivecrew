//
//  LocalWorkerDetailView.swift
//  Hivecrew
//
//  Full-screen trace view for Fast Worker and App Worker tasks (no VM display)
//

import SwiftUI
import HivecrewCore

struct LocalWorkerDetailView: View {
    let task: TaskRecord
    @ObservedObject var statePublisher: AgentStatePublisher

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(statePublisher.activityLog) { entry in
                            TraceEntryView(entry: entry, statePublisher: statePublisher)
                                .id(entry.id)
                        }

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
                        withAnimation { proxy.scrollTo(lastEntry.id, anchor: .bottom) }
                    }
                }
                .onChange(of: statePublisher.streamingReasoning) { _, _ in
                    if statePublisher.isReasoningStreaming {
                        withAnimation { proxy.scrollTo("streaming-reasoning", anchor: .bottom) }
                    }
                }
            }

            if let question = statePublisher.pendingQuestion {
                Divider()
                QuestionInputView(question: question, statePublisher: statePublisher)
            }

            if statePublisher.status == .running || statePublisher.status == .paused {
                Divider()
                InstructionInputBar(statePublisher: statePublisher)
            }

            Divider()
            statusFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { statePublisher.isTracePanelVisible = true }
        .onDisappear { statePublisher.isTracePanelVisible = false }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                runtimeBadge
                Spacer()
                statusBadge
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

            Text(task.title)
                .font(.headline)
                .lineLimit(2)
                .textSelection(.enabled)

            if !task.taskDescription.isEmpty && task.taskDescription != task.title {
                Text(task.taskDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var runtimeBadge: some View {
        let kind = task.assignedRuntimeKind ?? .fast
        HStack(spacing: 4) {
            Image(systemName: kind.iconName)
                .font(.caption2)
            Text(kind.displayName)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(kind.badgeColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(kind.badgeColor.opacity(0.12))
        .clipShape(Capsule())
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(statusColor)
        }
    }

    // MARK: - Footer

    private var statusFooter: some View {
        HStack(spacing: 16) {
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
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000.0) : "\(n)"
    }
}

// MARK: - Reusable sub-views extracted from AgentTracePanel

struct QuestionInputView: View {
    let question: AgentQuestion
    @ObservedObject var statePublisher: AgentStatePublisher
    @State private var textAnswer: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: question.isIntervention ? "hand.raised.fill" : "questionmark.bubble.fill")
                    .foregroundStyle(question.isIntervention ? .orange : .yellow)
                Text(question.isIntervention ? "Action Required:" : "Agent is asking:")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Text(question.question)
                .font(.body)
                .foregroundStyle(.primary)

            switch question {
            case .text:
                HStack {
                    TextField("Type your answer...", text: $textAnswer)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitTextAnswer() }
                    Button("Send") { submitTextAnswer() }
                        .buttonStyle(.borderedProminent)
                        .disabled(textAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            case .multipleChoice(let mcQuestion):
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(mcQuestion.options.enumerated()), id: \.offset) { index, option in
                        Button { statePublisher.provideAnswer(option) } label: {
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
            case .intervention:
                HStack(spacing: 12) {
                    Button("Cancel") { statePublisher.provideAnswer("cancelled") }
                        .buttonStyle(.bordered)
                    Button("Done") { statePublisher.provideAnswer("completed") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .background((question.isIntervention ? Color.orange : Color.yellow).opacity(0.1))
    }

    private func submitTextAnswer() {
        let answer = textAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        statePublisher.provideAnswer(answer)
        textAnswer = ""
    }
}

struct InstructionInputBar: View {
    @ObservedObject var statePublisher: AgentStatePublisher
    @State private var instructionText: String = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Add instructions...", text: $instructionText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitInstruction() }

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
        statePublisher.pendingInstructions = instruction
        statePublisher.logInfo("User added instruction: \(instruction)")
        instructionText = ""
    }
}

// MARK: - AgentRuntimeKind UI helpers

extension AgentRuntimeKind {
    var iconName: String {
        switch self {
        case .fast: return "bolt.fill"
        case .app: return "macwindow"
        case .isolatedVM: return "desktopcomputer"
        }
    }

    var badgeColor: Color {
        switch self {
        case .fast: return .orange
        case .app: return .purple
        case .isolatedVM: return .blue
        }
    }
}
