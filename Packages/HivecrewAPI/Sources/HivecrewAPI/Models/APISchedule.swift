//
//  APISchedule.swift
//  HivecrewAPI
//
//  Schedule and recurrence models for task scheduling
//

import Foundation

/// Recurrence type for scheduled tasks
public enum APIRecurrenceType: String, Codable, Sendable {
    case daily = "daily"
    case weekly = "weekly"
    case monthly = "monthly"
}

/// Recurrence configuration for recurring tasks
public struct APIRecurrence: Codable, Sendable, Equatable {
    /// Type of recurrence (daily, weekly, monthly)
    public let type: APIRecurrenceType
    
    /// Days of week for weekly recurrence (1=Sunday, 7=Saturday - matching iOS Calendar)
    public let daysOfWeek: [Int]?
    
    /// Day of month for monthly recurrence (1-31)
    public let dayOfMonth: Int?
    
    /// Hour of day (0-23)
    public let hour: Int
    
    /// Minute of hour (0-59)
    public let minute: Int
    
    public init(
        type: APIRecurrenceType,
        daysOfWeek: [Int]? = nil,
        dayOfMonth: Int? = nil,
        hour: Int,
        minute: Int
    ) {
        self.type = type
        self.daysOfWeek = daysOfWeek
        self.dayOfMonth = dayOfMonth
        self.hour = hour
        self.minute = minute
    }
}

/// Schedule configuration for creating a scheduled task
public struct APISchedule: Codable, Sendable, Equatable {
    /// For one-time schedules: when the task should run
    public let scheduledAt: Date?
    
    /// For recurring schedules: the recurrence configuration
    public let recurrence: APIRecurrence?
    
    public init(
        scheduledAt: Date? = nil,
        recurrence: APIRecurrence? = nil
    ) {
        self.scheduledAt = scheduledAt
        self.recurrence = recurrence
    }
}

/// Scheduled task response model (maps to ScheduledTask)
public struct APIScheduledTask: Codable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let providerName: String
    public let modelId: String
    public let isEnabled: Bool
    public let scheduleType: String
    public let scheduledAt: Date?
    public let recurrence: APIRecurrence?
    public let nextRunAt: Date?
    public let lastRunAt: Date?
    public let createdAt: Date
    
    public init(
        id: String,
        title: String,
        description: String,
        providerName: String,
        modelId: String,
        isEnabled: Bool,
        scheduleType: String,
        scheduledAt: Date?,
        recurrence: APIRecurrence?,
        nextRunAt: Date?,
        lastRunAt: Date?,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.providerName = providerName
        self.modelId = modelId
        self.isEnabled = isEnabled
        self.scheduleType = scheduleType
        self.scheduledAt = scheduledAt
        self.recurrence = recurrence
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.createdAt = createdAt
    }
}

/// Response for GET /schedules (list)
public struct APIScheduledTaskListResponse: Codable, Sendable {
    public let schedules: [APIScheduledTask]
    public let total: Int
    public let limit: Int
    public let offset: Int
    
    public init(schedules: [APIScheduledTask], total: Int, limit: Int, offset: Int) {
        self.schedules = schedules
        self.total = total
        self.limit = limit
        self.offset = offset
    }
}

/// Request for updating a scheduled task
public struct UpdateScheduleRequest: Codable, Sendable {
    public let title: String?
    public let description: String?
    public let scheduledAt: Date?
    public let recurrence: APIRecurrence?
    public let isEnabled: Bool?
    
    public init(
        title: String? = nil,
        description: String? = nil,
        scheduledAt: Date? = nil,
        recurrence: APIRecurrence? = nil,
        isEnabled: Bool? = nil
    ) {
        self.title = title
        self.description = description
        self.scheduledAt = scheduledAt
        self.recurrence = recurrence
        self.isEnabled = isEnabled
    }
}
