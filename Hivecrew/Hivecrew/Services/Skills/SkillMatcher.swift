//
//  SkillMatcher.swift
//  Hivecrew
//
//  Two-step LLM process to match skills to tasks
//

import Combine
import Foundation
import HivecrewShared
import HivecrewLLM

/// Service for matching skills to tasks using a two-step LLM process
public class SkillMatcher {
    
    // MARK: - Properties
    
    private let llmClient: any LLMClientProtocol
    
    // MARK: - Initialization
    
    public init(llmClient: any LLMClientProtocol) {
        self.llmClient = llmClient
    }
    
    // MARK: - Matching
    
    /// Match skills to a task using two-step LLM process
    /// - Parameters:
    ///   - task: The task description
    ///   - availableSkills: List of available skills
    /// - Returns: Array of matched skills
    public func matchSkills(
        forTask task: String,
        availableSkills: [Skill]
    ) async throws -> [Skill] {
        try await matchSkillsWithStreaming(
            forTask: task,
            availableSkills: availableSkills,
            onReasoningUpdate: nil
        )
    }
    
    /// Match skills to a task with streaming reasoning updates
    /// - Parameters:
    ///   - task: The task description
    ///   - availableSkills: List of available skills
    ///   - onReasoningUpdate: Callback for streaming reasoning text
    /// - Returns: Array of matched skills
    public func matchSkillsWithStreaming(
        forTask task: String,
        availableSkills: [Skill],
        onReasoningUpdate: ((String) -> Void)?
    ) async throws -> [Skill] {
        // If no skills available, return empty
        guard !availableSkills.isEmpty else {
            return []
        }
        
        // Step 1: Generate task steps with streaming
        let taskSteps = try await generateTaskStepsWithStreaming(
            for: task,
            onReasoningUpdate: onReasoningUpdate
        )
        
        // If no steps generated, return empty
        guard !taskSteps.steps.isEmpty else {
            return []
        }
        
        // Step 2: Select relevant skills with streaming
        let selectedSkills = try await selectSkillsWithStreaming(
            forSteps: taskSteps,
            task: task,
            availableSkills: availableSkills,
            onReasoningUpdate: onReasoningUpdate
        )
        
        // Map selected skill names to actual skills
        let matchedSkills = selectedSkills.selectedSkillNames.compactMap { name in
            availableSkills.first { $0.name == name }
        }
        
        return matchedSkills
    }
    
    // MARK: - Step 1: Generate Task Steps
    
