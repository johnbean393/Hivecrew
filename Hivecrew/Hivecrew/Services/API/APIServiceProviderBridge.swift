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
    let vmServiceClient: VMServiceClient
    let modelContext: ModelContext
    let fileStorage: TaskFileStorage
    
    /// App start time for uptime calculation
    private let appStartTime = Date()
    
    init(
        taskService: TaskService,
        vmServiceClient: VMServiceClient,
        modelContext: ModelContext,
        fileStorage: TaskFileStorage
    ) {
        self.taskService = taskService
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
        outputDirectory: String?
    ) async throws -> APITask {
        // Find provider by name
        let providerId = try await findProviderIdByName(providerName)
        
        // Create the task using TaskService
        let task = try await taskService.createTask(
            description: description,
            providerId: providerId,
            modelId: modelId,
            attachedFilePaths: attachedFilePaths,
            outputDirectory: outputDirectory
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
        guard taskService.tasks.contains(where: { $0.id == id }) else {
            throw APIError.notFound("Task with ID '\(id)' not found")
        }
        
        let inputFiles = try await fileStorage.getUploadedFiles(for: id)
        let outputFiles = try await fileStorage.getOutputFiles(for: id)
        
        return APITaskFilesResponse(
            taskId: id,
            inputFiles: inputFiles,
            outputFiles: outputFiles
        )
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
        var memoryUsedGB: Double? = nil
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
