//
//  PlanningAgent.swift
//  Hivecrew
//
//  Lightweight planning agent that generates execution plans without a VM
//

import Foundation
import HivecrewLLM
import HivecrewShared

/// A lightweight agent that generates execution plans without requiring a VM
@MainActor
class PlanningAgent {
    
    // MARK: - Properties
    
    private let llmClient: any LLMClientProtocol
    private let skillMatcher: SkillMatcher
    private weak var statePublisher: PlanningStatePublisher?
    
    /// Maximum number of tool call iterations
    private let maxToolIterations = 10
    
    /// Maximum retries for LLM calls
    private let maxLLMRetries = 3
    
    /// Maximum retries for invalid plan outputs
    private let maxInvalidPlanRetries = 2
    
    /// Base delay for exponential backoff (in seconds)
    private let baseRetryDelay: Double = 2.0
    
    // MARK: - Initialization
    
    init(llmClient: any LLMClientProtocol, embeddingService: SkillEmbeddingService? = nil) {
        self.llmClient = llmClient
        self.skillMatcher = SkillMatcher(llmClient: llmClient, embeddingService: embeddingService)
    }
    
    // MARK: - Plan Generation
    
    /// Generate an execution plan for a task
    /// - Parameters:
    ///   - task: The task record
    ///   - attachedFiles: URLs of attached files
    ///   - availableSkills: Skills available for selection
    ///   - statePublisher: Publisher for streaming UI updates
    /// - Returns: Tuple of the plan markdown and selected skills
    func generatePlan(
        task: TaskRecord,
        attachedFiles: [URL],
        availableSkills: [Skill],
        statePublisher: PlanningStatePublisher
    ) async throws -> (planMarkdown: String, selectedSkills: [Skill]) {
        self.statePublisher = statePublisher
        
        // Start generation
        statePublisher.startGeneration()
        
        do {
            // Step 1: Build file mapping (fast, do first)
            let attachedFileMap = buildAttachedFileMap(from: attachedFiles)
            let fileList = PlanningPrompts.buildFileList(from: attachedFiles)
            
            // Step 2: Match skills with streaming reasoning
            statePublisher.setStatus("Matching skills...")
            let selectedSkills = try await matchSkills(
                forTask: task.taskDescription,
                availableSkills: availableSkills,
                statePublisher: statePublisher
            )
            statePublisher.setSelectedSkills(selectedSkills.map(\.name))
            
            // Step 3: Generate the plan
            statePublisher.setStatus("Generating execution plan...")
            let planMarkdown = try await generatePlanWithToolLoop(
                task: task.taskDescription,
                fileList: fileList,
                attachedFileMap: attachedFileMap,
                selectedSkills: selectedSkills,
                statePublisher: statePublisher
            )
            
            statePublisher.setPlanText(planMarkdown)
            statePublisher.completeGeneration()
            
            return (planMarkdown, selectedSkills)
            
        } catch {
            statePublisher.failGeneration(with: error)
            throw error
        }
    }
    
    /// Revise an existing plan based on user feedback
    /// - Parameters:
    ///   - currentPlan: The current plan markdown
    ///   - revisionRequest: The user's revision request
    /// - Returns: The revised plan markdown
    func revisePlan(
        currentPlan: String,
        revisionRequest: String
    ) async throws -> String {
        let messages: [LLMMessage] = [
            .system("You are a planning assistant. Update the plan according to the user's request. Keep the Markdown format with checkbox items."),
            .user(PlanningPrompts.revisionPrompt(currentPlan: currentPlan, revisionRequest: revisionRequest))
        ]
        
        let response = try await llmClient.chat(messages: messages, tools: nil)
        
        guard let text = response.text, !text.isEmpty else {
            throw PlanningError.noResponseGenerated
        }
        
        return text
    }
    
    // MARK: - Private Methods
    
    /// Match skills for the task with streaming reasoning updates
    private func matchSkills(
        forTask task: String,
        availableSkills: [Skill],
        statePublisher: PlanningStatePublisher
    ) async throws -> [Skill] {
        // Only match enabled skills
        let enabledSkills = availableSkills.filter { $0.isEnabled }
        
        guard !enabledSkills.isEmpty else {
            return []
        }
        
        do {
            return try await skillMatcher.matchSkillsWithStreaming(
                forTask: task,
                availableSkills: enabledSkills,
                onReasoningUpdate: { [weak statePublisher] reasoning in
                    Task { @MainActor in
                        statePublisher?.setReasoningText(reasoning)
                    }
                }
            )
        } catch {
            // Skill matching failure shouldn't fail the whole plan
            print("Skill matching failed: \(error)")
            return []
        }
    }
    
