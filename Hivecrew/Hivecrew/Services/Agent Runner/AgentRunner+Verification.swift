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
                tools: nil
            )
            
            // Parse the JSON response
            guard let responseText = response.text else {
                statePublisher.logInfo("No response from completion check, assuming success")
                return (true, agentSummary)
            }
            
            // Try to extract JSON from the response
            let jsonResult = parseCompletionJSON(responseText)
            
            if let success = jsonResult.success {
                return (success, jsonResult.summary ?? agentSummary)
            } else {
                // Fallback: assume success if we can't parse
                statePublisher.logInfo("Could not parse completion check response, assuming success")
                return (true, agentSummary)
            }
        } catch {
            // On error, assume success (don't fail the task just because verification failed)
            statePublisher.logError("Completion verification failed: \(error.localizedDescription)")
            return (true, agentSummary)
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
                let success = json["success"] as? Bool
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
    
    /// Call LLM with retry logic for transient failures
    func callLLMWithRetry(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?
    ) async throws -> LLMResponse {
        var lastError: Error?
        
        for attempt in 1...maxLLMRetries {
            do {
                return try await llmClient.chat(messages: messages, tools: tools)
            } catch {
                lastError = error
                
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
