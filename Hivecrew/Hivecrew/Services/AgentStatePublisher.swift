//
//  AgentStatePublisher.swift
//  Hivecrew
//
//  Observable state publisher for agent execution UI updates
//

import Foundation
import AppKit
import Combine
import UserNotifications

/// Status of an agent
enum AgentStatus: String, Sendable {
    case idle = "idle"
    case connecting = "connecting"
    case running = "running"
    case paused = "paused"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}

/// A permission request for a dangerous tool operation
struct PermissionRequest: Identifiable, Sendable, Equatable {
    
    let id = UUID()
    let toolName: String
    let details: String
    let createdAt: Date = Date()
    
}

/// An entry in the agent's activity log
struct AgentActivityEntry: Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let type: ActivityType
    let summary: String
    let details: String?
    let screenshotPath: String?
    /// Reasoning/thinking content from models that support reasoning tokens (optional for backward compatibility)
    let reasoning: String?
    /// Subagent ID for subagent UI entries (optional)
    let subagentId: String?
    
    enum ActivityType: String, Sendable {
        case observation = "observation"
        case toolCall = "tool_call"
        case toolResult = "tool_result"
        case llmRequest = "llm_request"
        case llmResponse = "llm_response"
        case userQuestion = "user_question"
        case userAnswer = "user_answer"
        case error = "error"
        case info = "info"
        case subagent = "subagent"
    }
    
    init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        type: ActivityType,
        summary: String,
        details: String? = nil,
        screenshotPath: String? = nil,
        reasoning: String? = nil,
        subagentId: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.summary = summary
        self.details = details
        self.screenshotPath = screenshotPath
        self.reasoning = reasoning
        self.subagentId = subagentId
    }
}

// MARK: - Subagent Progress Models

enum SubagentStatus: String, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

enum SubagentProgressLineType: String, Sendable {
    case info
    case toolCall
    case toolResult
    case llmResponse
    case error
}

struct SubagentProgressLine: Identifiable, Sendable, Equatable {
    let id: String
    let timestamp: Date
    let type: SubagentProgressLineType
    let summary: String
    let details: String?
    
    init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        type: SubagentProgressLineType,
        summary: String,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.summary = summary
        self.details = details
    }
}

struct SubagentBoxState: Identifiable, Sendable, Equatable {
    let id: String
    let goal: String
    let purpose: String?
    let domain: String
    var status: SubagentStatus
    var currentAction: String
    var lines: [SubagentProgressLine]
}

/// Observable state for agent execution UI updates
@MainActor
class AgentStatePublisher: ObservableObject {
    /// Current step number in the agent loop
    @Published var currentStep: Int = 0
    
    /// Last screenshot captured (as NSImage for display)
    @Published var lastScreenshot: NSImage?
    
    /// Path to last screenshot file
    @Published var lastScreenshotPath: String?
    
    /// Activity log entries
    @Published var activityLog: [AgentActivityEntry] = []
    
    /// Current agent status
    @Published var status: AgentStatus = .idle
    
    /// Current tool being executed (nil if not executing)
    @Published var currentToolCall: String?
    
    /// Pending question from the agent (nil if no question)
    @Published var pendingQuestion: AgentQuestion?
    
    /// Pending permission request from the agent (nil if no request)
    @Published var pendingPermissionRequest: PermissionRequest?
    
    /// Latest prompt tokens used (includes cached tokens for some providers)
    @Published var promptTokens: Int = 0
    
    /// Latest completion tokens used
    @Published var completionTokens: Int = 0
    
    /// Latest total tokens used (actual billed tokens from API)
    @Published var totalTokens: Int = 0
    
    /// Pending instructions from the user to inject into conversation
    @Published var pendingInstructions: String?
    
    /// Current streaming reasoning text (updated as reasoning streams in)
    @Published var streamingReasoning: String = ""
    
    /// Whether reasoning is currently streaming
    @Published var isReasoningStreaming: Bool = false
    
    /// Whether the trace panel for this task is currently visible (user can answer inline)
    var isTracePanelVisible: Bool = false
    
    /// Plan progress state (for tasks with execution plans)
    @Published var planProgress: PlanState?
    
    /// Real-time subagent progress states
    @Published var subagents: [SubagentBoxState] = []
    
    /// Recent inter-agent mailbox messages for trace panel display
    @Published var recentMessages: [SubagentManager.AgentMessage] = []
    
    /// Task ID this publisher is tracking
    let taskId: String
    
    /// Task title for display purposes
    var taskTitle: String = "Agent Task"
    
    /// Session ID
    var sessionId: String?
    
    /// Continuation for waiting for question answers
    private var answerContinuation: CheckedContinuation<String, Never>?
    
    /// Continuation for waiting for permission responses
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    
    init(taskId: String, taskTitle: String = "Agent Task") {
        self.taskId = taskId
        self.taskTitle = taskTitle
    }
    
