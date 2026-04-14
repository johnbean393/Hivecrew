//
//  APITaskRequests.swift
//  HivecrewAPI
//
//  Request and response types for task and schedule API endpoints
//

import Foundation

// MARK: - Task Actions

/// Task action types for PATCH /tasks/:id
public enum APITaskAction: String, Codable, Sendable {
    case cancel = "cancel"
    case pause = "pause"
    case resume = "resume"
    case rerun = "rerun"
    case instruct = "instruct"
    case approvePlan = "approve_plan"
    case editPlan = "edit_plan"
    case cancelPlan = "cancel_plan"
    case approveWriteback = "approve_writeback"
    case discardWriteback = "discard_writeback"
}

// MARK: - Task Requests

/// Request for POST /tasks (JSON body)
public struct CreateTaskRequest: Codable, Sendable {
    public let description: String
    public let providerName: String
    public let modelId: String
    public let priority: APITaskPriority?
    /// Custom output directory path for task deliverables (optional)
    public let outputDirectory: String?
    /// Whether to generate a plan before executing the task
    public let planFirst: Bool?
    /// Optional reasoning toggle for providers that expose boolean reasoning.
    public let reasoningEnabled: Bool?
    /// Optional reasoning effort for providers that expose explicit effort levels.
    public let reasoningEffort: String?
    /// Names of skills explicitly mentioned by the user via @skill-name
    public let mentionedSkillNames: [String]?
    /// Direct task references selected for continuation context.
    public let referencedTaskIds: [String]?
    /// Primary source task when the task was initiated as a continuation.
    public let continuationSourceTaskId: String?
    /// Optional retrieval context pack id approved by the user.
    public let contextPackId: String?
    /// Optional selected retrieval suggestion IDs used for context pack creation.
    public let contextSuggestionIds: [String]?
    /// Optional mode overrides by suggestion ID (`file_ref`, `inline_snippet`, `structured_summary`).
    public let contextModeOverrides: [String: String]?
    /// Optional inline context blocks to inject into the system prompt.
    public let contextInlineBlocks: [String]?
    /// Optional attachment paths from retrieval context pack materialization.
    public let contextAttachmentPaths: [String]?
    
    public init(
        description: String,
        providerName: String,
        modelId: String,
        priority: APITaskPriority? = nil,
        outputDirectory: String? = nil,
        planFirst: Bool? = nil,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil,
        mentionedSkillNames: [String]? = nil,
        referencedTaskIds: [String]? = nil,
        continuationSourceTaskId: String? = nil,
        contextPackId: String? = nil,
        contextSuggestionIds: [String]? = nil,
        contextModeOverrides: [String: String]? = nil,
        contextInlineBlocks: [String]? = nil,
        contextAttachmentPaths: [String]? = nil
    ) {
        self.description = description
        self.providerName = providerName
        self.modelId = modelId
        self.priority = priority
        self.outputDirectory = outputDirectory
        self.planFirst = planFirst
        self.reasoningEnabled = reasoningEnabled
        self.reasoningEffort = reasoningEffort
        self.mentionedSkillNames = mentionedSkillNames
        self.referencedTaskIds = referencedTaskIds
        self.continuationSourceTaskId = continuationSourceTaskId
        self.contextPackId = contextPackId
        self.contextSuggestionIds = contextSuggestionIds
        self.contextModeOverrides = contextModeOverrides
        self.contextInlineBlocks = contextInlineBlocks
        self.contextAttachmentPaths = contextAttachmentPaths
    }
}

/// One execution target in a multi-model batch prompt-bar submission.
public struct CreateTaskBatchTarget: Codable, Sendable, Equatable {
    public let providerId: String
    public let modelId: String
    public let copyCount: Int
    public let reasoningEnabled: Bool?
    public let reasoningEffort: String?

    public init(
        providerId: String,
        modelId: String,
        copyCount: Int = 1,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil
    ) {
        self.providerId = providerId
        self.modelId = modelId
        self.copyCount = copyCount
        self.reasoningEnabled = reasoningEnabled
        self.reasoningEffort = reasoningEffort
    }
}

/// Request for POST /tasks/batch (JSON body or multipart targets field)
public struct CreateTaskBatchRequest: Codable, Sendable {
    public let description: String
    public let planFirst: Bool?
    public let mentionedSkillNames: [String]?
    public let targets: [CreateTaskBatchTarget]

    public init(
        description: String,
        planFirst: Bool? = nil,
        mentionedSkillNames: [String]? = nil,
        targets: [CreateTaskBatchTarget]
    ) {
        self.description = description
        self.planFirst = planFirst
        self.mentionedSkillNames = mentionedSkillNames
        self.targets = targets
    }
}

/// Response for POST /tasks/batch
public struct CreateTaskBatchResponse: Codable, Sendable {
    public let tasks: [APITask]

    public init(tasks: [APITask]) {
        self.tasks = tasks
    }
}

/// Request for PATCH /tasks/:id
public struct UpdateTaskRequest: Codable, Sendable {
    public let action: APITaskAction
    public let instructions: String?
    /// Edited plan markdown, used with the `editPlan` action
    public let planMarkdown: String?
    
    public init(action: APITaskAction, instructions: String? = nil, planMarkdown: String? = nil) {
        self.action = action
        self.instructions = instructions
        self.planMarkdown = planMarkdown
    }
}

// MARK: - Question Answer

/// Request body for POST /tasks/:id/question/answer
public struct AnswerQuestionRequest: Codable, Sendable {
    public let questionId: String
    public let answer: String
    
    public init(questionId: String, answer: String) {
        self.questionId = questionId
        self.answer = answer
    }
}

// MARK: - Permission Response

/// Request body for POST /tasks/:id/permission/respond
public struct RespondToPermissionRequest: Codable, Sendable {
    public let permissionId: String
    public let approved: Bool
    
    public init(permissionId: String, approved: Bool) {
        self.permissionId = permissionId
        self.approved = approved
    }
}

// MARK: - Schedule Requests

/// Request for POST /schedules (create scheduled task)
public struct CreateScheduleRequest: Codable, Sendable {
    public let title: String
    public let description: String
    public let providerName: String
    public let modelId: String
    public let reasoningEnabled: Bool?
    public let reasoningEffort: String?
    public let outputDirectory: String?
    public let schedule: APISchedule
    
    public init(
        title: String,
        description: String,
        providerName: String,
        modelId: String,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil,
        outputDirectory: String? = nil,
        schedule: APISchedule
    ) {
        self.title = title
        self.description = description
        self.providerName = providerName
        self.modelId = modelId
        self.reasoningEnabled = reasoningEnabled
        self.reasoningEffort = reasoningEffort
        self.outputDirectory = outputDirectory
        self.schedule = schedule
    }
}
