//
//  AgentQuestionSheet.swift
//  Hivecrew
//
//  Modal sheet for displaying agent questions and collecting user responses
//

import SwiftUI

/// Sheet for displaying and answering agent questions
struct AgentQuestionSheet: View {
    let question: AgentQuestion
    let onAnswer: (String) -> Void
    let onDismiss: () -> Void
    
    @State private var textAnswer: String = ""
    @State private var selectedOptionIndex: Int?
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            headerView
            
            // Question content
            Text(question.question)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal)
            
            // Answer input
            answerInputView
            
            // Action buttons
            actionButtons
        }
        .padding(32)
        .frame(width: 400)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            
            Text("Agent Question")
                .font(.headline)
        }
    }
    
    // MARK: - Answer Input
    
    @ViewBuilder
    private var answerInputView: some View {
        switch question {
        case .text:
            textQuestionInput
        case .multipleChoice(let mcQuestion):
            MultipleChoiceInputView(
                options: mcQuestion.options,
                selectedIndex: $selectedOptionIndex
            )
        }
    }
    
    // MARK: - Text Question Input
    
    private var textQuestionInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your answer:")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            TextEditor(text: $textAnswer)
                .font(.body)
                .frame(height: 100)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
        .padding(.horizontal)
    }
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Skip") {
                onAnswer("(User skipped this question)")
                onDismiss()
            }
            .buttonStyle(.bordered)
            
            Button("Submit") {
                submitAnswer()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
        }
    }
    
    // MARK: - Helpers
    
    private var canSubmit: Bool {
        switch question {
        case .text:
            return !textAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .multipleChoice:
            return selectedOptionIndex != nil
        }
    }
    
    private func submitAnswer() {
        let answer: String
        switch question {
        case .text:
            answer = textAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        case .multipleChoice(let mcQuestion):
            if let index = selectedOptionIndex, index < mcQuestion.options.count {
                answer = mcQuestion.options[index]
            } else {
                return
            }
        }
        
        onAnswer(answer)
        onDismiss()
    }
}

// MARK: - Multiple Choice Input View

/// Separate view for multiple choice input to help compiler type-checking
struct MultipleChoiceInputView: View {
    let options: [String]
    @Binding var selectedIndex: Int?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select an option:")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            VStack(spacing: 4) {
                ForEach(0..<options.count, id: \.self) { index in
                    optionButton(index: index, option: options[index])
                }
            }
        }
        .padding(.horizontal)
    }
    
    private func optionButton(index: Int, option: String) -> some View {
        let isSelected = selectedIndex == index
        return Button(action: { selectedIndex = index }) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(option)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(optionBackground(isSelected: isSelected))
            .overlay(optionBorder(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }
    
    private func optionBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
    }
    
    private func optionBorder(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
    }
}

// MARK: - View Modifier

/// View modifier to show agent question sheet
struct AgentQuestionModifier: ViewModifier {
    @Binding var question: AgentQuestion?
    let onAnswer: (String) -> Void
    
    func body(content: Content) -> some View {
        content
            .sheet(item: $question) { q in
                AgentQuestionSheet(
                    question: q,
                    onAnswer: onAnswer,
                    onDismiss: { question = nil }
                )
            }
    }
}

extension View {
    func agentQuestionSheet(_ question: Binding<AgentQuestion?>, onAnswer: @escaping (String) -> Void) -> some View {
        modifier(AgentQuestionModifier(question: question, onAnswer: onAnswer))
    }
}

// MARK: - Previews

#Preview("Text Question") {
    AgentQuestionSheet(
        question: .text(AgentTextQuestion(
            taskId: "test",
            question: "What is the name of the project you want to create?"
        )),
        onAnswer: { print("Answer: \($0)") },
        onDismiss: {}
    )
}

#Preview("Multiple Choice") {
    AgentQuestionSheet(
        question: .multipleChoice(AgentMultipleChoiceQuestion(
            taskId: "test",
            question: "Which format would you like for the output?",
            options: ["PDF", "Word Document", "Plain Text", "Markdown"]
        )),
        onAnswer: { print("Answer: \($0)") },
        onDismiss: {}
    )
}
