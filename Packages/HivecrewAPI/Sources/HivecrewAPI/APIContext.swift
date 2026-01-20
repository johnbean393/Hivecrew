//
//  APIContext.swift
//  HivecrewAPI
//
//  Request context and service container for API routes
//

import Foundation
import Hummingbird
import NIOCore

/// Protocol for accessing services from the main app
/// The main app will provide an implementation of this protocol
public protocol APIServiceProvider: Sendable {
    
    // MARK: - Task Operations
    
    /// Create a new task
    func createTask(
        description: String,
        providerName: String,
        modelId: String,
        attachedFilePaths: [String],
        outputDirectory: String?
    ) async throws -> APITask
    
    /// Get all tasks with optional filtering
    func getTasks(
        status: [APITaskStatus]?,
        limit: Int,
        offset: Int,
        sortBy: String,
        order: String
    ) async throws -> APITaskListResponse
    
    /// Get a task by ID
    func getTask(id: String) async throws -> APITask
    
    /// Perform an action on a task
    func performTaskAction(id: String, action: APITaskAction, instructions: String?) async throws -> APITask
    
    /// Delete a task
    func deleteTask(id: String) async throws
    
    /// Get files for a task
    func getTaskFiles(id: String) async throws -> APITaskFilesResponse
    
    /// Get file data for download (serves from actual file paths stored in task)
    func getTaskFileData(taskId: String, filename: String, isInput: Bool) async throws -> (data: Data, mimeType: String)
    
    // MARK: - Schedule Operations
    
    /// Get scheduled tasks
    func getScheduledTasks(limit: Int, offset: Int) async throws -> APIScheduledTaskListResponse
    
    /// Get a scheduled task by ID
    func getScheduledTask(id: String) async throws -> APIScheduledTask
    
    /// Create a scheduled task
    func createScheduledTask(
        title: String,
        description: String,
        providerName: String,
        modelId: String,
        attachedFilePaths: [String],
        outputDirectory: String?,
        schedule: APISchedule
    ) async throws -> APIScheduledTask
    
    /// Update a scheduled task
    func updateScheduledTask(id: String, request: UpdateScheduleRequest) async throws -> APIScheduledTask
    
    /// Delete a scheduled task
    func deleteScheduledTask(id: String) async throws
    
    /// Run a scheduled task immediately
    func runScheduledTaskNow(id: String) async throws -> APITask
    
    // MARK: - Provider Operations
    
    /// Get all providers
    func getProviders() async throws -> APIProviderListResponse
    
    /// Get a provider by ID
    func getProvider(id: String) async throws -> APIProvider
    
    /// Get a provider by name
    func getProviderByName(name: String) async throws -> APIProvider
    
    /// Get models for a provider
    func getProviderModels(id: String) async throws -> APIModelListResponse
    
    // MARK: - Template Operations
    
    /// Get all templates
    func getTemplates() async throws -> APITemplateListResponse
    
    /// Get a template by ID
    func getTemplate(id: String) async throws -> APITemplate
    
    // MARK: - System Operations
    
    /// Get system status
    func getSystemStatus() async throws -> APISystemStatus
    
    /// Get system configuration
    func getSystemConfig() async throws -> APISystemConfig
}

/// Request context for Hummingbird
public struct APIRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    
    public init(source: Source) {
        self.coreContext = .init(source: source)
    }
}
