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
    case planning = 9      // Yellow dot - plan is being generated
    case planReview = 10   // Blue dot - awaiting user review/edit of plan
    case planFailed = 11   // Red dot - planning failed
    
    var displayName: String {
        switch self {
        case .queued: return String(localized: "Queued")
        case .waitingForVM: return String(localized: "Waiting for VM")
        case .running: return String(localized: "In Progress")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        case .paused: return String(localized: "Paused")
        case .timedOut: return String(localized: "Timed Out")
        case .maxIterations: return String(localized: "Max Iterations")
        case .planning: return String(localized: "Generating Plan")
        case .planReview: return String(localized: "Review Plan")
        case .planFailed: return String(localized: "Planning Failed")
        }
    }
    
    var statusColor: String {
        switch self {
        case .queued, .waitingForVM, .paused, .planning: return "yellow"
        case .running: return "green"
        case .completed: return "gray"
        case .failed, .planFailed: return "red"
        case .cancelled: return "gray"
        case .timedOut, .maxIterations: return "orange"
        case .planReview: return "blue"
        }
    }
    
    var isActive: Bool {
        switch self {
        case .queued, .waitingForVM, .running, .paused, .planning, .planReview:
            return true
        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed:
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
    
    /// Model ID to use (e.g., "moonshotai/kimi-k2.5", "claude-3-opus")
    var modelId: String
    
    /// Summary of the task result (on completion)
    var resultSummary: String?
    
    /// Error message (on failure)
    var errorMessage: String?
    
    /// Legacy: Paths to files attached to this task (copied to VM's shared folder)
    /// Kept for backwards compatibility with older database versions
    /// New tasks should use attachmentInfos instead
    private var legacyAttachedFilePaths: [String]?
    
    /// JSON-encoded attachment info for files attached to this task
    /// Stores both original and copied paths for each attachment
    private var attachmentInfosData: Data?
    
    /// Paths to output files produced by this task (copied from VM's outbox)
    /// Optional to support migration from older database versions
    var outputFilePaths: [String]?
    
    /// Custom output directory for this task (overrides app-level setting)
    /// If nil, uses the app's default output directory setting
    var outputDirectory: String?
    
    /// Names of skills explicitly mentioned by the user via @skill-name
    /// These skills will be force-included in addition to auto-matched skills
    var mentionedSkillNames: [String]?

    /// Approved retrieval context pack ID used for this task (if any).
    var retrievalContextPackId: String?

    /// Additional file paths materialized by retrieval context packing.
    var retrievalContextAttachmentPaths: [String]?

    /// Suggestion IDs selected by the user during context approval.
    var retrievalSelectedSuggestionIds: [String]?

    /// JSON-encoded inline context blocks to inject into the system prompt.
    private var retrievalInlineContextData: Data?

    /// JSON-encoded per-suggestion mode overrides at pack creation time.
    private var retrievalModeOverridesData: Data?
    
    /// Whether the task was verified as successful by the completion check
    /// nil = not yet checked, true = verified success, false = verified failure
    var wasSuccessful: Bool?
    
    // MARK: - Plan Mode Properties
    
    /// Whether plan mode was enabled for this task (optional for migration compatibility)
    private var planFirstEnabledRaw: Bool?
    
    /// The generated/edited execution plan (Markdown with checkboxes)
    var planMarkdown: String?
    
    /// Names of skills auto-selected during planning
    var planSelectedSkillNames: [String]?
    
    /// Computed property for planFirstEnabled with default value
    var planFirstEnabled: Bool {
        get { planFirstEnabledRaw ?? false }
        set { planFirstEnabledRaw = newValue }
    }

    // MARK: - Retrieval Context Properties

    var retrievalInlineContextBlocks: [String] {
        get {
            guard
                let retrievalInlineContextData,
                let decoded = try? JSONDecoder().decode([String].self, from: retrievalInlineContextData)
            else {
                return []
            }
            return decoded
        }
        set {
            retrievalInlineContextData = try? JSONEncoder().encode(newValue)
        }
    }

    var retrievalModeOverrides: [String: String] {
        get {
            guard
                let retrievalModeOverridesData,
                let decoded = try? JSONDecoder().decode([String: String].self, from: retrievalModeOverridesData)
            else {
                return [:]
            }
            return decoded
        }
        set {
            retrievalModeOverridesData = try? JSONEncoder().encode(newValue)
        }
    }
    
    // MARK: - Attachment Properties
    
    /// Decoded attachment infos from stored data
    /// Includes backwards compatibility: migrates legacy paths if needed
    var attachmentInfos: [AttachmentInfo] {
        get {
            // First try to decode from new format
            if let data = attachmentInfosData,
               let infos = try? JSONDecoder().decode([AttachmentInfo].self, from: data) {
                return infos
            }
            // Fallback: migrate from legacy paths
            if let legacyPaths = legacyAttachedFilePaths {
                return legacyPaths.map { AttachmentInfo(path: $0) }
            }
            return []
        }
        set {
            attachmentInfosData = try? JSONEncoder().encode(newValue)
            // Clear legacy data once we have new format
            legacyAttachedFilePaths = nil
        }
    }
    
    /// Paths to files attached to this task
    /// Computed from attachmentInfos for backwards compatibility
    /// Returns effective paths (copied if available, original otherwise)
    var attachedFilePaths: [String] {
        get {
            attachmentInfos.map { $0.effectivePath }
        }
        set {
            // When setting paths directly (legacy behavior), create basic AttachmentInfos
            attachmentInfos = newValue.map { AttachmentInfo(path: $0) }
        }
    }
    
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
        attachmentInfos: [AttachmentInfo]? = nil,
        outputFilePaths: [String]? = nil,
        outputDirectory: String? = nil,
        mentionedSkillNames: [String]? = nil,
        retrievalContextPackId: String? = nil,
        retrievalInlineContextBlocks: [String] = [],
        retrievalContextAttachmentPaths: [String]? = nil,
        retrievalSelectedSuggestionIds: [String]? = nil,
        retrievalModeOverrides: [String: String]? = nil,
        planFirstEnabled: Bool = false,
        planMarkdown: String? = nil,
        planSelectedSkillNames: [String]? = nil
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
        self.outputFilePaths = outputFilePaths
        self.outputDirectory = outputDirectory
        self.mentionedSkillNames = mentionedSkillNames
        self.retrievalContextPackId = retrievalContextPackId
        self.retrievalContextAttachmentPaths = retrievalContextAttachmentPaths
        self.retrievalSelectedSuggestionIds = retrievalSelectedSuggestionIds
        self.retrievalInlineContextData = try? JSONEncoder().encode(retrievalInlineContextBlocks)
        self.retrievalModeOverridesData = try? JSONEncoder().encode(retrievalModeOverrides ?? [:])
        self.planFirstEnabledRaw = planFirstEnabled
        self.planMarkdown = planMarkdown
        self.planSelectedSkillNames = planSelectedSkillNames
        
        // Use new attachment infos if provided, otherwise fall back to legacy paths
        if let infos = attachmentInfos {
            self.attachmentInfosData = try? JSONEncoder().encode(infos)
            self.legacyAttachedFilePaths = nil
        } else if !attachedFilePaths.isEmpty {
            // Store as legacy paths for backwards compatibility
            self.legacyAttachedFilePaths = attachedFilePaths
            self.attachmentInfosData = nil
        } else {
            self.legacyAttachedFilePaths = nil
            self.attachmentInfosData = nil
        }
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
