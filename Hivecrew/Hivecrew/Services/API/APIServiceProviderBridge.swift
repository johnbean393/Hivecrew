//
//  APIServiceProviderBridge.swift
//  Hivecrew
//
//  Implementation of APIServiceProvider that bridges the API to the app's services
//

import Foundation
import SwiftData
import HivecrewAPI
import HivecrewShared

/// Implementation of the API service provider that bridges to Hivecrew's internal services
@MainActor
final class APIServiceProviderBridge: APIServiceProvider, Sendable {
    
    let taskService: TaskService
    let schedulerService: SchedulerService
    let vmServiceClient: VMServiceClient
    let modelContext: ModelContext
    let fileStorage: TaskFileStorage
    
    /// App start time for uptime calculation
    private let appStartTime = Date()
    
    init(
        taskService: TaskService,
        schedulerService: SchedulerService,
        vmServiceClient: VMServiceClient,
        modelContext: ModelContext,
        fileStorage: TaskFileStorage
    ) {
        self.taskService = taskService
        self.schedulerService = schedulerService
        self.vmServiceClient = vmServiceClient
        self.modelContext = modelContext
        self.fileStorage = fileStorage
    }
    
    // MARK: - Task Operations
    
    func createTask(
        description: String,
        providerName: String,
        modelId: String,
        attachedFilePaths: [String],
        outputDirectory: String?,
        planFirst: Bool = false,
        mentionedSkillNames: [String] = []
    ) async throws -> APITask {
        // Find provider by name
        let providerId = try await findProviderIdByName(providerName)
        
        // Create the task using TaskService
        let task = try await taskService.createTask(
            description: description,
            providerId: providerId,
            modelId: modelId,
            attachedFilePaths: attachedFilePaths,
            outputDirectory: outputDirectory,
            mentionedSkillNames: mentionedSkillNames,
            planFirstEnabled: planFirst
        )
        
        return convertToAPITask(task)
    }
    
    func getTasks(
        status: [APITaskStatus]?,
        limit: Int,
        offset: Int,
        sortBy: String,
        order: String
    ) async throws -> APITaskListResponse {
        var tasks = taskService.tasks
        
        // Filter by status if provided
        if let statusFilter = status {
            let internalStatuses = statusFilter.map { convertFromAPIStatus($0) }
            tasks = tasks.filter { internalStatuses.contains($0.status) }
        }
        
        // Sort
        switch sortBy {
        case "startedAt":
            tasks.sort { (a, b) in
                let aDate = a.startedAt ?? Date.distantPast
                let bDate = b.startedAt ?? Date.distantPast
                return order == "desc" ? aDate > bDate : aDate < bDate
            }
        case "completedAt":
            tasks.sort { (a, b) in
                let aDate = a.completedAt ?? Date.distantPast
                let bDate = b.completedAt ?? Date.distantPast
                return order == "desc" ? aDate > bDate : aDate < bDate
            }
        default: // createdAt
            tasks.sort { order == "desc" ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt }
        }
        
        let total = tasks.count
        
        // Apply pagination
        let startIndex = min(offset, tasks.count)
        let endIndex = min(offset + limit, tasks.count)
        let paginatedTasks = Array(tasks[startIndex..<endIndex])
        
        return APITaskListResponse(
            tasks: paginatedTasks.map { convertToAPITaskSummary($0) },
            total: total,
            limit: limit,
            offset: offset
        )
    }
    
    func getTask(id: String) async throws -> APITask {
        guard let task = taskService.tasks.first(where: { $0.id == id }) else {
            throw APIError.notFound("Task with ID '\(id)' not found")
        }
        return convertToAPITask(task)
    }
    