    /// Ask a question and wait for the user's answer
    func askQuestion(_ question: AgentQuestion) async -> String {
        // Set the pending question
        pendingQuestion = question
        
        // Log the question
        addActivity(AgentActivityEntry(
            type: .userQuestion,
            summary: "Agent is asking: \(question.question)"
        ))
        
        // Show floating question window over all apps (including full-screen)
        showQuestionWindow(question)
        
        // Wait for the answer using a continuation
        let answer = await withCheckedContinuation { continuation in
            self.answerContinuation = continuation
        }
        
        // Clear the question and log the answer
        pendingQuestion = nil
        addActivity(AgentActivityEntry(
            type: .userAnswer,
            summary: "User answered: \(answer)"
        ))
        
        return answer
    }
    
    /// Show a floating window for the question that appears over all apps
    /// Only shows if the trace panel (where user can answer) is not currently visible
    private func showQuestionWindow(_ question: AgentQuestion) {
        // Don't show the popup if the trace panel is visible - user can answer via the in-app UI
        guard !isTracePanelVisible else { return }
        
        QuestionWindowController.shared.showQuestion(
            question,
            taskTitle: taskTitle,
            statePublisher: self
        )
    }
    
    /// Provide an answer to the pending question
    func provideAnswer(_ answer: String) {
        guard answerContinuation != nil else { return }
        
        // Close the floating window if it's open (answer may come from in-app UI)
        QuestionWindowController.shared.closePanel()
        
        answerContinuation?.resume(returning: answer)
        answerContinuation = nil
    }
    
    /// Request permission for a dangerous operation
    func requestPermission(toolName: String, details: String) async -> Bool {
        // Set the pending permission request
        pendingPermissionRequest = PermissionRequest(toolName: toolName, details: details)
        
        // Log the permission request
        addActivity(AgentActivityEntry(
            type: .info,
            summary: "Requesting permission: \(toolName)"
        ))
        
        // Send a notification
        sendPermissionNotification(toolName: toolName, details: details)
        
        // Wait for the response
        let approved = await withCheckedContinuation { continuation in
            self.permissionContinuation = continuation
        }
        
        // Clear the request and log the response
        pendingPermissionRequest = nil
        addActivity(AgentActivityEntry(
            type: .info,
            summary: approved ? String(localized: "Permission granted: \(toolName)") : String(localized: "Permission denied: \(toolName)")
        ))
        
        return approved
    }
    
