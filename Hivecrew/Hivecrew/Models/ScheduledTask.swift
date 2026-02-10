//
//  ScheduledTask.swift
//  Hivecrew
//
//  SwiftData model for persisting scheduled task records
//

import Foundation
import SwiftData

/// Type of schedule
enum ScheduleType: Int, Codable, CaseIterable {
    case oneTime = 0    // Run once at a specific date/time
    case recurring = 1  // Run repeatedly based on recurrence rule
    
    var displayName: String {
        switch self {
        case .oneTime: return String(localized: "One-time")
        case .recurring: return String(localized: "Recurring")
        }
    }
}

/// Frequency for recurring schedules
enum RecurrenceFrequency: Int, Codable, CaseIterable {
    case daily = 0
    case weekly = 1
    case monthly = 2
    
    var displayName: String {
        switch self {
        case .daily: return String(localized: "Daily")
        case .weekly: return String(localized: "Weekly")
        case .monthly: return String(localized: "Monthly")
        }
    }
}

/// Rule defining recurrence pattern for scheduled tasks
struct RecurrenceRule: Codable, Equatable {
    /// How often the task repeats
    var frequency: RecurrenceFrequency
    
    /// Days of the week for weekly frequency (1=Sunday, 2=Monday, ..., 7=Saturday)
    var daysOfWeek: Set<Int>?
    
    /// Day of the month for monthly frequency (1-31)
    var dayOfMonth: Int?
    
    /// Time of day to run (hour and minute components)
    var hour: Int
    var minute: Int
    
    /// Create a daily recurrence rule
    static func daily(at hour: Int, minute: Int) -> RecurrenceRule {
        RecurrenceRule(frequency: .daily, daysOfWeek: nil, dayOfMonth: nil, hour: hour, minute: minute)
    }
    
    /// Create a weekly recurrence rule
    static func weekly(on days: Set<Int>, at hour: Int, minute: Int) -> RecurrenceRule {
        RecurrenceRule(frequency: .weekly, daysOfWeek: days, dayOfMonth: nil, hour: hour, minute: minute)
    }
    
    /// Create a monthly recurrence rule
    static func monthly(on day: Int, at hour: Int, minute: Int) -> RecurrenceRule {
        RecurrenceRule(frequency: .monthly, daysOfWeek: nil, dayOfMonth: day, hour: hour, minute: minute)
    }
    
    /// Human-readable description of the recurrence
    var displayDescription: String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let timeString = Calendar.current.date(from: components).map { timeFormatter.string(from: $0) } ?? "\(hour):\(String(format: "%02d", minute))"
        
        switch frequency {
        case .daily:
            return String(localized: "Daily at \(timeString)")
            
        case .weekly:
            guard let days = daysOfWeek, !days.isEmpty else {
                return String(localized: "Weekly at \(timeString)")
            }
            let symbols = Calendar.current.shortWeekdaySymbols
            let dayNames = [""] + symbols  // 1=Sunday, 2=Monday, etc.
            let sortedDays = days.sorted()
            let dayString = sortedDays.map { dayNames[$0] }.joined(separator: ", ")
            return String(localized: "Every \(dayString) at \(timeString)")
            
        case .monthly:
            guard let day = dayOfMonth else {
                return String(localized: "Monthly at \(timeString)")
            }
            let suffix: String
            switch day {
            case 1, 21, 31: suffix = "st"
            case 2, 22: suffix = "nd"
            case 3, 23: suffix = "rd"
            default: suffix = "th"
            }
            return String(localized: "Monthly on the \(day)\(suffix) at \(timeString)")
        }
    }
}

/// SwiftData model for persisting scheduled task records
@Model
final class ScheduledTask {
    /// Unique identifier for this scheduled task
    @Attribute(.unique) var id: String
    
    /// User-provided title for the scheduled task
    var title: String
    
    /// Full task description that will be sent to the agent
    var taskDescription: String
    
    /// ID of the LLM provider to use
    var providerId: String
    
    /// Model ID to use (e.g., "moonshotai/kimi-k2.5", "claude-3-opus")
    var modelId: String
    
    /// Paths to files attached to this task
    var attachedFilePaths: [String]
    
    /// Custom output directory for task results
    var outputDirectory: String?
    
    /// Names of skills explicitly mentioned by the user
    var mentionedSkillNames: [String]?
    
    // MARK: - Schedule Configuration
    
    /// Type of schedule (one-time or recurring)
    var scheduleTypeRaw: Int
    
    /// Scheduled date/time for one-time schedules
    var scheduledDate: Date?
    
    /// Encoded recurrence rule for recurring schedules
    var recurrenceRuleData: Data?
    
    // MARK: - State
    
    /// Whether this scheduled task is active
    var isEnabled: Bool
    
    /// When this scheduled task was created
    var createdAt: Date
    
    /// When this scheduled task last ran
    var lastRunAt: Date?
    
    /// When this scheduled task will run next
    var nextRunAt: Date?
    
    // MARK: - Initialization
    
