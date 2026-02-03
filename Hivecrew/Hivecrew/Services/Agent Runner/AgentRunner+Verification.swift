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
        var payloadTooLargeRetries = 0
        let maxPayloadRetries = 3
        var workingMessages = messages
        var workingScaleLevel = currentImageScaleLevel
        
        for attempt in 1...maxLLMRetries {
            do {
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
                let response = try await llmClient.chatWithReasoningStream(
                    messages: workingMessages,
                    tools: tools,
                    onReasoningUpdate: reasoningCallback
                )
                
                let hasText = !(response.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let hasToolCalls = !(response.toolCalls?.isEmpty ?? true)
                if !hasText && !hasToolCalls {
                    throw LLMError.unknown(message: "Empty response from model")
                }
                
                return response
            } catch {
                lastError = error
                
                // Check for payload too large error
                if isPayloadTooLargeError(error) && payloadTooLargeRetries < maxPayloadRetries {
                    payloadTooLargeRetries += 1
                    
                    // Try to downscale images further
                    if let nextLevel = workingScaleLevel.next {
                        statePublisher.logInfo("Payload too large. Downscaling images to \(nextLevel) and retrying...")
                        workingScaleLevel = nextLevel
                        downscaleMessages(&workingMessages, to: nextLevel)
                        if updateConversationHistory {
                            currentImageScaleLevel = nextLevel
                            downscaleConversationImages(to: nextLevel)
                        }
                        continue // Retry immediately without counting against normal retries
                    } else {
                        // Already at minimum scale, try removing older images
                        statePublisher.logInfo("Payload too large at minimum scale. Removing older images...")
                        aggressiveCompactMessages(&workingMessages)
                        if updateConversationHistory {
                            aggressiveCompactConversationHistory()
                        }
                        continue
                    }
                }
                
                // Retry explicitly on empty responses
                if isEmptyResponseError(error) && attempt < maxLLMRetries {
                    let delay = baseRetryDelay * pow(2.0, Double(attempt - 1))
                    statePublisher.logInfo("LLM returned empty response (attempt \(attempt)/\(maxLLMRetries)). Retrying in \(Int(delay))s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                
                // Check if error is retryable
                if isRetryableError(error) && attempt < maxLLMRetries {
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
    
    /// Aggressively compact conversation history when at minimum image scale
    /// Keeps only the most recent image
    private func aggressiveCompactConversationHistory() {
        var foundFirst = false
        
        // Iterate in reverse to keep only the most recent image
        for i in stride(from: conversationHistory.count - 1, through: 0, by: -1) {
            let message = conversationHistory[i]
            
            if message.role == .user && message.hasImages {
                if foundFirst {
                    // Remove all images except the first (most recent) one
                    let textContent = message.textContent
                    conversationHistory[i] = .user("[Image removed to reduce payload size]\n\(textContent)")
                } else {
                    foundFirst = true
                }
            }
        }
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
