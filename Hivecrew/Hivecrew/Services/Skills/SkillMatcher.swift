//
//  SkillMatcher.swift
//  Hivecrew
//
//  LLM-based skill matching for tasks
//

import Combine
import Foundation
import HivecrewShared
import HivecrewLLM

/// Service for matching skills to tasks using LLM
public class SkillMatcher {
    
    // MARK: - Properties
    
    private let llmClient: any LLMClientProtocol
    
    // MARK: - Initialization
    
    public init(llmClient: any LLMClientProtocol) {
        self.llmClient = llmClient
    }
    
    // MARK: - Matching
    
    /// Match skills to a task using LLM
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
        
        // Select relevant skills with streaming
        let selectedSkills = try await selectSkillsWithStreaming(
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
    
    // MARK: - Select Skills
    
    private func selectSkillsWithStreaming(
        task: String,
        availableSkills: [Skill],
        onReasoningUpdate: ((String) -> Void)?
    ) async throws -> SelectedSkills {
        // Format skills (name + description only)
        let skillsText = availableSkills.map { skill in
            "- \(skill.name): \(skill.description)"
        }.joined(separator: "\n")
        
        let prompt = """
        You are selecting which skills are REQUIRED for a task. Veer on the side of strictness.
        
        TASK: \(task)
        
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
        - Task asks to "read a PDF, then write a Word document" → select docx skill (not pdf)  
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
        
        let selectedSkills = try await selectSkillsWithStreaming(
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