    init(
        id: String = UUID().uuidString,
        title: String,
        taskDescription: String,
        providerId: String,
        modelId: String,
        attachedFilePaths: [String] = [],
        outputDirectory: String? = nil,
        mentionedSkillNames: [String]? = nil,
        scheduleType: ScheduleType = .oneTime,
        scheduledDate: Date? = nil,
        recurrenceRule: RecurrenceRule? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.taskDescription = taskDescription
        self.providerId = providerId
        self.modelId = modelId
        self.attachedFilePaths = attachedFilePaths
        self.outputDirectory = outputDirectory
        self.mentionedSkillNames = mentionedSkillNames
        self.scheduleTypeRaw = scheduleType.rawValue
        self.scheduledDate = scheduledDate
        self.recurrenceRuleData = recurrenceRule.flatMap { try? JSONEncoder().encode($0) }
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        
        // Calculate initial nextRunAt
        self.nextRunAt = Self.calculateNextRun(
            scheduleType: scheduleType,
            scheduledDate: scheduledDate,
            recurrenceRule: recurrenceRule,
            from: createdAt
        )
    }
    
    // MARK: - Computed Properties
    
    /// Schedule type
    var scheduleType: ScheduleType {
        get { ScheduleType(rawValue: scheduleTypeRaw) ?? .oneTime }
        set { scheduleTypeRaw = newValue.rawValue }
    }
    
    /// Decoded recurrence rule
    var recurrenceRule: RecurrenceRule? {
        get {
            guard let data = recurrenceRuleData else { return nil }
            return try? JSONDecoder().decode(RecurrenceRule.self, from: data)
        }
        set {
            recurrenceRuleData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }
    
    /// Human-readable schedule description
    var scheduleDescription: String {
        switch scheduleType {
        case .oneTime:
            guard let date = scheduledDate else { return String(localized: "Not scheduled") }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
            
        case .recurring:
            return recurrenceRule?.displayDescription ?? String(localized: "Not configured")
        }
    }
    
    /// Whether the schedule has passed (for one-time schedules)
    var hasExpired: Bool {
        guard scheduleType == .oneTime else { return false }
        guard let date = scheduledDate else { return true }
        return date < Date()
    }
    
    // MARK: - Next Run Calculation
    
    /// Calculate the next run time based on schedule configuration
    static func calculateNextRun(
        scheduleType: ScheduleType,
        scheduledDate: Date?,
        recurrenceRule: RecurrenceRule?,
        from referenceDate: Date = Date()
    ) -> Date? {
        switch scheduleType {
        case .oneTime:
            // For one-time schedules, return the scheduled date if it's in the future
            guard let date = scheduledDate else { return nil }
            return date > referenceDate ? date : nil
            
        case .recurring:
            guard let rule = recurrenceRule else { return nil }
            return calculateNextRecurrence(rule: rule, from: referenceDate)
        }
    }
    
    /// Calculate the next occurrence based on recurrence rule
    private static func calculateNextRecurrence(rule: RecurrenceRule, from referenceDate: Date) -> Date? {
        let calendar = Calendar.current
        
        // Start from today at the scheduled time
        var components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        components.hour = rule.hour
        components.minute = rule.minute
        components.second = 0
        
        guard var candidateDate = calendar.date(from: components) else { return nil }
        
        // If candidate is in the past, move to next possible occurrence
        if candidateDate <= referenceDate {
            switch rule.frequency {
            case .daily:
                candidateDate = calendar.date(byAdding: .day, value: 1, to: candidateDate) ?? candidateDate
                
            case .weekly:
                candidateDate = calendar.date(byAdding: .day, value: 1, to: candidateDate) ?? candidateDate
                
            case .monthly:
                candidateDate = calendar.date(byAdding: .month, value: 1, to: candidateDate) ?? candidateDate
            }
        }
        
        switch rule.frequency {
        case .daily:
            // For daily, the candidate date is already correct
            return candidateDate
            
        case .weekly:
            guard let days = rule.daysOfWeek, !days.isEmpty else { return candidateDate }
            
            // Find the next matching day of week
            for _ in 0..<8 {
                let weekday = calendar.component(.weekday, from: candidateDate)
                if days.contains(weekday) && candidateDate > referenceDate {
                    return candidateDate
                }
                candidateDate = calendar.date(byAdding: .day, value: 1, to: candidateDate) ?? candidateDate
            }
            return candidateDate
            
        case .monthly:
            guard let targetDay = rule.dayOfMonth else { return candidateDate }
            
            // Find the next month that has the target day
            for _ in 0..<13 {
                let currentComponents = calendar.dateComponents([.year, .month], from: candidateDate)
                var targetComponents = currentComponents
                targetComponents.day = targetDay
                targetComponents.hour = rule.hour
                targetComponents.minute = rule.minute
                targetComponents.second = 0
                
                // Check if this month has enough days
                let range = calendar.range(of: .day, in: .month, for: candidateDate)
                let daysInMonth = range?.count ?? 31
                
                if targetDay <= daysInMonth {
                    if let targetDate = calendar.date(from: targetComponents), targetDate > referenceDate {
                        return targetDate
                    }
                }
                
                // Move to next month
                candidateDate = calendar.date(byAdding: .month, value: 1, to: candidateDate) ?? candidateDate
            }
            return candidateDate
        }
    }
    
    /// Update nextRunAt after the task has run
    func updateNextRunAfterExecution() {
        lastRunAt = Date()
        
        switch scheduleType {
        case .oneTime:
            // One-time schedules don't run again
            nextRunAt = nil
            isEnabled = false
            
        case .recurring:
            // Calculate next occurrence from now
            nextRunAt = Self.calculateNextRun(
                scheduleType: scheduleType,
                scheduledDate: scheduledDate,
                recurrenceRule: recurrenceRule,
                from: Date()
            )
        }
    }
}
