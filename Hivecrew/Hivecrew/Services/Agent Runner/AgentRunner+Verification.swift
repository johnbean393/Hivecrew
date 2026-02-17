//
//  AgentRunner+Verification.swift
//  Hivecrew
//
//  Completion verification and LLM retry logic
//

import Foundation
import HivecrewLLM

// MARK: - Completion Verification

extension AgentRunner {
    
    /// Verify task completion using a structured LLM call
    /// Returns (success, summary)
    func verifyCompletion(agentSummary: String) async -> (Bool, String?) {
        do {
            // Build the verification prompt
            let verificationPrompt = AgentPrompts.structuredCompletionCheckPrompt(
                task: task.taskDescription,
                agentSummary: agentSummary
            )
            
            // Make a simple LLM call (no tools) with retry logic
            let response = try await callLLMWithRetry(
                messages: [.user(verificationPrompt)],
                tools: nil,
                updateConversationHistory: false
            )
            
            // Parse the JSON response
            guard let responseText = response.text else {
                statePublisher.logInfo("No response from completion check, treating as incomplete")
                return (false, "Completion check returned no response.")
            }
            
            // Try to extract JSON from the response
            let jsonResult = parseCompletionJSON(responseText)
            
            if let success = jsonResult.success {
                return (success, jsonResult.summary ?? agentSummary)
            } else {
                // Treat unparseable response as incomplete
                statePublisher.logInfo("Could not parse completion check response, treating as incomplete")
                return (false, "Completion check returned invalid JSON.")
            }
        } catch {
            // On error, treat as incomplete rather than assuming success
            statePublisher.logError("Completion verification failed: \(error.localizedDescription)")
            return (false, "Completion check failed to run.")
        }
    }
    
    /// Parse the JSON response from completion check
    func parseCompletionJSON(_ text: String) -> (success: Bool?, summary: String?) {
        // Try to find JSON in the response (it might have extra text around it)
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Find the first { and last }
        if let startIndex = jsonString.firstIndex(of: "{"),
           let endIndex = jsonString.lastIndex(of: "}") {
            jsonString = String(jsonString[startIndex...endIndex])
        }
        
        guard let data = jsonString.data(using: .utf8) else {
            return (nil, nil)
        }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let success: Bool?
                if let successValue = json["success"] as? Bool {
                    success = successValue
                } else if let successString = json["success"] as? String {
                    let normalized = successString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if ["true", "yes"].contains(normalized) {
                        success = true
                    } else if ["false", "no"].contains(normalized) {
                        success = false
                    } else {
                        success = nil
                    }
                } else {
                    success = nil
                }
                let summary = json["summary"] as? String
                return (success, summary)
            }
        } catch {
            // Failed to parse JSON
        }
        
        return (nil, nil)
    }
}

// MARK: - LLM Retry Logic

extension AgentRunner {
    