    /// Build a map from filename to host file URL
    private func buildAttachedFileMap(from attachedFiles: [URL]) -> [String: URL] {
        var map: [String: URL] = [:]
        for url in attachedFiles {
            map[url.lastPathComponent] = url
        }
        return map
    }
    
    /// Generate the plan with a tool call loop for reading files
    private func generatePlanWithToolLoop(
        task: String,
        fileList: [(filename: String, vmPath: String)],
        attachedFileMap: [String: URL],
        selectedSkills: [Skill],
        statePublisher: PlanningStatePublisher
    ) async throws -> String {
        // Build the system prompt
        let systemPrompt = PlanningPrompts.systemPrompt(
            task: task,
            attachedFiles: fileList,
            availableSkills: selectedSkills
        )
        
        // Initialize conversation
        var messages: [LLMMessage] = [
            .system(systemPrompt),
            .user(PlanningPrompts.generatePlanPrompt(task: task))
        ]
        
        var invalidPlanAttempts = 0
        var lastStreamedPlanText = ""
        
        // Tool call loop
        var iteration = 0
        while iteration < maxToolIterations {
            iteration += 1
            lastStreamedPlanText = ""
            
            // Call LLM with streaming for both reasoning and content
            let response = try await callLLMWithRetry(
                messages: &messages,
                tools: PlanningTools.allTools,
                statePublisher: statePublisher,
                onReasoningUpdate: { [weak statePublisher] reasoning in
                    Task { @MainActor in
                        statePublisher?.setReasoningText(reasoning)
                    }
                },
                onContentUpdate: { [weak statePublisher] content in
                    Task { @MainActor in
                        lastStreamedPlanText = content
                        // Stream the plan content as it arrives
                        statePublisher?.setPlanText(content)
                    }
                }
            )
            
            // Check for tool calls
            if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                // Add assistant message with tool calls
                messages.append(.assistant(
                    response.text ?? "",
                    toolCalls: toolCalls
                ))
                
                // Execute each tool call
                for toolCall in toolCalls {
                    // Update UI with tool call status
                    let filename = extractFilename(from: toolCall)
                    statePublisher.setToolCall("Reading", details: filename)
                    statePublisher.setStatus("Reading \(filename ?? "file")...")
                    
                    // Execute the tool with error handling
                    let result: PlanningToolResult
                    do {
                        result = try await PlanningTools.executeToolCall(
                            toolCall,
                            attachedFiles: attachedFileMap
                        )
                    } catch {
                        // Return error as text result instead of crashing
                        result = PlanningToolResult.text("Error reading file: \(error.localizedDescription)")
                    }
                    
                    // Mark file as read
                    if let filename = filename {
                        statePublisher.markFileRead(filename)
                    }
                    
                    // Add tool result text to messages
                    messages.append(.toolResult(
                        toolCallId: toolCall.id,
                        content: result.text
                    ))
                    
                    // If the result contains an image, inject it as a user message
                    // so the model can see it (same pattern as AgentRunner+Loop.swift)
                    if result.hasImage,
                       let imageBase64 = result.imageBase64,
                       let imageMimeType = result.imageMimeType {
                        messages.append(
                            LLMMessage.user(
                                text: "Here is the image from the read_file tool result:",
                                images: [.imageBase64(data: imageBase64, mimeType: imageMimeType)]
                            )
                        )
                    }
                }
                
                // Clear tool call status and update status
                statePublisher.setToolCall(nil)
                statePublisher.setStatus("Generating plan...")
                
                // Continue the loop for more LLM calls
                continue
            }
            
            // No tool calls - we should have the plan
            let rawText = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let candidateText = rawText.isEmpty ? lastStreamedPlanText : rawText
            let cleaned = cleanPlanText(candidateText)
            
            if let validationError = validatePlanText(cleaned) {
                invalidPlanAttempts += 1
                if invalidPlanAttempts <= maxInvalidPlanRetries {
                    statePublisher.setStatus("Plan output invalid. Retrying...")
                    
                    if let responseText = response.text, !responseText.isEmpty {
                        messages.append(.assistant(responseText))
                    }
                    
                    let retryPrompt = """
                    The plan output was invalid: \(validationError)
                    
                    Please output the full plan again, following the required format:
                    - Title heading (#)
                    - Overview paragraph
                    - Implementation sections
                    - ## Tasks section with checkbox items (- [ ])
                    """
                    messages.append(.user(retryPrompt))
                    continue
                }
                
                throw PlanningError.invalidPlan(validationError)
            }
            
            if !cleaned.isEmpty {
                // Stream the plan text to the UI
                statePublisher.setPlanText(cleaned)
                statePublisher.setStatus("Plan generated")
                return cleaned
            }
            
            // No response - something went wrong
            throw PlanningError.noResponseGenerated
        }
        
