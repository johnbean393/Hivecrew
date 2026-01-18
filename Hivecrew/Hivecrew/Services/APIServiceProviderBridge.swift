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
    
    private let taskService: TaskService
    private let vmServiceClient: VMServiceClient
    private let modelContext: ModelContext
    private let fileStorage: TaskFileStorage
    
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
    
    private func convertFromAPIStatus(_ status: APITaskStatus) -> TaskStatus {
        switch status {
        case .queued: return .queued
        case .waitingForVM: return .waitingForVM
        case .running: return .running
        case .paused: return .paused
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .maxIterations: return .maxIterations
        }
    }
    
    private func convertToAPIStatus(_ status: TaskStatus) -> APITaskStatus {
        switch status {
        case .queued: return .queued
        case .waitingForVM: return .waitingForVM
        case .running: return .running
        case .paused: return .paused
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .maxIterations: return .maxIterations
        }
    }
    
    private func convertToAPITask(_ task: TaskRecord) -> APITask {
        // Get provider name
        let providerName = getProviderName(for: task.providerId)
        
        // Get input and output files
        let inputFiles = getInputFiles(for: task)
        let outputFiles = getOutputFiles(for: task)
        
        // Get token usage from session if available
        var tokenUsage: APITokenUsage? = nil
        if let sessionId = task.sessionId,
           let publisher = taskService.statePublishers[task.id] {
            tokenUsage = APITokenUsage(
                prompt: publisher.promptTokens,
                completion: publisher.completionTokens,
                total: publisher.totalTokens
            )
        }
        
        return APITask(
            id: task.id,
            title: task.title,
            description: task.taskDescription,
            status: convertToAPIStatus(task.status),
            providerName: providerName,
            modelId: task.modelId,
            createdAt: task.createdAt,
            startedAt: task.startedAt,
            completedAt: task.completedAt,
            resultSummary: task.resultSummary,
            errorMessage: task.errorMessage,
            inputFiles: inputFiles,
            outputFiles: outputFiles,
            wasSuccessful: task.wasSuccessful,
            vmId: task.assignedVMId,
            duration: task.startedAt.map { Int(Date().timeIntervalSince($0)) },
            stepCount: taskService.statePublishers[task.id]?.currentStep,
            tokenUsage: tokenUsage
        )
    }
    
    private func convertToAPITaskSummary(_ task: TaskRecord) -> APITaskSummary {
        let providerName = getProviderName(for: task.providerId)
        
        return APITaskSummary(
            id: task.id,
            title: task.title,
            status: convertToAPIStatus(task.status),
            providerName: providerName,
            modelId: task.modelId,
            createdAt: task.createdAt,
            startedAt: task.startedAt,
            completedAt: task.completedAt,
            inputFileCount: task.attachedFilePaths.count,
            outputFileCount: task.outputFilePaths?.count ?? 0
        )
    }
    
    private func getProviderName(for providerId: String) -> String {
        let descriptor = FetchDescriptor<LLMProviderRecord>(
            predicate: #Predicate { $0.id == providerId }
        )
        if let provider = try? modelContext.fetch(descriptor).first {
            return provider.displayName
        }
        return "Unknown"
    }
    
    private func getInputFiles(for task: TaskRecord) -> [APIFile] {
        return task.attachedFilePaths.map { path in
            let url = URL(fileURLWithPath: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return APIFile(
                name: url.lastPathComponent,
                size: size,
                mimeType: APIFile.mimeType(for: url.lastPathComponent)
            )
        }
    }
    
    private func getOutputFiles(for task: TaskRecord) -> [APIFile] {
        guard let outputPaths = task.outputFilePaths else { return [] }
        return outputPaths.map { path in
            let url = URL(fileURLWithPath: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return APIFile(
                name: url.lastPathComponent,
                size: size,
                mimeType: APIFile.mimeType(for: url.lastPathComponent)
            )
        }
    }
    
    private func convertToAPIProviderSummary(_ provider: LLMProviderRecord) -> APIProviderSummary {
        return APIProviderSummary(
            id: provider.id,
            displayName: provider.displayName,
            baseURL: provider.effectiveBaseURL.absoluteString,
            isDefault: provider.isDefault,
            hasAPIKey: provider.hasAPIKey,
            createdAt: provider.createdAt,
            lastUsedAt: provider.lastUsedAt
        )
    }
    
    private func convertToAPIProvider(_ provider: LLMProviderRecord) -> APIProvider {
        return APIProvider(
            id: provider.id,
            displayName: provider.displayName,
            baseURL: provider.effectiveBaseURL.absoluteString,
            isDefault: provider.isDefault,
            hasAPIKey: provider.hasAPIKey,
            organizationId: provider.organizationId,
            timeoutInterval: provider.timeoutInterval,
            createdAt: provider.createdAt,
            lastUsedAt: provider.lastUsedAt
        )
    }
    
    private func convertToAPITemplateSummary(_ template: TemplateInfo, defaultId: String?) -> APITemplateSummary {
        return APITemplateSummary(
            id: template.id,
            name: template.name,
            description: template.description,
            isDefault: template.id == defaultId,
            createdAt: nil,
            diskSizeGB: nil,
            cpuCount: template.cpuCount,
            memoryGB: nil
        )
    }
    
    private func convertToAPITemplate(_ template: TemplateInfo, defaultId: String?) -> APITemplate {
        // Get the bundle path using AppPaths
        let bundlePath = AppPaths.templateBundlePath(id: template.id)
        
        return APITemplate(
            id: template.id,
            name: template.name,
            description: template.description,
            isDefault: template.id == defaultId,
            createdAt: nil,
            diskSizeGB: nil,
            cpuCount: template.cpuCount,
            memoryGB: nil,
            macOSVersion: nil,
            path: bundlePath.path
        )
    }
    
    private func fetchModelsFromProvider(baseURL: URL, apiKey: String) async throws -> [APIModel] {
        let modelsURL = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: modelsURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "HivecrewAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models"])
        }
        
        struct ModelsResponse: Decodable {
            let data: [ModelData]
        }
        
        struct ModelData: Decodable {
            let id: String
            let context_length: Int?
        }
        
        let decoder = JSONDecoder()
        let modelsResponse = try decoder.decode(ModelsResponse.self, from: data)
        
        return modelsResponse.data.map { model in
            APIModel(
                id: model.id,
                name: model.id, // Use ID as name if no separate name field
                contextLength: model.context_length
            )
        }
    }
}
