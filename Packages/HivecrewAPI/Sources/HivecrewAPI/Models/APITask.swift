//
//  APITask.swift
//  HivecrewAPI
//
//  Core task models: status enums, task detail, task summary, and list response
//

import Foundation

// MARK: - Enums

/// Task status values
public enum APITaskStatus: String, Codable, Sendable {
    case queued = "queued"
    case waitingForVM = "waiting_for_vm"
    case running = "running"
    case paused = "paused"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
    case timedOut = "timed_out"
    case maxIterations = "max_iterations"
    case planning = "planning"
    case planReview = "plan_review"
    case planFailed = "plan_failed"
}

/// Task priority values
public enum APITaskPriority: String, Codable, Sendable {
    case low = "low"
    case normal = "normal"
    case high = "high"
}

// MARK: - Agent Question

/// A pending question from the agent that requires a human answer before the task can proceed.
public struct APIAgentQuestion: Codable, Sendable {
    public let id: String
    public let question: String
    public let suggestedAnswers: [String]?
    public let createdAt: Date
    
    public init(
        id: String,
        question: String,
        suggestedAnswers: [String]? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.question = question
        self.suggestedAnswers = suggestedAnswers
        self.createdAt = createdAt
    }
}

// MARK: - Permission Request

/// A pending permission request from the agent for a potentially dangerous operation.
public struct APIPermissionRequest: Codable, Sendable {
    public let id: String
    public let toolName: String
    public let details: String
    public let createdAt: Date
    
    public init(
        id: String,
        toolName: String,
        details: String,
        createdAt: Date
    ) {
        self.id = id
        self.toolName = toolName
        self.details = details
        self.createdAt = createdAt
    }
}

// MARK: - Supporting Types

/// Token usage information
public struct APITokenUsage: Codable, Sendable {
    public let prompt: Int
    public let completion: Int
    public let total: Int
    
    public init(prompt: Int, completion: Int, total: Int) {
        self.prompt = prompt
        self.completion = completion
        self.total = total
    }
}

// MARK: - Task Models

/// Task response model (full details)
public struct APITask: Codable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let status: APITaskStatus
    public let providerName: String
    public let modelId: String
    public let createdAt: Date
    public let startedAt: Date?
    public let completedAt: Date?
    public let resultSummary: String?
    public let errorMessage: String?
    public let inputFiles: [APIFile]
    public let outputFiles: [APIFile]
    public let wasSuccessful: Bool?
    public let vmId: String?
    public let duration: Int?
    public let stepCount: Int?
    public let tokenUsage: APITokenUsage?
    public let planMarkdown: String?
    public let planFirst: Bool?
    public let pendingQuestion: APIAgentQuestion?
    public let pendingPermission: APIPermissionRequest?
    
    public init(
        id: String,
        title: String,
        description: String,
        status: APITaskStatus,
        providerName: String,
        modelId: String,
        createdAt: Date,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        resultSummary: String? = nil,
        errorMessage: String? = nil,
        inputFiles: [APIFile] = [],
        outputFiles: [APIFile] = [],
        wasSuccessful: Bool? = nil,
        vmId: String? = nil,
        duration: Int? = nil,
        stepCount: Int? = nil,
        tokenUsage: APITokenUsage? = nil,
        planMarkdown: String? = nil,
        planFirst: Bool? = nil,
        pendingQuestion: APIAgentQuestion? = nil,
        pendingPermission: APIPermissionRequest? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.providerName = providerName
        self.modelId = modelId
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.resultSummary = resultSummary
        self.errorMessage = errorMessage
        self.inputFiles = inputFiles
        self.outputFiles = outputFiles
        self.wasSuccessful = wasSuccessful
        self.vmId = vmId
        self.duration = duration
        self.stepCount = stepCount
        self.tokenUsage = tokenUsage
        self.planMarkdown = planMarkdown
        self.planFirst = planFirst
        self.pendingQuestion = pendingQuestion
        self.pendingPermission = pendingPermission
    }
}

/// Task summary for list responses
public struct APITaskSummary: Codable, Sendable {
    public let id: String
    public let title: String
    public let status: APITaskStatus
    public let providerName: String
    public let modelId: String
    public let createdAt: Date
    public let startedAt: Date?
    public let completedAt: Date?
    public let inputFileCount: Int
    public let outputFileCount: Int
    
    public init(
        id: String,
        title: String,
        status: APITaskStatus,
        providerName: String,
        modelId: String,
        createdAt: Date,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        inputFileCount: Int = 0,
        outputFileCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.providerName = providerName
        self.modelId = modelId
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.inputFileCount = inputFileCount
        self.outputFileCount = outputFileCount
    }
}

// MARK: - List Response

/// Response for GET /tasks (list)
public struct APITaskListResponse: Codable, Sendable {
    public let tasks: [APITaskSummary]
    public let total: Int
    public let limit: Int
    public let offset: Int
    
    public init(tasks: [APITaskSummary], total: Int, limit: Int, offset: Int) {
        self.tasks = tasks
        self.total = total
        self.limit = limit
        self.offset = offset
    }
}
