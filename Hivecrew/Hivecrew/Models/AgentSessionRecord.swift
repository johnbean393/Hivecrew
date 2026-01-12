//
//  AgentSessionRecord.swift
//  Hivecrew
//
//  SwiftData model for persisting agent session records
//

import Foundation
import SwiftData

/// Status of an agent session
enum AgentSessionStatus: String, Codable, CaseIterable {
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}

/// SwiftData model for persisting agent session records
@Model
final class AgentSessionRecord {
    /// Unique identifier for this session
    @Attribute(.unique) var id: String
    
    /// ID of the task this session is executing
    var taskId: String
    
    /// ID of the VM running this session
    var vmId: String
    
    /// When the session started
    var startedAt: Date
    
    /// When the session ended (nil if still running)
    var endedAt: Date?
    
    /// Current status of the session
    var status: String
    
    /// Path to the session trace directory
    var tracePath: String
    
    /// Total prompt tokens used
    var promptTokens: Int
    
    /// Total completion tokens used
    var completionTokens: Int
    
    /// Number of steps executed
    var stepCount: Int
    
    /// Last screenshot path (for live preview)
    var lastScreenshotPath: String?
    
    /// Estimated cost in USD (based on token usage)
    var estimatedCost: Double
    
    init(
        id: String = UUID().uuidString,
        taskId: String,
        vmId: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        status: AgentSessionStatus = .running,
        tracePath: String,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        stepCount: Int = 0,
        lastScreenshotPath: String? = nil,
        estimatedCost: Double = 0.0
    ) {
        self.id = id
        self.taskId = taskId
        self.vmId = vmId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status.rawValue
        self.tracePath = tracePath
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.stepCount = stepCount
        self.lastScreenshotPath = lastScreenshotPath
        self.estimatedCost = estimatedCost
    }
    
}
