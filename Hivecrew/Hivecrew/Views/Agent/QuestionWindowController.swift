//
//  QuestionWindowController.swift
//  Hivecrew
//
//  Floating window controller for displaying agent questions over all apps
//

import AppKit
import SwiftUI

// MARK: - Custom Panel

/// Custom NSPanel subclass that can become key even when borderless
/// This allows text input to work in a borderless floating panel
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Controller for a floating question window that appears over all apps, including full-screen
@MainActor
final class QuestionWindowController {
    
    // MARK: - Singleton
    
    static let shared = QuestionWindowController()
    
    // MARK: - Properties
    
    private var panel: NSPanel?
    private var currentQuestion: AgentQuestion?
    private weak var statePublisher: AgentStatePublisher?
    private var taskTitle: String = ""
    
    private init() {}
    
    // MARK: - Public API
    
    /// Show a question in a floating window
    /// - Parameters:
    ///   - question: The question to display
    ///   - taskTitle: The title of the task asking the question
    ///   - statePublisher: The state publisher to send the answer to
    func showQuestion(_ question: AgentQuestion, taskTitle: String, statePublisher: AgentStatePublisher) {
        // Store the current state
        currentQuestion = question
        self.statePublisher = statePublisher
        self.taskTitle = taskTitle
        
        // Close any existing panel
        closePanel(clearState: false)
        
        // Create and configure the panel
        let panel = createPanel(for: question, taskTitle: taskTitle)
        self.panel = panel
        
        // Center the panel on the screen
        centerPanel(panel)
        
        // Show the panel and make it key (for text input) without activating the app
        panel.orderFrontRegardless()
        panel.makeKey()
    }
    
    /// Close the question window
    func closePanel(clearState: Bool = true) {
        panel?.close()
        panel = nil
        if clearState {
            currentQuestion = nil
            statePublisher = nil
            taskTitle = ""
        }
    }
    
    // MARK: - Panel Creation
    
    private func createPanel(for question: AgentQuestion, taskTitle: String) -> NSPanel {
        // Create the SwiftUI view
        let questionView = FloatingQuestionView(
            question: question,
            taskTitle: taskTitle,
            onAnswer: { [weak self] answer in
                self?.handleAnswer(answer)
            },
            onSkip: { [weak self] in
                self?.handleAnswer("(User skipped this question)")
            }
        )
        
        // Create the hosting view
        let hostingView = NSHostingView(rootView: questionView)
        hostingView.setFrameSize(hostingView.fittingSize)
        
        // Calculate panel size based on content
        let contentSize = hostingView.fittingSize
        let panelSize = NSSize(
            width: max(contentSize.width, 420),
            height: max(contentSize.height, 200)
        )
        
        // Create the panel with our custom KeyablePanel that allows text input
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Configure panel for floating over all apps including full-screen
        // Use .screenSaver level to ensure it appears above full-screen apps
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [
            .canJoinAllSpaces,        // Appear on all spaces
            .fullScreenAuxiliary,     // Appear over full-screen apps
            .stationary               // Stay in place during Exposé
        ]
        
        // Additional configuration
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        
        // Set up the content view with visual effect background
        let visualEffectView = NSVisualEffectView()
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 12
        visualEffectView.layer?.masksToBounds = true
        
        // Add the hosting view to the visual effect view
        visualEffectView.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])
        
        panel.contentView = visualEffectView
        
        // Recalculate size after setting content
        let finalSize = hostingView.fittingSize
        panel.setContentSize(NSSize(
            width: max(finalSize.width, 420),
            height: max(finalSize.height, 200)
        ))
        
        return panel
    }
    
    private func centerPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        
        let screenFrame = screen.visibleFrame
        let panelFrame = panel.frame
        
        let x = screenFrame.midX - panelFrame.width / 2
        let y = screenFrame.midY - panelFrame.height / 2 + 100 // Slightly above center
        
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    private func handleAnswer(_ answer: String) {
        // Directly call provideAnswer on the state publisher
        // This ensures proper @MainActor isolation
        statePublisher?.provideAnswer(answer)
        closePanel()
    }
}

// MARK: - Floating Question View

/// SwiftUI view for the floating question panel
private struct FloatingQuestionView: View {
    let question: AgentQuestion
    let taskTitle: String
    let onAnswer: (String) -> Void
    let onSkip: () -> Void
    
    @State private var textAnswer: String = ""
    @State private var selectedOptionIndex: Int?
    
    var body: some View {
        VStack(spacing: 16) {
            // Header with task title
            headerView
            
            // Question text
            Text(question.question)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
            
            // Answer input
            answerInputView
            
            // Action buttons
            actionButtons
            
            // Footer with context
            footerView
        }
        .padding(24)
        .frame(width: 400)
        .background(Color.clear)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                
                Text(taskTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }
    
    // MARK: - Footer
    
    private var footerView: some View {
        Text("Agent is waiting for your response")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    
    // MARK: - Answer Input
    
    @ViewBuilder
    private var answerInputView: some View {
        switch question {
        case .text:
            textQuestionInput
        case .multipleChoice(let mcQuestion):
            multipleChoiceInput(options: mcQuestion.options)
        }
    }
    
    private var textQuestionInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your answer:")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            TextEditor(text: $textAnswer)
                .font(.body)
                .frame(height: 80)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }
    
    private func multipleChoiceInput(options: [String]) -> some View {
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
    }
    
    private func optionButton(index: Int, option: String) -> some View {
        let isSelected = selectedOptionIndex == index
        return Button(action: { selectedOptionIndex = index }) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(option)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Skip") {
                onSkip()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape, modifiers: [])
            
            Button("Submit") {
                submitAnswer()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: [])
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
    }
}
