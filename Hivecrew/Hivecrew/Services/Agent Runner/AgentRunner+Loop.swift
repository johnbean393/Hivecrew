//
//  AgentRunner+Loop.swift
//  Hivecrew
//
//  Main agent loop implementation (observe -> decide -> execute)
//

import Foundation
import AppKit
import HivecrewLLM
import HivecrewAgentProtocol

// MARK: - Main Loop

extension AgentRunner {
    
    func runLoop() async throws -> AgentResult {
        while stepCount < maxSteps && !isCancelled && !isTimedOut {
            // Check if paused at the start of each iteration
            if isPaused {
                let instructions = await waitIfPaused()
                
                // Check if we were cancelled while paused
                if isCancelled {
                    break
                }
                
                // Add resume instructions to conversation if provided
                if let instructions = instructions, !instructions.isEmpty {
                    conversationHistory.append(.user("User instruction: \(instructions)"))
                }
            }
            stepCount += 1
            await tracer.nextStep()
            
            // 1. OBSERVE: Take a screenshot (skip if last tools were all host-side)
            let observation = try await observe(skipIfHostSide: !needsScreenshotUpdate)
            
            // 2. DECIDE: Send observation to LLM
            let (response, toolCalls) = try await decide(observation: observation)
            
            // Check for pause/cancel/timeout after LLM call
            if isCancelled || isTimedOut {
                break
            }
            if isPaused {
                let instructions = await waitIfPaused()
                if isCancelled { break }
                if let instructions = instructions, !instructions.isEmpty {
                    conversationHistory.append(.user("User instruction: \(instructions)"))
                }
            }
            
            // 3. EXECUTE: Run tool calls or complete if none
            if let toolCalls = toolCalls, !toolCalls.isEmpty {
                let results = try await execute(toolCalls: toolCalls)
                
                // Check if any non-host-side tools were executed
                // If all tools were host-side, we can skip the next screenshot
                let anyGuestSideTools = toolCalls.contains { toolCall in
                    if let method = AgentMethod(rawValue: toolCall.function.name) {
                        return !method.isHostSideTool
                    }
                    return false // Unknown tools assumed to need screenshot
                }
                needsScreenshotUpdate = anyGuestSideTools
                
                // Add tool results to conversation
                for result in results {
                    let content = result.success ? result.result : "Error: \(result.errorMessage ?? "Unknown error")"
                    conversationHistory.append(.toolResult(toolCallId: result.toolCallId, content: content))
                    
                    // If the tool result contains an image, inject it into the conversation
                    // as a user message with the image so the model can see it
                    if result.hasImage, let imageBase64 = result.imageBase64, let mimeType = result.imageMimeType {
                        conversationHistory.append(
                            LLMMessage.user(
                                text: "Here is the image from the \(result.toolName) tool result:",
                                images: [.imageBase64(data: imageBase64, mimeType: mimeType)]
                            )
                        )
                    }
                }
                
                // Check for pause/cancel/timeout after tool execution
                if isCancelled || isTimedOut {
                    break
                }
                if isPaused {
                    let instructions = await waitIfPaused()
                    if isCancelled { break }
                    if let instructions = instructions, !instructions.isEmpty {
                        conversationHistory.append(.user("User instruction: \(instructions)"))
                    }
                }
            } else {
                // No tool calls means the LLM thinks it's done - run completion verification
                let agentSummary = response?.text ?? "Task completed"
                
                completionAttempts += 1
                statePublisher.logInfo("Agent finished (attempt \(completionAttempts)/\(maxCompletionAttempts)). Verifying completion...")
                
                // Call LLM to verify completion with structured output
                let (verifiedSuccess, verifiedSummary) = await verifyCompletion(agentSummary: agentSummary)
                
                if verifiedSuccess {
                    // Task successfully completed
                    let finalSummary = verifiedSummary ?? agentSummary
                    
                    statePublisher.status = .completed
                    statePublisher.logInfo("Task verified as complete")
                    
                    let tokenUsage = await tracer.getTokenUsage()
                    try await tracer.logSessionEnd(status: "completed", summary: finalSummary)
                    
                    return AgentResult(
                        success: true,
                        summary: finalSummary,
                        errorMessage: nil,
                        stepCount: stepCount,
                        promptTokens: tokenUsage.prompt,
                        completionTokens: tokenUsage.completion,
                        terminationReason: .completed
                    )
                } else if completionAttempts < maxCompletionAttempts {
                    // Verification failed but we have retries left - prompt agent to continue
                    let failureReason = verifiedSummary ?? "The task does not appear to be complete."
                    
                    statePublisher.logInfo("Task incomplete: \(failureReason). Prompting agent to continue...")
                    
                    // Add a user message prompting the agent to continue
                    conversationHistory.append(.user("""
                        The task verification indicates the task is NOT complete yet.
                        
                        Reason: \(failureReason)
                        
                        Please continue working on the task. Analyze the current screen and take the necessary actions to complete the original task.
                        """))
                    
                    // Continue the loop - don't return
                } else {
                    // Max attempts reached - fail the task
                    let finalSummary = verifiedSummary ?? "Task could not be completed after \(maxCompletionAttempts) attempts"
                    
                    statePublisher.status = .failed
                    statePublisher.logInfo("Task verification failed after \(maxCompletionAttempts) attempts")
                    
                    let tokenUsage = await tracer.getTokenUsage()
                    try await tracer.logSessionEnd(status: "failed", summary: finalSummary)
                    
                    return AgentResult(
                        success: false,
                        summary: finalSummary,
                        errorMessage: "Task did not complete successfully after \(maxCompletionAttempts) verification attempts",
                        stepCount: stepCount,
                        promptTokens: tokenUsage.prompt,
                        completionTokens: tokenUsage.completion,
                        terminationReason: .failed
                    )
                }
            }
            
            // Small delay between steps to avoid overwhelming the system
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        
        // Determine termination reason
        let terminationReason: AgentTerminationReason
        let status: String
        let message: String
        
        if isCancelled {
            terminationReason = .cancelled
            status = "cancelled"
            message = "Agent was cancelled"
            statePublisher.status = .cancelled
        } else if isTimedOut {
            terminationReason = .timedOut
            status = "timed_out"
            message = "Agent timed out after \(timeoutMinutes) minutes"
            statePublisher.status = .failed
        } else {
            terminationReason = .maxIterations
            status = "max_iterations"
            message = "Reached maximum iterations (\(maxSteps))"
            statePublisher.status = .failed
        }
        
        statePublisher.logInfo(message)
        
        let tokenUsage = await tracer.getTokenUsage()
        try await tracer.logSessionEnd(status: status, summary: message)
        
        return AgentResult(
            success: false,
            summary: nil,
            errorMessage: message,
            stepCount: stepCount,
            promptTokens: tokenUsage.prompt,
            completionTokens: tokenUsage.completion,
            terminationReason: terminationReason
        )
    }
    
    /// Take a screenshot and add it to the conversation
    /// - Parameter skipIfHostSide: If true and last tools were host-side, reuses previous screenshot
    func observe(skipIfHostSide: Bool = false) async throws -> ScreenshotResult {
        statePublisher.logObservation(screenshotPath: nil)
        
        // Use cached initial screenshot for step 1, fetch new screenshot for subsequent steps
        let screenshot: ScreenshotResult
        if stepCount == 1, let initial = initialScreenshot {
            screenshot = initial
            initialScreenshot = nil // Clear the cache after use
        } else if skipIfHostSide {
            // Optimization: If last tools were all host-side (didn't affect VM state),
            // reuse the previous screenshot instead of capturing a new one
            // This saves ~200-500ms per host tool execution
            statePublisher.logInfo("Skipping screenshot (last tools were host-side)")
            // Return a placeholder - we'll reuse the last image in conversation history
            return ScreenshotResult(imageBase64: "", width: 0, height: 0)
        } else {
            screenshot = try await connection.screenshot()
        }
        
        // Save screenshot to disk
        let screenshotPath = screenshotsPath.appendingPathComponent("step_\(stepCount).png")
        if let imageData = Data(base64Encoded: screenshot.imageBase64) {
            try imageData.write(to: screenshotPath)
            
            // Update state with screenshot
            if let nsImage = NSImage(data: imageData) {
                statePublisher.updateScreenshot(nsImage, path: screenshotPath.path)
            }
        }
        
        // Log observation
        try await tracer.logObservation(
            observationType: "screenshot",
            screenshotPath: screenshotPath.path,
            screenWidth: screenshot.width,
            screenHeight: screenshot.height
        )
        
        return screenshot
    }
    
    /// Send the current state to the LLM and get a decision
    func decide(observation: ScreenshotResult) async throws -> (LLMResponse?, [LLMToolCall]?) {
        // Check for pending instructions from user
        if let instructions = statePublisher.pendingInstructions {
            statePublisher.pendingInstructions = nil
            // Add user instructions as a separate message
            conversationHistory.append(.user("User instruction: \(instructions)"))
        }
        
        // Build user message with screenshot (or reuse last one if host-side tools only)
        let userMessage: LLMMessage
        if observation.imageBase64.isEmpty {
            // Host-side tools only - no new screenshot, just add text message
            userMessage = LLMMessage.user("Tool results above (step \(stepCount)). Continue with the task.")
        } else {
            // New screenshot available
            userMessage = LLMMessage.user(
                text: "Here is the current screen (step \(stepCount)). Analyze it and decide what to do next.",
                images: [.imageBase64(data: observation.imageBase64, mimeType: "image/png")]
            )
        }
        
        // IMPORTANT: To prevent memory explosion, we only keep the most recent screenshot
        // in the conversation history. Remove old screenshot messages but keep text-only messages.
        compactConversationHistory()
        
        // Add to conversation
        conversationHistory.append(userMessage)
        
        // Log request
        statePublisher.logLLMRequest(messageCount: conversationHistory.count, toolCount: tools.count)
        try await tracer.logLLMRequest(
            messageCount: conversationHistory.count,
            toolCount: tools.count,
            model: llmClient.configuration.model
        )
        
        let startTime = Date()
        
        // Send to LLM with retry logic for transient failures
        let response: LLMResponse
        do {
            response = try await callLLMWithRetry(messages: conversationHistory, tools: tools)
        } catch {
            // Log formatted error before rethrowing
            statePublisher.logError("LLM call failed: \(formatLLMError(error))")
            throw error
        }
        
        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        
        // Log response
        let toolCalls = response.toolCalls
        statePublisher.logLLMResponse(
            text: response.text,
            toolCallCount: toolCalls?.count ?? 0,
            promptTokens: response.usage?.promptTokens ?? 0,
            completionTokens: response.usage?.completionTokens ?? 0,
            totalTokens: response.usage?.totalTokens ?? 0
        )
        try await tracer.logLLMResponse(response, latencyMs: latencyMs)
        
        // Add assistant response to conversation (with tool calls if any)
        if let toolCalls = toolCalls, !toolCalls.isEmpty {
            conversationHistory.append(.assistant(response.text ?? "", toolCalls: toolCalls))
        }
        
        return (response, toolCalls)
    }
    
    /// Execute tool calls with timeout checking
    func execute(toolCalls: [LLMToolCall]) async throws -> [ToolExecutionResult] {
        var results: [ToolExecutionResult] = []
        
        for toolCall in toolCalls {
            // Check for timeout/cancel/pause before starting each tool
            if isTimedOut || isCancelled || isPaused {
                let reason = isTimedOut ? "timed out" : (isCancelled ? "cancelled" : "paused")
                let result = ToolExecutionResult.failure(
                    toolCallId: toolCall.id,
                    toolName: toolCall.function.name,
                    error: "Agent was \(reason) before tool could execute",
                    durationMs: 0
                )
                results.append(result)
                // For pause, we want to break immediately so the loop can handle it
                if isPaused { break }
                continue
            }
            
            // Log tool call start
            statePublisher.logToolCallStart(toolName: toolCall.function.name)
            try await tracer.logToolCall(toolCall)
            
            // Execute the tool with timeout/cancel monitoring
            let result = await executeWithTimeoutCheck(toolCall: toolCall)
            results.append(result)
            
            // Log tool result
            statePublisher.logToolCallResult(
                toolName: toolCall.function.name,
                success: result.success,
                result: result.success ? result.result : (result.errorMessage ?? "Unknown error"),
                durationMs: result.durationMs
            )
            
            try await tracer.logToolResult(
                toolCallId: result.toolCallId,
                toolName: result.toolName,
                success: result.success,
                result: result.result,
                errorMessage: result.errorMessage,
                latencyMs: result.durationMs
            )
        }
        
        return results
    }
    
    /// Execute a single tool call while monitoring for timeout/cancellation
    func executeWithTimeoutCheck(toolCall: LLMToolCall) async -> ToolExecutionResult {
        let startTime = Date()
        
        // Use an AsyncStream to race tool execution against abort conditions
        let resultStream = AsyncStream<ToolExecutionResult?> { continuation in
            // Start tool execution in a separate task
            Task { @MainActor in
                let result = await self.toolExecutor.execute(toolCall: toolCall)
                continuation.yield(result)
                continuation.finish()
            }
            
            // Start abort monitor in a separate task
            Task {
                while true {
                    try? await Task.sleep(nanoseconds: 250_000_000) // Check every 250ms
                    let shouldAbort = await MainActor.run {
                        self.isTimedOut || self.isCancelled || self.isPaused
                    }
                    if shouldAbort {
                        continuation.yield(nil) // Signal abort
                        continuation.finish()
                        break
                    }
                }
            }
        }
        
        // Wait for the first result
        for await result in resultStream {
            if let toolResult = result {
                // Tool completed successfully
                return toolResult
            } else {
                // Abort signal received
                let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
                let reason: String
                if isTimedOut {
                    reason = "Agent timed out during tool execution"
                } else if isCancelled {
                    reason = "Agent was cancelled during tool execution"
                } else {
                    reason = "Agent was paused during tool execution"
                }
                return .failure(
                    toolCallId: toolCall.id,
                    toolName: toolCall.function.name,
                    error: reason,
                    durationMs: durationMs
                )
            }
        }
        
        // Fallback (shouldn't reach here)
        return .failure(
            toolCallId: toolCall.id,
            toolName: toolCall.function.name,
            error: "Tool execution ended unexpectedly",
            durationMs: Int(Date().timeIntervalSince(startTime) * 1000)
        )
    }
    
    /// Compact the conversation history to prevent memory explosion
    /// Removes old screenshot data but keeps text summaries
    func compactConversationHistory() {
        // Keep system prompt (index 0) and remove images from older user messages
        // Only keep the last 2 screenshots to provide context
        let maxScreenshotsToKeep = 2
        var screenshotCount = 0
        
        // Iterate in reverse to keep the most recent screenshots
        for i in stride(from: conversationHistory.count - 1, through: 0, by: -1) {
            let message = conversationHistory[i]
            
            // Check if this message has images
            if message.role == .user && message.hasImages {
                screenshotCount += 1
                
                if screenshotCount > maxScreenshotsToKeep {
                    // Replace with text-only version
                    let textContent = message.textContent
                    conversationHistory[i] = .user("[Screenshot from earlier step - image removed to save memory]\n\(textContent)")
                }
            }
        }
    }
}
