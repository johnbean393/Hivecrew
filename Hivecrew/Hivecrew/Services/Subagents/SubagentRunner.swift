//
//  SubagentRunner.swift
//  Hivecrew
//
//  Runs a background LLM-driven subagent with restricted tools.
//

import Foundation
import HivecrewLLM

@MainActor
final class SubagentRunner {
    static let finalReportToolName = "submit_final_report"

    enum CompletionStatus: String, Sendable {
        case success
        case failed
    }

    struct Result: Sendable {
        let status: CompletionStatus
        let summary: String
        let details: String?
        let failureReason: String?
    }

    private struct FinalReportPayload: Decodable {
        struct TodoItem: Decodable {
            let index: Int
            let completed: Bool
        }

        let status: String
        let todoItems: [TodoItem]
        let report: String
        let failureReason: String?
    }
    
    struct ProgressLine: Sendable {
        let type: SubagentProgressLineType
        let summary: String
        let details: String?
    }
    
    private let subagentId: String
    private let goal: String
    private let domain: SubagentDomain
    private let toolAllowlist: [String]
    private let todoItems: [String]
    private let llmClient: any LLMClientProtocol
    private let tracer: AgentTracer
    private let toolExecutor: SubagentToolExecutor
    private let tools: [LLMToolDefinition]
    private let maxIterations: Int
    private let maxLLMRetries = 3
    private let onActionUpdate: (@MainActor (String) -> Void)?
    private let onLine: (@MainActor (ProgressLine) -> Void)?
    private let drainMessages: (@MainActor () -> [SubagentManager.AgentMessage])?
    private var incompleteTodoRetryCount = 0
    private let maxIncompleteTodoRetries = 3
    private var consecutiveNoToolCalls = 0
    private let maxContinueNudges = 3
    private let maxReportNudges = 2
    
    init(
        subagentId: String,
        goal: String,
        domain: SubagentDomain,
        toolAllowlist: [String],
        todoItems: [String],
        llmClient: any LLMClientProtocol,
        tracer: AgentTracer,
        toolExecutor: SubagentToolExecutor,
        tools: [LLMToolDefinition],
        maxIterations: Int = 50,
        onActionUpdate: (@MainActor (String) -> Void)? = nil,
        onLine: (@MainActor (ProgressLine) -> Void)? = nil,
        drainMessages: (@MainActor () -> [SubagentManager.AgentMessage])? = nil
    ) {
        self.subagentId = subagentId
        self.goal = goal
        self.domain = domain
        self.toolAllowlist = toolAllowlist
        self.todoItems = todoItems
        self.llmClient = llmClient
        self.tracer = tracer
        self.toolExecutor = toolExecutor
        self.tools = Self.withFinalReportTool(tools)
        self.maxIterations = maxIterations
        self.onActionUpdate = onActionUpdate
        self.onLine = onLine
        self.drainMessages = drainMessages
    }
    
