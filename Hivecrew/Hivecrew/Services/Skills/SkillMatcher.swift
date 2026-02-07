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

/// Service for matching skills to tasks using LLM, with optional embedding-based pre-filtering.
///
/// Two-stage matching pipeline:
/// 1. **Stage 1 (Embedding Pre-Filter)**: Uses on-device NLEmbedding to rank skills by semantic
///    similarity to the task, keeping only the top-K candidates. Runs entirely on-device with zero
///    API calls. Only activates when the skill count exceeds a threshold (default: 10).
/// 2. **Stage 2 (LLM Selection)**: Sends the pre-filtered candidates to the LLM for final selection
///    using the existing strict matching prompt.
///
/// Falls back to sending all skills to the LLM if the embedding service is unavailable.
public class SkillMatcher {
    
    // MARK: - Properties
    
    private let llmClient: any LLMClientProtocol
    
    /// Optional embedding service for pre-filtering skills before LLM selection
    private let embeddingService: SkillEmbeddingService?
    
    // MARK: - Initialization
    
    /// - Parameters:
    ///   - llmClient: The LLM client for final skill selection
    ///   - embeddingService: Optional embedding service for semantic pre-filtering.
    ///     If nil, all skills are sent directly to the LLM (original behavior).
    public init(llmClient: any LLMClientProtocol, embeddingService: SkillEmbeddingService? = nil) {
        self.llmClient = llmClient
        self.embeddingService = embeddingService
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
    
    /// Match skills to a task with streaming reasoning updates.
    /// Uses two-stage matching when an embedding service is available:
    /// 1. Pre-filter by semantic similarity (on-device)
    /// 2. Final selection by LLM
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
        
        // Stage 1: Embedding-based pre-filtering (if available)
        let candidateSkills: [Skill]
        if let embeddingService = embeddingService, embeddingService.isAvailable {
            candidateSkills = embeddingService.rankSkills(availableSkills, forTask: task)
        } else {
            candidateSkills = availableSkills
        }
        
        // Stage 2: LLM-based final selection on the (possibly reduced) candidate set
        let selectedSkills = try await selectSkillsWithStreaming(
            task: task,
            availableSkills: candidateSkills,
            onReasoningUpdate: onReasoningUpdate
        )
        
        // Map selected skill names to actual skills (look up in original list for safety)
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
        You are selecting which skills would help complete a task. These skills have already been pre-filtered for relevance — your job is to confirm which ones genuinely apply.
        
        TASK: \(task)
        
        AVAILABLE SKILLS:
        \(skillsText)
        
        SELECTION RULES:
        1. Select a skill if the task's primary goal or deliverable matches the skill's domain
        2. Select skills whose tools, formats, or workflows the task will clearly use
        3. Do NOT select skills that are only tangentially related (e.g. don't select xlsx for a task that merely mentions "data")
        4. When multiple skills cover similar ground, prefer the most specific match
        5. It is fine to select zero skills if truly none are relevant, but do not avoid selecting relevant skills out of excessive caution
        
        Examples of when to select:
        - Task asks to "create a PowerPoint" → select pptx skill
        - Task asks to "create a 3D model" → select 3D modeling skills (e.g. build123d, render-glb)
        - Task asks to "create a website" → select frontend-design skill
        - Task asks to "analyze financial statements" → select analyzing-financial-statements skill
        
        Examples of when NOT to select:
        - Task mentions "research" but doesn't specifically need web artifacts → don't select web-artifacts-builder
        - Task is general coding but doesn't specifically need frontend design → don't select frontend-design
        - Task involves any document but doesn't specifically need Excel / LibreOffice → don't select xlsx
        
        Respond with ONLY a valid JSON object:
        {
            "selectedSkillNames": ["skill-name-here"],
            "reasoning": "Brief explanation of why each skill was selected"
        }
        """
        
        let messages: [LLMMessage] = [
            .system("You are a skill selector. Select skills that clearly match the task's domain and deliverables. These candidates have been pre-filtered for relevance, so focus on confirming genuine matches rather than defaulting to none. Always respond with valid JSON only."),
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
    /// Match skills for a task, returning skill summaries with reasoning.
    /// Uses two-stage matching (embedding pre-filter + LLM) when available.
    public func matchSkillsWithReasoning(
        forTask task: String,
        availableSkills: [Skill]
    ) async throws -> (skills: [Skill], reasoning: String) {
        guard !availableSkills.isEmpty else {
            return ([], "No skills available")
        }
        
        // Stage 1: Embedding-based pre-filtering (if available)
        let candidateSkills: [Skill]
        if let embeddingService = embeddingService, embeddingService.isAvailable {
            candidateSkills = embeddingService.rankSkills(availableSkills, forTask: task)
        } else {
            candidateSkills = availableSkills
        }
        
        // Stage 2: LLM selection
        let selectedSkills = try await selectSkillsWithStreaming(
            task: task,
            availableSkills: candidateSkills,
            onReasoningUpdate: nil
        )
        
        let matchedSkills = selectedSkills.selectedSkillNames.compactMap { name in
            availableSkills.first { $0.name == name }
        }
        
        return (matchedSkills, selectedSkills.reasoning)
    }
}
