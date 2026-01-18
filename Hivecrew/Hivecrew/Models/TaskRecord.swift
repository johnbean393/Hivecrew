//
//  TaskRecord.swift
//  Hivecrew
//
//  SwiftData model for persisting task records
//

import Foundation
import SwiftData

/// Status of a task in the queue/execution lifecycle
enum TaskStatus: Int, Codable, CaseIterable {
    case queued = 0        // Task is queued, waiting to start
    case waitingForVM = 1  // Yellow dot - waiting for VM to become available
    case running = 2       // Green dot - agent is actively working
    case completed = 3     // Task completed successfully
    case failed = 4        // Red dot - task failed
    case cancelled = 5     // Task was cancelled by user
    case paused = 6        // Yellow dot - agent is paused, awaiting user
    case timedOut = 7      // Orange dot - task exceeded time limit
    case maxIterations = 8 // Orange dot - task exceeded max iterations
    
    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .waitingForVM: return "Waiting for VM"
        case .running: return "In Progress"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .paused: return "Paused"
        case .timedOut: return "Timed Out"
        case .maxIterations: return "Max Iterations"
        }
    }
    
    var statusColor: String {
        switch self {
        case .queued, .waitingForVM, .paused: return "yellow"
        case .running: return "green"
        case .completed: return "gray"
        case .failed: return "red"
        case .cancelled: return "gray"
        case .timedOut, .maxIterations: return "orange"
        }
    }
    
    var isActive: Bool {
        switch self {
        case .queued, .waitingForVM, .running, .paused:
            return true
        case .completed, .failed, .cancelled, .timedOut, .maxIterations:
            return false
        }
    }
}

/// SwiftData model for persisting task records
@Model
final class TaskRecord {
    /// Unique identifier for this task
    @Attribute(.unique) var id: String
    
    /// LLM-generated short title (e.g., "Create Paris Trip Research `docx`")
    var title: String
    
    /// Full user-provided task description
    var taskDescription: String
    
    /// Current status of the task
    var statusRaw: Int
    
    /// When the task was created
    var createdAt: Date
    
    /// When the task started running
    var startedAt: Date?
    
    /// When the task completed (success, failure, or cancellation)
    var completedAt: Date?
    
    /// ID of the VM assigned to this task (nil if not yet assigned)
    var assignedVMId: String?
    
    /// ID of the agent session running this task
    var sessionId: String?
    
    /// ID of the LLM provider to use
    var providerId: String
    
    /// Model ID to use (e.g., "gpt-5.2", "claude-3-opus")
    var modelId: String
    
    /// Summary of the task result (on completion)
    var resultSummary: String?
    
    /// Error message (on failure)
    var errorMessage: String?
    
    /// Paths to files attached to this task (copied to VM's shared folder)
    var attachedFilePaths: [String]
    
    /// Paths to output files produced by this task (copied from VM's outbox)
    /// Optional to support migration from older database versions
    var outputFilePaths: [String]?
    
    /// Custom output directory for this task (overrides app-level setting)
    /// If nil, uses the app's default output directory setting
    var outputDirectory: String?
    
    /// Whether the task was verified as successful by the completion check
    /// nil = not yet checked, true = verified success, false = verified failure
    var wasSuccessful: Bool?
    
    init(
        id: String = UUID().uuidString,
        title: String,
        taskDescription: String,
        status: TaskStatus = .queued,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        assignedVMId: String? = nil,
        sessionId: String? = nil,
        providerId: String,
        modelId: String,
        resultSummary: String? = nil,
        errorMessage: String? = nil,
        attachedFilePaths: [String] = [],
        outputFilePaths: [String]? = nil,
        outputDirectory: String? = nil
    ) {
        self.id = id
        self.title = title
        self.taskDescription = taskDescription
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.assignedVMId = assignedVMId
        self.sessionId = sessionId
        self.providerId = providerId
        self.modelId = modelId
        self.resultSummary = resultSummary
        self.errorMessage = errorMessage
        self.attachedFilePaths = attachedFilePaths
        self.outputFilePaths = outputFilePaths
        self.outputDirectory = outputDirectory
    }
    
    /// Computed status property
    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }
    
    /// Duration from creation to completion (or now if still running)
    var duration: TimeInterval {
        let endTime = completedAt ?? Date()
        return endTime.timeIntervalSince(startedAt ?? createdAt)
    }
    
    /// Formatted duration string
    var durationString: String {
        let seconds = Int(duration)
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        } else {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
    }
}
