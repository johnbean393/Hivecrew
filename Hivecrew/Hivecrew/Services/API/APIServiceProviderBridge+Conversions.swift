//
//  APIServiceProviderBridge+Conversions.swift
//  Hivecrew
//
//  Conversion methods for APIServiceProviderBridge
//

import Foundation
import SwiftData
import HivecrewAPI
import HivecrewShared

// MARK: - Status Conversions

extension APIServiceProviderBridge {
    
    func convertFromAPIStatus(_ status: APITaskStatus) -> TaskStatus {
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
    
    func convertToAPIStatus(_ status: TaskStatus) -> APITaskStatus {
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
}

// MARK: - Task Conversions

extension APIServiceProviderBridge {
    
    func convertToAPITask(_ task: TaskRecord) -> APITask {
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
    
    func convertToAPITaskSummary(_ task: TaskRecord) -> APITaskSummary {
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
    
    func getProviderName(for providerId: String) -> String {
        let descriptor = FetchDescriptor<LLMProviderRecord>(
            predicate: #Predicate { $0.id == providerId }
        )
        if let provider = try? modelContext.fetch(descriptor).first {
            return provider.displayName
        }
        return "Unknown"
    }
    
    func getInputFiles(for task: TaskRecord) -> [APIFile] {
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
    
    func getOutputFiles(for task: TaskRecord) -> [APIFile] {
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
}

// MARK: - Provider Conversions

extension APIServiceProviderBridge {
    
    func convertToAPIProviderSummary(_ provider: LLMProviderRecord) -> APIProviderSummary {
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
    
    func convertToAPIProvider(_ provider: LLMProviderRecord) -> APIProvider {
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
}

// MARK: - Template Conversions

extension APIServiceProviderBridge {
    
    func convertToAPITemplateSummary(_ template: TemplateInfo, defaultId: String?) -> APITemplateSummary {
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
    
    func convertToAPITemplate(_ template: TemplateInfo, defaultId: String?) -> APITemplate {
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
}

// MARK: - Schedule Conversions

extension APIServiceProviderBridge {
    
    /// Convert ScheduledTask to APIScheduledTask
    func convertToAPIScheduledTask(_ schedule: ScheduledTask) -> APIScheduledTask {
        let providerName = getProviderName(for: schedule.providerId)
        
        // Convert recurrence rule if present
        var recurrence: APIRecurrence? = nil
        if let rule = schedule.recurrenceRule {
            recurrence = convertToAPIRecurrence(rule)
        }
        
        // Get input files metadata
        let inputFiles = getInputFilesForSchedule(schedule)
        
        return APIScheduledTask(
            id: schedule.id,
            title: schedule.title,
            description: schedule.taskDescription,
            providerName: providerName,
            modelId: schedule.modelId,
            isEnabled: schedule.isEnabled,
            scheduleType: schedule.scheduleType.displayName.lowercased(),
            scheduledAt: schedule.scheduledDate,
            recurrence: recurrence,
            nextRunAt: schedule.nextRunAt,
            lastRunAt: schedule.lastRunAt,
            createdAt: schedule.createdAt,
            inputFiles: inputFiles,
            inputFileCount: inputFiles.count
        )
    }
    
    /// Get input files metadata for a scheduled task
    func getInputFilesForSchedule(_ schedule: ScheduledTask) -> [APIFile] {
        return schedule.attachedFilePaths.map { path in
            let url = URL(fileURLWithPath: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            let mimeType = APIFile.mimeType(for: url.lastPathComponent)
            return APIFile(name: url.lastPathComponent, size: size, mimeType: mimeType)
        }
    }
    
    /// Convert RecurrenceRule to APIRecurrence
    func convertToAPIRecurrence(_ rule: RecurrenceRule) -> APIRecurrence {
        let type: APIRecurrenceType
        switch rule.frequency {
        case .daily: type = .daily
        case .weekly: type = .weekly
        case .monthly: type = .monthly
        }
        
        // Convert daysOfWeek from Set to Array if present
        let daysArray: [Int]? = rule.daysOfWeek.map { Array($0).sorted() }
        
        return APIRecurrence(
            type: type,
            daysOfWeek: daysArray,
            dayOfMonth: rule.dayOfMonth,
            hour: rule.hour,
            minute: rule.minute
        )
    }
    
    /// Convert APIRecurrence to RecurrenceRule
    func convertFromAPIRecurrence(_ recurrence: APIRecurrence) -> RecurrenceRule {
        let frequency: RecurrenceFrequency
        switch recurrence.type {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        }
        
        // Convert daysOfWeek from Array to Set if present
        let daysSet: Set<Int>? = recurrence.daysOfWeek.map { Set($0) }
        
        return RecurrenceRule(
            frequency: frequency,
            daysOfWeek: daysSet,
            dayOfMonth: recurrence.dayOfMonth,
            hour: recurrence.hour,
            minute: recurrence.minute
        )
    }
}

// MARK: - Model Fetching

extension APIServiceProviderBridge {
    
    func fetchModelsFromProvider(baseURL: URL, apiKey: String) async throws -> [APIModel] {
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
                name: model.id,
                contextLength: model.context_length
            )
        }
    }
}