    private func generateTaskStepsWithStreaming(
        for task: String,
        onReasoningUpdate: ((String) -> Void)?
    ) async throws -> TaskSteps {
        let prompt = """
        You are planning the steps needed to complete a task for a macOS automation agent.
        
        TASK: \(task)
        
        Generate a list of high-level steps the agent should take. For each step, identify:
        - A brief description
        - The category of work (file-operation, web-research, ui-interaction, document-creation, data-processing, system-operation, communication, other)
        - Tools likely needed (examples: open_app, keyboard_type, run_shell, read_file, mouse_click, web_search, etc.)
        
        Keep the list concise (3-7 steps typically).
        
        Respond with ONLY a valid JSON object matching this schema:
        {
            "steps": [
                {
                    "stepNumber": 1,
                    "description": "What needs to be done",
                    "category": "category-name",
                    "toolsLikelyNeeded": ["tool1", "tool2"]
                }
            ]
        }
        """
        
        let messages: [LLMMessage] = [
            .system("You are a task planning assistant. Always respond with valid JSON only, no additional text."),
            .user(prompt)
        ]
        
        let response = try await llmClient.chatWithStreaming(
            messages: messages,
            tools: nil,
            onReasoningUpdate: onReasoningUpdate,
            onContentUpdate: nil
        )
        
        guard let text = response.text else {
            throw SkillError.matchingError("No response from LLM")
        }
        
        // Parse JSON response
        guard let jsonData = extractJSON(from: text).data(using: .utf8) else {
            throw SkillError.matchingError("Failed to extract JSON from response")
        }
        
        do {
            let taskSteps = try JSONDecoder().decode(TaskSteps.self, from: jsonData)
            return taskSteps
        } catch {
            throw SkillError.matchingError("Failed to parse task steps: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Step 2: Select Skills
    
    private func selectSkillsWithStreaming(
        forSteps taskSteps: TaskSteps,
        task: String,
        availableSkills: [Skill],
        onReasoningUpdate: ((String) -> Void)?
    ) async throws -> SelectedSkills {
        // Format steps for prompt
        let stepsText = taskSteps.steps.map { step in
            "\(step.stepNumber). \(step.description) [Category: \(step.category), Tools: \(step.toolsLikelyNeeded.joined(separator: ", "))]"
        }.joined(separator: "\n")
        
        // Format skills (name + description only)
        let skillsText = availableSkills.map { skill in
            "- \(skill.name): \(skill.description)"
        }.joined(separator: "\n")
        
        let prompt = """
        You are selecting which skills are REQUIRED for a task. Veer on the side of strictness.
        
        ORIGINAL TASK: \(task)
        
        TASK STEPS:
        \(stepsText)
        
        AVAILABLE SKILLS:
        \(skillsText)
        
        SELECTION RULES:
        1. ONLY select a skill if the task requires and makes HEAVY use of that skill's specific capability
        2. A skill must match the PRIMARY deliverable or format requested in the task
        3. Do NOT select skills for tangential or "nice to have" features
        4. Do NOT select skills just because they COULD be useful - they must be REQUIRED and HEAVILY USED
        5. When in doubt, do NOT include the skill
        6. Prefer selecting ZERO skills over selecting marginally relevant ones
        
        Examples of when to select:
        - Task asks to "create a PowerPoint" → select pptx skill
        - Task asks to "read a PDF, then write a Word document" → select docx skill  
        - Task asks to "extract text from a PDF" → select pdf skill
        - Task asks to "create a website" -> select a frontend-design skill
        
        Examples of when NOT to select:
        - Task mentions "research" but doesn't specifically need web artifacts → don't select web-artifacts-builder
        - Task is general coding but doesn't specifically need frontend design → don't select frontend-design
        - Task involves any document but doesn't specifically need Excel / LibreOffice → don't select xlsx
        
        Return an EMPTY array if no skills are essential.
        
        Respond with ONLY a valid JSON object:
        {
            "selectedSkillNames": [],
            "reasoning": "Brief explanation"
        }
        """
        
        let messages: [LLMMessage] = [
            .system("You are a strict skill selector. Default to selecting NO skills. Only select skills that are EXPLICITLY required by the task. Always respond with valid JSON only."),
            .user(prompt)
        ]
        
        let response = try await llmClient.chatWithStreaming(
            messages: messages,
            tools: nil,
            onReasoningUpdate: onReasoningUpdate,
            onContentUpdate: nil
        )
        
        guard let text = response.text else {
            throw SkillError.matchingError("No response from LLM")
        }
        
        // Parse JSON response
        guard let jsonData = extractJSON(from: text).data(using: .utf8) else {
            throw SkillError.matchingError("Failed to extract JSON from response")
        }
        
        do {
            let selectedSkills = try JSONDecoder().decode(SelectedSkills.self, from: jsonData)
            return selectedSkills
        } catch {
            throw SkillError.matchingError("Failed to parse selected skills: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helpers
    
    /// Extract JSON from a response that might contain markdown code blocks
    private func extractJSON(from text: String) -> String {
        var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code blocks if present
        if jsonText.hasPrefix("```json") {
            jsonText = String(jsonText.dropFirst(7))
        } else if jsonText.hasPrefix("```") {
            jsonText = String(jsonText.dropFirst(3))
        }
        
        if jsonText.hasSuffix("```") {
            jsonText = String(jsonText.dropLast(3))
        }
        
        jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Try to find JSON object bounds
        if let startIndex = jsonText.firstIndex(of: "{"),
           let endIndex = jsonText.lastIndex(of: "}") {
            jsonText = String(jsonText[startIndex...endIndex])
        }
        
        return jsonText
    }
}

// MARK: - Convenience Extension

extension SkillMatcher {
    /// Match skills for a task, returning skill summaries with reasoning
    public func matchSkillsWithReasoning(
        forTask task: String,
        availableSkills: [Skill]
    ) async throws -> (skills: [Skill], reasoning: String) {
        guard !availableSkills.isEmpty else {
            return ([], "No skills available")
        }
        
        let taskSteps = try await generateTaskStepsWithStreaming(for: task, onReasoningUpdate: nil)
        guard !taskSteps.steps.isEmpty else {
            return ([], "Could not determine task steps")
        }
        
        let selectedSkills = try await selectSkillsWithStreaming(
            forSteps: taskSteps,
            task: task,
            availableSkills: availableSkills,
            onReasoningUpdate: nil
        )
        
        let matchedSkills = selectedSkills.selectedSkillNames.compactMap { name in
            availableSkills.first { $0.name == name }
        }
        
        return (matchedSkills, selectedSkills.reasoning)
    }
}