    /// Send a macOS notification for permission request
    private func sendPermissionNotification(toolName: String, details: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Permission Required")
        content.body = "\(toolName): \(details.prefix(80))..."
        content.sound = .default
        content.categoryIdentifier = "AGENT_PERMISSION"
        content.userInfo = ["taskId": taskId]
        
        let request = UNNotificationRequest(
            identifier: "agent-permission-\(taskId)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to send permission notification: \(error)")
            }
        }
    }
    
    /// Provide a response to the pending permission request
    func providePermissionResponse(_ approved: Bool) {
        guard permissionContinuation != nil else { return }
        permissionContinuation?.resume(returning: approved)
        permissionContinuation = nil
    }
    
    /// Update the screenshot
    func updateScreenshot(_ image: NSImage?, path: String?) {
        lastScreenshot = image
        lastScreenshotPath = path
    }
    
    /// Add an activity entry
    func addActivity(_ entry: AgentActivityEntry) {
        activityLog.append(entry)
        // Keep only the last 100 entries
        if activityLog.count > 100 {
            activityLog.removeFirst(activityLog.count - 100)
        }
    }
    
    /// Log an observation (screenshot)
    func logObservation(screenshotPath: String?) {
        addActivity(AgentActivityEntry(
            type: .observation,
            summary: "Captured screenshot",
            screenshotPath: screenshotPath
        ))
    }
    
    /// Log an LLM request
    func logLLMRequest(messageCount: Int, toolCount: Int) {
        addActivity(AgentActivityEntry(
            type: .llmRequest,
            summary: "Sending request to LLM",
            details: "\(messageCount) messages, \(toolCount) tools available"
        ))
    }
    
    /// Log an LLM response
    func logLLMResponse(text: String?, toolCallCount: Int, promptTokens: Int, completionTokens: Int, totalTokens: Int, reasoning: String? = nil) {
        let hasUsage = promptTokens > 0 || completionTokens > 0 || totalTokens > 0
        if hasUsage {
            // API usage already includes prior context; use latest values directly.
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            // Use API-provided totalTokens which reflects actual billed usage
            // (may differ from promptTokens + completionTokens due to caching)
            self.totalTokens = totalTokens
        }
        
        // Stop streaming when response is logged
        isReasoningStreaming = false
        
        var summary = ""
        if toolCallCount > 0 {
            summary = "LLM requested \(toolCallCount) tool call(s)"
        } else if let text = text, !text.isEmpty {
            summary = "LLM responded: \(text.prefix(100))\(text.count > 100 ? "..." : "")"
        } else {
            summary = "LLM responded (no content)"
        }
        
        // Use the streamed reasoning if available and no reasoning was passed
        let finalReasoning = reasoning ?? (streamingReasoning.isEmpty ? nil : streamingReasoning)
        
        addActivity(AgentActivityEntry(
            type: .llmResponse,
            summary: summary,
            details: "Tokens: \(totalTokens) total (\(promptTokens) prompt, \(completionTokens) completion)",
            reasoning: finalReasoning
        ))
        
        // Clear streaming reasoning after logging
        streamingReasoning = ""
    }
    
    /// Start streaming reasoning (called when LLM request begins)
    func startReasoningStream() {
        streamingReasoning = ""
        isReasoningStreaming = true
    }
    
    /// Update streaming reasoning (called as reasoning tokens arrive)
    func updateStreamingReasoning(_ reasoning: String) {
        streamingReasoning = reasoning
    }
    
    /// Log a tool call starting
    func logToolCallStart(toolName: String) {
        if toolName == "spawn_subagent" {
            // Subagent spawning has a dedicated UI box.
            currentToolCall = nil
            return
        }
        currentToolCall = toolName
        addActivity(AgentActivityEntry(
            type: .toolCall,
            summary: "Executing: \(toolName)"
        ))
    }
    
    /// Log a tool call result
    func logToolCallResult(toolName: String, success: Bool, result: String, durationMs: Int) {
        if toolName == "spawn_subagent" {
            // Subagent spawning has a dedicated UI box.
            currentToolCall = nil
            return
        }
        currentToolCall = nil
        addActivity(AgentActivityEntry(
            type: .toolResult,
            summary: success ? "✓ \(toolName) completed" : "✗ \(toolName) failed",
            details: "\(result)\n(\(durationMs)ms)"
        ))
    }
    
    /// Log an error
    func logError(_ message: String) {
        addActivity(AgentActivityEntry(
            type: .error,
            summary: "Error: \(message)"
        ))
    }
    
    /// Log an info message
    func logInfo(_ message: String) {
        addActivity(AgentActivityEntry(
            type: .info,
            summary: message
        ))
    }
    
    // MARK: - Subagent UI Updates
    
    func subagentStarted(
        id: String,
        goal: String,
        purpose: String?,
        domain: String
    ) {
        // Add activity entry (renders as a box in the trace)
        addActivity(AgentActivityEntry(
            type: .subagent,
            summary: "Subagent: \(purpose ?? id)",
            subagentId: id
        ))
        
        if let index = subagents.firstIndex(where: { $0.id == id }) {
            subagents[index] = SubagentBoxState(
                id: id,
                goal: goal,
                purpose: purpose,
                domain: domain,
                status: .running,
                currentAction: "Starting…",
                lines: subagents[index].lines
            )
        } else {
            subagents.append(SubagentBoxState(
                id: id,
                goal: goal,
                purpose: purpose,
                domain: domain,
                status: .running,
                currentAction: "Starting…",
                lines: []
            ))
        }
    }
    
    func subagentSetAction(id: String, action: String) {
        guard let index = subagents.firstIndex(where: { $0.id == id }) else { return }
        subagents[index].currentAction = action
    }
    
    func subagentAppendLine(id: String, type: SubagentProgressLineType, summary: String, details: String? = nil) {
        guard let index = subagents.firstIndex(where: { $0.id == id }) else { return }
        subagents[index].lines.append(SubagentProgressLine(type: type, summary: summary, details: details))
        // Cap to avoid unbounded growth
        if subagents[index].lines.count > 200 {
            subagents[index].lines.removeFirst(subagents[index].lines.count - 200)
        }
    }
    
    func subagentFinished(id: String, status: SubagentStatus, summary: String?) {
        guard let index = subagents.firstIndex(where: { $0.id == id }) else { return }
        subagents[index].status = status
        switch status {
        case .completed:
            subagents[index].currentAction = String(localized: "Completed")
        case .failed:
            subagents[index].currentAction = String(localized: "Failed")
        case .cancelled:
            subagents[index].currentAction = String(localized: "Cancelled")
        case .running:
            break
        }
        if let summary, !summary.isEmpty {
            subagentAppendLine(
                id: id,
                type: .info,
                summary: "Final summary",
                details: summary
            )
        }
    }
    
    // MARK: - Mailbox UI Updates
    
    func messageReceived(_ message: SubagentManager.AgentMessage) {
        recentMessages.append(message)
        // Cap to avoid unbounded growth
        if recentMessages.count > 50 {
            recentMessages.removeFirst(recentMessages.count - 50)
        }
        
        let senderLabel = message.from == "main" ? "main agent" : "subagent \(message.from.prefix(8))"
        let recipientLabel = message.to == "main" ? "main agent" : (message.to == "broadcast" ? "all agents" : "subagent \(message.to.prefix(8))")
        addActivity(AgentActivityEntry(
            type: .info,
            summary: "Mailbox: \(senderLabel) → \(recipientLabel): \(message.subject)"
        ))
    }
    
}
