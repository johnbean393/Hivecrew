//
//  APIContext.swift
//  HivecrewAPI
//
//  Request context and service provider protocol for API routes
//

import Foundation
import Hummingbird
import NIOCore

// MARK: - Service Provider Protocol

/// Abstraction layer between the API routes and the main application.
///
/// The host app supplies a concrete implementation of this protocol when
/// creating the ``HivecrewAPIServer``. All methods are `async throws` and
/// follow a consistent naming convention:
///
/// - **create…** / **get…** / **delete…** for CRUD operations.
/// - **perform…** for side-effect actions.
/// - **subscribe…** for streaming.
///
/// Methods that accept an `id` parameter always use the label `id`.
public protocol APIServiceProvider: Sendable {
    
    // MARK: - Task Operations
    
    /// Create a new task from a description and provider/model selection.
    func createTask(
        description: String,
        providerName: String,
        modelId: String,
        attachedFilePaths: [String],
        outputDirectory: String?,
        planFirst: Bool,
        mentionedSkillNames: [String]
    ) async throws -> APITask
    
    /// List tasks with optional status filtering, pagination, and sorting.
    func getTasks(
        status: [APITaskStatus]?,
        limit: Int,
        offset: Int,
        sortBy: String,
        order: String
    ) async throws -> APITaskListResponse
    
    /// Retrieve a single task by its unique identifier.
    func getTask(id: String) async throws -> APITask
    
    /// Perform a lifecycle action on a task (cancel, pause, resume, plan review, etc.).
    func performTaskAction(id: String, action: APITaskAction, instructions: String?) async throws -> APITask
    
    /// Permanently delete a task by its unique identifier.
    func deleteTask(id: String) async throws
    
    /// Retrieve file metadata for a task's input and output files.
    func getTaskFiles(id: String) async throws -> APITaskFilesResponse
    
    /// Download raw file data for a specific task file.
    func getTaskFileData(taskId: String, filename: String, isInput: Bool) async throws -> (data: Data, mimeType: String)
    
    /// Retrieve the latest VM screenshot for a running task.
    ///
    /// Returns the raw image data and its MIME type, or `nil` if no
    /// screenshot is currently available (e.g. task is not running).
    func getTaskScreenshot(id: String) async throws -> (data: Data, mimeType: String)?
    
    /// Retrieve the pending question for a task, if any.
    ///
    /// Returns the current ``APIAgentQuestion`` awaiting a human answer,
    /// or `nil` if the agent has no outstanding question.
    func getPendingQuestion(taskId: String) async throws -> APIAgentQuestion?
    
    /// Submit an answer to a pending agent question.
    ///
    /// - Parameters:
    ///   - taskId: The task whose agent asked the question.
    ///   - questionId: The unique identifier of the question being answered.
    ///   - answer: The human-provided answer text.
    func answerQuestion(taskId: String, questionId: String, answer: String) async throws
    
    /// Retrieve the pending permission request for a task, if any.
    ///
    /// Returns the current ``APIPermissionRequest`` awaiting approval,
    /// or `nil` if the agent has no outstanding permission request.
    func getPendingPermission(taskId: String) async throws -> APIPermissionRequest?
    
    /// Respond to a pending agent permission request.
    ///
    /// - Parameters:
    ///   - taskId: The task whose agent requested permission.
    ///   - permissionId: The unique identifier of the permission request.
    ///   - approved: Whether the operation is approved (`true`) or denied (`false`).
    func respondToPermission(taskId: String, permissionId: String, approved: Bool) async throws
    
    // MARK: - Schedule Operations
    
    /// List scheduled tasks with pagination.
    func getScheduledTasks(limit: Int, offset: Int) async throws -> APIScheduledTaskListResponse
    
    /// Retrieve a single scheduled task by its unique identifier.
    func getScheduledTask(id: String) async throws -> APIScheduledTask
    
    /// Create a new scheduled (one-time or recurring) task.
    func createScheduledTask(
        title: String,
        description: String,
        providerName: String,
        modelId: String,
        attachedFilePaths: [String],
        outputDirectory: String?,
        schedule: APISchedule
    ) async throws -> APIScheduledTask
    
    /// Update a scheduled task's configuration, title, or enabled state.
    func updateScheduledTask(id: String, request: UpdateScheduleRequest) async throws -> APIScheduledTask
    
    /// Permanently delete a scheduled task.
    func deleteScheduledTask(id: String) async throws
    
    /// Trigger an immediate execution of a scheduled task.
    func runScheduledTaskNow(id: String) async throws -> APITask
    
    // MARK: - Provider Operations
    
    /// List all registered AI providers.
    func getProviders() async throws -> APIProviderListResponse
    
    /// Retrieve a single provider by its unique identifier.
    func getProvider(id: String) async throws -> APIProvider
    
    /// Retrieve a single provider by its display name.
    func getProviderByName(name: String) async throws -> APIProvider
    
    /// List available models for a given provider.
    func getProviderModels(id: String) async throws -> APIModelListResponse
    
    // MARK: - Template Operations
    
    /// List all task templates.
    func getTemplates() async throws -> APITemplateListResponse
    
    /// Retrieve a single template by its unique identifier.
    func getTemplate(id: String) async throws -> APITemplate
    
    // MARK: - Skill Operations
    
    /// List all available skills.
    func getSkills() async throws -> [APISkill]
    
    // MARK: - Provisioning Operations
    
    /// Retrieve VM provisioning configuration (environment variables and injected files).
    ///
    /// Environment variable values are intentionally omitted from the response
    /// because they typically contain sensitive information (API keys, tokens, etc.).
    func getProvisioning() async throws -> APIProvisioningResponse
    
    // MARK: - System Operations
    
    /// Retrieve current system status (running agents, queued tasks, VM counts, etc.).
    func getSystemStatus() async throws -> APISystemStatus
    
    /// Retrieve system configuration values.
    func getSystemConfig() async throws -> APISystemConfig
    
    // MARK: - Event Streaming
    
    /// Subscribe to real-time task events via Server-Sent Events.
    ///
    /// Returns an `AsyncStream` that yields ``APITaskEvent`` values as the
    /// task progresses. The stream finishes when the task completes, fails,
    /// or is cancelled.
    func subscribeToTaskEvents(id: String) async throws -> AsyncStream<APITaskEvent>
    
    /// Get task activity events since a given offset (for polling).
    ///
    /// Returns events from the task's activity log starting from `since`.
    /// The `total` count in the response lets the client track its position.
    func getTaskActivity(id: String, since: Int) async throws -> APIActivityResponse
}

// MARK: - Request Context

/// Hummingbird request context used by all API routes.
public struct APIRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    
    public init(source: Source) {
        self.coreContext = .init(source: source)
    }
}
