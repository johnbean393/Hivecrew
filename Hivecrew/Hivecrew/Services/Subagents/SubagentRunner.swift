//
//  SubagentRunner.swift
//  Hivecrew
//
//  Runs a background LLM-driven subagent with restricted tools.
//

import Foundation
import HivecrewLLM

final class SubagentRunner: @unchecked Sendable {
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

    private actor RuntimeState {
        struct Snapshot: Sendable {
            let messages: [LLMMessage]
            let lastResponseText: String?
        }

        private var messages: [LLMMessage]
        private var lastResponseText: String?

        init(messages: [LLMMessage], lastResponseText: String? = nil) {
            self.messages = messages
            self.lastResponseText = lastResponseText
        }

        func replace(messages: [LLMMessage], lastResponseText: String?) {
            self.messages = messages
            self.lastResponseText = lastResponseText
        }

        func snapshot() -> Snapshot {
            Snapshot(messages: messages, lastResponseText: lastResponseText)
        }
    }

    private enum RuntimeTimeoutError: LocalizedError {
        case timedOut

        var errorDescription: String? {
            "Subagent runtime limit reached"
        }
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
    private let supportsVision: Bool
    private let runtimeDelegate: SubagentManager.RuntimeDelegate
    private let maxIterations: Int
    private let maxLLMRetries = 3
    private let maxContextCompactionRetries = 3
    private let baseRetryDelay: Double = 2.0
    private let defaultToolResultContextLimit = 6_000
    private var incompleteTodoRetryCount = 0
    private let maxIncompleteTodoRetries = 3
    private var consecutiveNoToolCalls = 0
    private let maxContinueNudges = 3
    private let maxReportNudges = 2
    private var currentImageScaleLevel: ImageDownscaler.ScaleLevel = .medium
    
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
        supportsVision: Bool,
        runtimeDelegate: SubagentManager.RuntimeDelegate,
        maxIterations: Int = 100,
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
        self.supportsVision = supportsVision
        self.runtimeDelegate = runtimeDelegate
        self.maxIterations = maxIterations
    }

    private func updateAction(_ action: String) async {
        await runtimeDelegate.updateAction(action)
    }

    private func emitLine(_ line: ProgressLine) async {
        await runtimeDelegate.emitLine(line)
    }
    
    func run(runtimeTimeoutSeconds: Double? = nil) async throws -> Result {
        let initialMessages: [LLMMessage] = [
            .system(systemPrompt()),
            .user(goal)
        ]
        let runtimeState = RuntimeState(messages: initialMessages)

        do {
            if let runtimeTimeoutSeconds {
                return try await withRuntimeTimeout(seconds: runtimeTimeoutSeconds) {
                    try await self.runLoop(
                        initialMessages: initialMessages,
                        runtimeState: runtimeState
                    )
                }
            }

            return try await runLoop(
                initialMessages: initialMessages,
                runtimeState: runtimeState
            )
        } catch is RuntimeTimeoutError {
            return try await finalizeDueToRuntimeLimit(
                runtimeTimeoutSeconds: runtimeTimeoutSeconds,
                runtimeState: runtimeState
            )
        }
    }