    func performTaskAction(id: String, action: APITaskAction, instructions: String?) async throws -> APITask {
        guard let task = taskService.tasks.first(where: { $0.id == id }) else {
            throw APIError.notFound("Task with ID '\(id)' not found")
        }
        
        switch action {
        case .cancel:
            guard task.status.isActive else {
                throw APIError.conflict("Cannot cancel task with status '\(task.status.displayName)'")
            }
            await taskService.cancelTask(task)
            
        case .pause:
            guard task.status == .running else {
                throw APIError.conflict("Cannot pause task with status '\(task.status.displayName)'")
            }
            taskService.pauseTask(task)
            
        case .resume:
            guard task.status == .paused else {
                throw APIError.conflict("Cannot resume task with status '\(task.status.displayName)'")
            }
            taskService.resumeTask(task, withInstructions: instructions)
            
        case .instruct:
            guard task.status == .running else {
                throw APIError.conflict("Cannot send instructions to task with status '\(task.status.displayName)' — task must be running")
            }
            guard let text = instructions, !text.isEmpty else {
                throw APIError.badRequest("Instructions text is required for the 'instruct' action")
            }
            guard let statePublisher = taskService.statePublishers[task.id] else {
                throw APIError.conflict("No active agent found for task '\(id)'")
            }
            statePublisher.pendingInstructions = text
            
        case .rerun:
            guard !task.status.isActive else {
                throw APIError.conflict("Cannot rerun task with status '\(task.status.displayName)' — task must be finished first")
            }
            let newTask = try await taskService.rerunTask(task)
            return convertToAPITask(newTask)
            
        case .approvePlan:
            guard task.status == .planReview else {
                throw APIError.conflict("Cannot approve plan for task with status '\(task.status.displayName)'")
            }
            await taskService.executePlan(for: task)
            
        case .editPlan:
            guard task.status == .planReview else {
                throw APIError.conflict("Cannot edit plan for task with status '\(task.status.displayName)'")
            }
            // Update the plan markdown if provided via instructions
            if let editedPlan = instructions, !editedPlan.isEmpty {
                task.planMarkdown = editedPlan
                try? modelContext.save()
            }
            await taskService.executePlan(for: task)
            
        case .cancelPlan:
            guard task.status == .planReview || task.status == .planning else {
                throw APIError.conflict("Cannot cancel plan for task with status '\(task.status.displayName)'")
            }
            await taskService.cancelPlanning(for: task)
        }
        
        return convertToAPITask(task)
    }
    
    func deleteTask(id: String) async throws {
        guard let task = taskService.tasks.first(where: { $0.id == id }) else {
            throw APIError.notFound("Task with ID '\(id)' not found")
        }
        
        await taskService.deleteTask(task)
    }
    
    func getTaskFiles(id: String) async throws -> APITaskFilesResponse {
        guard let task = taskService.tasks.first(where: { $0.id == id }) else {
            throw APIError.notFound("Task with ID '\(id)' not found")
        }
        
        // Get input files from task's attachedFilePaths
        let inputFiles: [APIFileDetail] = task.attachedFilePaths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            let mimeType = APIFile.mimeType(for: url.lastPathComponent)
            return APIFileDetail(name: url.lastPathComponent, size: size, mimeType: mimeType, uploadedAt: nil, createdAt: nil)
        }
        
