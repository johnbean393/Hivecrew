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
    
    struct ProgressLine: Sendable {
        let type: SubagentProgressLineType
        let summary: String
        let details: String?
    }
    
    private let subagentId: String
    private let goal: String
    private let domain: SubagentDomain
    private let toolAllowlist: [String]
    private let llmClient: any LLMClientProtocol
    private let tracer: AgentTracer
    private let toolExecutor: SubagentToolExecutor
    private let tools: [LLMToolDefinition]
    private let maxIterations: Int
    private let onActionUpdate: (@MainActor (String) -> Void)?
    private let onLine: (@MainActor (ProgressLine) -> Void)?
    
    init(
        subagentId: String,
        goal: String,
        domain: SubagentDomain,
        toolAllowlist: [String],
        llmClient: any LLMClientProtocol,
        tracer: AgentTracer,
        toolExecutor: SubagentToolExecutor,
        tools: [LLMToolDefinition],
        maxIterations: Int = 10,
        onActionUpdate: (@MainActor (String) -> Void)? = nil,
        onLine: (@MainActor (ProgressLine) -> Void)? = nil
    ) {
        self.subagentId = subagentId
        self.goal = goal
        self.domain = domain
        self.toolAllowlist = toolAllowlist
        self.llmClient = llmClient
        self.tracer = tracer
        self.toolExecutor = toolExecutor
        self.tools = tools
        self.maxIterations = maxIterations
        self.onActionUpdate = onActionUpdate
        self.onLine = onLine
    }
    
    func run() async throws -> Result {
        var messages: [LLMMessage] = [
            .system(systemPrompt()),
            .user(goal)
        ]
        
        var iteration = 0
        var lastResponseText: String?
        var lastStreamedText: String = ""
        
        while iteration < maxIterations {
            iteration += 1
            await tracer.nextStep()
            
            onActionUpdate?("Thinking…")
            try? await tracer.logLLMRequest(
                messageCount: messages.count,
                toolCount: tools.count,
                model: llmClient.configuration.model
            )
            
            let start = Date()
            lastStreamedText = ""
            let response = try await llmClient.chatWithStreaming(
                messages: messages,
                tools: tools,
                onReasoningUpdate: { _ in },
                onContentUpdate: { content in
                    lastStreamedText = content
                }
            )
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
            
            if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                messages.append(.assistant(response.text ?? "", toolCalls: toolCalls))
                
                for toolCall in toolCalls {
                    try? await tracer.logToolCall(toolCall)
                    onActionUpdate?("Executing: \(toolCall.function.name)")
                    onLine?(ProgressLine(
                        type: .toolCall,
                        summary: "Executing: \(toolCall.function.name)",
                        details: "Args: \(toolCall.function.arguments)"
                    ))
                    
                    let result: SubagentToolExecutor.ToolResult
                    do {
                        result = try await toolExecutor.execute(toolCall: toolCall)
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
            
            break
        }
        
        onActionUpdate?("Writing report…")
        let detailedSummary = try await ensureDetailedSummary(messages: messages, fallback: lastResponseText ?? lastStreamedText)
        let outcome = outcomeForReport(detailedSummary)
        onActionUpdate?("Done")
        return Result(
            status: outcome.status,
            summary: detailedSummary,
            details: nil,
            failureReason: outcome.failureReason
        )
    }
    
    private func systemPrompt() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())
        let allowed = toolAllowlist.isEmpty ? "none" : toolAllowlist.joined(separator: ", ")
        return """
        You are a Hivecrew subagent. You operate asynchronously and must stay within the allowed tools.
        
        Today's date: \(dateStr)
        
        Goal: \(goal)
        Domain: \(domain.rawValue)
        Allowed tools: \(allowed)
        
        Rules:
        - Only call tools that appear in the allowed tools list.
        - Do not ask the user questions or request intervention.
        - Start by calling create_todo_list with 3-7 concise, high-level steps. Keep the list lightweight and avoid including excessive background or main-agent knowledge.
        - Track progress with add_todo_item and finish_todo_item. Every todo item must be completed before reporting success.
        - If you cannot complete every todo item, report STATUS: FAILED and explain why in the final report.
        - Prefer web_search/read_webpage_content for research; avoid run_shell unless the goal explicitly requires shell or file operations.
        - Treat any model lists or factual claims in the goal as hypotheses; verify and correct them using sources.
        - Do not use prior knowledge for factual claims. Every factual claim must be grounded in tool-derived sources.
        - When you are done, respond with a detailed report that includes:
          - STATUS: SUCCESS or STATUS: FAILED (first line)
          - TODO LIST: with items formatted as "- [x] ..." or "- [ ] ..."
          - What you did (step-by-step, concise)
          - Key findings (bulleted)
          - Sources (URLs) for any web-derived claims
          - Commands run and their relevant outputs (if any)
          - Clear next steps/recommendations for the root agent
        """
    }
    
    private func ensureDetailedSummary(messages: [LLMMessage], fallback: String) async throws -> String {
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinalReportCompliant(trimmed), trimmed.count >= 300 {
            return trimmed
        }
        
        let prompt = """
        Produce the final report now.
        Do NOT call any tools.
        Use this exact format:
        
        STATUS: SUCCESS or STATUS: FAILED
        TODO LIST:
        - [x] Item
        - [ ] Item
        
        Then include: What you did, Key findings, Sources, Commands run, Next steps.
        """
        let response = try await llmClient.chat(
            messages: messages + [.user(prompt)],
            tools: nil
        )
        let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinalReportCompliant(text), text.count >= 200 {
            return text
        }
        if isFinalReportCompliant(trimmed) {
            return trimmed
        }
        return trimmed.isEmpty ? "Subagent completed but produced no summary." : trimmed
    }

    private struct FinalReportOutcome {
        let status: CompletionStatus
        let failureReason: String?
    }

    private struct FinalReportEvaluation {
        let reportedStatus: CompletionStatus?
        let todoItems: [Bool]

        var hasTodoList: Bool {
            !todoItems.isEmpty
        }

        var allTodoItemsComplete: Bool {
            hasTodoList && todoItems.allSatisfy { $0 }
        }
    }

    private func outcomeForReport(_ report: String) -> FinalReportOutcome {
        let evaluation = evaluateFinalReport(report)
        if let reported = evaluation.reportedStatus {
            if reported == .failed {
                return FinalReportOutcome(status: .failed, failureReason: "Subagent reported failed status.")
            }
            if !evaluation.hasTodoList {
                return FinalReportOutcome(status: .failed, failureReason: "Final report missing TODO LIST section.")
            }
            if !evaluation.allTodoItemsComplete {
                return FinalReportOutcome(status: .failed, failureReason: "Todo list not fully completed.")
            }
            return FinalReportOutcome(status: .success, failureReason: nil)
        }

        var reason = "Final report missing STATUS line."
        if !evaluation.hasTodoList {
            reason = "Final report missing STATUS line and TODO LIST section."
        } else if !evaluation.allTodoItemsComplete {
            reason = "Final report missing STATUS line and has incomplete todo items."
        }
        return FinalReportOutcome(status: .failed, failureReason: reason)
    }

    private func isFinalReportCompliant(_ report: String) -> Bool {
        let evaluation = evaluateFinalReport(report)
        return evaluation.reportedStatus != nil && evaluation.hasTodoList
    }

    private func evaluateFinalReport(_ report: String) -> FinalReportEvaluation {
        let lines = report.components(separatedBy: .newlines)
        var reportedStatus: CompletionStatus?
        var inTodoList = false
        var todoItems: [Bool] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let lower = trimmed.lowercased()

            if lower.hasPrefix("status:") || lower.hasPrefix("status -") {
                let normalized = lower
                    .replacingOccurrences(of: "status:", with: "")
                    .replacingOccurrences(of: "status -", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if normalized.hasPrefix("success") || normalized.hasPrefix("completed") || normalized.hasPrefix("complete") {
                    reportedStatus = .success
                } else if normalized.hasPrefix("failed") || normalized.hasPrefix("failure") {
                    reportedStatus = .failed
                }
                continue
            }

            if lower == "todo list:" || lower == "todo list" || lower == "to-do list:" || lower == "to-do list" {
                inTodoList = true
                continue
            }

            if inTodoList {
                if let completion = parseTodoCheckbox(from: trimmed) {
                    todoItems.append(completion)
                    continue
                }

                if trimmed.hasPrefix("-") || trimmed.range(of: #"^\d+\."#, options: .regularExpression) != nil {
                    todoItems.append(false)
                    continue
                }

                if looksLikeSectionHeader(trimmed) {
                    inTodoList = false
                }
            }
        }

        return FinalReportEvaluation(reportedStatus: reportedStatus, todoItems: todoItems)
    }

    private func parseTodoCheckbox(from line: String) -> Bool? {
        let lower = line.lowercased()
        if lower.contains("[x]") {
            return true
        }
        if lower.contains("[ ]") {
            return false
        }
        return nil
    }

    private func looksLikeSectionHeader(_ line: String) -> Bool {
        if line.hasPrefix("#") { return true }
        if line.hasSuffix(":") { return true }
        return false
    }
}