    /// Call LLM with retry logic for transient failures and streaming reasoning support
    /// Also handles payload too large (413) errors by downscaling images
    func callLLMWithRetry(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        updateConversationHistory: Bool = true
    ) async throws -> LLMResponse {
        var lastError: Error?
        var contextCompactionRetries = 0
        let maxCompactionRetries = 3
        var workingMessages = messages
        var workingScaleLevel = currentImageScaleLevel
        let initialBudget = await ContextBudgetResolver.shared.resolve(using: llmClient)
        var maxInputTokens = initialBudget.maxInputTokens

        if let maxInputTokens {
            await proactivelyCompactMessagesIfNeeded(
                messages: &workingMessages,
                tools: tools,
                maxInputTokens: maxInputTokens,
                updateConversationHistory: updateConversationHistory
            )
        }
        
        for attempt in 1...maxLLMRetries {
            do {
                try throwIfAgentInterrupted()

                // Start reasoning stream before the LLM call
                await MainActor.run {
                    statePublisher.startReasoningStream()
                }
                
                // Create a callback that updates the state publisher on the main actor
                let reasoningCallback: ReasoningStreamCallback = { [weak self] reasoning in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.statePublisher.updateStreamingReasoning(reasoning)
                    }
                }
                
                // Use the provided messages (which may have been downscaled)
                let response = try await runCancellableLLMCall(
                    messages: workingMessages,
                    tools: tools,
                    onReasoningUpdate: reasoningCallback
                )
                
                let hasText = !(response.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let hasToolCalls = !(response.toolCalls?.isEmpty ?? true)
                if !hasText && !hasToolCalls {
                    // Log details about the empty response for debugging
                    let responseId = response.id
                    let finishReason = response.finishReason?.rawValue ?? "nil"
                    let choiceCount = response.choices.count
                    let reasoning = response.reasoning?.prefix(100) ?? "nil"
                    print("[AgentRunner] Empty response detected - id: \(responseId), finishReason: \(finishReason), choices: \(choiceCount), reasoning: \(reasoning)")
                    throw LLMError.unknown(message: "Empty response from model (id: \(responseId), finishReason: \(finishReason), choices: \(choiceCount))")
                }
                
                return response
            } catch {
                lastError = error

                if let learnedBudget = await learnContextBudget(from: error) {
                    maxInputTokens = learnedBudget.maxInputTokens ?? maxInputTokens
                }

                // Context pressure should always trigger compaction before retry.
                if let compactionReason = ContextCompactionPolicy.compactionReason(for: error),
                   contextCompactionRetries < maxCompactionRetries {
                    contextCompactionRetries += 1

                    if isPayloadTooLargeError(error) {
                        // Keep the existing downscale flow for 413-like failures.
                        if let nextLevel = workingScaleLevel.next {
                            statePublisher.logInfo("Context compaction triggered (\(compactionReason.rawValue)). Downscaling images to \(nextLevel) and retrying...")
                            workingScaleLevel = nextLevel
                            downscaleMessages(&workingMessages, to: nextLevel)
                            if updateConversationHistory {
                                currentImageScaleLevel = nextLevel
                                downscaleConversationImages(to: nextLevel)
                            }
                            continue
                        }

                        statePublisher.logInfo("Context compaction triggered (\(compactionReason.rawValue)). Removing older images and retrying...")
                        aggressiveCompactMessages(&workingMessages)
                        truncateToolResultsForContextLimit(&workingMessages, maxToolResultChars: 12000)
                        if updateConversationHistory {
                            conversationHistory = workingMessages
                        }
                        continue
                    }

                    statePublisher.logInfo("Context compaction triggered (\(compactionReason.rawValue)). Compacting messages and retrying...")
                    let compacted = await compactMessagesForContextLimit(
                        &workingMessages,
                        keepMostRecentImageOnly: true,
                        maxToolResultChars: 12000
                    )
                    if !compacted {
                        // Ensure at least one compaction attempt on context-limit errors.
                        aggressiveCompactMessages(&workingMessages)
                        truncateToolResultsForContextLimit(&workingMessages, maxToolResultChars: 8000)
                    }
                    if updateConversationHistory {
                        conversationHistory = workingMessages
                    }
                    if let maxInputTokens {
                        await proactivelyCompactMessagesIfNeeded(
                            messages: &workingMessages,
                            tools: tools,
                            maxInputTokens: maxInputTokens,
                            updateConversationHistory: updateConversationHistory
                        )
                    }
                    continue
                }
                
                // Retry explicitly on empty responses
                if isEmptyResponseError(error) && attempt < maxLLMRetries {
                    try throwIfAgentInterrupted()
                    let delay = baseRetryDelay * pow(2.0, Double(attempt - 1))
                    statePublisher.logInfo("LLM returned empty response (attempt \(attempt)/\(maxLLMRetries)). Retrying in \(Int(delay))s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                
                // Check if error is retryable
                if isRetryableError(error) && attempt < maxLLMRetries {
                    try throwIfAgentInterrupted()
                    let delay = baseRetryDelay * pow(2.0, Double(attempt - 1))
                    statePublisher.logInfo("LLM call failed (attempt \(attempt)/\(maxLLMRetries)): \(formatLLMError(error)). Retrying in \(Int(delay))s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    throw error
                }
            }
        }
        
        // Should never reach here, but just in case
        throw lastError ?? AgentRunnerError.taskFailed("LLM call failed after \(maxLLMRetries) attempts")
    }
    
    /// Check if an error indicates payload was too large
    private func isPayloadTooLargeError(_ error: Error) -> Bool {
        // Check for LLMError.payloadTooLarge
        if let llmError = error as? LLMError, llmError.isPayloadTooLarge {
            return true
        }
        
        // Also check error message for 413 or "oversized payload" 
        let errorString = error.localizedDescription.lowercased()
        return errorString.contains("413") || 
               errorString.contains("oversized payload") ||
               errorString.contains("payload too large") ||
               errorString.contains("request entity too large")
    }

    private func proactivelyCompactMessagesIfNeeded(
        messages: inout [LLMMessage],
        tools: [LLMToolDefinition]?,
        maxInputTokens: Int,
        updateConversationHistory: Bool
    ) async {
        guard maxInputTokens > 0 else {
            return
        }

        let maxPasses = 3
        for pass in 1...maxPasses {
            let estimated = PromptUsageEstimator.estimatePromptTokens(messages: messages, tools: tools)
            let decision = ContextCompactionPolicy.proactiveDecision(
                estimatedPromptTokens: estimated,
                maxInputTokens: maxInputTokens
            )
            guard decision.shouldCompact else {
                return
            }

            let fillPercent = Int(((decision.fillRatio ?? 0) * 100).rounded())
            statePublisher.logInfo("Context compaction triggered (threshold85): \(estimated)/\(maxInputTokens) tokens (\(fillPercent)% full).")

            let changed = await compactMessagesForContextLimit(
                &messages,
                keepMostRecentImageOnly: false,
                maxToolResultChars: 12000
            )
            if !changed {
                statePublisher.logInfo("Context remained above threshold but no additional compaction was possible.")
                return
            }

            if updateConversationHistory {
                conversationHistory = messages
            }

            let afterEstimate = PromptUsageEstimator.estimatePromptTokens(messages: messages, tools: tools)
            let afterFill = Int(
                (PromptUsageEstimator.fillRatio(
                    estimatedPromptTokens: afterEstimate,
                    maxInputTokens: maxInputTokens
                ) * 100).rounded()
            )
            statePublisher.logInfo("Context compaction pass \(pass) -> \(afterEstimate)/\(maxInputTokens) tokens (\(afterFill)% full).")
        }
    }

    @discardableResult
    private func compactMessagesForContextLimit(
        _ messages: inout [LLMMessage],
        keepMostRecentImageOnly: Bool,
        maxToolResultChars: Int
    ) async -> Bool {
        var changed = false
        let keepRecentCount = keepMostRecentImageOnly ? 6 : 8
        if await summarizeOlderMessagesWithLLM(&messages, keepRecentCount: keepRecentCount) {
            changed = true
        }

        let maxImagesToKeep = keepMostRecentImageOnly ? 1 : 2
        var keptImageMessages = 0

        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let message = messages[i]
            let hasImages = message.role == .user && message.hasImages
            let shouldDropImages = hasImages && (keptImageMessages >= maxImagesToKeep)
            if hasImages && !shouldDropImages {
                keptImageMessages += 1
            }

            var newContent: [LLMMessageContent] = []
            var removedImages = false

            for part in message.content {
                switch part {
                case .imageBase64, .imageURL:
                    if shouldDropImages {
                        removedImages = true
                    } else {
                        newContent.append(part)
                    }
                case .toolResult(let toolCallId, let content):
                    if content.count > maxToolResultChars {
                        let truncated = String(content.prefix(maxToolResultChars))
                        newContent.append(
                            .toolResult(
                                toolCallId: toolCallId,
                                content: truncated + "\n\n[... truncated to reduce context size ...]"
                            )
                        )
                        changed = true
                    } else {
                        newContent.append(part)
                    }
                default:
                    newContent.append(part)
                }
            }

            if removedImages {
                changed = true
                if newContent.isEmpty {
                    newContent = [.text("[Image removed to reduce context usage]")]
                } else {
                    newContent.append(.text("[Image removed to reduce context usage]"))
                }
            }

            if newContent != message.content {
                changed = true
                messages[i] = LLMMessage(
                    role: message.role,
                    content: newContent,
                    name: message.name,
                    toolCalls: message.toolCalls,
                    toolCallId: message.toolCallId,
                    reasoning: message.reasoning
                )
            }
        }

        return changed
    }

    private func summarizeOlderMessagesWithLLM(
        _ messages: inout [LLMMessage],
        keepRecentCount: Int
    ) async -> Bool {
        let startIndex = messages.first?.role == .system ? 1 : 0
        let endIndexExclusive = max(startIndex, messages.count - keepRecentCount)
        guard endIndexExclusive - startIndex >= 3 else {
            return false
        }

        let olderMessages = Array(messages[startIndex..<endIndexExclusive])
        guard let summary = await generateCompactionSummaryUsingLLM(for: olderMessages) else {
            return false
        }

        let summaryMessage = LLMMessage.assistant(
            """
            [Compacted context summary generated by the model]
            \(summary)
            """
        )
        messages.replaceSubrange(startIndex..<endIndexExclusive, with: [summaryMessage])
        return true
    }

    private func generateCompactionSummaryUsingLLM(
        for messages: [LLMMessage]
    ) async -> String? {
        let transcript = buildCompactionTranscript(from: messages, maxCharacters: 24_000)
        guard !transcript.isEmpty else {
            return nil
        }

        let compactionMessages: [LLMMessage] = [
            .system(
                """
                You are compacting prior agent context for future turns.
                Produce a dense factual summary that preserves:
                - user goals and constraints
                - decisions already made
                - completed actions and outcomes
                - unresolved tasks, blockers, and errors
                - exact file paths, commands, and thresholds when present
                Do not invent facts. Keep it concise and scannable.
                """
            ),
            .user(
                """
                Compact this prior context. Return only the summary.

                \(transcript)
                """
            )
        ]

        do {
            let response = try await llmClient.chat(messages: compactionMessages, tools: nil)
            guard let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return nil
            }
            // Keep inserted summaries bounded.
            return String(text.prefix(8000))
        } catch {
            statePublisher.logInfo("LLM summary compaction failed: \(error.localizedDescription). Falling back to heuristic compaction.")
            return nil
        }
    }

    private func buildCompactionTranscript(
        from messages: [LLMMessage],
        maxCharacters: Int
    ) -> String {
        guard maxCharacters > 0 else { return "" }
        var parts: [String] = []
        var totalCount = 0

        for message in messages {
            let roleLabel = message.role.rawValue.uppercased()
            var body = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)

            let imageCount = message.content.reduce(into: 0) { partial, content in
                switch content {
                case .imageBase64, .imageURL:
                    partial += 1
                default:
                    break
                }
            }
            if imageCount > 0 {
                body += "\n[Images omitted: \(imageCount)]"
            }

            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                let names = toolCalls.map { $0.function.name }.joined(separator: ", ")
                body += "\n[Tool calls: \(names)]"
            }

            let candidate = "[\(roleLabel)] \(body)"
            guard !candidate.isEmpty else { continue }

            if totalCount + candidate.count > maxCharacters {
                let remaining = max(0, maxCharacters - totalCount)
                if remaining > 64 {
                    parts.append(String(candidate.prefix(remaining)))
                }
                parts.append("[TRUNCATED]")
                break
            }

            parts.append(candidate)
            totalCount += candidate.count
        }

