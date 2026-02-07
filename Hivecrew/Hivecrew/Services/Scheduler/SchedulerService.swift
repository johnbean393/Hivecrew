//
//  SchedulerService.swift
//  Hivecrew
//
//  Service for monitoring and triggering scheduled tasks
//

import Foundation
import SwiftData
import Combine
import UserNotifications

/// Service that monitors scheduled tasks and triggers them when due
@MainActor
class SchedulerService: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = SchedulerService()
    
    // MARK: - Published State
    
    /// All scheduled tasks
    @Published var scheduledTasks: [ScheduledTask] = []
    
    /// Whether the scheduler is running
    @Published var isRunning: Bool = false
    
    // MARK: - Dependencies
    
    private var modelContext: ModelContext?
    private var taskService: TaskService?
    
    /// Timer for periodic schedule checking
    private var checkTimer: Timer?
    
    /// How often to check for due schedules (in seconds)
    private let checkInterval: TimeInterval = 5 // 5 seconds for responsive execution
    
    /// Grace period for considering a schedule "due" (in seconds)
    /// A schedule is due if nextRunAt is within this many seconds in the past
    private let gracePeriod: TimeInterval = 300 // 5 minutes
    
    // MARK: - Initialization
    
    private init() {}
    
    /// Configure the service with required dependencies
    func configure(modelContext: ModelContext, taskService: TaskService) {
        self.modelContext = modelContext
        self.taskService = taskService
        loadScheduledTasks()
    }
    
    // MARK: - Lifecycle
    
    /// Start the scheduler service
    func start() {
        guard !isRunning else { return }
        
        isRunning = true
        
        // Check immediately on start
        Task {
            await checkAndRunDueSchedules()
        }
        
        // Start periodic checking
        startCheckTimer()
        
        print("SchedulerService: Started with \(scheduledTasks.count) scheduled tasks")
    }
    
    /// Stop the scheduler service
    func stop() {
        stopCheckTimer()
        isRunning = false
        print("SchedulerService: Stopped")
    }
    
    // MARK: - Timer Management
    
    private func startCheckTimer() {
        stopCheckTimer()
        
        checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkAndRunDueSchedules()
            }
        }
    }
    
    private func stopCheckTimer() {
        checkTimer?.invalidate()
        checkTimer = nil
    }
    
    // MARK: - Schedule Checking
    
    /// Check for due schedules and run them
    func checkAndRunDueSchedules() async {
        let now = Date()
        
        // Find enabled schedules that are due
        let dueSchedules = scheduledTasks.filter { schedule in
            guard schedule.isEnabled else { return false }
            guard let nextRun = schedule.nextRunAt else { return false }
            
            // Schedule is due if nextRunAt has passed (is in the past)
            // Grace period allows tasks that were slightly missed (e.g., app was closed) to still run
            let cutoffTime = now.addingTimeInterval(-gracePeriod)
            return nextRun <= now && nextRun >= cutoffTime
        }
        
        if !dueSchedules.isEmpty {
            print("SchedulerService: Found \(dueSchedules.count) due schedule(s)")
        }
        
        for schedule in dueSchedules {
            await runScheduledTask(schedule)
        }
    }
    
    /// Run a scheduled task by creating a new task from its template
    private func runScheduledTask(_ schedule: ScheduledTask) async {
        guard let taskService = taskService else {
            print("SchedulerService: Cannot run scheduled task - TaskService not configured")
            return
        }
        
        print("SchedulerService: Running scheduled task '\(schedule.title)'")
        
        do {
            // Create the task using TaskService
            _ = try await taskService.createTask(
                description: schedule.taskDescription,
                providerId: schedule.providerId,
                modelId: schedule.modelId,
                attachedFilePaths: schedule.attachedFilePaths,
                outputDirectory: schedule.outputDirectory,
                mentionedSkillNames: schedule.mentionedSkillNames ?? []
            )
            
            // Update the schedule's state
            schedule.updateNextRunAfterExecution()
            try? modelContext?.save()
            
            // Send notification for scheduled task start
            sendScheduledTaskNotification(schedule: schedule, started: true)
            
            objectWillChange.send()
            
            print("SchedulerService: Successfully started scheduled task '\(schedule.title)'")
            
        } catch {
            print("SchedulerService: Failed to run scheduled task '\(schedule.title)': \(error)")
            sendScheduledTaskNotification(schedule: schedule, started: false, error: error)
        }
    }
    
    // MARK: - CRUD Operations
    
    /// Load scheduled tasks from SwiftData
    func loadScheduledTasks() {
        guard let context = modelContext else { return }
        
        let descriptor = FetchDescriptor<ScheduledTask>(
            sortBy: [SortDescriptor(\.nextRunAt)]
        )
        
        do {
            scheduledTasks = try context.fetch(descriptor)
            print("SchedulerService: Loaded \(scheduledTasks.count) scheduled task(s)")
        } catch {
            print("SchedulerService: Failed to load scheduled tasks: \(error)")
        }
    }
    
    /// Create a new scheduled task
    func createScheduledTask(
        title: String,
        taskDescription: String,
        providerId: String,
        modelId: String,
        attachedFilePaths: [String] = [],
        outputDirectory: String? = nil,
        mentionedSkillNames: [String]? = nil,
        scheduleType: ScheduleType,
        scheduledDate: Date? = nil,
        recurrenceRule: RecurrenceRule? = nil
    ) throws -> ScheduledTask {
        guard let context = modelContext else {
            throw SchedulerError.noModelContext
        }
        
        let schedule = ScheduledTask(
            title: title,
            taskDescription: taskDescription,
            providerId: providerId,
            modelId: modelId,
            attachedFilePaths: attachedFilePaths,
            outputDirectory: outputDirectory,
            mentionedSkillNames: mentionedSkillNames,
            scheduleType: scheduleType,
            scheduledDate: scheduledDate,
            recurrenceRule: recurrenceRule
        )
        
        context.insert(schedule)
        try context.save()
        
        scheduledTasks.append(schedule)
        scheduledTasks.sort { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
        
        objectWillChange.send()
        
        print("SchedulerService: Created scheduled task '\(title)' (next run: \(schedule.nextRunAt?.description ?? "never"))")
        
        return schedule
    }
    
    /// Update an existing scheduled task
    func updateScheduledTask(
        _ schedule: ScheduledTask,
        title: String? = nil,
        taskDescription: String? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        attachedFilePaths: [String]? = nil,
        outputDirectory: String? = nil,
        mentionedSkillNames: [String]? = nil,
        scheduleType: ScheduleType? = nil,
        scheduledDate: Date? = nil,
        recurrenceRule: RecurrenceRule? = nil,
        isEnabled: Bool? = nil
    ) throws {
        guard let context = modelContext else {
            throw SchedulerError.noModelContext
        }
        
        if let title = title { schedule.title = title }
        if let taskDescription = taskDescription { schedule.taskDescription = taskDescription }
        if let providerId = providerId { schedule.providerId = providerId }
        if let modelId = modelId { schedule.modelId = modelId }
        if let attachedFilePaths = attachedFilePaths { schedule.attachedFilePaths = attachedFilePaths }
        if let outputDirectory = outputDirectory { schedule.outputDirectory = outputDirectory }
        if let mentionedSkillNames = mentionedSkillNames { schedule.mentionedSkillNames = mentionedSkillNames }
        if let isEnabled = isEnabled { schedule.isEnabled = isEnabled }
        
        // Update schedule configuration if provided
        if let scheduleType = scheduleType {
            schedule.scheduleType = scheduleType
        }
        if scheduledDate != nil {
            schedule.scheduledDate = scheduledDate
        }
        if recurrenceRule != nil {
            schedule.recurrenceRule = recurrenceRule
        }
        
        // Recalculate next run if schedule configuration changed
        if scheduleType != nil || scheduledDate != nil || recurrenceRule != nil {
            schedule.nextRunAt = ScheduledTask.calculateNextRun(
                scheduleType: schedule.scheduleType,
                scheduledDate: schedule.scheduledDate,
                recurrenceRule: schedule.recurrenceRule
            )
        }
        
        try context.save()
        
        // Re-sort the list
        scheduledTasks.sort { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
        
        objectWillChange.send()
        
        print("SchedulerService: Updated scheduled task '\(schedule.title)'")
    }
    
    /// Toggle a scheduled task's enabled state
    func toggleScheduledTask(_ schedule: ScheduledTask) throws {
        guard let context = modelContext else {
            throw SchedulerError.noModelContext
        }
        
        schedule.isEnabled.toggle()
        
        // Recalculate next run when re-enabling
        if schedule.isEnabled {
            schedule.nextRunAt = ScheduledTask.calculateNextRun(
                scheduleType: schedule.scheduleType,
                scheduledDate: schedule.scheduledDate,
                recurrenceRule: schedule.recurrenceRule
            )
        }
        
        try context.save()
        objectWillChange.send()
        
        print("SchedulerService: Toggled scheduled task '\(schedule.title)' to \(schedule.isEnabled ? "enabled" : "disabled")")
    }
    
    /// Delete a scheduled task
    func deleteScheduledTask(_ schedule: ScheduledTask) throws {
        guard let context = modelContext else {
            throw SchedulerError.noModelContext
        }
        
        let title = schedule.title
        
        scheduledTasks.removeAll { $0.id == schedule.id }
        context.delete(schedule)
        try context.save()
        
        objectWillChange.send()
        
        print("SchedulerService: Deleted scheduled task '\(title)'")
    }
    
    /// Run a scheduled task immediately (manual trigger)
    func runNow(_ schedule: ScheduledTask) async {
        await runScheduledTask(schedule)
    }
    
    // MARK: - Notifications
    
    /// Send a notification when a scheduled task starts or fails
    private func sendScheduledTaskNotification(schedule: ScheduledTask, started: Bool, error: Error? = nil) {
        let content = UNMutableNotificationContent()
        
        if started {
            content.title = String(localized: "Scheduled Task Started")
            content.body = String(localized: "'\(schedule.title)' has started running.")
            content.sound = .default
        } else {
            content.title = String(localized: "Scheduled Task Failed")
            content.body = String(localized: "'\(schedule.title)' failed to start: \(error?.localizedDescription ?? String(localized: "Unknown error"))")
            content.sound = .defaultCritical
        }
        
        let request = UNNotificationRequest(
            identifier: "scheduled-task-\(schedule.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("SchedulerService: Failed to send notification: \(error)")
            }
        }
    }
    
    // MARK: - Computed Properties
    
    /// Enabled scheduled tasks
    var enabledSchedules: [ScheduledTask] {
        scheduledTasks.filter { $0.isEnabled }
    }
    
    /// Upcoming schedules (next 24 hours)
    var upcomingSchedules: [ScheduledTask] {
        let tomorrow = Date().addingTimeInterval(24 * 60 * 60)
        return scheduledTasks.filter { schedule in
            guard schedule.isEnabled, let nextRun = schedule.nextRunAt else { return false }
            return nextRun <= tomorrow
        }
    }
}

// MARK: - Errors

enum SchedulerError: LocalizedError {
    case noModelContext
    case scheduleNotFound
    
    var errorDescription: String? {
        switch self {
        case .noModelContext:
            return String(localized: "Model context not configured")
        case .scheduleNotFound:
            return String(localized: "Scheduled task not found")
        }
    }
}