    func run() async throws -> Result {
        var messages: [LLMMessage] = [
            .system(systemPrompt()),
            .user(goal)
        ]
        
        var iteration = 0
        var consecutiveLLMFailures = 0
        var lastResponseText: String?
        var lastStreamedText: String = ""
        
        while iteration < maxIterations {
            iteration += 1
            await tracer.nextStep()
            
            // Auto-inject any pending mailbox messages before the LLM call
            if let drain = drainMessages {
                let incoming = drain()
                for msg in incoming {
                    let senderLabel = msg.from == "main" ? "main agent" : "subagent \(msg.from)"
                    messages.append(.user(
                        "[Message from \(senderLabel)] Subject: \(msg.subject)\n\(msg.body)"
                    ))
                    onLine?(ProgressLine(
                        type: .info,
                        summary: "Mailbox: received message from \(senderLabel)",
                        details: "Subject: \(msg.subject)"
                    ))
                }
            }
            
            onActionUpdate?("Thinking…")
            try? await tracer.logLLMRequest(
                messageCount: messages.count,
                toolCount: tools.count,
                model: llmClient.configuration.model
            )
            
            // LLM call with retry
            let start = Date()
            lastStreamedText = ""
            let response: LLMResponse
            do {
                response = try await llmClient.chatWithStreaming(
                    messages: messages,
                    tools: tools,
                    onReasoningUpdate: { _ in },
                    onContentUpdate: { content in
                        lastStreamedText = content
                    }
                )
                consecutiveLLMFailures = 0
            } catch {
                consecutiveLLMFailures += 1
                let errorMsg = error.localizedDescription
                onLine?(ProgressLine(
                    type: .error,
                    summary: "LLM call failed (\(consecutiveLLMFailures)/\(maxLLMRetries))",
                    details: errorMsg
                ))
                if consecutiveLLMFailures >= maxLLMRetries {
                    return Result(
                        status: .failed,
                        summary: "LLM call failed \(maxLLMRetries) times consecutively.",
                        details: nil,
                        failureReason: errorMsg
                    )
                }
                // Brief backoff before retry
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(consecutiveLLMFailures))) * 1_000_000_000)
                continue
            }
            
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            lastResponseText = (response.text?.isEmpty == false) ? response.text : lastStreamedText
            if let text = lastResponseText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onLine?(ProgressLine(
                    type: .llmResponse,
                    summary: "LLM response",
                    details: text
                ))
            }
            
            try? await tracer.logLLMResponse(response, latencyMs: latencyMs)
            
            // If the LLM returned tool calls, process them
            if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                consecutiveNoToolCalls = 0
                messages.append(.assistant(response.text ?? "", toolCalls: toolCalls))
                
                for toolCall in toolCalls {
                    try? await tracer.logToolCall(toolCall)
                    onActionUpdate?("Executing: \(toolCall.function.name)")
                    onLine?(ProgressLine(
                        type: .toolCall,
                        summary: "Executing: \(toolCall.function.name)",
                        details: "Args: \(toolCall.function.arguments)"
                    ))

                    if toolCall.function.name == Self.finalReportToolName {
                        if let result = handleFinalReportToolCall(toolCall, messages: &messages) {
                            let isSuccess = result.status == .success
                            try? await tracer.logToolResult(
                                toolCallId: toolCall.id,
                                toolName: toolCall.function.name,
                                success: isSuccess,
                                result: result.summary,
                                errorMessage: isSuccess ? nil : result.failureReason,
                                latencyMs: nil
                            )
                            return result
                        }
                        continue
                    }
                    
                    let result: SubagentToolExecutor.ToolResult
                    do {
                        result = try await toolExecutor.execute(toolCall: toolCall, subagentId: subagentId)
                    } catch {
                        let message = error.localizedDescription
                        onLine?(ProgressLine(
                            type: .error,
                            summary: "Tool failed: \(toolCall.function.name)",
                            details: message
                        ))
                        try? await tracer.logToolResult(
                            toolCallId: toolCall.id,
                            toolName: toolCall.function.name,
                            success: false,
                            result: nil,
                            errorMessage: message,
                            latencyMs: nil
                        )
                        messages.append(.toolResult(
                            toolCallId: toolCall.id,
                            content: "Error: \(message)"
                        ))
                        continue
                    }
                    
                    switch result {
                    case .text(let content):
                        let truncated = String(content.prefix(1200)) + (content.count > 1200 ? "\n…(truncated)" : "")
                        onLine?(ProgressLine(
                            type: .toolResult,
                            summary: "✓ \(toolCall.function.name)",
                            details: truncated
                        ))
                        try? await tracer.logToolResult(
                            toolCallId: toolCall.id,
                            toolName: toolCall.function.name,
                            success: true,
                            result: content,
                            errorMessage: nil,
                            latencyMs: nil
                        )
                        messages.append(.toolResult(
                            toolCallId: toolCall.id,
                            content: content
                        ))
                    case .image(let description, let base64, let mimeType):
                        onLine?(ProgressLine(
                            type: .toolResult,
                            summary: "✓ \(toolCall.function.name)",
                            details: description
                        ))
                        try? await tracer.logToolResult(
                            toolCallId: toolCall.id,
                            toolName: toolCall.function.name,
                            success: true,
                            result: description,
                            errorMessage: nil,
                            latencyMs: nil
                        )
                        messages.append(.toolResult(
                            toolCallId: toolCall.id,
                            content: description
                        ))
                        messages.append(.user(
                            text: "Here is the image from the \(toolCall.function.name) tool result:",
                            images: [.imageBase64(data: base64, mimeType: mimeType)]
                        ))
                    }
                }
                
                continue
            }
            
            // LLM returned text without tool calls
            consecutiveNoToolCalls += 1
            messages.append(.assistant(response.text ?? ""))
            
            if consecutiveNoToolCalls <= maxContinueNudges {
                // Phase 1: Tell the agent to keep working
                messages.append(.user("Do not respond with text. You must call tools to complete your todo items. Review your todo list and call the next tool needed to make progress."))
                onLine?(ProgressLine(
                    type: .info,
                    summary: "Prompting subagent to continue working (\(consecutiveNoToolCalls)/\(maxContinueNudges))",
                    details: nil
                ))
                continue
            }
            
            if consecutiveNoToolCalls <= maxContinueNudges + maxReportNudges {
                // Phase 2: Agent is stuck — ask for the final report
                let reportNudge = consecutiveNoToolCalls - maxContinueNudges
                messages.append(.user("You appear to be stuck. Call \(Self.finalReportToolName) now to submit your final report. Mark incomplete items as not completed and set status to failed if needed."))
                onLine?(ProgressLine(
                    type: .info,
                    summary: "Requesting final report (\(reportNudge)/\(maxReportNudges))",
                    details: nil
                ))
                continue
            }
            
            // Exhausted all nudges
            break
        }
        
        // Loop exited without submit_final_report — try to extract one
        onActionUpdate?("Writing report…")
        let finalResult = try await finalizeResult(messages: messages, fallback: lastResponseText ?? lastStreamedText)
        onActionUpdate?("Done")
        return finalResult
    }
    
    private func systemPrompt() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())
        let allowedTools = Array(Set(toolAllowlist + [Self.finalReportToolName])).sorted()
        let allowed = allowedTools.isEmpty ? "none" : allowedTools.joined(separator: ", ")
        let todoListSection = formatTodoListSection()
        return """
        You are a Hivecrew subagent. You operate asynchronously and must stay within the allowed tools.
        
        Today's date: \(dateStr)
        
        Goal: \(goal)
        Domain: \(domain.rawValue)
        Allowed tools: \(allowed)
        
        TODO LIST (prescribed by the main agent):
        \(todoListSection)
        
        Rules:
        - Only call tools that appear in the allowed tools list.
        - Do not ask the user questions or request intervention.
        - Do NOT create or modify the todo list. Do not call create_todo_list or add_todo_item.
        - Use finish_todo_item with the item numbers shown in the list to mark prescribed items complete as you finish them.
        - Every todo item must be completed before reporting STATUS: SUCCESS.
        - If you cannot complete every todo item, report STATUS: FAILED and explain why in the final report.
        - Do not produce the final report until all todo items are completed or a blocker prevents completion.
        - If no todo list is provided, report STATUS: FAILED and explain that the list was missing.
        - When finished, call \(Self.finalReportToolName) with a structured report. Do NOT return a normal message.
        - In \(Self.finalReportToolName), include todoItems for every list index with completed=true/false.
        - Prefer web_search/read_webpage_content for research; avoid run_shell unless the goal explicitly requires shell or file operations.
        - Treat any model lists or factual claims in the goal as hypotheses; verify and correct them using sources.
        - Do not use prior knowledge for factual claims. Every factual claim must be grounded in tool-derived sources.
        - You can send messages to other agents using send_message (to: 'main', a subagent ID, or 'broadcast'). Messages sent to you will appear automatically in your context.
        - Use send_message to share important findings with other agents, notify the main agent of critical discoveries, or coordinate with sibling subagents.
        - The report you submit must include:
          - What you did (step-by-step, concise)
          - Key findings (bulleted)
          - Sources (URLs) for any web-derived claims
          - Commands run and their relevant outputs (if any)
          - Clear next steps/recommendations for the root agent
        """
    }
    
    private func finalizeResult(messages: [LLMMessage], fallback: String) async throws -> Result {
        // Force the LLM to call submit_final_report with only that tool available.
        // Try up to 3 times, each with escalating prompts.
        let reportOnlyTools = [Self.finalReportToolDefinition()]
        var forceMessages = messages
        
        let prompts = [
            "Your session is ending. Call \(Self.finalReportToolName) now. Summarize everything you accomplished. For each todo item, mark completed=true if done or completed=false if not. This is the ONLY tool available.",
            "You MUST call \(Self.finalReportToolName) right now. It is the only tool available. Include status (success/failed), todoItems array with index and completed for each item, and a report string summarizing your work.",
            "FINAL ATTEMPT. Call \(Self.finalReportToolName). Arguments: {\"status\": \"failed\", \"todoItems\": [\(todoItems.enumerated().map { "{\"index\":\($0.offset+1),\"completed\":false}" }.joined(separator: ","))], \"report\": \"Session ended before completion.\", \"failureReason\": \"Ran out of iterations.\"}. Call the tool with these or better arguments NOW."
        ]
        
        for (index, prompt) in prompts.enumerated() {
            forceMessages.append(.user(prompt))
            
            let response: LLMResponse
            do {
                response = try await llmClient.chat(
                    messages: forceMessages,
                    tools: reportOnlyTools
                )
            } catch {
                onLine?(ProgressLine(
                    type: .error,
                    summary: "Forced report LLM call failed (\(index + 1)/\(prompts.count))",
                    details: error.localizedDescription
                ))
                continue
            }
            
            if let toolCall = response.toolCalls?.first(where: { $0.function.name == Self.finalReportToolName }),
               let payload = decodeFinalReportPayload(toolCall) {
                return resultFromStructuredReport(payload)
            }
            
            // Append the assistant's non-tool response so the next attempt has context
            forceMessages.append(.assistant(response.text ?? ""))
        }
        
        // Absolute last resort: synthesize a failed result from whatever text we have
        let summary = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(
            status: .failed,
            summary: summary.isEmpty ? "Subagent session ended without producing a report." : summary,
            details: nil,
            failureReason: "Subagent did not submit a structured final report after \(prompts.count) forced attempts."
        )
    }

    private func handleFinalReportToolCall(_ toolCall: LLMToolCall, messages: inout [LLMMessage]) -> Result? {
        guard let payload = decodeFinalReportPayload(toolCall) else {
            let errorMessage = "Error: Invalid final report payload. Use \(Self.finalReportToolName) with the required JSON schema."
            messages.append(.toolResult(toolCallId: toolCall.id, content: errorMessage))
            return nil
        }
        let validation = validateTodoItems(payload.todoItems)
        if !validation.hasTodoList {
            return Result(
                status: .failed,
                summary: payload.report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Subagent reported without a prescribed todo list."
                    : payload.report,
                details: nil,
                failureReason: validation.failureReason ?? "No todo list provided by main agent."
            )
        }
        if !validation.allCompleted {
            if incompleteTodoRetryCount < maxIncompleteTodoRetries {
                incompleteTodoRetryCount += 1
                let message = buildIncompleteTodoMessage(validation: validation)
                messages.append(.toolResult(toolCallId: toolCall.id, content: message))
                return nil
            }
        }
        return resultFromStructuredReport(payload, validation: validation)
    }

    private func decodeFinalReportPayload(_ toolCall: LLMToolCall) -> FinalReportPayload? {
        do {
            return try toolCall.function.decodeArguments(FinalReportPayload.self)
        } catch {
            return nil
        }
    }

    private func resultFromStructuredReport(_ payload: FinalReportPayload, validation: TodoValidation? = nil) -> Result {
        let reportedStatus = normalizeStatus(payload.status)
        let validation = validation ?? validateTodoItems(payload.todoItems)
        let summary = payload.report.trimmingCharacters(in: .whitespacesAndNewlines)
        if reportedStatus == .success && !validation.allCompleted {
            return Result(
                status: .failed,
                summary: summary.isEmpty ? "Subagent reported success without completing todo items." : summary,
                details: nil,
                failureReason: validation.failureReason ?? "Todo list not fully completed."
            )
        }
        if reportedStatus == .failed {
            return Result(
                status: .failed,
                summary: summary.isEmpty ? "Subagent reported failed status." : summary,
                details: nil,
                failureReason: payload.failureReason ?? validation.failureReason ?? "Subagent reported failed status."
            )
        }
        return Result(
            status: .success,
            summary: summary.isEmpty ? "Subagent completed successfully." : summary,
            details: nil,
            failureReason: nil
        )
    }

    private struct TodoValidation {
        let missingIndices: [Int]
        let incompleteIndices: [Int]
        let hasTodoList: Bool

        var allCompleted: Bool {
            hasTodoList && missingIndices.isEmpty && incompleteIndices.isEmpty
        }

        var failureReason: String? {
            if !hasTodoList {
                return "No todo list provided by main agent."
            }
            if missingIndices.isEmpty && incompleteIndices.isEmpty {
                return nil
            }
            if !missingIndices.isEmpty {
                return "Final report missing todo item(s): \(missingIndices.map(String.init).joined(separator: ", "))."
            }
            return "Todo list not fully completed."
        }
    }

    private func validateTodoItems(_ items: [FinalReportPayload.TodoItem]) -> TodoValidation {
        if todoItems.isEmpty {
            return TodoValidation(missingIndices: [], incompleteIndices: [], hasTodoList: false)
        }
        let byIndex = Dictionary(uniqueKeysWithValues: items.map { ($0.index, $0) })
        var missing: [Int] = []
        var incomplete: [Int] = []
        for index in 1...todoItems.count {
            guard let item = byIndex[index] else {
                missing.append(index)
                continue
            }
            if item.completed == false {
                incomplete.append(index)
            }
        }
        return TodoValidation(missingIndices: missing, incompleteIndices: incomplete, hasTodoList: true)
    }

    private func normalizeStatus(_ status: String) -> CompletionStatus {
        let lowered = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "success" || lowered == "completed" {
            return .success
        }
        return .failed
    }

    private func buildIncompleteTodoMessage(validation: TodoValidation) -> String {
        if !validation.hasTodoList {
            return "No todo list was provided by the main agent. You must report STATUS: FAILED with a failureReason indicating the missing list."
        }
        var lines: [String] = ["Todo list incomplete. Complete the items below, then call \(Self.finalReportToolName) again."]

        if !validation.missingIndices.isEmpty {
            lines.append("Missing items:")
            for index in validation.missingIndices.sorted() {
                lines.append("- #\(index): \(todoItems[safe: index - 1] ?? "Unknown item")")
            }
        }

        if !validation.incompleteIndices.isEmpty {
            lines.append("Incomplete items:")
            for index in validation.incompleteIndices.sorted() {
                lines.append("- #\(index): \(todoItems[safe: index - 1] ?? "Unknown item")")
            }
        }

        lines.append("Use finish_todo_item with the item numbers above.")
        lines.append("If an item is blocked after reasonable attempts, set status to failed and include failureReason.")
        return lines.joined(separator: "\n")
    }

    private static func finalReportToolDefinition() -> LLMToolDefinition {
        LLMToolDefinition.function(
            name: finalReportToolName,
            description: "Submit the final structured subagent report.",
            parameters: [
                "type": "object",
                "properties": [
                    "status": [
                        "type": "string",
                        "description": "Overall completion status.",
                        "enum": ["success", "failed"]
                    ],
                    "todoItems": [
                        "type": "array",
                        "description": "Completion state for each prescribed todo item by index.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "index": [
                                    "type": "integer",
                                    "description": "1-based index of the todo item."
                                ],
                                "completed": [
                                    "type": "boolean",
                                    "description": "True if the item was completed."
                                ]
                            ],
                            "required": ["index", "completed"],
                            "additionalProperties": false
                        ]
                    ],
                    "report": [
                        "type": "string",
                        "description": "Final report text including what you did, findings, sources, commands, and next steps."
                    ],
                    "failureReason": [
                        "type": "string",
                        "description": "If status is failed, explain why."
                    ]
                ],
                "required": ["status", "todoItems", "report"],
                "additionalProperties": false
            ]
        )
    }

    private static func withFinalReportTool(_ tools: [LLMToolDefinition]) -> [LLMToolDefinition] {
        if tools.contains(where: { $0.function.name == finalReportToolName }) {
            return tools
        }
        return tools + [finalReportToolDefinition()]
    }

    private func formatTodoListSection() -> String {
        if todoItems.isEmpty {
            return "1. [ ] (no items provided)"
        }
        let items = todoItems
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return items.enumerated()
            .map { "\($0.offset + 1). [ ] \($0.element)" }
            .joined(separator: "\n")
    }
}