        // Get output files from task's outputFilePaths
        let outputFiles: [APIFileDetail] = (task.outputFilePaths ?? []).compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            let mimeType = APIFile.mimeType(for: url.lastPathComponent)
            return APIFileDetail(name: url.lastPathComponent, size: size, mimeType: mimeType, uploadedAt: nil, createdAt: nil)
        }
        
        return APITaskFilesResponse(
            taskId: id,
            inputFiles: inputFiles,
            outputFiles: outputFiles
        )
    }
    
    func getTaskFileData(taskId: String, filename: String, isInput: Bool) async throws -> (data: Data, mimeType: String) {
        guard let task = taskService.tasks.first(where: { $0.id == taskId }) else {
            throw APIError.notFound("Task with ID '\(taskId)' not found")
        }
        
        // Find the file path that matches the filename
        let paths = isInput ? task.attachedFilePaths : (task.outputFilePaths ?? [])
        
        guard let filePath = paths.first(where: { URL(fileURLWithPath: $0).lastPathComponent == filename }) else {
            throw APIError.notFound("File '\(filename)' not found in task")
        }
        
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw APIError.notFound("File '\(filename)' no longer exists at expected location")
        }
        
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        let mimeType = APIFile.mimeType(for: filename)
        
        return (data, mimeType)
    }
    
    // MARK: - Schedule Operations
    
    func getScheduledTasks(limit: Int, offset: Int) async throws -> APIScheduledTaskListResponse {
        var schedules = schedulerService.scheduledTasks
        
        // Sort by nextRunAt (ascending - earliest first)
        schedules.sort { ($0.nextRunAt ?? Date.distantFuture) < ($1.nextRunAt ?? Date.distantFuture) }
        
        let total = schedules.count
        
        // Apply pagination
        let startIndex = min(offset, schedules.count)
        let endIndex = min(offset + limit, schedules.count)
        let paginatedSchedules = Array(schedules[startIndex..<endIndex])
        
        return APIScheduledTaskListResponse(
            schedules: paginatedSchedules.map { convertToAPIScheduledTask($0) },
            total: total,
            limit: limit,
            offset: offset
        )
    }
    
    func getScheduledTask(id: String) async throws -> APIScheduledTask {
        guard let schedule = schedulerService.scheduledTasks.first(where: { $0.id == id }) else {
            throw APIError.notFound("Scheduled task with ID '\(id)' not found")
        }
        return convertToAPIScheduledTask(schedule)
    }
    
    func createScheduledTask(
        title: String,
        description: String,
        providerName: String,
        modelId: String,
        attachedFilePaths: [String],
        outputDirectory: String?,
        schedule: APISchedule
    ) async throws -> APIScheduledTask {
        // Find provider by name
        let providerId = try await findProviderIdByName(providerName)
        
        // Determine schedule type and configuration
        let scheduleType: ScheduleType
        var scheduledDate: Date? = nil
        var recurrenceRule: RecurrenceRule? = nil
        
        if let recurrence = schedule.recurrence {
            // Recurring schedule
            scheduleType = .recurring
            recurrenceRule = convertFromAPIRecurrence(recurrence)
        } else if let scheduledAt = schedule.scheduledAt {
            // One-time schedule
            scheduleType = .oneTime
            scheduledDate = scheduledAt
        } else {
            throw APIError.badRequest("Schedule must include either scheduledAt (one-time) or recurrence (recurring)")
        }
        
        // Create the scheduled task
        let scheduledTask = try schedulerService.createScheduledTask(
            title: title,
            taskDescription: description,
            providerId: providerId,
            modelId: modelId,
            attachedFilePaths: attachedFilePaths,
            outputDirectory: outputDirectory,
            scheduleType: scheduleType,
            scheduledDate: scheduledDate,
            recurrenceRule: recurrenceRule
        )
        
        return convertToAPIScheduledTask(scheduledTask)
    }
    
    func updateScheduledTask(id: String, request: UpdateScheduleRequest) async throws -> APIScheduledTask {
        guard let schedule = schedulerService.scheduledTasks.first(where: { $0.id == id }) else {
            throw APIError.notFound("Scheduled task with ID '\(id)' not found")
        }
        
        // Determine updated schedule type and configuration
        var scheduleType: ScheduleType? = nil
        var scheduledDate: Date? = nil
        var recurrenceRule: RecurrenceRule? = nil
        
        if let recurrence = request.recurrence {
            scheduleType = .recurring
            recurrenceRule = convertFromAPIRecurrence(recurrence)
        } else if let scheduledAt = request.scheduledAt {
            scheduleType = .oneTime
            scheduledDate = scheduledAt
        }
        
        try schedulerService.updateScheduledTask(
            schedule,
            title: request.title,
            taskDescription: request.description,
            scheduleType: scheduleType,
            scheduledDate: scheduledDate,
            recurrenceRule: recurrenceRule,
            isEnabled: request.isEnabled
        )
        
        return convertToAPIScheduledTask(schedule)
    }
    
    func deleteScheduledTask(id: String) async throws {
        guard let schedule = schedulerService.scheduledTasks.first(where: { $0.id == id }) else {
            throw APIError.notFound("Scheduled task with ID '\(id)' not found")
        }
        
        try schedulerService.deleteScheduledTask(schedule)
    }
    
    func runScheduledTaskNow(id: String) async throws -> APITask {
        guard let schedule = schedulerService.scheduledTasks.first(where: { $0.id == id }) else {
            throw APIError.notFound("Scheduled task with ID '\(id)' not found")
        }
        
        // Run the scheduled task immediately
        await schedulerService.runNow(schedule)
        
        // Find the task that was just created (most recent task with matching description)
        if let task = taskService.tasks.first(where: { $0.taskDescription == schedule.taskDescription }) {
            return convertToAPITask(task)
        }
        
        throw APIError.internalError("Failed to find created task")
    }
    
    // MARK: - Provider Operations
    
    func getProviders() async throws -> APIProviderListResponse {
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        let providers = try modelContext.fetch(descriptor)
        
        return APIProviderListResponse(
            providers: providers.map { convertToAPIProviderSummary($0) }
        )
    }
    
    func getProvider(id: String) async throws -> APIProvider {
        let descriptor = FetchDescriptor<LLMProviderRecord>(
            predicate: #Predicate { $0.id == id }
        )
        guard let provider = try modelContext.fetch(descriptor).first else {
            throw APIError.notFound("Provider with ID '\(id)' not found")
        }
        return convertToAPIProvider(provider)
    }
    
    func getProviderByName(name: String) async throws -> APIProvider {
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        let providers = try modelContext.fetch(descriptor)
        guard let provider = providers.first(where: { $0.displayName.lowercased() == name.lowercased() }) else {
            throw APIError.notFound("Provider with name '\(name)' not found")
        }
        return convertToAPIProvider(provider)
    }
    
    func getProviderModels(id: String) async throws -> APIModelListResponse {
        let descriptor = FetchDescriptor<LLMProviderRecord>(
            predicate: #Predicate { $0.id == id }
        )
        guard let provider = try modelContext.fetch(descriptor).first else {
            throw APIError.notFound("Provider with ID '\(id)' not found")
        }
        
        // Fetch models from the provider's API
        guard let apiKey = provider.retrieveAPIKey() else {
            throw APIError.badRequest("Provider has no API key configured")
        }
        
        do {
            let models = try await fetchModelsFromProvider(
                baseURL: provider.effectiveBaseURL,
                apiKey: apiKey
            )
            return APIModelListResponse(models: models)
        } catch {
            throw APIError.badGateway("Failed to fetch models from provider: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Template Operations
    
    func getTemplates() async throws -> APITemplateListResponse {
        let templates = try await vmServiceClient.listTemplates()
        let defaultId = UserDefaults.standard.string(forKey: "defaultTemplateId")
        
        return APITemplateListResponse(
            templates: templates.map { convertToAPITemplateSummary($0, defaultId: defaultId) },
            defaultTemplateId: defaultId
        )
    }
    
    func getTemplate(id: String) async throws -> APITemplate {
        let templates = try await vmServiceClient.listTemplates()
        guard let template = templates.first(where: { $0.id == id }) else {
            throw APIError.notFound("Template with ID '\(id)' not found")
        }
        
        let defaultId = UserDefaults.standard.string(forKey: "defaultTemplateId")
        return convertToAPITemplate(template, defaultId: defaultId)
    }
    
    // MARK: - Skill Operations
    
    func getSkills() async throws -> [APISkill] {
        let skills = taskService.skillManager.skills
        return skills.map { skill in
            APISkill(
                name: skill.name,
                description: skill.description,
                isEnabled: skill.isEnabled
            )
        }
    }
    
    // MARK: - Provisioning Operations
    
    func getProvisioning() async throws -> APIProvisioningResponse {
        let config = VMProvisioningService.shared.config
        
        let envVars = config.environmentVariables
            .filter { !$0.key.isEmpty }
            .map { APIEnvironmentVariable(key: $0.key) }
        
        let files = config.fileInjections
            .map { APIInjectedFile(fileName: $0.resolvedFileName, guestPath: $0.guestPath) }
        
        return APIProvisioningResponse(
            environmentVariables: envVars,
            injectedFiles: files
        )
    }
    
    // MARK: - System Operations
    
    func getSystemStatus() async throws -> APISystemStatus {
        let running = taskService.runningAgents.count
        let paused = taskService.tasks.filter { $0.status == .paused }.count
        let queued = taskService.queuedTasks.count
        let maxConcurrent = UserDefaults.standard.integer(forKey: "maxConcurrentVMs")
        let effectiveMax = maxConcurrent > 0 ? maxConcurrent : 2
        
        let pending = taskService.pendingVMCount
        let available = max(0, effectiveMax - running - pending)
        
        // Get memory info
        let memoryUsedGB: Double? = nil
        var memoryTotalGB: Double? = nil
        
        let processInfo = ProcessInfo.processInfo
        memoryTotalGB = Double(processInfo.physicalMemory) / (1024 * 1024 * 1024)
        
        // Get uptime
        let uptime = Int(Date().timeIntervalSince(appStartTime))
        
        // Get version from bundle
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        
        return APISystemStatus(
            status: "healthy",
            version: version,
            uptime: uptime,
            agents: APIAgentCounts(
                running: running,
                paused: paused,
                queued: queued,
                maxConcurrent: effectiveMax
            ),
            vms: APIVMCounts(
                active: running,
                pending: pending,
                available: available
            ),
            resources: APIResourceUsage(
                cpuUsage: nil,
                memoryUsedGB: memoryUsedGB,
                memoryTotalGB: memoryTotalGB
            )
        )
    }
    
    func getSystemConfig() async throws -> APISystemConfig {
        let defaults = UserDefaults.standard
        
        let maxConcurrent = defaults.integer(forKey: "maxConcurrentVMs")
        let timeout = defaults.integer(forKey: "defaultTaskTimeoutMinutes")
        let maxIterations = defaults.integer(forKey: "defaultMaxIterations")
        let defaultTemplate = defaults.string(forKey: "defaultTemplateId")
        let apiPort = defaults.integer(forKey: "apiServerPort")
        
        return APISystemConfig(
            maxConcurrentVMs: maxConcurrent > 0 ? maxConcurrent : 2,
            defaultTimeoutMinutes: timeout > 0 ? timeout : 30,
            defaultMaxIterations: maxIterations > 0 ? maxIterations : 100,
            defaultTemplateId: defaultTemplate,
            apiPort: apiPort > 0 ? apiPort : 5482
        )
    }
    
    // MARK: - Screenshot
    
    func getTaskScreenshot(id: String) async throws -> (data: Data, mimeType: String)? {
        guard taskService.tasks.contains(where: { $0.id == id }) else {
            throw APIError.notFound("Task with ID '\(id)' not found")
        }
        
        // Look up the running agent's state publisher for this task
        guard let statePublisher = taskService.statePublishers[id],
              let screenshotPath = statePublisher.lastScreenshotPath else {
            return nil
        }
        
        guard FileManager.default.fileExists(atPath: screenshotPath) else {
            return nil
        }
        
        let url = URL(fileURLWithPath: screenshotPath)
        let data = try Data(contentsOf: url)
        let mimeType = APIFile.mimeType(for: url.lastPathComponent)
        
        return (data, mimeType)
    }
    
    // MARK: - Agent Questions
    
    func getPendingQuestion(taskId: String) async throws -> APIAgentQuestion? {
        guard taskService.tasks.contains(where: { $0.id == taskId }) else {
            throw APIError.notFound("Task with ID '\(taskId)' not found")
        }
        
        guard let statePublisher = taskService.statePublishers[taskId],
              let pendingQuestion = statePublisher.pendingQuestion else {
            return nil
        }
        
        return convertToAPIAgentQuestion(pendingQuestion)
    }
    
    func answerQuestion(taskId: String, questionId: String, answer: String) async throws {
        guard taskService.tasks.contains(where: { $0.id == taskId }) else {
            throw APIError.notFound("Task with ID '\(taskId)' not found")
        }
        
        guard let statePublisher = taskService.statePublishers[taskId] else {
            throw APIError.notFound("No active agent for task '\(taskId)'")
        }
        
        guard let pendingQuestion = statePublisher.pendingQuestion else {
            throw APIError.conflict("No pending question for task '\(taskId)'")
        }
        
        guard pendingQuestion.id == questionId else {
            throw APIError.conflict("Question ID '\(questionId)' does not match pending question '\(pendingQuestion.id)'")
        }
        
        statePublisher.provideAnswer(answer)
    }
    
    // MARK: - Agent Permissions
    
    func getPendingPermission(taskId: String) async throws -> APIPermissionRequest? {
        guard taskService.tasks.contains(where: { $0.id == taskId }) else {
            throw APIError.notFound("Task with ID '\(taskId)' not found")
        }
        
        guard let statePublisher = taskService.statePublishers[taskId],
              let pendingPermission = statePublisher.pendingPermissionRequest else {
            return nil
        }
        
        return convertToAPIPermissionRequest(pendingPermission)
    }
    
    func respondToPermission(taskId: String, permissionId: String, approved: Bool) async throws {
        guard taskService.tasks.contains(where: { $0.id == taskId }) else {
            throw APIError.notFound("Task with ID '\(taskId)' not found")
        }
        
        guard let statePublisher = taskService.statePublishers[taskId] else {
            throw APIError.notFound("No active agent for task '\(taskId)'")
        }
        
        guard let pendingPermission = statePublisher.pendingPermissionRequest else {
            throw APIError.conflict("No pending permission request for task '\(taskId)'")
        }
        
        guard pendingPermission.id.uuidString == permissionId else {
            throw APIError.conflict("Permission ID '\(permissionId)' does not match pending permission '\(pendingPermission.id.uuidString)'")
        }
        
        statePublisher.providePermissionResponse(approved)
    }
    
    // MARK: - Activity Polling
    
    func getTaskActivity(id: String, since: Int) async throws -> APIActivityResponse {
        guard taskService.tasks.contains(where: { $0.id == id }) else {
            throw APIError.notFound("Task with ID '\(id)' not found")
        }
        
        guard let statePublisher = taskService.statePublishers[id] else {
            // No active agent — return empty
            return APIActivityResponse(events: [], total: 0)
        }
        
        let log = statePublisher.activityLog
        let total = log.count
        let newEntries = since < total ? Array(log.dropFirst(since)) : []
        let events = newEntries.map { Self.convertActivityEntry($0) }
        
        return APIActivityResponse(events: events, total: total)
    }
    
    // MARK: - Event Streaming
    
    func subscribeToTaskEvents(id: String) async throws -> AsyncStream<APITaskEvent> {
        guard taskService.tasks.contains(where: { $0.id == id }) else {
            throw APIError.notFound("Task with ID '\(id)' not found")
        }
        
        guard taskService.statePublishers[id] != nil else {
            // No active agent — return an empty stream
            return AsyncStream { $0.finish() }
        }
        
        // Snapshot the current activity log on the main actor
        let initialLog = taskService.statePublishers[id]!.activityLog
        let taskId = id
        
        return AsyncStream { continuation in
            // Emit existing activity log entries as initial burst
            for entry in initialLog {
                continuation.yield(Self.convertActivityEntry(entry))
            }
            
            // Poll for new entries from a @MainActor task.
            // This avoids Combine subscription lifecycle issues with @Sendable
            // closures in Swift 6 strict concurrency mode.
            let pollingTask = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                
                var lastSeenCount = initialLog.count
                
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    
                    guard let pub = self.taskService.statePublishers[taskId] else {
                        continuation.finish()
                        return
                    }
                    
                    // Yield any new activity log entries
                    let log = pub.activityLog
                    if log.count > lastSeenCount {
                        for entry in log.dropFirst(lastSeenCount) {
                            continuation.yield(Self.convertActivityEntry(entry))
                        }
                        lastSeenCount = log.count
                    }
                    
                    // Finish on terminal status
                    let status = pub.status
                    if [.completed, .failed, .cancelled].contains(status) {
                        continuation.yield(APITaskEvent(
                            type: .statusChange,
                            timestamp: Date(),
                            data: [
                                "status": .string(status.rawValue),
                                "taskId": .string(taskId)
                            ]
                        ))
                        continuation.finish()
                        return
                    }
                }
            }
            
            continuation.onTermination = { _ in
                pollingTask.cancel()
            }
        }
    }
    
    /// Convert an internal AgentActivityEntry to an API event.
    /// Static so it can be called from non-isolated Combine sink closures.
    private static func convertActivityEntry(_ entry: AgentActivityEntry) -> APITaskEvent {
        let eventType: APITaskEventType
        switch entry.type {
        case .toolCall:
            eventType = .toolCallStart
        case .toolResult:
            eventType = .toolCallResult
        case .llmRequest, .llmResponse:
            eventType = .llmResponse
        case .observation:
            eventType = .screenshot
        case .userQuestion:
            eventType = .question
        case .subagent:
            eventType = .subagentUpdate
        case .error, .info, .userAnswer:
            eventType = .statusChange
        }
        
        var data: [String: JSONValue] = [
            "summary": .string(entry.summary)
        ]
        if let details = entry.details {
            data["details"] = .string(details)
        }
        if let reasoning = entry.reasoning {
            data["reasoning"] = .string(reasoning)
        }
        if let subagentId = entry.subagentId {
            data["subagentId"] = .string(subagentId)
        }
        data["activityType"] = .string(entry.type.rawValue)
        
        return APITaskEvent(
            type: eventType,
            timestamp: entry.timestamp,
            data: data
        )
    }
    
    // MARK: - Private Helpers
    
    private func findProviderIdByName(_ name: String) async throws -> String {
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        let providers = try modelContext.fetch(descriptor)
        guard let provider = providers.first(where: { $0.displayName.lowercased() == name.lowercased() }) else {
            throw APIError.notFound("Provider with name '\(name)' not found")
        }
        return provider.id
    }
}

