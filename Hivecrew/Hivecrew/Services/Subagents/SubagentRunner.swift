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
    struct Result: Sendable {
        let summary: String
        let details: String?
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
        onActionUpdate?("Done")
        return Result(summary: detailedSummary, details: nil)
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
        - Prefer web_search/read_webpage_content for research; avoid run_shell unless the goal explicitly requires shell or file operations.
        - Treat any model lists or factual claims in the goal as hypotheses; verify and correct them using sources.
        - Do not use prior knowledge for factual claims. Every factual claim must be grounded in tool-derived sources.
        - When you are done, respond with a detailed report that includes:
          - What you did (step-by-step, concise)
          - Key findings (bulleted)
          - Sources (URLs) for any web-derived claims
          - Commands run and their relevant outputs (if any)
          - Clear next steps/recommendations for the root agent
        """
    }
    
    private func ensureDetailedSummary(messages: [LLMMessage], fallback: String) async throws -> String {
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 300 {
            return trimmed
        }
        
        let prompt = """
        Produce the final report now.
        Do NOT call any tools.
        """
        let response = try await llmClient.chat(
            messages: messages + [.user(prompt)],
            tools: nil
        )
        let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 200 {
            return text
        }
        return trimmed.isEmpty ? "Subagent completed but produced no summary." : trimmed
    }
}