    private func runLoop(
        initialMessages: [LLMMessage],
        runtimeState: RuntimeState
    ) async throws -> Result {
        var messages = initialMessages
        var iteration = 0
        var lastResponseText: String?
        var lastStreamedText: String = ""

        while iteration < maxIterations {
            iteration += 1
            await tracer.nextStep()
            
            // Auto-inject any pending mailbox messages before the LLM call
            let incoming = await runtimeDelegate.drainMessages()
            for msg in incoming {
                let senderLabel = msg.from == "main" ? "main agent" : "subagent \(msg.from)"
                messages.append(.user(
                    "[Message from \(senderLabel)] Subject: \(msg.subject)\n\(msg.body)"
                ))
                await emitLine(ProgressLine(
                    type: .info,
                    summary: "Mailbox: received message from \(senderLabel)",
                    details: "Subject: \(msg.subject)"
                ))
            }
            await runtimeState.replace(messages: messages, lastResponseText: lastResponseText)
            
            await updateAction("Thinking…")
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
                response = try await callStreamingLLMWithRetry(messages: &messages) { content in
                    lastStreamedText = content
                }
            } catch {
                if isCancellationError(error) {
                    throw CancellationError()
                }
                let errorMsg = error.localizedDescription
                await emitLine(ProgressLine(
                    type: .error,
                    summary: "LLM call failed",
                    details: errorMsg
                ))
                return Result(
                    status: .failed,
                    summary: "LLM call failed after retries.",
                    details: nil,
                    failureReason: errorMsg
                )
            }
            
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            lastResponseText = (response.text?.isEmpty == false) ? response.text : lastStreamedText
            if let text = lastResponseText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await emitLine(ProgressLine(
                    type: .llmResponse,
                    summary: "LLM response",
                    details: text
                ))
            }
            await runtimeState.replace(messages: messages, lastResponseText: lastResponseText)
            
            try? await tracer.logLLMResponse(response, latencyMs: latencyMs)
            
            // If the LLM returned tool calls, process them
            if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                consecutiveNoToolCalls = 0
                messages.append(.assistant(response.text ?? "", toolCalls: toolCalls))
                await runtimeState.replace(messages: messages, lastResponseText: lastResponseText)
                
