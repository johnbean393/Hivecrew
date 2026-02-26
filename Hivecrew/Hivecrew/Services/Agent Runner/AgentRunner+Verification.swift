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

        let hooks = SharedLLMRetryHandler.Hooks(
            logInfo: { [weak self] message in
                self?.statePublisher.logInfo(message)
            },
            checkInterruption: { [weak self] in
                try self?.throwIfAgentInterrupted()
            },
            onMessagesChanged: { [weak self] compactedMessages in
                guard let self, updateConversationHistory else { return }
                self.conversationHistory = compactedMessages
            },
            onImageScaleLevelChanged: { [weak self] newScale in
                guard let self, updateConversationHistory else { return }
                self.currentImageScaleLevel = newScale
            }
        )

        let options = SharedLLMRetryHandler.Options(
            maxLLMRetries: maxLLMRetries,
            maxContextCompactionRetries: 3,
            baseRetryDelay: baseRetryDelay,
            proactiveCompactionPasses: 3,
            normalToolResultLimit: 12000,
            aggressiveToolResultLimit: 8000
        )

        let outcome = try await SharedLLMRetryHandler.callWithRetry(
            llmClient: llmClient,
            messages: messages,
            tools: tools,
            imageScaleLevel: currentImageScaleLevel,
            onReasoningUpdate: reasoningCallback,
            onContentUpdate: nil,
            llmCall: { [weak self] callMessages, callTools, callReasoningUpdate, _ in
                guard let self else { throw LLMError.cancelled }
                return try await self.runCancellableLLMCall(
                    messages: callMessages,
                    tools: callTools,
                    onReasoningUpdate: callReasoningUpdate
                )
            },
            options: options,
            hooks: hooks
        )

        if updateConversationHistory {
            conversationHistory = outcome.messages
            currentImageScaleLevel = outcome.imageScaleLevel
        }

        return outcome.response
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
