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
    /// Names of skills explicitly mentioned by the user via @skill-name
    public let mentionedSkillNames: [String]?
    
    public init(
        description: String,
        providerName: String,
        modelId: String,
        priority: APITaskPriority? = nil,
        outputDirectory: String? = nil,
        planFirst: Bool? = nil,
        mentionedSkillNames: [String]? = nil
    ) {
        self.description = description
        self.providerName = providerName
        self.modelId = modelId
        self.priority = priority
        self.outputDirectory = outputDirectory
        self.planFirst = planFirst
        self.mentionedSkillNames = mentionedSkillNames
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
    public let outputDirectory: String?
    public let schedule: APISchedule
    
    public init(
        title: String,
        description: String,
        providerName: String,
        modelId: String,
        outputDirectory: String? = nil,
        schedule: APISchedule
    ) {
        self.title = title
        self.description = description
        self.providerName = providerName
        self.modelId = modelId
        self.outputDirectory = outputDirectory
        self.schedule = schedule
    }
}
