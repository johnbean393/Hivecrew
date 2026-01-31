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
    
    // MARK: - Initialization
    
    init(llmClient: any LLMClientProtocol) {
        self.llmClient = llmClient
        self.skillMatcher = SkillMatcher(llmClient: llmClient)
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
            
            // Step 2: Match skills in parallel with plan generation start
            statePublisher.setStatus("Analyzing task and matching skills...")
            
            // Start skill matching as a task but continue with plan generation
            async let skillMatchTask = matchSkills(
                forTask: task.taskDescription,
                availableSkills: availableSkills
            )
            
            // Get skills result (this happens quickly)
            let selectedSkills = try await skillMatchTask
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
    
    /// Match skills for the task
    private func matchSkills(
        forTask task: String,
        availableSkills: [Skill]
    ) async throws -> [Skill] {
        // Only match enabled skills
        let enabledSkills = availableSkills.filter { $0.isEnabled }
        
        guard !enabledSkills.isEmpty else {
            return []
        }
        
        do {
            return try await skillMatcher.matchSkills(
                forTask: task,
                availableSkills: enabledSkills
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
        
        // Tool call loop
        var iteration = 0
        while iteration < maxToolIterations {
            iteration += 1
            
            // Call LLM with streaming for both reasoning and content
            let response = try await llmClient.chatWithStreaming(
                messages: messages,
                tools: PlanningTools.allTools,
                onReasoningUpdate: { [weak statePublisher] reasoning in
                    Task { @MainActor in
                        statePublisher?.setReasoningText(reasoning)
                    }
                },
                onContentUpdate: { [weak statePublisher] content in
                    Task { @MainActor in
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
                    
                    // Execute the tool
                    let result = try await PlanningTools.executeToolCall(
                        toolCall,
                        attachedFiles: attachedFileMap
                    )
                    
                    // Mark file as read
                    if let filename = filename {
                        statePublisher.markFileRead(filename)
                    }
                    
                    // Add tool result to messages
                    messages.append(.toolResult(
                        toolCallId: toolCall.id,
                        content: result
                    ))
                }
                
                // Clear tool call status and update status
                statePublisher.setToolCall(nil)
                statePublisher.setStatus("Generating plan...")
                
                // Continue the loop for more LLM calls
                continue
            }
            
            // No tool calls - we should have the plan
            if let text = response.text, !text.isEmpty {
                // Stream the plan text to the UI
                statePublisher.setPlanText(text)
                statePublisher.setStatus("Plan generated")
                return cleanPlanText(text)
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