                for toolCall in toolCalls {
                    try? await tracer.logToolCall(toolCall)
                    await updateAction("Executing: \(toolCall.function.name)")
                    await emitLine(ProgressLine(
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
                        await runtimeState.replace(messages: messages, lastResponseText: lastResponseText)
                        continue
                    }
                    
                    let result: SubagentToolExecutor.ToolResult
                    do {
                        result = try await toolExecutor.execute(toolCall: toolCall, subagentId: subagentId)
                    } catch {
                        let message = error.localizedDescription
                        await emitLine(ProgressLine(
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
                        await runtimeState.replace(messages: messages, lastResponseText: lastResponseText)
                        continue
                    }
                    
                    switch result {
                    case .text(let content):
                        let truncated = String(content.prefix(1200)) + (content.count > 1200 ? "\n…(truncated)" : "")
                        let contextSafeContent = toolResultContentForContext(
                            toolName: toolCall.function.name,
                            content: content
                        )
                        await emitLine(ProgressLine(
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
                            content: contextSafeContent
                        ))
                    case .image(let description, let base64, let mimeType):
                        await emitLine(ProgressLine(
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
                        if supportsVision {
                            messages.append(.user(
                                text: "Here is the image from the \(toolCall.function.name) tool result:",
                                images: [.imageBase64(data: base64, mimeType: mimeType)]
                            ))
                        } else {
                            messages.append(.user("An image was produced by \(toolCall.function.name), but this model does not support vision input. Continue with text-only tools."))
                        }
                    }
                    await runtimeState.replace(messages: messages, lastResponseText: lastResponseText)
                }
                
                continue
            }
            
            // LLM returned text without tool calls
            consecutiveNoToolCalls += 1
            messages.append(.assistant(response.text ?? ""))
            await runtimeState.replace(messages: messages, lastResponseText: lastResponseText)
            
            if consecutiveNoToolCalls <= maxContinueNudges {
                // Phase 1: Tell the agent to keep working
                messages.append(.user("Do not respond with text. You must call tools to complete your todo items. Review your todo list and call the next tool needed to make progress."))
                await runtimeState.replace(messages: messages, lastResponseText: lastResponseText)
                await emitLine(ProgressLine(
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
                await runtimeState.replace(messages: messages, lastResponseText: lastResponseText)
                await emitLine(ProgressLine(
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
        await updateAction("Writing report…")
        let finalResult = try await finalizeResult(messages: messages, fallback: lastResponseText ?? lastStreamedText)
        await updateAction("Done")
        return finalResult
    }

    private func finalizeDueToRuntimeLimit(
        runtimeTimeoutSeconds: Double?,
        runtimeState: RuntimeState
    ) async throws -> Result {
        let snapshot = await runtimeState.snapshot()
        let timeoutMessage = runtimeLimitMessage(runtimeTimeoutSeconds)

        await emitLine(ProgressLine(
            type: .info,
            summary: timeoutMessage,
            details: "Forcing a final report from the work completed so far."
        ))
        await updateAction("Writing report…")

        var forceMessages = snapshot.messages
        forceMessages.append(.user(
            "Your runtime limit has been reached. Stop all additional work and call \(Self.finalReportToolName) now. Use only the evidence already collected. Mark incomplete todo items as completed=false and set status to failed if needed. Do not call any tool other than \(Self.finalReportToolName)."
        ))

        let fallback = snapshot.lastResponseText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let result = try await finalizeResult(
            messages: forceMessages,
            fallback: fallback.isEmpty ? timeoutMessage : fallback
        )
        await updateAction("Done")

        guard result.status == .failed else {
            return result
        }

        let failureReason = [result.failureReason, timeoutMessage]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return Result(
            status: .failed,
            summary: result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? timeoutMessage : result.summary,
            details: result.details,
            failureReason: failureReason.isEmpty ? nil : failureReason
        )
    }

    private func withRuntimeTimeout<T>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RuntimeTimeoutError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func runtimeLimitMessage(_ runtimeTimeoutSeconds: Double?) -> String {
        guard let runtimeTimeoutSeconds else {
            return "Subagent runtime limit reached."
        }

        let totalMinutes = Int((runtimeTimeoutSeconds / 60.0).rounded())
        return "Subagent reached its \(totalMinutes)-minute runtime limit."
    }

    private func callStreamingLLMWithRetry(
        messages: inout [LLMMessage],
        onContentUpdate: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        let options = SharedLLMRetryHandler.Options(
            maxLLMRetries: maxLLMRetries,
            maxContextCompactionRetries: maxContextCompactionRetries,
            baseRetryDelay: baseRetryDelay,
            proactiveCompactionPasses: 3,
            normalToolResultLimit: 8_000,
            aggressiveToolResultLimit: 4_000
        )

        let hooks = SharedLLMRetryHandler.Hooks(
            logInfo: { [weak self] message in
                Task { [weak self] in
                    await self?.emitLine(ProgressLine(
                        type: .info,
                        summary: message,
                        details: nil
                    ))
                }
            },
            checkInterruption: {
                try Task.checkCancellation()
            },
            onImageScaleLevelChanged: { [weak self] newScale in
                self?.currentImageScaleLevel = newScale
            }
        )

        let outcome = try await SharedLLMRetryHandler.callWithRetry(
            llmClient: llmClient,
            messages: messages,
            tools: tools,
            imageScaleLevel: currentImageScaleLevel,
            onReasoningUpdate: { _ in },
            onContentUpdate: { content in
                onContentUpdate(content)
            },
            llmCall: { [weak self] callMessages, callTools, callReasoningUpdate, callContentUpdate in
                guard let self else { throw LLMError.cancelled }
                return try await self.llmClient.chatWithStreaming(
                    messages: callMessages,
                    tools: callTools,
                    onReasoningUpdate: callReasoningUpdate,
                    onContentUpdate: callContentUpdate
                )
            },
            options: options,
            hooks: hooks
        )

        messages = outcome.messages
        currentImageScaleLevel = outcome.imageScaleLevel
        return outcome.response
    }

    private func callNonStreamingLLMWithRetry(
        messages: inout [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> LLMResponse {
        let options = SharedLLMRetryHandler.Options(
            maxLLMRetries: maxLLMRetries,
            maxContextCompactionRetries: maxContextCompactionRetries,
            baseRetryDelay: baseRetryDelay,
            proactiveCompactionPasses: 3,
            normalToolResultLimit: 8_000,
            aggressiveToolResultLimit: 4_000
        )

        let hooks = SharedLLMRetryHandler.Hooks(
            logInfo: { [weak self] message in
                Task { [weak self] in
                    await self?.emitLine(ProgressLine(
                        type: .info,
                        summary: message,
                        details: nil
                    ))
                }
            },
            checkInterruption: {
                try Task.checkCancellation()
            },
            onImageScaleLevelChanged: { [weak self] newScale in
                self?.currentImageScaleLevel = newScale
            }
        )

        let outcome = try await SharedLLMRetryHandler.callWithRetry(
            llmClient: llmClient,
            messages: messages,
            tools: tools,
            imageScaleLevel: currentImageScaleLevel,
            onReasoningUpdate: nil,
            onContentUpdate: nil,
            llmCall: { [weak self] callMessages, callTools, _, _ in
                guard let self else { throw LLMError.cancelled }
                return try await self.llmClient.chat(
                    messages: callMessages,
                    tools: callTools
                )
            },
            options: options,
            hooks: hooks
        )

        messages = outcome.messages
        currentImageScaleLevel = outcome.imageScaleLevel
        return outcome.response
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let llmError = error as? LLMError, case .cancelled = llmError {
            return true
        }

        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }

        return false
    }
    
    private func systemPrompt() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())
        let allowedTools = Array(Set(toolAllowlist + [Self.finalReportToolName])).sorted()
        let allowed = allowedTools.isEmpty ? "none" : allowedTools.joined(separator: ", ")
        let todoListSection = formatTodoListSection()
        let visionLine = supportsVision
            ? "Model vision input: enabled."
            : "Model vision input: disabled. Do not rely on image content."
        return """
        You are a Hivecrew subagent. You operate asynchronously and must stay within the allowed tools.
        
        Today's date: \(dateStr)
        
        Goal: \(goal)
        Domain: \(domain.rawValue)
        \(visionLine)
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
        - Prefer web_search to discover sources and extract_info_from_webpage for targeted questions. Use read_webpage_content sparingly for short pages or quick source inspection because long page dumps will bloat your context.
        - Once you have enough evidence to finish the assigned memo or table, stop researching and submit the final report instead of continuing to browse for marginal improvements.
        - Avoid repeated near-duplicate searches. Refine the query or move on once a source is clearly unhelpful.
        - Prefer primary sources, short official summaries, earnings releases, shareholder letters, and focused extracts over raw full-document dumps.
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
                response = try await callNonStreamingLLMWithRetry(
                    messages: &forceMessages,
                    tools: reportOnlyTools
                )
            } catch {
                if isCancellationError(error) {
                    throw CancellationError()
                }
                await emitLine(ProgressLine(
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

    private func toolResultContentForContext(toolName: String, content: String) -> String {
        let normalizedTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let maxChars: Int

        switch normalizedTool {
        case "read_webpage_content", "read_file":
            maxChars = 10_000
        case "web_search":
            maxChars = 5_000
        case "extract_info_from_webpage":
            maxChars = 4_000
        case "run_shell":
            maxChars = 6_000
        case "list_directory":
            maxChars = 4_000
        default:
            maxChars = defaultToolResultContextLimit
        }

        return truncateForContext(content, maxChars: maxChars)
    }

    private func truncateForContext(_ content: String, maxChars: Int) -> String {
        guard maxChars > 0, content.count > maxChars else {
            return content
        }

        let removedCount = content.count - maxChars
        let notice = "\n\n[... truncated \(removedCount) characters to reduce context size ...]\n\n"
        let headChars = max(0, Int(Double(maxChars) * 0.75))
        let tailChars = max(0, maxChars - headChars - notice.count)

        guard tailChars >= 512 else {
            let prefixLength = max(0, maxChars - notice.count)
            let prefix = String(content.prefix(prefixLength))
            return prefix + notice
        }

        let prefix = String(content.prefix(headChars))
        let suffix = String(content.suffix(tailChars))
        return prefix + notice + suffix
    }
}
