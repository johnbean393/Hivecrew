//
//  SkillExtractor.swift
//  Hivecrew
//
//  Extracts skills from successful task traces using LLM and skill-creator
//

import Combine
import Foundation
import HivecrewShared
import HivecrewLLM

/// Extracted skill data from LLM
public struct ExtractedSkillData: Codable, Sendable {
    public let name: String
    public let description: String
    public let instructions: String
    public let allowedTools: String?
    
    public init(name: String, description: String, instructions: String, allowedTools: String?) {
        self.name = name
        self.description = description
        self.instructions = instructions
        self.allowedTools = allowedTools
    }
}

/// Service for extracting skills from successful task traces
public class SkillExtractor {
    
    // MARK: - Properties
    
    private let skillManager: SkillManager
    private let llmClient: any LLMClientProtocol
    
    // MARK: - Initialization
    
    public init(skillManager: SkillManager, llmClient: any LLMClientProtocol) {
        self.skillManager = skillManager
        self.llmClient = llmClient
    }
    
    // MARK: - Extraction
    
    /// Extract a skill from a completed task's trace
    /// - Parameters:
    ///   - taskDescription: The original task description
    ///   - tracePath: Path to the trace.jsonl file
    ///   - taskId: Optional task ID for reference
    /// - Returns: The extracted Skill
    public func extractSkill(
        taskDescription: String,
        tracePath: URL,
        taskId: String? = nil
    ) async throws -> Skill {
        // 1. Ensure skill-creator is available
        try await skillManager.ensureSkillCreatorAvailable()
        let skillCreator = try skillManager.loadSkill(name: SkillManager.skillCreatorName)
        
        // 2. Parse trace file
        let events = try AgentTracer.parseTraceFile(at: tracePath)
        
        // 3. Extract relevant data from trace
        let traceData = formatTraceData(from: events)
        
        // 4. Build extraction prompt with skill-creator instructions
        let prompt = buildExtractionPrompt(
            taskDescription: taskDescription,
            traceData: traceData,
            skillCreator: skillCreator
        )
        
        // 5. Send to LLM
        let messages: [LLMMessage] = [
            .system("You are a skill extraction assistant. Generate reusable skills following the Agent Skills specification. Always respond with valid JSON."),
            .user(prompt)
        ]
        
        let response = try await llmClient.chat(messages: messages, tools: nil)
        
        guard let text = response.text else {
            throw SkillError.extractionError("No response from LLM")
        }
        
        // 6. Parse response
        let extractedData = try parseExtractedSkill(from: text)
        
        // 7. Create Skill object
        let skill = Skill(
            name: extractedData.name,
            description: extractedData.description,
            license: nil,
            compatibility: nil,
            metadata: ["extracted-from-task": taskDescription.prefix(100).description],
            allowedTools: extractedData.allowedTools,
            instructions: extractedData.instructions,
            isImported: false,
            sourceTaskId: taskId,
            createdAt: Date(),
            isEnabled: true
        )
        
        return skill
    }
    
    // MARK: - Trace Data Formatting
    
    private func formatTraceData(from events: [TraceEvent]) -> String {
        var output = ""
        
        for event in events {
            switch event.data {
            case .toolCall(let data):
                output += "TOOL CALL: \(data.toolName)\n"
                output += "  Arguments: \(data.arguments)\n"
                
            case .toolResult(let data):
                output += "TOOL RESULT: \(data.toolName)\n"
                output += "  Success: \(data.success)\n"
                if let error = data.errorMessage {
                    output += "  Error: \(error)\n"
                }
                if let preview = data.resultPreview {
                    let truncated = String(preview.prefix(200))
                    output += "  Result: \(truncated)...\n"
                }
                
            case .llmResponse(let data):
                if let preview = data.contentPreview, !preview.isEmpty {
                    output += "LLM REASONING: \(String(preview.prefix(300)))...\n"
                }
                
            case .observation(let data):
                output += "OBSERVATION: \(data.observationType)\n"
                
            case .error(let data):
                output += "ERROR: \(data.errorType) - \(data.message)\n"
                output += "  Recoverable: \(data.recoverable)\n"
                
            case .sessionStart(let data):
                output += "SESSION START: \(data.taskDescription)\n"
                output += "  Model: \(data.model)\n"
                
            case .sessionEnd(let data):
                output += "SESSION END: \(data.status)\n"
                output += "  Steps: \(data.totalSteps)\n"
                if let summary = data.summary {
                    output += "  Summary: \(summary)\n"
                }
                
            default:
                break
            }
            
            output += "\n"
        }
        
        return output
    }
    
