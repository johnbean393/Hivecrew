//
//  APITask.swift
//  HivecrewAPI
//
//  Task models for API requests and responses
//

import Foundation

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
}

/// Task priority values
public enum APITaskPriority: String, Codable, Sendable {
    case low = "low"
    case normal = "normal"
    case high = "high"
}

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
        tokenUsage: APITokenUsage? = nil
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

/// Request for POST /tasks (JSON body)
public struct CreateTaskRequest: Codable, Sendable {
    public let description: String
    public let providerName: String
    public let modelId: String
    public let priority: APITaskPriority?
    /// Custom output directory path for task deliverables (optional)
    public let outputDirectory: String?
    
    public init(
        description: String,
        providerName: String,
        modelId: String,
        priority: APITaskPriority? = nil,
        outputDirectory: String? = nil
    ) {
        self.description = description
        self.providerName = providerName
        self.modelId = modelId
        self.priority = priority
        self.outputDirectory = outputDirectory
    }
}

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

/// Task action types for PATCH /tasks/:id
public enum APITaskAction: String, Codable, Sendable {
    case cancel = "cancel"
    case pause = "pause"
    case resume = "resume"
}

/// Request for PATCH /tasks/:id
public struct UpdateTaskRequest: Codable, Sendable {
    public let action: APITaskAction
    public let instructions: String?
    
    public init(action: APITaskAction, instructions: String? = nil) {
        self.action = action
        self.instructions = instructions
    }
}