        throw PlanningError.maxIterationsReached
    }
    
    /// Extract the filename from a tool call
    private func extractFilename(from toolCall: LLMToolCall) -> String? {
        guard toolCall.function.name == "read_file" else { return nil }
        
        do {
            let args = try toolCall.function.argumentsDictionary()
            return args["filename"] as? String
        } catch {
            return nil
        }
    }
    
    /// Clean up the plan text (remove markdown code blocks if present)
    private func cleanPlanText(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code block wrapper if present
        if cleaned.hasPrefix("```markdown") {
            cleaned = String(cleaned.dropFirst(11))
        } else if cleaned.hasPrefix("```md") {
            cleaned = String(cleaned.dropFirst(5))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Validate that the plan text is usable and complete enough
    private func validatePlanText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Plan output was empty."
        }
        
        if PlanParser.extractTitle(from: trimmed) == nil {
            return "Missing title heading (# Title)."
        }
        
        let tasks = PlanParser.parseTodos(from: trimmed)
        if tasks.isEmpty {
            return "Missing Tasks checklist items (- [ ])."
        }
        
        return nil
    }
    
    /// Call LLM with retry logic and payload compaction
    private func callLLMWithRetry(
        messages: inout [LLMMessage],
        tools: [LLMToolDefinition],
        statePublisher: PlanningStatePublisher,
        onReasoningUpdate: @escaping ReasoningStreamCallback,
        onContentUpdate: @escaping ContentStreamCallback
    ) async throws -> LLMResponse {
        var lastError: Error?
        var contextCompactions = 0
        let maxContextCompactions = 3
        let initialBudget = await ContextBudgetResolver.shared.resolve(using: llmClient)
        var maxInputTokens = initialBudget.maxInputTokens

        if let maxInputTokens {
            await proactivelyCompactMessagesIfNeeded(
                messages: &messages,
                tools: tools,
                maxInputTokens: maxInputTokens,
                statePublisher: statePublisher
            )
        }
        
        for attempt in 1...maxLLMRetries {
            do {
                if attempt > 1 {
                    statePublisher.setStatus("Retrying plan generation (attempt \(attempt)/\(maxLLMRetries))...")
                }
                
                let response = try await llmClient.chatWithStreaming(
                    messages: messages,
                    tools: tools,
                    onReasoningUpdate: onReasoningUpdate,
                    onContentUpdate: onContentUpdate
                )
                
                return response
            } catch {
                lastError = error

                if let learnedBudget = await learnContextBudget(from: error, statePublisher: statePublisher) {
                    maxInputTokens = learnedBudget.maxInputTokens ?? maxInputTokens
                }

                if let reason = ContextCompactionPolicy.compactionReason(for: error),
                   contextCompactions < maxContextCompactions {
                    contextCompactions += 1
                    statePublisher.setStatus("Context compaction triggered (\(reason.rawValue)). Reducing context and retrying...")
                    messages = await compactMessagesForLargePayloadWithLLM(messages, statePublisher: statePublisher)
                    if let maxInputTokens {
                        await proactivelyCompactMessagesIfNeeded(
                            messages: &messages,
                            tools: tools,
                            maxInputTokens: maxInputTokens,
                            statePublisher: statePublisher
                        )
                    }
                    continue
                }
                
                if isRetryableError(error) && attempt < maxLLMRetries {
                    let delay = baseRetryDelay * pow(2.0, Double(attempt - 1))
                    statePublisher.setStatus("Plan generation failed. Retrying in \(Int(delay))s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                
                throw error
            }
        }
        
        throw lastError ?? PlanningError.noResponseGenerated
    }

    private func proactivelyCompactMessagesIfNeeded(
        messages: inout [LLMMessage],
        tools: [LLMToolDefinition],
        maxInputTokens: Int,
        statePublisher: PlanningStatePublisher
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
            statePublisher.setStatus("Context compaction triggered (threshold85): \(fillPercent)% full. Reducing context...")

            let compacted = await compactMessagesForLargePayloadWithLLM(
                messages,
                statePublisher: statePublisher
            )
            if compacted == messages {
                statePublisher.setStatus("Context exceeded threshold but no additional compaction was possible.")
                return
            }
            messages = compacted

            let afterEstimate = PromptUsageEstimator.estimatePromptTokens(messages: messages, tools: tools)
            let afterFill = Int(
                (PromptUsageEstimator.fillRatio(
                    estimatedPromptTokens: afterEstimate,
                    maxInputTokens: maxInputTokens
                ) * 100).rounded()
            )
            statePublisher.setStatus("Context compaction pass \(pass) -> \(afterFill)% full.")
        }
    }

    private func learnContextBudget(
        from error: Error,
        statePublisher: PlanningStatePublisher
    ) async -> ContextBudget? {
        guard let info = ContextLimitErrorParser.parse(error: error) else {
            return nil
        }

        let learned = await ContextBudgetResolver.shared.learnContextLimit(
            providerBaseURL: llmClient.configuration.baseURL,
            modelId: llmClient.configuration.model,
            maxInputTokens: info.maxInputTokens,
            requestedTokens: info.requestedTokens
        )

        if let learnedLimit = learned?.maxInputTokens {
            statePublisher.setStatus("Learned provider context limit (\(learnedLimit) tokens). Applying stricter compaction.")
        }

        return learned
    }

    private func compactMessagesForLargePayloadWithLLM(
        _ messages: [LLMMessage],
        statePublisher: PlanningStatePublisher
    ) async -> [LLMMessage] {
        var working = messages
        if await summarizeOlderMessagesWithLLM(&working) {
            statePublisher.setStatus("Applied model-based context summary compaction.")
        }
        return compactMessagesForLargePayload(working)
    }

    private func summarizeOlderMessagesWithLLM(
        _ messages: inout [LLMMessage]
    ) async -> Bool {
        let startIndex = messages.first?.role == .system ? 1 : 0
        let keepRecentCount = 6
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
                You are compacting prior planner context for future turns.
                Preserve all task requirements, constraints, decisions, tool outputs, unresolved issues,
                and critical file paths. Do not invent facts. Return only the compacted summary.
                """
            ),
            .user(
                """
                Compact this prior planning context:

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
            return String(text.prefix(8000))
        } catch {
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
            let candidate = "[\(roleLabel)] \(body)"
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
    
    /// Determine whether an error is retryable
    private func isRetryableError(_ error: Error) -> Bool {
        if let llmError = error as? LLMError {
            return llmError.isRetryable
        }
        
        let errorString = error.localizedDescription.lowercased()
        if errorString.contains("rate limit") || errorString.contains("too many requests") {
            return true
        }
        if errorString.contains("network") || errorString.contains("timeout") ||
           errorString.contains("connection") || errorString.contains("temporarily unavailable") {
            return true
        }
        if errorString.contains("500") || errorString.contains("502") ||
           errorString.contains("503") || errorString.contains("504") {
            return true
        }
        
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
    
    /// Compact messages when payload is too large by trimming tool output and removing images
    private func compactMessagesForLargePayload(_ messages: [LLMMessage]) -> [LLMMessage] {
        let maxToolResultChars = 12000
        var compacted: [LLMMessage] = []
        
        for message in messages {
            var newContent: [LLMMessageContent] = []
            var removedImage = false
            
            for part in message.content {
                switch part {
                case .imageBase64, .imageURL:
                    removedImage = true
                case .toolResult(let toolCallId, let content):
                    if content.count > maxToolResultChars {
                        let truncated = String(content.prefix(maxToolResultChars))
                        let suffix = "\n\n[... truncated to reduce payload size ...]"
                        newContent.append(.toolResult(toolCallId: toolCallId, content: truncated + suffix))
                    } else {
                        newContent.append(part)
                    }
                default:
                    newContent.append(part)
                }
            }
            
            if removedImage {
                if newContent.isEmpty {
                    newContent = [.text("[Image removed to reduce payload size]")]
                } else {
                    newContent.append(.text("[Image removed to reduce payload size]"))
                }
            }
            
            if newContent.isEmpty {
                compacted.append(message)
            } else {
                compacted.append(LLMMessage(
                    role: message.role,
                    content: newContent,
                    name: message.name,
                    toolCalls: message.toolCalls,
                    toolCallId: message.toolCallId,
                    reasoning: message.reasoning
                ))
            }
        }
        
        return compacted
    }
}

// MARK: - Errors

public enum PlanningError: Error, LocalizedError {
    case noResponseGenerated
    case maxIterationsReached
    case invalidPlan(String)
    
    public var errorDescription: String? {
        switch self {
        case .noResponseGenerated:
            return "Failed to generate a plan - no response from LLM"
        case .maxIterationsReached:
            return "Plan generation exceeded maximum iterations"
        case .invalidPlan(let reason):
            return "Invalid plan: \(reason)"
        }
    }
}
