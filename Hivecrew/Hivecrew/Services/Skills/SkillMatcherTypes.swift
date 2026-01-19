//
//  SkillMatcherTypes.swift
//  Hivecrew
//
//  Structured output types for skill matching
//

import Combine
import Foundation

// MARK: - Step 1: Task Steps

/// Response from LLM Call 1: List of steps needed to complete a task
public struct TaskSteps: Codable, Sendable {
    public let steps: [TaskStep]
    
    public init(steps: [TaskStep]) {
        self.steps = steps
    }
}

/// A single step in the task execution plan
public struct TaskStep: Codable, Sendable {
    /// Step number (1-indexed)
    public let stepNumber: Int
    
    /// What needs to be done in this step
    public let description: String
    
    /// Category of work (e.g., "file-operation", "web-research", "ui-interaction", "document-creation")
    public let category: String
    
    /// Tools likely needed for this step (e.g., ["open_app", "keyboard_type", "run_shell"])
    public let toolsLikelyNeeded: [String]
    
    public init(stepNumber: Int, description: String, category: String, toolsLikelyNeeded: [String]) {
        self.stepNumber = stepNumber
        self.description = description
        self.category = category
        self.toolsLikelyNeeded = toolsLikelyNeeded
    }
}

// MARK: - Step 2: Selected Skills

/// Response from LLM Call 2: Skills selected for the task
public struct SelectedSkills: Codable, Sendable {
    /// Names of skills to use
    public let selectedSkillNames: [String]
    
    /// Brief explanation of why these skills were selected
    public let reasoning: String
    
    public init(selectedSkillNames: [String], reasoning: String) {
        self.selectedSkillNames = selectedSkillNames
        self.reasoning = reasoning
    }
}

// MARK: - JSON Schema Definitions

extension TaskSteps {
    /// JSON schema for structured output
    public static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "steps": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "stepNumber": ["type": "integer", "description": "Step number (1-indexed)"],
                            "description": ["type": "string", "description": "What needs to be done in this step"],
                            "category": [
                                "type": "string",
                                "description": "Category of work",
                                "enum": [
                                    "file-operation",
                                    "web-research",
                                    "ui-interaction",
                                    "document-creation",
                                    "data-processing",
                                    "system-operation",
                                    "communication",
                                    "other"
                                ]
                            ],
                            "toolsLikelyNeeded": [
                                "type": "array",
                                "items": ["type": "string"],
                                "description": "Tools likely needed for this step"
                            ]
                        ],
                        "required": ["stepNumber", "description", "category", "toolsLikelyNeeded"]
                    ]
                ]
            ],
            "required": ["steps"]
        ]
    }
}

extension SelectedSkills {
    /// JSON schema for structured output
    public static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "selectedSkillNames": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Names of skills to use for this task"
                ],
                "reasoning": [
                    "type": "string",
                    "description": "Brief explanation of why these skills were selected"
                ]
            ],
            "required": ["selectedSkillNames", "reasoning"]
        ]
    }
}