    // MARK: - Prompt Building
    
    private func buildExtractionPrompt(
        taskDescription: String,
        traceData: String,
        skillCreator: Skill
    ) -> String {
        """
        You are creating a new skill based on a successful task execution.
        
        Follow these guidelines for creating skills:
        
        ---
        \(skillCreator.instructions)
        ---
        
        Now, analyze this task execution and create a reusable skill:
        
        ORIGINAL TASK: \(taskDescription)
        
        EXECUTION TRACE:
        \(traceData)
        
        Based on the skill-creator guidelines above, generate a reusable skill that captures this workflow pattern.
        
        Requirements:
        1. Create a `name` (lowercase, hyphens only, max 64 chars) that describes the skill type
        2. Write a `description` (max 1024 chars) explaining what the skill does AND when to use it
        3. Write `instructions` (markdown) with:
           - Overview of the workflow
           - Step-by-step instructions (generalize specific values to placeholders like {filename}, {url})
           - Decision heuristics (when to use which tool)
           - Error recovery tips (based on any failures in the trace)
           - Common edge cases
        4. List `allowedTools` (space-delimited) based on tools actually used
        
        Keep instructions under 500 lines. Focus on the reusable pattern, not task-specific details.
        
        Respond with ONLY a valid JSON object matching this schema:
        {
            "name": "skill-name",
            "description": "What the skill does and when to use it",
            "instructions": "Full markdown instructions...",
            "allowedTools": "tool1 tool2 tool3"
        }
        """
    }
    
    // MARK: - Response Parsing
    
    private func parseExtractedSkill(from text: String) throws -> ExtractedSkillData {
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
        
        // Find JSON object bounds
        if let startIndex = jsonText.firstIndex(of: "{"),
           let endIndex = jsonText.lastIndex(of: "}") {
            jsonText = String(jsonText[startIndex...endIndex])
        }
        
        guard let jsonData = jsonText.data(using: .utf8) else {
            throw SkillError.extractionError("Failed to encode JSON")
        }
        
        do {
            let extracted = try JSONDecoder().decode(ExtractedSkillData.self, from: jsonData)
            
            // Validate name
            guard Skill.isValidName(extracted.name) else {
                throw SkillError.invalidName(extracted.name)
            }
            
            return extracted
        } catch let error as SkillError {
            throw error
        } catch {
            throw SkillError.extractionError("Failed to parse extracted skill: \(error.localizedDescription)")
        }
    }
}

// MARK: - Preview Extraction

extension SkillExtractor {
    /// Generate a preview of the extracted skill without saving
    public func previewExtraction(
        taskDescription: String,
        tracePath: URL
    ) async throws -> ExtractedSkillData {
        // Ensure skill-creator is available
        try await skillManager.ensureSkillCreatorAvailable()
        let skillCreator = try skillManager.loadSkill(name: SkillManager.skillCreatorName)
        
        // Parse trace file
        let events = try AgentTracer.parseTraceFile(at: tracePath)
        let traceData = formatTraceData(from: events)
        
        // Build prompt
        let prompt = buildExtractionPrompt(
            taskDescription: taskDescription,
            traceData: traceData,
            skillCreator: skillCreator
        )
        
        // Send to LLM
        let messages: [LLMMessage] = [
            .system("You are a skill extraction assistant. Generate reusable skills following the Agent Skills specification. Always respond with valid JSON."),
            .user(prompt)
        ]
        
        let response = try await llmClient.chat(messages: messages, tools: nil)
        
        guard let text = response.text else {
            throw SkillError.extractionError("No response from LLM")
        }
        
        return try parseExtractedSkill(from: text)
    }
}