        return parts.joined(separator: "\n\n")
    }

    @discardableResult
    private func truncateToolResultsForContextLimit(
        _ messages: inout [LLMMessage],
        maxToolResultChars: Int
    ) -> Bool {
        var changed = false
        for i in 0..<messages.count {
            let message = messages[i]
            var updatedContent: [LLMMessageContent] = []
            var messageChanged = false

            for part in message.content {
                switch part {
                case .toolResult(let toolCallId, let content):
                    if content.count > maxToolResultChars {
                        let truncated = String(content.prefix(maxToolResultChars))
                        updatedContent.append(
                            .toolResult(
                                toolCallId: toolCallId,
                                content: truncated + "\n\n[... truncated to reduce context size ...]"
                            )
                        )
                        messageChanged = true
                    } else {
                        updatedContent.append(part)
                    }
                default:
                    updatedContent.append(part)
                }
            }

            if messageChanged {
                changed = true
                messages[i] = LLMMessage(
                    role: message.role,
                    content: updatedContent,
                    name: message.name,
                    toolCalls: message.toolCalls,
                    toolCallId: message.toolCallId,
                    reasoning: message.reasoning
                )
            }
        }
        return changed
    }

    private func learnContextBudget(from error: Error) async -> ContextBudget? {
        guard let contextInfo = ContextLimitErrorParser.parse(error: error) else {
            return nil
        }
        let learned = await ContextBudgetResolver.shared.learnContextLimit(
            providerBaseURL: llmClient.configuration.baseURL,
            modelId: llmClient.configuration.model,
            maxInputTokens: contextInfo.maxInputTokens,
            requestedTokens: contextInfo.requestedTokens
        )
        if let learnedLimit = learned?.maxInputTokens {
            statePublisher.logInfo("Learned context budget from provider error: \(learnedLimit) tokens.")
        }
        return learned
    }
    
    /// Detect empty response errors from the model
    private func isEmptyResponseError(_ error: Error) -> Bool {
        if let llmError = error as? LLMError {
            switch llmError {
            case .noChoices:
                return true
            case .unknown(let message):
                let normalized = message.lowercased()
                return normalized.contains("empty response") || normalized.contains("no content")
            default:
                break
            }
        }
        
        let errorString = error.localizedDescription.lowercased()
        return errorString.contains("empty response") ||
               errorString.contains("no content") ||
               errorString.contains("no response choices")
    }
    
    /// Aggressively compact any message array when at minimum image scale
    /// Keeps only the most recent image
    private func aggressiveCompactMessages(_ messages: inout [LLMMessage]) {
        var foundFirst = false
        
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let message = messages[i]
            
            if message.role == .user && message.hasImages {
                if foundFirst {
                    let textContent = message.textContent
                    messages[i] = .user("[Image removed to reduce payload size]\n\(textContent)")
                } else {
                    foundFirst = true
                }
            }
        }
    }
    
    /// Downscale images in any message array to the specified scale level
    private func downscaleMessages(_ messages: inout [LLMMessage], to scaleLevel: ImageDownscaler.ScaleLevel) {
        for i in 0..<messages.count {
            let message = messages[i]
            
            guard message.role == .user && message.hasImages else { continue }
            
            var newContent: [LLMMessageContent] = []
            var wasModified = false
            
            for content in message.content {
                switch content {
                case .imageBase64(let data, let mimeType):
                    if let downscaled = ImageDownscaler.downscale(
                        base64Data: data,
                        mimeType: mimeType,
                        to: scaleLevel
                    ) {
                        newContent.append(.imageBase64(data: downscaled.data, mimeType: downscaled.mimeType))
                        wasModified = true
                    } else {
                        newContent.append(content)
                    }
                default:
                    newContent.append(content)
                }
            }
            
            if wasModified {
                messages[i] = LLMMessage(
                    role: message.role,
                    content: newContent,
                    name: message.name,
                    toolCalls: message.toolCalls,
                    toolCallId: message.toolCallId,
                    reasoning: message.reasoning
                )
            }
        }
    }
    
    /// Check if an error is retryable (transient)
    func isRetryableError(_ error: Error) -> Bool {
        let errorString = error.localizedDescription.lowercased()
        
        // Rate limits
        if errorString.contains("rate limit") || errorString.contains("too many requests") {
            return true
        }
        
        // Network errors
        if errorString.contains("network") || errorString.contains("timeout") ||
           errorString.contains("connection") || errorString.contains("temporarily unavailable") {
            return true
        }
        
        // Server errors (5xx)
        if errorString.contains("500") || errorString.contains("502") ||
           errorString.contains("503") || errorString.contains("504") {
            return true
        }
        
        // Check for URLError types
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost:
                return true
            default:
                break
            }
        }
        
        return false
    }

    func isCancellationError(_ error: Error) -> Bool {
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

    private func runCancellableLLMCall(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?
    ) async throws -> LLMResponse {
        try throwIfAgentInterrupted()

        let llmClient = self.llmClient
        let requestTask = Task<LLMResponse, Error> {
            try await llmClient.chatWithReasoningStream(
                messages: messages,
                tools: tools,
                onReasoningUpdate: onReasoningUpdate
            )
        }

        currentLLMRequestTask = requestTask
        defer {
            currentLLMRequestTask = nil
        }

        do {
            return try await requestTask.value
        } catch {
            if isTimedOut {
                throw LLMError.timeout
            }
            if isCancelled || isPaused || isCancellationError(error) {
                throw LLMError.cancelled
            }
            throw error
        }
    }

    private func throwIfAgentInterrupted() throws {
        if isTimedOut {
            throw LLMError.timeout
        }
        if isCancelled || isPaused {
            throw LLMError.cancelled
        }
    }
    
    /// Format LLM error for user-friendly display
    func formatLLMError(_ error: Error) -> String {
        let errorString = error.localizedDescription
        
        // Check for common error patterns and provide clearer messages
        if errorString.contains("401") || errorString.lowercased().contains("unauthorized") {
            return "Invalid API key - please check your provider settings"
        }
        
        if errorString.contains("403") || errorString.lowercased().contains("forbidden") {
            return "Access denied - your API key may not have access to this model"
        }
        
        if errorString.contains("404") {
            return "Model not found - please check the model ID in your provider settings"
        }
        
        if errorString.contains("429") || errorString.lowercased().contains("rate limit") {
            return "Rate limited - too many requests, will retry"
        }
        
        if errorString.contains("500") || errorString.contains("502") ||
           errorString.contains("503") || errorString.contains("504") {
            return "Server error - the API is temporarily unavailable"
        }
        
        // For network errors
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Request timed out"
            case .notConnectedToInternet:
                return "No internet connection"
            case .networkConnectionLost:
                return "Network connection lost"
            default:
                return "Network error: \(urlError.localizedDescription)"
            }
        }
        
        return errorString
    }
}
